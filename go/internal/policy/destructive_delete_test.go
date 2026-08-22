package policy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

func TestNormalizeDestructiveDeletePolicy(t *testing.T) {
	cases := map[string]string{
		"":        "ask",
		"ask":     "ask",
		"WARN":    "warn",
		" warn ":  "warn",
		`"warn"`:  "warn",
		"allow":   "ask", // no silent allow: warn is the only relaxation
		"approve": "ask",
		"unknown": "ask",
	}
	for input, want := range cases {
		if got := NormalizeDestructiveDeletePolicy(input); got != want {
			t.Errorf("NormalizeDestructiveDeletePolicy(%q) = %q, want %q", input, got, want)
		}
	}
}

func warnCtx(t *testing.T, command string) hookproto.RuleContext {
	t.Helper()
	ctx := makeCtx("Bash", map[string]interface{}{"command": command})
	ctx.ProjectRoot = t.TempDir()
	ctx.DestructiveDeletePolicy = DestructiveDeletePolicyWarn
	return ctx
}

// The memorised annoyance (2026-08-14 / 2026-08-22): any preceding segment
// makes the agent-owned proof impossible, so the default asks even for a
// target that is plainly inside the worktree. warn accepts the spelling.
func TestR05_WarnApprovesLocalSpellingAfterPrecedingSegment(t *testing.T) {
	commands := []string{
		"cd /anywhere && rm -rf tmp/pdfs/s0-progress",
		"echo hi && rm -rf ./dist",
		"cd /anywhere && rm -rf ./build; mkdir -p ./build",
	}
	for _, command := range commands {
		t.Run(command, func(t *testing.T) {
			ctx := warnCtx(t, command)
			result := EvaluateRules(ctx)
			if result.Decision != hookproto.DecisionApprove {
				t.Fatalf("expected approve under warn, got %s: %s", result.Decision, result.Reason)
			}
			if !strings.HasPrefix(result.SystemMessage, "R05_WARN:") {
				t.Fatalf("expected R05_WARN system message, got %q", result.SystemMessage)
			}
			if result.RuleID != "R05:confirm-rm-rf" {
				t.Fatalf("expected R05 rule id for the record hook, got %q", result.RuleID)
			}
		})
	}
}

func TestR05_WarnApprovesAbsoluteUnderRootAfterPrecedingSegment(t *testing.T) {
	ctx := warnCtx(t, "")
	target := filepath.Join(ctx.ProjectRoot, "build")
	ctx.Input.ToolInput["command"] = "echo hi && rm -rf " + target
	result := EvaluateRules(ctx)
	if result.Decision != hookproto.DecisionApprove {
		t.Fatalf("expected approve for absolute in-root target under warn, got %s: %s", result.Decision, result.Reason)
	}
}

// 133.10 residual, accepted knowingly under warn: a preceding segment can plant
// a symlink so that an in-root spelling resolves outside the worktree. The
// default (ask) still catches this — see TestR05_PrecedingSegmentCanCreateExternalSymlink.
func TestR05_WarnAcceptsPlantedSymlinkResidual(t *testing.T) {
	ctx := warnCtx(t, "")
	outside := t.TempDir()
	link := filepath.Join(ctx.ProjectRoot, "r05-link")
	if err := os.Symlink(outside, link); err != nil {
		t.Skip("symlink unsupported")
	}
	ctx.Input.ToolInput["command"] = "ln -sfn " + outside + " " + link + " && rm -rf " + filepath.Join(link, "victim")
	if result := EvaluateRules(ctx); result.Decision != hookproto.DecisionApprove {
		t.Fatalf("warn mode accepts the in-root spelling by design, got %s", result.Decision)
	}
	ctx.DestructiveDeletePolicy = ""
	if result := EvaluateRules(ctx); result.Decision != hookproto.DecisionAsk {
		t.Fatalf("default must still ask for the planted-symlink path, got %s", result.Decision)
	}
}

// The blast-radius backstop (spec.md HOTL invariant 3) survives warn mode.
func TestR05_WarnStillAsksOutsideTheBackstop(t *testing.T) {
	commands := []string{
		"cd /anywhere && rm -rf /var/data",          // absolute outside root
		"cd /anywhere && rm -rf ../sibling",         // parent traversal
		"cd /anywhere && rm -rf $DIR",               // unresolved variable
		"cd /anywhere && rm -rf ./build/*",          // glob
		"cd /anywhere && rm -rf .",                  // bare cwd
		"cd /anywhere && rm -rf /",                  // filesystem root
		"cd /anywhere && rm -rf ~/Library/Caches",   // home
		"cd /anywhere && rm -rf /tmp",               // shared temp root
		"cd /anywhere && rm -rf /tmp/other-session", // someone else's scratch
	}
	for _, command := range commands {
		t.Run(command, func(t *testing.T) {
			ctx := warnCtx(t, command)
			result := EvaluateRules(ctx)
			if result.Decision != hookproto.DecisionAsk {
				t.Fatalf("expected ask under warn for %q, got %s", command, result.Decision)
			}
		})
	}
}

func TestR05_WarnApprovesOwnSessionScratchAfterPrecedingSegment(t *testing.T) {
	sessionID := "session-0123456789abcdef"
	ctx := warnCtx(t, "echo hi && rm -rf "+filepath.Join(os.TempDir(), sessionID, "scratch"))
	ctx.Input.SessionID = sessionID
	result := EvaluateRules(ctx)
	if result.Decision != hookproto.DecisionApprove {
		t.Fatalf("expected approve for own session scratch under warn, got %s: %s", result.Decision, result.Reason)
	}
}

// Pins the default: with no policy set, the same command keeps asking.
func TestR05_DefaultStillAsksAfterPrecedingSegment(t *testing.T) {
	ctx := makeCtx("Bash", map[string]interface{}{"command": "cd /anywhere && rm -rf tmp/pdfs/s0-progress"})
	ctx.ProjectRoot = t.TempDir()
	result := EvaluateRules(ctx)
	if result.Decision != hookproto.DecisionAsk {
		t.Fatalf("expected ask by default, got %s", result.Decision)
	}
}

// warn never bypasses the rules that sit above R05 (R01 sudo) or the
// non-bypassable R06.
func TestR05_WarnDoesNotLeakIntoOtherRules(t *testing.T) {
	ctx := warnCtx(t, "sudo rm -rf ./dist")
	if result := EvaluateRules(ctx); result.Decision != hookproto.DecisionDeny {
		t.Fatalf("R01 must still deny sudo, got %s", result.Decision)
	}
}

// The warn approval is advisory: it must never preempt a hard deny declared
// later in the rule slice for the same compound command (CodeRabbit finding on
// PR #325 — the first R05 warn implementation returned before R08 ever ran).
func TestR05_WarnDoesNotPreemptLaterDenyRules(t *testing.T) {
	cases := []struct {
		name       string
		command    string
		mutate     func(*hookproto.RuleContext)
		wantRuleID string
	}{
		{
			name:       "R08 breezing reviewer no-write",
			command:    "echo hi && rm -rf ./dist",
			mutate:     func(ctx *hookproto.RuleContext) { ctx.BreezingRole = "reviewer" },
			wantRuleID: "R08:breezing-reviewer-no-write",
		},
		{
			name:       "R06 force push deny",
			command:    "echo hi && rm -rf ./dist && git push --force origin feature",
			mutate:     func(ctx *hookproto.RuleContext) {},
			wantRuleID: "R06:no-force-push",
		},
		{
			name:       "R10 git bypass flags deny",
			command:    "echo hi && rm -rf ./dist && git commit --no-verify -m x",
			mutate:     func(ctx *hookproto.RuleContext) {},
			wantRuleID: "R10:no-git-bypass-flags",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx := warnCtx(t, tc.command)
			tc.mutate(&ctx)
			result := EvaluateRules(ctx)
			if result.Decision != hookproto.DecisionDeny {
				t.Fatalf("expected deny from %s, got %s: %s", tc.wantRuleID, result.Decision, result.SystemMessage)
			}
			if result.RuleID != tc.wantRuleID {
				t.Fatalf("expected %s to win over the advisory warn approve, got %s", tc.wantRuleID, result.RuleID)
			}
		})
	}
}

// Push to a protected branch keeps its ask even when the same compound command
// contains a warn-approved deletion (the operator's main-branch exception).
func TestR05_WarnDoesNotPreemptProtectedBranchPushAsk(t *testing.T) {
	ctx := warnCtx(t, "rm -rf ./dist && git push origin main")
	result := EvaluateRules(ctx)
	if result.Decision != hookproto.DecisionAsk {
		t.Fatalf("expected R12 ask to win over the advisory warn approve, got %s", result.Decision)
	}
	if result.RuleID != "R12:confirm-direct-push-protected-branch" {
		t.Fatalf("expected R12 to win, got %s", result.RuleID)
	}
}

// Without a usable project root a relative spelling has no worktree to anchor
// to and the record file has nowhere to go — warn must keep asking.
func TestR05_WarnEmptyProjectRootStillAsks(t *testing.T) {
	ctx := makeCtx("Bash", map[string]interface{}{"command": "cd /anywhere && rm -rf tmp/x"})
	ctx.ProjectRoot = ""
	ctx.DestructiveDeletePolicy = DestructiveDeletePolicyWarn
	result := EvaluateRules(ctx)
	if result.Decision != hookproto.DecisionAsk {
		t.Fatalf("expected ask with empty project root under warn, got %s", result.Decision)
	}
}
