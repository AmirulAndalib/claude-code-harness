package hookhandler

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeScopeLeashContractsFixture(t *testing.T, dir, taskID string, declaredScope []string) {
	t.Helper()
	stateDir := filepath.Join(dir, ".claude", "state")
	if err := os.MkdirAll(filepath.Join(stateDir, "contracts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(stateDir, "active-task.json"),
		[]byte(`{"phase":"134","task":"`+taskID+`"}`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	scope, err := json.Marshal(declaredScope)
	if err != nil {
		t.Fatal(err)
	}
	contract := `{"task":{"id":"` + taskID + `","declared_scope":` + string(scope) + `}}`
	if err := os.WriteFile(
		filepath.Join(stateDir, "contracts", taskID+".sprint-contract.json"),
		[]byte(contract),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
}

func writeChangedFilesFixture(t *testing.T, dir string, touched []string) {
	t.Helper()
	stateDir := filepath.Join(dir, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	for _, f := range touched {
		entry := changedFileEntry{File: f, Action: "Write", Timestamp: "2026-08-15T00:00:00Z"}
		data, err := json.Marshal(entry)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(data)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(filepath.Join(stateDir, "changed-files.jsonl"), []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStopSessionEvaluator_DroppedScopeAdvisoryOnUntouchedDeclaredFile(t *testing.T) {
	dir := t.TempDir()
	writeScopeLeashContractsFixture(t, dir, "134.5", []string{"a.go", "b.go"})
	writeChangedFilesFixture(t, dir, []string{"a.go"})

	h := &StopSessionEvaluatorHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(`{}`), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp stopSessionResponse
	if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &resp); err != nil {
		t.Fatalf("invalid JSON output: %v\noutput: %s", err, out.String())
	}
	if !resp.OK {
		t.Fatalf("dropped-scope advisory must not block the stop: %+v", resp)
	}
	if !strings.Contains(resp.SystemMessage, "b.go") {
		t.Fatalf("expected dropped scope entry b.go in systemMessage, got %q", resp.SystemMessage)
	}
	if !strings.Contains(resp.SystemMessage, "134.5") {
		t.Fatalf("expected task id in systemMessage, got %q", resp.SystemMessage)
	}
}

func TestStopSessionEvaluator_NoDroppedScopeAdvisoryWhenAllTouched(t *testing.T) {
	dir := t.TempDir()
	writeScopeLeashContractsFixture(t, dir, "134.5", []string{"a.go", "b.go"})
	writeChangedFilesFixture(t, dir, []string{"a.go", "b.go"})

	h := &StopSessionEvaluatorHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(`{}`), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp stopSessionResponse
	if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &resp); err != nil {
		t.Fatalf("invalid JSON output: %v\noutput: %s", err, out.String())
	}
	if resp.SystemMessage != "" {
		t.Fatalf("no dropped scope should mean no advisory, got %q", resp.SystemMessage)
	}
}

func TestStopSessionEvaluator_NoDroppedScopeAdvisoryWithoutActiveTask(t *testing.T) {
	dir := t.TempDir()

	h := &StopSessionEvaluatorHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(`{}`), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp stopSessionResponse
	if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &resp); err != nil {
		t.Fatalf("invalid JSON output: %v\noutput: %s", err, out.String())
	}
	if resp.SystemMessage != "" {
		t.Fatalf("no active task should mean no advisory, got %q", resp.SystemMessage)
	}
}
