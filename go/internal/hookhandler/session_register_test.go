package hookhandler

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

type sessionHookCommandConfig struct {
	Type    string `json:"type"`
	Command string `json:"command"`
}

type sessionHookGroupConfig struct {
	Hooks []sessionHookCommandConfig `json:"hooks"`
}

type sessionHooksConfig struct {
	Hooks map[string][]sessionHookGroupConfig `json:"hooks"`
}

// TestRegisterHealth_NotConfigured covers the tri-state "not-configured"
// arm from active-watching-test-policy.md: SessionStart fires without a
// session_id (e.g., a bootstrap fallback path) and we must neither create
// state nor surface a warning. The hook is opt-in, so absence == silence.
func TestRegisterHealth_NotConfigured(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	if err := HandleSessionRegister(strings.NewReader(`{}`), nil); err != nil {
		t.Errorf("not-configured path must not return error: %v", err)
	}
	activeFile := filepath.Join(dir, ".claude", "sessions", "active.json")
	if _, err := os.Stat(activeFile); !os.IsNotExist(err) {
		t.Errorf("active.json must not be created when session_id is empty, stat err=%v", err)
	}
}

// TestRegisterHealth_Healthy covers the happy path: a valid SessionStart
// produces an entry whose shape matches scripts/session-register.sh's
// active.json schema (short_id 12 chars, status=active, positive
// last_seen, non-empty pid). The contract is exercised via the public
// JSON, not by reaching into internals, so a future bash-only consumer
// of active.json remains compatible.
func TestRegisterHealth_Healthy(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	if err := HandleSessionRegister(strings.NewReader(`{"session_id":"test-session-abc123def456"}`), nil); err != nil {
		t.Fatalf("healthy register returned error: %v", err)
	}

	activeFile := filepath.Join(dir, ".claude", "sessions", "active.json")
	data, err := os.ReadFile(activeFile)
	if err != nil {
		t.Fatalf("active.json should be created on healthy register: %v", err)
	}

	var sessions map[string]ActiveSession
	if err := json.Unmarshal(data, &sessions); err != nil {
		t.Fatalf("active.json is not valid JSON: %v\nraw=%s", err, data)
	}

	s, ok := sessions["test-session-abc123def456"]
	if !ok {
		t.Fatalf("session_id missing from active.json; raw=%s", data)
	}
	if s.ShortID != "test-session" {
		t.Errorf("short_id should be the 12-char session_id prefix, got %q", s.ShortID)
	}
	if s.Status != "active" {
		t.Errorf("status should be %q, got %q", "active", s.Status)
	}
	if s.PID == "" {
		t.Error("pid must be set; empty pid means the writer skipped recording it")
	}
	if s.LastSeen <= 0 {
		t.Errorf("last_seen should be a positive epoch, got %d", s.LastSeen)
	}
}

// TestRegisterHealth_Corrupted covers the tri-state "corrupted" arm: a
// preexisting active.json that fails JSON parse must not crash the
// SessionStart chain. Per active-watching-test-policy.md the handler
// silently recovers — the next healthy register rebuilds the file.
func TestRegisterHealth_Corrupted(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	sessionsDir := filepath.Join(dir, ".claude", "sessions")
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	activeFile := filepath.Join(sessionsDir, "active.json")
	if err := os.WriteFile(activeFile, []byte("{not valid json"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := HandleSessionRegister(strings.NewReader(`{"session_id":"recovery-session"}`), nil); err != nil {
		t.Fatalf("corrupted state should not propagate an error: %v", err)
	}

	data, err := os.ReadFile(activeFile)
	if err != nil {
		t.Fatalf("active.json should still exist after recovery: %v", err)
	}
	var sessions map[string]ActiveSession
	if err := json.Unmarshal(data, &sessions); err != nil {
		t.Errorf("active.json should be repaired to valid JSON, got error %v\nraw=%s", err, data)
	}
	if _, ok := sessions["recovery-session"]; !ok {
		t.Errorf("recovery register entry should be present after corruption: %s", data)
	}
}

// TestSessionUnregister_RemovesEntry covers the unregister handler contract:
// an entry that was registered must be hard-deleted from active.json so peers
// scanning for live coordination state see the truth immediately.
func TestSessionUnregister_RemovesEntry(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	payload := `{"session_id":"to-remove"}`
	if err := HandleSessionRegister(strings.NewReader(payload), nil); err != nil {
		t.Fatalf("register failed: %v", err)
	}
	if err := HandleSessionUnregister(strings.NewReader(payload), nil); err != nil {
		t.Fatalf("unregister failed: %v", err)
	}

	activeFile := filepath.Join(dir, ".claude", "sessions", "active.json")
	data, err := os.ReadFile(activeFile)
	if err != nil {
		t.Fatalf("active.json should still exist after unregister: %v", err)
	}
	var sessions map[string]ActiveSession
	if err := json.Unmarshal(data, &sessions); err != nil {
		t.Fatalf("invalid JSON after unregister: %v\n%s", err, data)
	}
	if _, ok := sessions["to-remove"]; ok {
		t.Errorf("entry should be removed by Unregister, got: %s", data)
	}
}

// TestRegister_StaleCleanup covers the bounded-growth invariant: entries
// older than registerStaleCutoff (24h) must be pruned during the next
// register write so active.json does not accumulate the long tail of
// crashed sessions that never ran SessionEnd.
func TestRegister_StaleCleanup(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	sessionsDir := filepath.Join(dir, ".claude", "sessions")
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	activeFile := filepath.Join(sessionsDir, "active.json")

	now := time.Now().Unix()
	seed := map[string]ActiveSession{
		"stale-session": {ShortID: "stale-sessio", LastSeen: now - 26*3600, PID: "1", Status: "active"},
		"fresh-session": {ShortID: "fresh-sessio", LastSeen: now - 60, PID: "2", Status: "active"},
	}
	out, _ := json.MarshalIndent(seed, "", "  ")
	if err := os.WriteFile(activeFile, out, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := HandleSessionRegister(strings.NewReader(`{"session_id":"new-session"}`), nil); err != nil {
		t.Fatalf("register failed: %v", err)
	}

	data, _ := os.ReadFile(activeFile)
	var sessions map[string]ActiveSession
	_ = json.Unmarshal(data, &sessions)

	if _, ok := sessions["stale-session"]; ok {
		t.Errorf("stale entry (>24h) should have been pruned, got: %s", data)
	}
	if _, ok := sessions["fresh-session"]; !ok {
		t.Errorf("fresh entry (<24h) must be preserved, got: %s", data)
	}
	if _, ok := sessions["new-session"]; !ok {
		t.Errorf("newly registered session must be present, got: %s", data)
	}
}

// TestSessionRoster_ForeignEntrySurvivesRegisterAndPrune proves that entries
// owned by another session-state schema are carried through a CCH write. The
// foreign entry carries a last_seen field with a foreign shape: decoding it as
// ActiveSession would still make the old prune loop delete it as stale.
func TestSessionRoster_ForeignEntrySurvivesRegisterAndPrune(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	const (
		foreignID = "mem-foreign-entry"
		ownID     = "cch-own-entry"
	)
	foreign := json.RawMessage(`{"source":"mem","last_seen":1,"updated_at":"2026-08-24T08:00:00Z","payload":{"note":"keep me"}}`)
	sessionsDir := filepath.Join(dir, ".claude", "sessions")
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	activeFile := filepath.Join(sessionsDir, "active.json")
	seed := map[string]json.RawMessage{
		foreignID: foreign,
		"cch-stale-entry": mustMarshalActiveSession(t, ActiveSession{
			ShortID:  "cch-stale-ent",
			LastSeen: time.Now().Add(-26 * time.Hour).Unix(),
			PID:      "1",
			Status:   "active",
		}),
	}
	if err := writeRawActiveJSONForTest(activeFile, seed); err != nil {
		t.Fatal(err)
	}

	if err := HandleSessionRegister(strings.NewReader(`{"session_id":"`+ownID+`"}`), nil); err != nil {
		t.Fatalf("register failed: %v", err)
	}

	assertRawActiveEntryEqual(t, activeFile, foreignID, foreign)
	assertActiveEntryMissing(t, activeFile, "cch-stale-entry")
	assertActiveEntryPresent(t, activeFile, ownID)

	if err := HandleSessionUnregister(strings.NewReader(`{"session_id":"`+ownID+`"}`), nil); err != nil {
		t.Fatalf("unregister failed: %v", err)
	}
	assertRawActiveEntryEqual(t, activeFile, foreignID, foreign)
}

// TestSessionRoster_UnregisterDoesNotDeleteForeignEntry protects the case
// where the foreign producer happens to use the same key that CCH is asked to
// unregister. Only an entry matching the CCH schema is owned by this handler.
func TestSessionRoster_UnregisterDoesNotDeleteForeignEntry(t *testing.T) {
	dir := initGitRepoForPresence(t)
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	const sessionID = "shared-key"
	foreign := json.RawMessage(`{"provider":"mem","record_id":"shared-key","body":["retain"]}`)
	activeFile := filepath.Join(dir, ".claude", "sessions", "active.json")
	if err := writeRawActiveJSONForTest(activeFile, map[string]json.RawMessage{sessionID: foreign}); err != nil {
		t.Fatal(err)
	}

	if err := HandleSessionRegister(strings.NewReader(`{"session_id":"`+sessionID+`"}`), nil); err != nil {
		t.Fatalf("register failed: %v", err)
	}
	assertRawActiveEntryEqual(t, activeFile, sessionID, foreign)
	presence := presencePath(t, dir, sessionID)
	if _, err := os.Stat(presence); err != nil {
		t.Fatalf("register should create CCH presence for the session: %v", err)
	}
	if roster := FormatSessionTeamList(dir, time.Now()); !strings.Contains(roster, sessionID) {
		t.Fatalf("team view should report the registered presence before unregister: %q", roster)
	}

	if err := HandleSessionUnregister(strings.NewReader(`{"session_id":"`+sessionID+`"}`), nil); err != nil {
		t.Fatalf("unregister failed: %v", err)
	}
	assertRawActiveEntryEqual(t, activeFile, sessionID, foreign)
	if _, err := os.Stat(presence); !os.IsNotExist(err) {
		t.Fatalf("unregister should remove CCH presence, stat err=%v", err)
	}
	if roster := FormatSessionTeamList(dir, time.Now()); strings.Contains(roster, sessionID) {
		t.Fatalf("team view must stop reporting the ended presence: %q", roster)
	}
}

func mustMarshalActiveSession(t *testing.T, session ActiveSession) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(session)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func writeRawActiveJSONForTest(path string, entries map[string]json.RawMessage) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.Marshal(entries)
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o644)
}

func readRawActiveJSONForTest(t *testing.T, path string) map[string]json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var entries map[string]json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		t.Fatalf("active.json is not an object: %v\n%s", err, raw)
	}
	return entries
}

func assertRawActiveEntryEqual(t *testing.T, path, id string, want json.RawMessage) {
	t.Helper()
	entries := readRawActiveJSONForTest(t, path)
	got, ok := entries[id]
	if !ok {
		t.Fatalf("active.json entry %q is missing", id)
	}
	var gotCompact, wantCompact bytes.Buffer
	if err := json.Compact(&gotCompact, got); err != nil {
		t.Fatalf("compact stored entry %q: %v", id, err)
	}
	if err := json.Compact(&wantCompact, want); err != nil {
		t.Fatalf("compact expected entry %q: %v", id, err)
	}
	if !bytes.Equal(gotCompact.Bytes(), wantCompact.Bytes()) {
		t.Errorf("entry %q changed:\n got: %s\nwant: %s", id, gotCompact.Bytes(), wantCompact.Bytes())
	}
}

func assertActiveEntryMissing(t *testing.T, path, id string) {
	t.Helper()
	if _, ok := readRawActiveJSONForTest(t, path)[id]; ok {
		t.Errorf("active.json entry %q should be absent", id)
	}
}

func assertActiveEntryPresent(t *testing.T, path, id string) {
	t.Helper()
	if _, ok := readRawActiveJSONForTest(t, path)[id]; !ok {
		t.Errorf("active.json entry %q should be present", id)
	}
}

// TestUnregister_NoActiveJsonNoError covers a second not-configured arm:
// SessionEnd fires before any register ever ran (e.g., a session that aborted
// mid-startup). The handler must not error and must not create state.
func TestUnregister_NoActiveJsonNoError(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)
	if err := HandleSessionUnregister(strings.NewReader(`{"session_id":"never-registered"}`), nil); err != nil {
		t.Errorf("unregister without prior active.json must not error: %v", err)
	}
	activeFile := filepath.Join(dir, ".claude", "sessions", "active.json")
	if _, err := os.Stat(activeFile); !os.IsNotExist(err) {
		t.Errorf("unregister must not create active.json out of nowhere, stat err=%v", err)
	}
}

// TestSessionRosterLifecycle_StopRetainsUntilSessionEnd pins the lifecycle
// boundary: Stop is a turn boundary and must leave the registered session in
// the roster, while SessionEnd is the terminal boundary that unregisters it.
// The configured commands are applied through the same handler as the hook
// dispatcher so this test fails while session-unregister is wired to Stop.
func TestSessionRosterLifecycle_StopRetainsUntilSessionEnd(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	const sessionID = "lifecycle-session"
	payload := `{"session_id":"` + sessionID + `"}`
	if err := HandleSessionRegister(strings.NewReader(payload), nil); err != nil {
		t.Fatalf("register failed: %v", err)
	}

	paths := sessionHookConfigPaths(t)
	configs := make([]sessionHooksConfig, 0, len(paths))
	for _, path := range paths {
		config := readSessionHooksConfig(t, path)
		configs = append(configs, config)
	}

	// Use the source hooks.json as the lifecycle simulation. The mirror is
	// checked above and separately by tests/test-hooks-sync.sh.
	config := configs[0]
	if err := applyConfiguredSessionUnregister(config.Hooks["Stop"], payload); err != nil {
		t.Fatalf("Stop lifecycle simulation failed: %v", err)
	}
	if roster := FormatSessionTeamList(dir, time.Now()); !strings.Contains(roster, sessionID) {
		t.Fatalf("Stop must retain registered session %q, roster=%q", sessionID, roster)
	}
	for i, config := range configs {
		assertSessionEndWiring(t, paths[i], config)
		for _, group := range config.Hooks["Stop"] {
			if hasSessionHook(group, "session-unregister") {
				t.Fatalf("hooks config %d must not unregister on Stop", i)
			}
		}
	}

	if err := applyConfiguredSessionUnregister(config.Hooks["SessionEnd"], payload); err != nil {
		t.Fatalf("SessionEnd lifecycle simulation failed: %v", err)
	}
	if roster := FormatSessionTeamList(dir, time.Now()); strings.Contains(roster, sessionID) {
		t.Fatalf("SessionEnd must remove registered session %q, roster=%q", sessionID, roster)
	}
}

// TestSessionRegister_StopRefreshPreservesDeclaredPresence pins the turn
// heartbeat contract: Stop must re-run session-register, but an existing
// presence card declared by the session keeps its label/task content while
// only its mtime is refreshed.
func TestSessionRegister_StopRefreshPreservesDeclaredPresence(t *testing.T) {
	dir := initGitRepoForPresence(t)
	t.Setenv("HARNESS_PROJECT_ROOT", dir)

	const (
		sessionID = "session-refresh-presence"
		label     = "declared-label"
		taskID    = "141.2"
	)
	initialPayload := `{"session_id":"` + sessionID + `","label":"` + label + `"}`
	if err := HandleSessionRegister(strings.NewReader(initialPayload), nil); err != nil {
		t.Fatalf("initial register failed: %v", err)
	}
	if err := SessionDeclareTask(dir, sessionID, taskID); err != nil {
		t.Fatalf("declare task failed: %v", err)
	}

	path := presencePath(t, dir, sessionID)
	beforeBody, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read declared presence: %v", err)
	}
	beforeCard := ParsePresenceCardBody(beforeBody)
	if beforeCard.Label != label || beforeCard.Task != taskID {
		t.Fatalf("declared card = %#v, want label=%q task=%q", beforeCard, label, taskID)
	}

	old := time.Now().Add(-time.Minute)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("age presence card: %v", err)
	}

	paths := sessionHookConfigPaths(t)
	configs := make([]sessionHooksConfig, 0, len(paths))
	for _, hookPath := range paths {
		config := readSessionHooksConfig(t, hookPath)
		configs = append(configs, config)
		if !hasSessionHookInGroups(config.Hooks["Stop"], "session-register") {
			t.Fatalf("%s must wire session-register in the Stop block", hookPath)
		}
	}

	// Simulate the source Stop block. The mirror is checked above and by the
	// dedicated hooks synchronization test.
	if err := applyConfiguredSessionRegister(configs[0].Hooks["Stop"], `{"session_id":"`+sessionID+`","label":"new-label"}`); err != nil {
		t.Fatalf("Stop register refresh failed: %v", err)
	}

	afterInfo, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat refreshed presence card: %v", err)
	}
	if !afterInfo.ModTime().After(old) {
		t.Fatalf("presence mtime = %s, want newer than %s", afterInfo.ModTime(), old)
	}
	afterBody, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read refreshed presence: %v", err)
	}
	if string(afterBody) != string(beforeBody) {
		t.Fatalf("register must preserve declared card bytes; before=%s after=%s", beforeBody, afterBody)
	}
}

func sessionHookConfigPaths(t *testing.T) []string {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller could not locate session_register_test.go")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", ".."))
	return []string{
		filepath.Join(root, "hooks", "hooks.json"),
		filepath.Join(root, ".claude-plugin", "hooks.json"),
	}
}

func readSessionHooksConfig(t *testing.T, path string) sessionHooksConfig {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hooks config %s: %v", path, err)
	}
	var config sessionHooksConfig
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatalf("parse hooks config %s: %v", path, err)
	}
	return config
}

func assertSessionEndWiring(t *testing.T, path string, config sessionHooksConfig) {
	t.Helper()
	for _, group := range config.Hooks["SessionEnd"] {
		if hasSessionHook(group, "session-cleanup") && hasSessionHook(group, "session-unregister") {
			return
		}
	}
	t.Fatalf("%s must wire session-unregister in the SessionEnd block with session-cleanup", path)
}

func hasSessionHook(group sessionHookGroupConfig, name string) bool {
	for _, hook := range group.Hooks {
		if strings.Contains(hook.Command, "hook "+name) {
			return true
		}
	}
	return false
}

func hasSessionHookInGroups(groups []sessionHookGroupConfig, name string) bool {
	for _, group := range groups {
		if hasSessionHook(group, name) {
			return true
		}
	}
	return false
}

func applyConfiguredSessionRegister(groups []sessionHookGroupConfig, payload string) error {
	for _, group := range groups {
		if hasSessionHook(group, "session-register") {
			return HandleSessionRegister(strings.NewReader(payload), nil)
		}
	}
	return nil
}

func applyConfiguredSessionUnregister(groups []sessionHookGroupConfig, payload string) error {
	for _, group := range groups {
		if hasSessionHook(group, "session-unregister") {
			return HandleSessionUnregister(strings.NewReader(payload), nil)
		}
	}
	return nil
}
