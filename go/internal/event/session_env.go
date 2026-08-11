package event

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// safeSessionIDRe restricts what we accept as a session id before writing it
// into a shell-sourced env file. Claude Code session ids are UUIDs; anything
// with shell metacharacters / control chars is refused outright (defense in
// depth on top of shellQuote — a newline inside quotes is valid shell but
// would confuse any line-based parser of the same file).
var safeSessionIDRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

// SessionEnvHandler は SessionStart フックハンドラ。
// CLAUDE_ENV_FILE を活用してハーネス環境変数を設定する。
//
// shell 版: scripts/hook-handlers/session-env-setup.sh
type SessionEnvHandler struct {
	// PluginRoot はバージョンファイルを探すルートディレクトリ。
	// 空の場合は環境変数 CLAUDE_PLUGIN_ROOT から取得する。
	PluginRoot string
}

// SessionEnvVars はハーネス環境変数のセット。
type SessionEnvVars struct {
	HarnessVersion           string
	HarnessEffortDefault     string
	HarnessAgentType         string
	HarnessIsRemote          string
	HarnessBreezingSessionID string // 空の場合は書き出さない
	// HarnessSessionID は SessionStart ペイロードの実 session_id。
	// hook が受け取る session_id と同一の値を Bash ツール環境へ届ける
	// 唯一の経路 (CLAUDE_SESSION_ID は Bash env に入らない・実測 2026-08-10)。
	// `harness work-mode` はこれを読んで work_states を実 ID で書く (132.7)。
	HarnessSessionID string
}

// sessionStartPayload は SessionStart フック stdin のうち必要なフィールド。
type sessionStartPayload struct {
	SessionID string `json:"session_id"`
}

// Handle は stdin から SessionStart ペイロードを読み取り、
// CLAUDE_ENV_FILE にハーネス環境変数を書き出す。
// CLAUDE_ENV_FILE が設定されていない場合は何もしない。
func (h *SessionEnvHandler) Handle(r io.Reader, _ io.Writer) error {
	// CLAUDE_ENV_FILE が設定されていない場合はスキップ
	envFile := os.Getenv("CLAUDE_ENV_FILE")
	if envFile == "" {
		return nil
	}

	// SessionStart ペイロードから実 session_id を取り出す
	// (パース失敗は無視して残りの変数だけ書き出す)
	var payload sessionStartPayload
	if data, err := io.ReadAll(r); err == nil && len(data) > 0 {
		_ = json.Unmarshal(data, &payload)
	}

	vars := h.buildEnvVars()
	if sid := strings.TrimSpace(payload.SessionID); safeSessionIDRe.MatchString(sid) {
		vars.HarnessSessionID = sid
	}
	return h.writeEnvFile(envFile, vars)
}

// buildEnvVars は現在の環境変数から SessionEnvVars を構築する。
func (h *SessionEnvHandler) buildEnvVars() SessionEnvVars {
	pluginRoot := h.PluginRoot
	if pluginRoot == "" {
		pluginRoot = os.Getenv("CLAUDE_PLUGIN_ROOT")
	}

	version := h.readVersion(pluginRoot)

	agentType := os.Getenv("BREEZING_ROLE")
	if agentType == "" {
		agentType = "solo"
	}

	isRemote := os.Getenv("CLAUDE_CODE_REMOTE")
	if isRemote == "" {
		isRemote = "false"
	}

	return SessionEnvVars{
		HarnessVersion:           version,
		HarnessEffortDefault:     "medium",
		HarnessAgentType:         agentType,
		HarnessIsRemote:          isRemote,
		HarnessBreezingSessionID: os.Getenv("BREEZING_SESSION_ID"),
	}
}

// readVersion は VERSION ファイルからバージョン文字列を読み取る。
func (h *SessionEnvHandler) readVersion(pluginRoot string) string {
	if pluginRoot == "" {
		return "unknown"
	}

	data, err := os.ReadFile(filepath.Join(pluginRoot, "VERSION"))
	if err != nil {
		return "unknown"
	}

	v := strings.TrimSpace(string(data))
	if v == "" {
		return "unknown"
	}
	return v
}

// writeEnvFile は CLAUDE_ENV_FILE にハーネス環境変数を追記する。
//
// 行形式は公式ドキュメント (hooks.md "Persist environment variables") の
// 例に合わせて `export KEY=VALUE` とする。CC はこのファイルを shell として
// source するため、`export` が無い素の `KEY=VALUE` は shell 変数どまりで
// Bash ツールの子プロセス環境に届かない (2026-08-11 実測: 旧形式で書いた
// HARNESS_VERSION 等が printenv に現れなかった)。
//
// SessionStart は resume / compact でも再発火し O_APPEND で追記されるため、
// 既に書いた変数は重複させず、値が変わりうる HARNESS_SESSION_ID のみ
// 上書き追記する (shell の source は後勝ちなので追記で正しく更新される)。
func (h *SessionEnvHandler) writeEnvFile(envFile string, vars SessionEnvVars) error {
	// シンボリックリンクチェック（セキュリティ）
	if isSymlink(envFile) {
		return fmt.Errorf("security: symlinked env file refused: %s", envFile)
	}

	existing := ""
	if data, err := os.ReadFile(envFile); err == nil {
		existing = string(data)
	}

	f, err := os.OpenFile(envFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return fmt.Errorf("opening env file: %w", err)
	}
	defer f.Close()

	lines := []string{
		fmt.Sprintf("export HARNESS_VERSION=%s", shellQuote(vars.HarnessVersion)),
		fmt.Sprintf("export HARNESS_EFFORT_DEFAULT=%s", shellQuote(vars.HarnessEffortDefault)),
		fmt.Sprintf("export HARNESS_AGENT_TYPE=%s", shellQuote(vars.HarnessAgentType)),
		fmt.Sprintf("export HARNESS_IS_REMOTE=%s", shellQuote(vars.HarnessIsRemote)),
	}
	if vars.HarnessBreezingSessionID != "" {
		lines = append(lines, fmt.Sprintf("export HARNESS_BREEZING_SESSION_ID=%s", shellQuote(vars.HarnessBreezingSessionID)))
	}
	if vars.HarnessSessionID != "" {
		lines = append(lines, fmt.Sprintf("export HARNESS_SESSION_ID=%s", shellQuote(vars.HarnessSessionID)))
	}

	for _, line := range lines {
		// resume / compact の再発火で同一行が既にあればスキップ (追記の肥大防止)。
		// 値が変わった行 (別 session_id 等) は追記され、source の後勝ちで有効になる。
		if strings.Contains(existing, line+"\n") || strings.HasSuffix(existing, line) {
			continue
		}
		if _, err := fmt.Fprintln(f, line); err != nil {
			return fmt.Errorf("writing env file: %w", err)
		}
	}
	return nil
}

// shellQuote は env file の値を single-quote で安全に囲む。
// session_id 等は外部入力なので、shell として source される
// ファイルへ書く前に必ず quote する。
func shellQuote(v string) string {
	return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'"
}
