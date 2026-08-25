package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/internal/livemsggate"
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
	livemsgVerificationGate = func(inboxSendOpts) (livemsgVerificationDecision, *livemsggate.Result) {
		calls++
		return livemsgVerificationSend, nil
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
	livemsgVerificationGate = func(inboxSendOpts) (livemsgVerificationDecision, *livemsggate.Result) {
		calls++
		return livemsgVerificationSend, nil
	}

	if code := runInboxSendWithVerification(t, "on"); code != 0 {
		t.Fatalf("send exit = %d, want 0", code)
	}
	if calls != 1 {
		t.Fatalf("gate calls = %d, want 1 when verification is on", calls)
	}
}

// TestInboxSendVerificationHoldBlocksDelivery pins that the gate's verdict
// actually decides the send. Phase 141.7 originally discarded the return
// value, so a HOLD would have been delivered anyway — the seam existed but
// could never hold anything back.
func TestInboxSendVerificationHoldBlocksDelivery(t *testing.T) {
	original := livemsgVerificationGate
	t.Cleanup(func() { livemsgVerificationGate = original })
	livemsgVerificationGate = func(inboxSendOpts) (livemsgVerificationDecision, *livemsggate.Result) {
		return livemsgVerificationDecision("HOLD"), nil
	}

	t.Setenv("HARNESS_LIVEMSG_VERIFICATION", "on")
	t.Setenv("HARNESS_PROJECT_ROOT", t.TempDir())
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	dbPath := filepath.Join(t.TempDir(), "livemsg.db")

	var stdout, stderr bytes.Buffer
	code := runInboxSendCommand([]string{
		"--team", "team", "--from", "sender", "--to", "receiver", "--db", dbPath, "body",
	}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("HOLD send exit = 0, want non-zero")
	}
	if !strings.Contains(stderr.String(), "held by verification gate") {
		t.Fatalf("sender was not told why: stderr = %q", stderr.String())
	}

	// The recipient must not see the message at all.
	var checkOut, checkErr bytes.Buffer
	if code := runInboxCheckCommand([]string{
		"--team", "team", "--agent", "receiver", "--db", dbPath,
	}, &checkOut, &checkErr); code != 0 {
		t.Fatalf("inbox check exit = %d", code)
	}
	if strings.Contains(checkOut.String(), "\"unread\":1") {
		t.Fatalf("held message was delivered: %s", checkOut.String())
	}
}
