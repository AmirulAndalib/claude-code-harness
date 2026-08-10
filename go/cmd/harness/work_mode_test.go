package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/state"
)

func runWorkModeCapture(t *testing.T, args []string) (stdout, stderr string, code int) {
	t.Helper()
	var out, errOut bytes.Buffer
	code = runWorkModeCommand(args, &out, &errOut)
	return out.String(), errOut.String(), code
}

func writeSessionIDForCLI(t *testing.T, projectRoot, sessionID string) {
	t.Helper()
	stateDir := filepath.Join(projectRoot, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "session.json"), []byte(`{"session_id":"`+sessionID+`"}`), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestWorkModeCLI_OnOffRoundTrip covers RED case (a)/(b): `on` sets work_mode
// true, `off` sets it back to false, verified by reading state back directly.
func TestWorkModeCLI_OnOffRoundTrip(t *testing.T) {
	dir := t.TempDir()
	const sessionID = "sess-workmode-roundtrip"
	writeSessionIDForCLI(t, dir, sessionID)
	t.Setenv("HARNESS_PROJECT_ROOT", dir)
	t.Setenv("CLAUDE_PLUGIN_DATA", "")

	stdout, stderr, code := runWorkModeCapture(t, []string{"on"})
	if code != 0 {
		t.Fatalf("on: exit %d, stderr=%s", code, stderr)
	}
	if strings.TrimSpace(stdout) != "on" {
		t.Fatalf("on: unexpected stdout %q", stdout)
	}

	dbPath := state.ResolveStatePath(dir)
	store, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()

	ws, err := store.GetWorkState(sessionID)
	if err != nil {
		t.Fatalf("GetWorkState: %v", err)
	}
	if ws == nil || !ws.WorkMode {
		t.Fatalf("expected work_mode true after on, got %+v", ws)
	}

	statusOut, _, code := runWorkModeCapture(t, []string{"status"})
	if code != 0 {
		t.Fatalf("status: exit %d", code)
	}
	if strings.TrimSpace(statusOut) != "on" {
		t.Fatalf("status: expected on, got %q", statusOut)
	}

	_, stderr, code = runWorkModeCapture(t, []string{"off"})
	if code != 0 {
		t.Fatalf("off: exit %d, stderr=%s", code, stderr)
	}

	ws, err = store.GetWorkState(sessionID)
	if err != nil {
		t.Fatalf("GetWorkState after off: %v", err)
	}
	if ws == nil || ws.WorkMode {
		t.Fatalf("expected work_mode false after off, got %+v", ws)
	}

	statusOut, _, code = runWorkModeCapture(t, []string{"status"})
	if code != 0 {
		t.Fatalf("status after off: exit %d", code)
	}
	if strings.TrimSpace(statusOut) != "off" {
		t.Fatalf("status after off: expected off, got %q", statusOut)
	}
}

// TestWorkModeCLI_PreservesOtherFlags covers RED case: turning work mode on
// must not silently clear CodexMode/BypassRmRf/BypassGitPush set previously.
func TestWorkModeCLI_PreservesOtherFlags(t *testing.T) {
	dir := t.TempDir()
	const sessionID = "sess-workmode-preserve"
	writeSessionIDForCLI(t, dir, sessionID)
	t.Setenv("HARNESS_PROJECT_ROOT", dir)
	t.Setenv("CLAUDE_PLUGIN_DATA", "")

	dbPath := state.ResolveStatePath(dir)
	store, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	// work_states.session_id has a FOREIGN KEY on sessions(session_id); seed
	// the sessions row first, same as the CLI itself does internally.
	if err := store.UpsertSession(state.SessionState{
		SessionID:   sessionID,
		Mode:        state.SessionModeNormal,
		ProjectRoot: dir,
		StartedAt:   time.Now().UTC().Format(time.RFC3339),
	}); err != nil {
		t.Fatalf("seed UpsertSession: %v", err)
	}
	if err := store.SetWorkState(sessionID, state.WorkStateOptions{
		CodexMode:     true,
		BypassRmRf:    true,
		BypassGitPush: false,
	}); err != nil {
		t.Fatalf("seed SetWorkState: %v", err)
	}
	store.Close()

	_, stderr, code := runWorkModeCapture(t, []string{"on"})
	if code != 0 {
		t.Fatalf("on: exit %d, stderr=%s", code, stderr)
	}

	store2, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	defer store2.Close()
	ws, err := store2.GetWorkState(sessionID)
	if err != nil {
		t.Fatalf("GetWorkState: %v", err)
	}
	if ws == nil {
		t.Fatalf("expected work state row after on")
	}
	if !ws.WorkMode {
		t.Fatalf("expected work_mode true, got false")
	}
	if !ws.CodexMode {
		t.Fatalf("expected CodexMode preserved true, got false")
	}
	if !ws.BypassRmRf {
		t.Fatalf("expected BypassRmRf preserved true, got false")
	}
	if ws.BypassGitPush {
		t.Fatalf("expected BypassGitPush preserved false, got true")
	}
}

// TestWorkModeCLI_DoesNotClobberExistingSessionRow guards against a
// regression introduced while building the on/off flow: `sessions` has no
// natural writer other than session-start today, but SetWorkState's FK
// requires a sessions row to exist. UpsertSession's ON CONFLICT unconditionally
// overwrites mode/context_json, so work-mode must only create a sessions row
// when one is missing — never overwrite an existing one (e.g. one carrying
// meaningful Context from session-start).
func TestWorkModeCLI_DoesNotClobberExistingSessionRow(t *testing.T) {
	dir := t.TempDir()
	const sessionID = "sess-workmode-no-clobber"
	writeSessionIDForCLI(t, dir, sessionID)
	t.Setenv("HARNESS_PROJECT_ROOT", dir)
	t.Setenv("CLAUDE_PLUGIN_DATA", "")

	dbPath := state.ResolveStatePath(dir)
	store, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if err := store.UpsertSession(state.SessionState{
		SessionID:   sessionID,
		Mode:        state.SessionModeBreezing,
		ProjectRoot: dir,
		StartedAt:   time.Now().UTC().Format(time.RFC3339),
		Context:     map[string]interface{}{"important": "do-not-clobber"},
	}); err != nil {
		t.Fatalf("seed UpsertSession: %v", err)
	}
	store.Close()

	_, stderr, code := runWorkModeCapture(t, []string{"on"})
	if code != 0 {
		t.Fatalf("on: exit %d, stderr=%s", code, stderr)
	}

	store2, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	defer store2.Close()
	sess, err := store2.GetSession(sessionID)
	if err != nil {
		t.Fatalf("GetSession: %v", err)
	}
	if sess == nil {
		t.Fatalf("expected session row to still exist")
	}
	if sess.Mode != state.SessionModeBreezing {
		t.Fatalf("expected mode preserved as %q, got %q (clobbered)", state.SessionModeBreezing, sess.Mode)
	}
	if sess.Context["important"] != "do-not-clobber" {
		t.Fatalf("expected context preserved, got %+v (clobbered)", sess.Context)
	}
}

// TestWorkModeCLI_UnresolvableSessionID covers RED case (c): if the session
// ID cannot be resolved, the command must exit non-zero with a non-empty
// reason on stderr instead of silently succeeding.
func TestWorkModeCLI_UnresolvableSessionID(t *testing.T) {
	dir := t.TempDir() // no .claude/state/session.json written
	t.Setenv("HARNESS_PROJECT_ROOT", dir)
	t.Setenv("CLAUDE_PLUGIN_DATA", "")

	_, stderr, code := runWorkModeCapture(t, []string{"on"})
	if code == 0 {
		t.Fatalf("expected non-zero exit when session id cannot be resolved")
	}
	if strings.TrimSpace(stderr) == "" {
		t.Fatalf("expected a non-empty reason on stderr")
	}
}

// TestWorkModeCLI_DoesNotReadOtherSessionRow covers RED case (d): the work
// mode state for session A must not leak into a status/on/off call made
// under session B's identity.
func TestWorkModeCLI_DoesNotReadOtherSessionRow(t *testing.T) {
	dir := t.TempDir()
	const sessionA = "sess-workmode-a"
	const sessionB = "sess-workmode-b"
	t.Setenv("HARNESS_PROJECT_ROOT", dir)
	t.Setenv("CLAUDE_PLUGIN_DATA", "")

	writeSessionIDForCLI(t, dir, sessionA)
	_, stderr, code := runWorkModeCapture(t, []string{"on"})
	if code != 0 {
		t.Fatalf("on (session A): exit %d, stderr=%s", code, stderr)
	}

	// Switch local session identity to B and check status: must be "off",
	// not "on" leaked from A's row.
	writeSessionIDForCLI(t, dir, sessionB)
	statusOut, _, code := runWorkModeCapture(t, []string{"status"})
	if code != 0 {
		t.Fatalf("status (session B): exit %d", code)
	}
	if strings.TrimSpace(statusOut) != "off" {
		t.Fatalf("session B leaked session A's work_mode: got %q", statusOut)
	}

	dbPath := state.ResolveStatePath(dir)
	store, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	wsA, err := store.GetWorkState(sessionA)
	if err != nil {
		t.Fatalf("GetWorkState(A): %v", err)
	}
	if wsA == nil || !wsA.WorkMode {
		t.Fatalf("expected session A row to still be on, got %+v", wsA)
	}
}
