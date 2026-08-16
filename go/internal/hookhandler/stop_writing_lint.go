package hookhandler

// stop_writing_lint.go
//
// Stop フックで .claude/state/changed-files.jsonl に記録された今回セッションの
// .md ファイルを writing-lint 辞書で再スキャンする。severity: error (major) の
// 辞書ヒットが残っていれば初回 Stop で decision:"block"、再入 (stop_hook_active)
// では systemMessage で警告するだけに留めて停止を許可する。この再入設計は
// stop_session_evaluator.go の WIP gate (Issue #269) と同型: block を繰り返すと
// 調査のみのセッションが停止不能になるため、1 回 block したら次は通す。
// severity: info/warning (minor) はこの Stop ゲートでは一切ブロックしない
// (PostToolUse の writing-lint hook が既に advisory で提示済み)。

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/Chachamaru127/claude-code-harness/go/internal/writinglint"
)

// writingLintMajorSeverity is the writing-rule.v1 severity level (schema
// enum: info/warning/error) treated as "major" for this Stop re-scan gate.
// error is the strongest level; info/warning map to "minor" and never block.
const writingLintMajorSeverity = "error"

// stopWritingLintInput is the Stop hook stdin JSON payload this handler reads.
type stopWritingLintInput struct {
	StopHookActive bool `json:"stop_hook_active"`
}

// StopWritingLintHandler は scripts 側に対応物のない新規 Go ネイティブハンドラ。
// stop_session_evaluator.go の再入設計を踏襲する。
type StopWritingLintHandler struct {
	// ProjectRoot はプロジェクトルートのパス。空の場合は環境変数/CWD から解決。
	ProjectRoot string
}

// Handle processes the Stop event: re-scan touched .md files for major
// (severity: error) writing-lint hits and block once on first Stop.
func (h *StopWritingLintHandler) Handle(in io.Reader, out io.Writer) error {
	projectRoot := h.ProjectRoot
	if projectRoot == "" {
		projectRoot = resolveProjectRoot()
	}

	var input stopWritingLintInput
	limited := io.LimitReader(in, 65536)
	if payload, _ := io.ReadAll(limited); len(payload) > 0 {
		_ = json.Unmarshal(payload, &input)
	}

	cfg := readWritingLintConfig(filepath.Join(projectRoot, harnessConfigFileName))
	if !cfg.Enabled {
		return writeJSON(out, stopSessionResponse{OK: true})
	}

	majorHits := scanTouchedMarkdownForMajorHits(projectRoot, cfg)
	if len(majorHits) == 0 {
		return writeJSON(out, stopSessionResponse{OK: true})
	}

	locale := resolveHarnessLocale(projectRoot)
	summary := strings.Join(majorHits, "; ")

	if input.StopHookActive {
		msg := fmt.Sprintf(
			localizedHarnessMessage(locale,
				"[WritingLint] Stopping with %d major writing-lint issue(s) remaining: %s",
				"[WritingLint] major の writing-lint 指摘が %d 件残ったまま停止します: %s"),
			len(majorHits), summary,
		)
		return writeJSON(out, stopSessionResponse{OK: true, SystemMessage: msg})
	}

	msg := fmt.Sprintf(
		localizedHarnessMessage(locale,
			"[WritingLint] %d major writing-lint issue(s) remain: %s",
			"[WritingLint] major の writing-lint 指摘が %d 件残っています: %s"),
		len(majorHits), summary,
	)
	return writeJSON(out, stopSessionResponse{Decision: "block", Reason: msg})
}

// scanTouchedMarkdownForMajorHits reads the de-duplicated list of files this
// run touched (track_changes.go's changed-files.jsonl, via
// loadTouchedFilesForStop), narrows to .md paths not covered by the
// writing-lint exclude list, and returns one summary string per severity:
// error dictionary hit found in their current on-disk content.
func scanTouchedMarkdownForMajorHits(projectRoot string, cfg writingLintConfig) []string {
	touched := loadTouchedFilesForStop(projectRoot)
	if len(touched) == 0 {
		return nil
	}

	dictPath := writinglint.ResolveDictPath(projectRoot)
	rules, err := writinglint.LoadDict(dictPath)
	if err != nil {
		return nil
	}

	var hits []string
	for _, rel := range touched {
		if !strings.HasSuffix(strings.ToLower(rel), ".md") {
			continue
		}
		if isWritingLintExcludedPath(rel) {
			continue
		}
		content, readErr := os.ReadFile(filepath.Join(projectRoot, rel))
		if readErr != nil {
			continue
		}
		matches, scanErr := writinglint.ScanText(string(content), rules, writinglint.ScanOpts{Scene: cfg.Scene})
		if scanErr != nil {
			continue
		}
		for _, m := range matches {
			if m.Severity != writingLintMajorSeverity {
				continue
			}
			hits = append(hits, fmt.Sprintf("%s [%s] %q", rel, m.RuleID, m.Text))
		}
	}
	return hits
}
