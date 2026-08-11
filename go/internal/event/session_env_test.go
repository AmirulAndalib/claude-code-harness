package event

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NOTE (2026-08-11, expectation baseline change): these tests previously
// expected bare `KEY=VALUE` lines. The official hooks doc ("Persist
// environment variables") shows `export KEY=VALUE`, and the bare form was
// measured NOT to reach Bash tool subprocess env in a live session
// (HARNESS_VERSION absent from printenv while the handler was wired).
// The expectations below pin the working `export KEY='VALUE'` form.

func TestSessionEnvHandler_Handle_NoEnvFile(t *testing.T) {
	// CLAUDE_ENV_FILE が設定されていない場合は何もしない
	t.Setenv("CLAUDE_ENV_FILE", "")

	h := &SessionEnvHandler{}
	err := h.Handle(strings.NewReader(`{}`), os.Stdout)
	if err != nil {
		t.Errorf("expected no error, got %v", err)
	}
}

func TestSessionEnvHandler_Handle_WritesEnvVars(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "env")
	versionFile := filepath.Join(dir, "VERSION")

	if err := os.WriteFile(versionFile, []byte("4.2.0\n"), 0600); err != nil {
		t.Fatal(err)
	}

	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("BREEZING_ROLE", "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("CLAUDE_CODE_REMOTE", "")

	h := &SessionEnvHandler{PluginRoot: dir}
	if err := h.Handle(strings.NewReader(`{}`), os.Stdout); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	content := string(data)

	checks := []string{
		"export HARNESS_VERSION='4.2.0'",
		"export HARNESS_EFFORT_DEFAULT='medium'",
		"export HARNESS_AGENT_TYPE='solo'",
		"export HARNESS_IS_REMOTE='false'",
	}
	for _, want := range checks {
		if !strings.Contains(content, want) {
			t.Errorf("expected %q in env file, got:\n%s", want, content)
		}
	}
	// BREEZING_SESSION_ID は空なので含まれていないはず
	if strings.Contains(content, "HARNESS_BREEZING_SESSION_ID") {
		t.Errorf("expected no HARNESS_BREEZING_SESSION_ID, got:\n%s", content)
	}
	// payload に session_id が無ければ HARNESS_SESSION_ID も書かない
	if strings.Contains(content, "HARNESS_SESSION_ID") {
		t.Errorf("expected no HARNESS_SESSION_ID for empty payload, got:\n%s", content)
	}
}

func TestSessionEnvHandler_Handle_BreezingRole(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "env")

	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("BREEZING_ROLE", "worker")
	t.Setenv("BREEZING_SESSION_ID", "sess-123")
	t.Setenv("CLAUDE_CODE_REMOTE", "true")

	h := &SessionEnvHandler{PluginRoot: dir}
	if err := h.Handle(strings.NewReader(`{}`), os.Stdout); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	content := string(data)

	checks := []string{
		"export HARNESS_AGENT_TYPE='worker'",
		"export HARNESS_IS_REMOTE='true'",
		"export HARNESS_BREEZING_SESSION_ID='sess-123'",
	}
	for _, want := range checks {
		if !strings.Contains(content, want) {
			t.Errorf("expected %q in env file, got:\n%s", want, content)
		}
	}
}

func TestSessionEnvHandler_Handle_MissingVersionFile(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "env")

	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("BREEZING_ROLE", "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("CLAUDE_CODE_REMOTE", "")

	// VERSION ファイルなし
	h := &SessionEnvHandler{PluginRoot: dir}
	if err := h.Handle(strings.NewReader(`{}`), os.Stdout); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "export HARNESS_VERSION='unknown'") {
		t.Errorf("expected HARNESS_VERSION=unknown, got:\n%s", string(data))
	}
}

// 132.7: SessionStart payload の実 session_id が HARNESS_SESSION_ID として
// export されること。`harness work-mode` はこの値で work_states を書き、
// guardrail は hook payload の session_id で引くため、両者が一致する。
func TestSessionEnvHandler_Handle_WritesRealSessionID(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "env")

	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("BREEZING_ROLE", "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("CLAUDE_CODE_REMOTE", "")

	h := &SessionEnvHandler{PluginRoot: dir}
	payload := `{"session_id":"70a2ee83-acc2-4afb-a0d3-81c2fa321dfd","hook_event_name":"SessionStart","source":"startup"}`
	if err := h.Handle(strings.NewReader(payload), os.Stdout); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "export HARNESS_SESSION_ID='70a2ee83-acc2-4afb-a0d3-81c2fa321dfd'") {
		t.Errorf("expected exported HARNESS_SESSION_ID, got:\n%s", string(data))
	}
}

// resume / compact の SessionStart 再発火では O_APPEND で追記されるため、
// 同一値の行を重複して書かないこと。別 session_id は追記され後勝ちになること。
func TestSessionEnvHandler_Handle_ResumeDoesNotDuplicate(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "env")

	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("BREEZING_ROLE", "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("CLAUDE_CODE_REMOTE", "")

	h := &SessionEnvHandler{PluginRoot: dir}
	payload := `{"session_id":"sid-aaa"}`
	for i := 0; i < 3; i++ {
		if err := h.Handle(strings.NewReader(payload), os.Stdout); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
	}

	data, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(data), "export HARNESS_SESSION_ID='sid-aaa'"); got != 1 {
		t.Errorf("HARNESS_SESSION_ID lines = %d, want 1:\n%s", got, string(data))
	}
	if got := strings.Count(string(data), "export HARNESS_VERSION="); got != 1 {
		t.Errorf("HARNESS_VERSION lines = %d, want 1:\n%s", got, string(data))
	}

	// fork 等で session_id が変わったら追記され、source の後勝ちで新 ID が有効
	if err := h.Handle(strings.NewReader(`{"session_id":"sid-bbb"}`), os.Stdout); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(envFile)
	content := string(data)
	if !strings.Contains(content, "export HARNESS_SESSION_ID='sid-bbb'") {
		t.Errorf("expected new session id appended, got:\n%s", content)
	}
	if strings.Index(content, "sid-bbb") < strings.Index(content, "sid-aaa") {
		t.Errorf("new session id must come after old one (source last-wins):\n%s", content)
	}
}

// session_id は UUID 形式のみ受理する。shell メタ文字・改行・空白を含む値は
// env file へ一切書かない (quote 防御より手前の入口拒否)。
func TestSessionEnvHandler_Handle_RejectsUnsafeSessionIDs(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "env")

	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("BREEZING_ROLE", "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("CLAUDE_CODE_REMOTE", "")

	h := &SessionEnvHandler{PluginRoot: dir}
	for _, sid := range []string{
		`x; rm -rf $HOME`,
		"a\nexport EVIL=1",
		"a'b",
		"a b",
		"$(whoami)",
	} {
		payload := `{"session_id":` + string(mustJSON(t, sid)) + `}`
		if err := h.Handle(strings.NewReader(payload), os.Stdout); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	}

	data, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "HARNESS_SESSION_ID") {
		t.Errorf("unsafe session ids must not be written at all, got:\n%s", string(data))
	}
	if strings.Contains(string(data), "EVIL") {
		t.Errorf("newline smuggling must be impossible, got:\n%s", string(data))
	}
}

func mustJSON(t *testing.T, s string) []byte {
	t.Helper()
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
