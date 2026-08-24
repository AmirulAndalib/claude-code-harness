package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func TestInboxSendRealGateHoldsMissingFileWithoutDelivery(t *testing.T) {
	repoRoot := t.TempDir()
	t.Setenv("HARNESS_LIVEMSG_VERIFICATION", "on")
	t.Setenv("HARNESS_PROJECT_ROOT", repoRoot)
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	dbPath := filepath.Join(t.TempDir(), "livemsg.db")

	var stdout, stderr bytes.Buffer
	code := runInboxSendCommand([]string{
		"--team", "team", "--from", "sender", "--to", "receiver", "--db", dbPath,
		"`docs/missing-report.md` を作成しました。",
	}, &stdout, &stderr)
	if code == 0 {
		t.Fatal("HOLD send exit = 0, want non-zero")
	}
	if !strings.Contains(stdout.String(), "docs/missing-report.md") || !strings.Contains(stdout.String(), "does not exist") {
		t.Fatalf("stdout does not contain the HOLD reason: %q", stdout.String())
	}

	var checkOut, checkErr bytes.Buffer
	if code := runInboxCheckCommand([]string{
		"--team", "team", "--agent", "receiver", "--db", dbPath,
	}, &checkOut, &checkErr); code != 0 {
		t.Fatalf("inbox check exit = %d; stderr = %q", code, checkErr.String())
	}
	if strings.TrimSpace(checkOut.String()) != "" {
		t.Fatalf("held message reached recipient inbox: %s", checkOut.String())
	}
}
