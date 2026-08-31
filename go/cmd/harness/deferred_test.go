package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeDeferredQueue(t *testing.T, root, content string) {
	t.Helper()
	stateDir := filepath.Join(root, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "deferred-ops.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunDeferredCommand_ListShowsPendingWithApproveCommand(t *testing.T) {
	root := t.TempDir()
	writeDeferredQueue(t, root,
		`{"id":"aaaaaaaaaaaa","timestamp":"2026-08-31T00:00:00Z","command":"rm -rf ./build/*","rule_id":"R05:confirm-rm-rf","policy":"defer","reason":"r","status":"pending"}`+"\n"+
			`{"id":"bbbbbbbbbbbb","timestamp":"2026-08-31T00:01:00Z","command":"rm -rf ./dist/*","rule_id":"R05:confirm-rm-rf","policy":"defer","reason":"r","status":"consumed"}`+"\n")

	var stdout, stderr bytes.Buffer
	if code := runDeferredCommand([]string{"list", root}, &stdout, &stderr); code != 0 {
		t.Fatalf("list exited %d: %s", code, stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "aaaaaaaaaaaa") || !strings.Contains(out, "bin/harness deferred approve aaaaaaaaaaaa") {
		t.Fatalf("list output missing pending entry/approve command:\n%s", out)
	}
	if strings.Contains(out, "bbbbbbbbbbbb") {
		t.Fatalf("list output must not show consumed entries:\n%s", out)
	}
}

func TestRunDeferredCommand_ListEmptyAndJSON(t *testing.T) {
	root := t.TempDir()
	var stdout, stderr bytes.Buffer
	if code := runDeferredCommand([]string{"list", root}, &stdout, &stderr); code != 0 {
		t.Fatalf("list on empty root exited %d: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "no pending deferred ops") {
		t.Fatalf("expected empty message, got: %s", stdout.String())
	}
	stdout.Reset()
	if code := runDeferredCommand([]string{"list", root, "--json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("list --json exited %d: %s", code, stderr.String())
	}
	if strings.TrimSpace(stdout.String()) != "[]" {
		t.Fatalf("expected [] for empty JSON list, got: %s", stdout.String())
	}
}

func TestRunDeferredCommand_ApproveFlipsAndFailsOnUnknown(t *testing.T) {
	root := t.TempDir()
	writeDeferredQueue(t, root,
		`{"id":"cccccccccccc","timestamp":"2026-08-31T00:00:00Z","command":"rm -rf ./build/*","rule_id":"R05:confirm-rm-rf","policy":"defer","reason":"r","status":"pending"}`+"\n")

	var stdout, stderr bytes.Buffer
	if code := runDeferredCommand([]string{"approve", "cccccccccccc", root}, &stdout, &stderr); code != 0 {
		t.Fatalf("approve exited %d: %s", code, stderr.String())
	}
	data, err := os.ReadFile(filepath.Join(root, ".claude", "state", "deferred-ops.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"status":"approved"`) {
		t.Fatalf("queue entry not flipped to approved:\n%s", data)
	}

	stdout.Reset()
	stderr.Reset()
	if code := runDeferredCommand([]string{"approve", "ffffffffffff", root}, &stdout, &stderr); code == 0 {
		t.Fatal("approve of unknown id must fail")
	}
	if !strings.Contains(stderr.String(), "no pending deferred op") {
		t.Fatalf("expected not-found message, got: %s", stderr.String())
	}
}

func TestRunDeferredCommand_UsageErrors(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := runDeferredCommand(nil, &stdout, &stderr); code == 0 {
		t.Fatal("no args must fail")
	}
	if code := runDeferredCommand([]string{"approve"}, &stdout, &stderr); code == 0 {
		t.Fatal("approve without id must fail")
	}
	if code := runDeferredCommand([]string{"bogus"}, &stdout, &stderr); code == 0 {
		t.Fatal("unknown subcommand must fail")
	}
}
