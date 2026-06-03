// Package orchestration wires the Phase 90 orchestration-visibility ledger
// rollup and scorecard summary into the Go hook handlers.
//
// The logic itself lives in shell scripts (scripts/orchestration-rollup.sh and
// scripts/orchestration-scorecard.sh) so it stays unit-testable and shared with
// non-Go callers. The Go handlers only invoke them:
//   - Run: folds a session into the lifetime accumulator at full-session
//     completion (TaskCompleted) and at session end (SessionEnd). Idempotent per
//     session_id, so invoking from both points never double-counts.
//   - Summary: produces the once-at-completion terminal summary shown to the user.
package orchestration

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// scriptTimeout caps a helper invocation so a hung jq can never block a hook.
const scriptTimeout = 5 * time.Second

// Run invokes scripts/orchestration-rollup.sh for the given session, folding the
// session's counted delegations into the lifetime accumulator.
//
// Record-only and fail-open: the script writes nothing to stdout, and any error
// here is intentionally ignored so orchestration telemetry never breaks a hook.
// sessionID may be empty — the script then resolves it from CLAUDE_SESSION_ID or
// session.json under projectRoot.
func Run(projectRoot, sessionID string) {
	script := resolveScript("orchestration-rollup.sh")
	if script == "" {
		return
	}

	args := []string{script}
	if sessionID != "" {
		args = append(args, sessionID)
	}

	ctx, cancel := context.WithTimeout(context.Background(), scriptTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "bash", args...)
	if projectRoot != "" {
		cmd.Dir = projectRoot
	}
	_ = cmd.Run() // fail-open
}

// Summary runs scripts/orchestration-scorecard.sh --format terminal and returns
// its stdout — the compact once-at-completion summary. Fail-open: returns "" on
// any error so a missing script or hung process never blocks the hook.
func Summary(projectRoot, sessionID string) string {
	script := resolveScript("orchestration-scorecard.sh")
	if script == "" {
		return ""
	}

	args := []string{script, "--format", "terminal"}
	if sessionID != "" {
		args = append(args, sessionID)
	}

	ctx, cancel := context.WithTimeout(context.Background(), scriptTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "bash", args...)
	if projectRoot != "" {
		cmd.Dir = projectRoot
	}
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

// resolveScript finds scripts/<name> relative to the running binary
// (<root>/bin/harness -> <root>/scripts/<name>), falling back to
// CLAUDE_PLUGIN_ROOT. Returns "" if not found.
func resolveScript(name string) string {
	if exe, err := os.Executable(); err == nil {
		root := filepath.Dir(filepath.Dir(exe)) // <root>/bin/harness -> <root>
		candidate := filepath.Join(root, "scripts", name)
		if fileExists(candidate) {
			return candidate
		}
	}
	if pr := os.Getenv("CLAUDE_PLUGIN_ROOT"); pr != "" {
		candidate := filepath.Join(pr, "scripts", name)
		if fileExists(candidate) {
			return candidate
		}
	}
	return ""
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
