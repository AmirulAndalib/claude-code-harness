package hookhandler

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/internal/writinglint"
)

// writeStopWritingLintDictFixture writes a fixture dictionary with one major
// (severity: error) rule and one minor (severity: warning) rule.
func writeStopWritingLintDictFixture(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "rules.jsonl")
	content := `{"id": "major-meta-narration", "pattern": "以下に示します", "good": "結論から直接書く", "enabled": true, "severity": "error"}
{"id": "minor-hedge", "pattern": "重要なのは.+である", "good": "何が変わるかを具体的に書く", "enabled": true, "severity": "warning"}
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeStopWritingLintConfig(t *testing.T, dir string) {
	t.Helper()
	config := "writing_lint:\n  enabled: true\n"
	if err := os.WriteFile(filepath.Join(dir, harnessConfigFileName), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}
}

// writeChangedFilesEntry appends one changed-files.jsonl entry for file under
// dir/.claude/state/changed-files.jsonl, mirroring track_changes.go's format.
func writeChangedFilesEntry(t *testing.T, dir, file string) {
	t.Helper()
	stateDir := filepath.Join(dir, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	entry := changedFileEntry{File: file, Action: "Write", Timestamp: "2026-08-15T00:00:00Z"}
	line, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(filepath.Join(stateDir, "changed-files.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.Write(append(line, '\n')); err != nil {
		t.Fatal(err)
	}
}

func TestStopWritingLint_EmptyInputNoTouchedFiles(t *testing.T) {
	dir := t.TempDir()
	writeStopWritingLintConfig(t, dir)
	dictPath := writeStopWritingLintDictFixture(t, dir)
	t.Setenv(writinglint.EnvDictPath, dictPath)

	h := &StopWritingLintHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(""), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertStopOK(t, out.String(), true)
}

func TestStopWritingLint_DisabledByDefaultSkipsScan(t *testing.T) {
	dir := t.TempDir()
	dictPath := writeStopWritingLintDictFixture(t, dir)
	t.Setenv(writinglint.EnvDictPath, dictPath)
	writeChangedFilesEntry(t, dir, "notes.md")
	if err := os.WriteFile(filepath.Join(dir, "notes.md"), []byte("以下に示します。"), 0o644); err != nil {
		t.Fatal(err)
	}
	// no config file written -> enabled defaults to false

	h := &StopWritingLintHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(""), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertStopOK(t, out.String(), true)
}

// (a) major 残存 fixture で初回 block -> 再入 approve のテスト
func TestStopWritingLint_ReentryAllowsStopWithWarning(t *testing.T) {
	dir := t.TempDir()
	writeStopWritingLintConfig(t, dir)
	dictPath := writeStopWritingLintDictFixture(t, dir)
	t.Setenv(writinglint.EnvDictPath, dictPath)

	writeChangedFilesEntry(t, dir, "notes.md")
	if err := os.WriteFile(filepath.Join(dir, "notes.md"), []byte("以下に示します。ここから本題です。"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 初回 Stop: major が残っているので block
	h := &StopWritingLintHandler{ProjectRoot: dir}
	var first bytes.Buffer
	if err := h.Handle(strings.NewReader(`{"stop_hook_active":false}`), &first); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertStopBlocked(t, first.String(), "notes.md")

	// 再入 (stop_hook_active:true): 同じ major が残っていても停止を許可し、警告のみ
	var second bytes.Buffer
	if err := h.Handle(strings.NewReader(`{"stop_hook_active":true}`), &second); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var resp map[string]interface{}
	if err := json.Unmarshal([]byte(strings.TrimSpace(second.String())), &resp); err != nil {
		t.Fatalf("invalid JSON output: %v\noutput: %s", err, second.String())
	}
	if decision, _ := resp["decision"].(string); decision == "block" {
		t.Fatalf("Stop re-entry with major writing-lint hits must not block, got decision=%q\noutput: %s", decision, second.String())
	}
	if ok, _ := resp["ok"].(bool); !ok {
		t.Fatalf("Stop re-entry must return ok:true, got ok=%v\noutput: %s", resp["ok"], second.String())
	}
	sysMsg, _ := resp["systemMessage"].(string)
	if sysMsg == "" {
		t.Fatalf("Stop re-entry must include a systemMessage warning\noutput: %s", second.String())
	}
	if !strings.Contains(sysMsg, "notes.md") {
		t.Errorf("systemMessage should mention the offending file, got: %q", sysMsg)
	}
}

// (b) minor のみで初回から block しない
func TestStopWritingLint_MinorOnlyDoesNotBlock(t *testing.T) {
	dir := t.TempDir()
	writeStopWritingLintConfig(t, dir)
	dictPath := writeStopWritingLintDictFixture(t, dir)
	t.Setenv(writinglint.EnvDictPath, dictPath)

	writeChangedFilesEntry(t, dir, "notes.md")
	if err := os.WriteFile(filepath.Join(dir, "notes.md"), []byte("重要なのはこの点である。"), 0o644); err != nil {
		t.Fatal(err)
	}

	h := &StopWritingLintHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(`{"stop_hook_active":false}`), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertStopOK(t, out.String(), true)
}

func TestStopWritingLint_NonMDFileIgnored(t *testing.T) {
	dir := t.TempDir()
	writeStopWritingLintConfig(t, dir)
	dictPath := writeStopWritingLintDictFixture(t, dir)
	t.Setenv(writinglint.EnvDictPath, dictPath)

	writeChangedFilesEntry(t, dir, "notes.txt")
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("以下に示します。"), 0o644); err != nil {
		t.Fatal(err)
	}

	h := &StopWritingLintHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(""), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertStopOK(t, out.String(), true)
}

func TestStopWritingLint_CleanFileNoBlock(t *testing.T) {
	dir := t.TempDir()
	writeStopWritingLintConfig(t, dir)
	dictPath := writeStopWritingLintDictFixture(t, dir)
	t.Setenv(writinglint.EnvDictPath, dictPath)

	writeChangedFilesEntry(t, dir, "notes.md")
	if err := os.WriteFile(filepath.Join(dir, "notes.md"), []byte("これは問題のない文章です。"), 0o644); err != nil {
		t.Fatal(err)
	}

	h := &StopWritingLintHandler{ProjectRoot: dir}
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(""), &out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertStopOK(t, out.String(), true)
}
