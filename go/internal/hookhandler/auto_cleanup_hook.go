package hookhandler

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// AutoCleanupHandler は PostToolUse フックハンドラ（自動サイズチェック）。
// Write/Edit ツールで書き込まれたファイルのサイズ（行数）をチェックし、
// Plans.md / session-log.md / CLAUDE.md が閾値を超えた場合に systemMessage で警告する。
//
// shell 版: scripts/auto-cleanup-hook.sh
type AutoCleanupHandler struct {
	// ProjectRoot はプロジェクトルートのパス。空の場合は cwd を使用する。
	ProjectRoot string

	// 閾値（0 の場合はデフォルト値を使用）
	PlansMaxLines      int
	SessionLogMaxLines int
	ClaudeMdMaxLines   int
}

const (
	defaultPlansMaxLines      = 200
	defaultSessionLogMaxLines = 600
	defaultClaudeMdMaxLines   = 100
)

// autoCleanupInput は PostToolUse フックの stdin JSON。
type autoCleanupInput struct {
	ToolInput    autoCleanupToolInput    `json:"tool_input"`
	ToolResponse autoCleanupToolResponse `json:"tool_response"`
	CWD          string                  `json:"cwd"`
}

type autoCleanupToolInput struct {
	FilePath string `json:"file_path"`
}

type autoCleanupToolResponse struct {
	FilePath string `json:"filePath"`
}

// Handle は stdin から PostToolUse ペイロードを読み取り、ファイルサイズをチェックする。
func (h *AutoCleanupHandler) Handle(r io.Reader, w io.Writer) error {
	data, _ := io.ReadAll(r)

	if len(data) == 0 {
		return nil
	}

	var inp autoCleanupInput
	if err := json.Unmarshal(data, &inp); err != nil {
		return nil
	}

	filePath := inp.ToolInput.FilePath
	if filePath == "" {
		filePath = inp.ToolResponse.FilePath
	}
	if filePath == "" {
		return nil
	}

	cwd := inp.CWD
	if cwd == "" {
		if h.ProjectRoot != "" {
			cwd = h.ProjectRoot
		} else {
			cwd, _ = os.Getwd()
		}
	}

	// プロジェクト相対パスへ正規化
	if strings.HasPrefix(filePath, cwd+"/") {
		filePath = filePath[len(cwd)+1:]
	}

	// 閾値を決定
	plansMax := h.PlansMaxLines
	if plansMax == 0 {
		plansMax = h.envInt("PLANS_MAX_LINES", defaultPlansMaxLines)
	}
	sessionMax := h.SessionLogMaxLines
	if sessionMax == 0 {
		sessionMax = h.envInt("SESSION_LOG_MAX_LINES", defaultSessionLogMaxLines)
	}
	claudeMax := h.ClaudeMdMaxLines
	if claudeMax == 0 {
		claudeMax = h.envInt("CLAUDE_MD_MAX_LINES", defaultClaudeMdMaxLines)
	}

	// 絶対パスを解決（ファイルの存在確認に使う）
	absPath := filePath
	if !filepath.IsAbs(absPath) {
		absPath = filepath.Join(cwd, filePath)
	}

	feedback := h.checkFile(filePath, absPath, plansMax, sessionMax, claudeMax, cwd, resolveHarnessLocale(cwd))
	if feedback == "" {
		return nil
	}

	return writeCleanupOutput(w, feedback)
}

// checkFile はファイルを判別してサイズチェックを行い、フィードバック文字列を返す。
func (h *AutoCleanupHandler) checkFile(relPath, absPath string, plansMax, sessionMax, claudeMax int, cwd, locale string) string {
	lower := strings.ToLower(relPath)
	var feedback string

	switch {
	case strings.Contains(lower, "plans.md"):
		feedback = h.checkPlans(absPath, plansMax, cwd, locale)
	case strings.Contains(lower, "session-log.md"):
		feedback = h.checkSessionLog(absPath, sessionMax, locale)
	case strings.Contains(lower, "claude.md"):
		feedback = h.checkClaudeMd(absPath, claudeMax, locale)
	}

	return feedback
}

// checkPlans は Plans.md の行数をチェックし、アーカイブ検知も行う。
func (h *AutoCleanupHandler) checkPlans(absPath string, maxLines int, cwd, locale string) string {
	lines, err := countLines(absPath)
	if err != nil {
		return ""
	}

	var feedback string
	if lines > maxLines {
		feedback = localizedHarnessMessage(locale,
			fmt.Sprintf("Warning: Plans.md has %d lines (limit: %d). Consider archiving old tasks with /maintenance.", lines, maxLines),
			fmt.Sprintf("⚠️ Plans.md が %d 行です（上限: %d行）。/maintenance で古いタスクをアーカイブすることを推奨します。", lines, maxLines))
	}

	// アーカイブセクション検知 + SSOT フラグチェック
	if containsArchiveSection(absPath) {
		// リポジトリルートの stateDir を使用
		repoRoot := cwd
		if root, err := gitRepoRoot(cwd); err == nil {
			repoRoot = root
		}
		stateDir := filepath.Join(repoRoot, ".claude", "state")
		ssotFlag := filepath.Join(stateDir, ".ssot-synced-this-session")

		if !fileExists(ssotFlag) {
			ssotWarning := localizedHarnessMessage(locale,
				"**Run /memory sync before cleaning up Plans.md** - important decisions or learnings may not be reflected in the SSOT (decisions.md/patterns.md).",
				"**Plans.md クリーンアップ前に /memory sync を実行してください** - 重要な決定や学習事項が SSOT (decisions.md/patterns.md) に反映されていない可能性があります。")
			if feedback != "" {
				feedback = feedback + localizedHarnessMessage(locale, " | Warning: ", " | ⚠️ ") + ssotWarning
			} else {
				feedback = localizedHarnessMessage(locale, "Warning: ", "⚠️ ") + ssotWarning
			}
		}
	}

	return feedback
}

// sessionLogRetentionDays mirrors the split rule in the maintenance skill:
// only entries older than this may be moved out of session-log.md.
const sessionLogRetentionDays = 30

// sessionLogEntryPattern matches the headers that delimit entries.
//
// Two spellings are accepted on purpose. The writer emits
// `## セッション: <RFC3339>` (go/internal/session/summary.go), which is what
// the live file contains, while the maintenance reference documents
// `## YYYY-MM-DD`. Matching only one of them would make this count zero on the
// other and silence the warning permanently — a worse failure than the
// over-firing it replaces. The optional time suffix is tolerated but not
// captured, and dropping it is deliberate rather than a shortcut. A date-only
// parse lands at 00:00 UTC, so an entry on the boundary day compares as older
// than a mid-day cutoff and is counted as archivable. That errs toward counting
// MORE entries, which makes the warning fire more readily. Keeping the time
// would push borderline entries to "still fresh" and silence it — and a warning
// that goes quiet is the failure mode this whole change exists to avoid
// (measured: three boundary-day entries all count as archivable).
var sessionLogEntryPattern = regexp.MustCompile(`(?m)^##\s+(?:セッション:\s*)?(\d{4}-\d{2}-\d{2})(?:[T\s]\S*)?\s*$`)

// checkSessionLog は session-log.md の行数をチェックする。
//
// 行数超過だけでは警告しない。/maintenance が実際に退避できるのは
// 「直近 sessionLogRetentionDays 日より古いエントリ」だけなので、
// 全エントリが保持期間内なら移動対象はゼロになる。その状態で警告を出すと、
// 従えば保持ルール違反、従わなければ毎回警告という詰みになる。
//
// 実測 (2026-08-14): 688 行 / 上限 600 に対し、27 エントリ全部が 30 日以内で
// 移動対象 0 件。上限を 500 → 600 に上げた数日後に再び超過しており、
// 数字を動かしても不一致が起きる位置がずれるだけだった。
//
// 対処できない警告は無視される警告になり、他の警告の信用を削る
// (patterns.md P43「承認され続ける ask は制御ではない」と同じ構造)。
// よって発火条件そのものを「行数超過 かつ 退避可能なエントリが 1 件以上」に絞る。
func (h *AutoCleanupHandler) checkSessionLog(absPath string, maxLines int, locale string) string {
	lines, err := countLines(absPath)
	if err != nil {
		return ""
	}
	if lines <= maxLines {
		return ""
	}

	archivable, err := countArchivableSessionLogEntries(absPath, time.Now())
	if err != nil {
		// 判定できないときは従来どおり警告する。黙るほうへ倒すと、
		// 解析が壊れた瞬間に警告が消えたことに誰も気づけない。
		archivable = -1
	}
	if archivable == 0 {
		return ""
	}

	return localizedHarnessMessage(locale,
		fmt.Sprintf("Warning: session-log.md has %d lines (limit: %d). Consider splitting it by month with /maintenance.", lines, maxLines),
		fmt.Sprintf("⚠️ session-log.md が %d 行です（上限: %d行）。/maintenance で月別に分割することを推奨します。", lines, maxLines))
}

// countArchivableSessionLogEntries returns how many entries are old enough to
// be moved out. A header whose date cannot be parsed is counted as archivable:
// treating it as fresh would suppress the warning on malformed input.
func countArchivableSessionLogEntries(absPath string, now time.Time) (int, error) {
	data, err := os.ReadFile(absPath) //nolint:gosec // path comes from the hook payload
	if err != nil {
		return 0, err
	}
	cutoff := now.AddDate(0, 0, -sessionLogRetentionDays)

	count := 0
	for _, m := range sessionLogEntryPattern.FindAllStringSubmatch(string(data), -1) {
		if len(m) < 2 {
			continue
		}
		d, err := time.Parse("2006-01-02", m[1])
		if err != nil {
			count++
			continue
		}
		if d.Before(cutoff) {
			count++
		}
	}
	return count, nil
}

// checkClaudeMd は CLAUDE.md の行数をチェックする。
func (h *AutoCleanupHandler) checkClaudeMd(absPath string, maxLines int, locale string) string {
	lines, err := countLines(absPath)
	if err != nil {
		return ""
	}
	if lines > maxLines {
		return localizedHarnessMessage(locale,
			fmt.Sprintf("Warning: CLAUDE.md has %d lines. Consider splitting rules into .claude/rules/ or moving long content to docs/ and referencing it with @docs/filename.md.", lines),
			fmt.Sprintf("⚠️ CLAUDE.md が %d 行です。.claude/rules/ への分割、または docs/ に移動して @docs/filename.md で参照することを検討してください。", lines))
	}
	return ""
}

// countLines はファイルの行数を数える。
func countLines(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()

	count := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		count++
	}
	return count, sc.Err()
}

// containsArchiveSection はファイルにアーカイブセクションが含まれているかを確認する。
func containsArchiveSection(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.Contains(line, localizedHarnessMessage("ja", "archive", "📦 アーカイブ")) ||
			strings.Contains(line, localizedHarnessMessage("ja", "archive", "## アーカイブ")) ||
			strings.Contains(line, "Archive") {
			return true
		}
	}
	return false
}

// envInt は環境変数を整数として取得し、未設定またはパース失敗時はデフォルト値を返す。
func (h *AutoCleanupHandler) envInt(key string, defaultVal int) int {
	val := os.Getenv(key)
	if val == "" {
		return defaultVal
	}
	var n int
	if _, err := fmt.Sscanf(val, "%d", &n); err != nil {
		return defaultVal
	}
	return n
}

// writeCleanupOutput は feedback を additionalContext として JSON 出力する。
// bash は単純な JSON 文字列として出力しているため、同じ形式で出力する。
func writeCleanupOutput(w io.Writer, feedback string) error {
	type hookOutput struct {
		HookEventName     string `json:"hookEventName"`
		AdditionalContext string `json:"additionalContext"`
	}
	type output struct {
		HookSpecificOutput hookOutput `json:"hookSpecificOutput"`
	}
	out := output{
		HookSpecificOutput: hookOutput{
			HookEventName:     "PostToolUse",
			AdditionalContext: feedback,
		},
	}
	data, err := json.Marshal(out)
	if err != nil {
		return fmt.Errorf("marshaling JSON: %w", err)
	}
	_, err = fmt.Fprintf(w, "%s\n", data)
	return err
}
