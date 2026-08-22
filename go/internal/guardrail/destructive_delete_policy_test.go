package guardrail

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

func bashInput(dir, command string) hookproto.HookInput {
	return hookproto.HookInput{
		SessionID: "session-0123456789abcdef",
		CWD:       dir,
		ToolName:  "Bash",
		ToolInput: map[string]interface{}{"command": command},
	}
}

func TestBuildContextDestructiveDeletePolicyDefaultsToAsk(t *testing.T) {
	clearGuardrailKnobEnv(t)
	ctx := BuildContext(bashInput(t.TempDir(), "rm -rf ./x"))
	if ctx.DestructiveDeletePolicy != "ask" {
		t.Fatalf("DestructiveDeletePolicy = %q, want ask", ctx.DestructiveDeletePolicy)
	}
}

func TestBuildContextDestructiveDeletePolicyFromEnv(t *testing.T) {
	clearGuardrailKnobEnv(t)
	t.Setenv("HARNESS_DESTRUCTIVE_DELETE_POLICY", "warn")
	ctx := BuildContext(bashInput(t.TempDir(), "rm -rf ./x"))
	if ctx.DestructiveDeletePolicy != "warn" {
		t.Fatalf("DestructiveDeletePolicy = %q, want warn", ctx.DestructiveDeletePolicy)
	}
}

func TestBuildContextDestructiveDeletePolicyFromProjectYAML(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".claude-code-harness.config.yaml"),
		[]byte("safety:\n  protected_branch_push: ask\n  destructive_delete: warn\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx := BuildContext(bashInput(dir, "rm -rf ./x"))
	if ctx.DestructiveDeletePolicy != "warn" {
		t.Fatalf("DestructiveDeletePolicy = %q, want warn (from YAML)", ctx.DestructiveDeletePolicy)
	}
	if ctx.ProtectedBranchPushPolicy != "ask" {
		t.Fatalf("ProtectedBranchPushPolicy = %q, want ask (shared YAML reader must not cross keys)", ctx.ProtectedBranchPushPolicy)
	}
}

func TestBuildContextDestructiveDeletePolicyFromPluginTOMLFallback(t *testing.T) {
	clearGuardrailKnobEnv(t)
	project := t.TempDir()
	plugin := t.TempDir()
	if err := os.WriteFile(filepath.Join(plugin, "harness.toml"),
		[]byte("[safety.permissions]\ndestructiveDelete = \"warn\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	input := bashInput(project, "rm -rf ./x")
	input.PluginRoot = plugin
	ctx := BuildContext(input)
	if ctx.DestructiveDeletePolicy != "warn" {
		t.Fatalf("DestructiveDeletePolicy = %q, want warn (from plugin harness.toml)", ctx.DestructiveDeletePolicy)
	}
}

func readDestructiveDeleteRecords(t *testing.T, dir string) []destructiveDeleteRecordEntry {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, ".claude", "state", destructiveDeleteRecordFile))
	if err != nil {
		return nil
	}
	var entries []destructiveDeleteRecordEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var e destructiveDeleteRecordEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("bad record line %q: %v", line, err)
		}
		entries = append(entries, e)
	}
	return entries
}

// End-to-end through EvaluatePreTool: warn approves the unprovable-but-local
// deletion AND leaves the review record. Approval without the record would be
// a silent allow, which the contract forbids.
func TestEvaluatePreTool_DestructiveDeleteWarnApprovesAndRecords(t *testing.T) {
	clearGuardrailKnobEnv(t)
	t.Setenv("HARNESS_DESTRUCTIVE_DELETE_POLICY", "warn")
	dir := t.TempDir()
	command := "cd " + dir + " && echo hi && rm -rf tmp/pdfs/s0-progress"

	result := EvaluatePreTool(bashInput(dir, command))
	if result.Decision != hookproto.DecisionApprove {
		t.Fatalf("expected approve under warn, got %s: %s", result.Decision, result.Reason)
	}
	if !strings.HasPrefix(result.SystemMessage, "R05_WARN:") {
		t.Fatalf("expected R05_WARN warning, got %q", result.SystemMessage)
	}
	records := readDestructiveDeleteRecords(t, dir)
	if len(records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(records))
	}
	if records[0].Command != command || records[0].Policy != "warn" || records[0].RuleID != "R05:confirm-rm-rf" || records[0].SessionID != "session-0123456789abcdef" {
		t.Fatalf("unexpected record: %+v", records[0])
	}
}

func TestEvaluatePreTool_DestructiveDeleteDefaultAsksAndDoesNotRecord(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := t.TempDir()
	result := EvaluatePreTool(bashInput(dir, "cd "+dir+" && echo hi && rm -rf tmp/pdfs/s0-progress"))
	if result.Decision != hookproto.DecisionAsk {
		t.Fatalf("expected ask by default, got %s", result.Decision)
	}
	if records := readDestructiveDeleteRecords(t, dir); len(records) != 0 {
		t.Fatalf("default ask must not write a warn record, got %d", len(records))
	}
}

func TestEvaluatePreTool_DestructiveDeleteWarnStillAsksOutsideRootAndDoesNotRecord(t *testing.T) {
	clearGuardrailKnobEnv(t)
	t.Setenv("HARNESS_DESTRUCTIVE_DELETE_POLICY", "warn")
	dir := t.TempDir()
	// Through the real entry point the runtime floor denies an out-of-worktree
	// deletion before R05 is even consulted; at the policy layer alone R05
	// asks (see TestR05_WarnStillAsksOutsideTheBackstop). Either way warn must
	// never turn it into an approval. The target is a sibling temp dir with no
	// session-id component, so it is neither in-root nor session scratch.
	outside := filepath.Join(t.TempDir(), "data")
	result := EvaluatePreTool(bashInput(dir, "cd "+dir+" && rm -rf "+outside))
	if result.Decision == hookproto.DecisionApprove {
		t.Fatalf("out-of-root target must not be approved under warn, got %s", result.Decision)
	}
	if records := readDestructiveDeleteRecords(t, dir); len(records) != 0 {
		t.Fatalf("ask must not write a warn record, got %d", len(records))
	}
}

// A provably agent-owned deletion is approved silently by the existing path;
// it must not be double-counted as a warn approval.
func TestEvaluatePreTool_DestructiveDeleteProvenLocalDoesNotRecord(t *testing.T) {
	clearGuardrailKnobEnv(t)
	t.Setenv("HARNESS_DESTRUCTIVE_DELETE_POLICY", "warn")
	dir := t.TempDir()
	result := EvaluatePreTool(bashInput(dir, "rm -rf "+filepath.Join(dir, "build")))
	if result.Decision != hookproto.DecisionApprove || result.SystemMessage != "" {
		t.Fatalf("expected silent approve for proven-local deletion, got %s / %q", result.Decision, result.SystemMessage)
	}
	if records := readDestructiveDeleteRecords(t, dir); len(records) != 0 {
		t.Fatalf("proven-local approve must not write a warn record, got %d", len(records))
	}
}
