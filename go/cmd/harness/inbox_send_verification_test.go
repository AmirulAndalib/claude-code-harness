package main

import (
	"bytes"
	"path/filepath"
	"testing"
)

func runInboxSendWithVerification(t *testing.T, verification string) int {
	t.Helper()
	t.Setenv("HARNESS_LIVEMSG_VERIFICATION", verification)
	t.Setenv("HARNESS_PROJECT_ROOT", t.TempDir())
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	dbPath := filepath.Join(t.TempDir(), "livemsg.db")
	var stdout, stderr bytes.Buffer
	return runInboxSendCommand([]string{
		"--team", "team", "--from", "sender", "--to", "receiver", "--db", dbPath, "body",
	}, &stdout, &stderr)
}

func TestInboxSendVerificationOffSkipsGate(t *testing.T) {
	original := livemsgVerificationGate
	t.Cleanup(func() { livemsgVerificationGate = original })
	calls := 0
	livemsgVerificationGate = func(inboxSendOpts) livemsgVerificationDecision {
		calls++
		return livemsgVerificationSend
	}

	if code := runInboxSendWithVerification(t, "off"); code != 0 {
		t.Fatalf("send exit = %d, want 0", code)
	}
	if calls != 0 {
		t.Fatalf("gate calls = %d, want 0 when verification is off", calls)
	}
}

func TestInboxSendVerificationOnCallsGate(t *testing.T) {
	original := livemsgVerificationGate
	t.Cleanup(func() { livemsgVerificationGate = original })
	calls := 0
	livemsgVerificationGate = func(inboxSendOpts) livemsgVerificationDecision {
		calls++
		return livemsgVerificationSend
	}

	if code := runInboxSendWithVerification(t, "on"); code != 0 {
		t.Fatalf("send exit = %d, want 0", code)
	}
	if calls != 1 {
		t.Fatalf("gate calls = %d, want 1 when verification is on", calls)
	}
}
