package guardrail

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
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

// Product default since v5.11.0 is warn (operator decision 2026-08-22).
func TestBuildContextDestructiveDeletePolicyDefaultsToWarn(t *testing.T) {
	clearGuardrailKnobEnv(t)
	ctx := BuildContext(bashInput(t.TempDir(), "rm -rf ./x"))
	if ctx.DestructiveDeletePolicy != "warn" {
		t.Fatalf("DestructiveDeletePolicy = %q, want warn (product default)", ctx.DestructiveDeletePolicy)
	}
}

// Producer tests use "ask" (the non-default value) so they prove the source
// actually drives the result instead of passing vacuously on the default.
func TestBuildContextDestructiveDeletePolicyFromEnv(t *testing.T) {
	clearGuardrailKnobEnv(t)
	t.Setenv("HARNESS_DESTRUCTIVE_DELETE_POLICY", "ask")
	ctx := BuildContext(bashInput(t.TempDir(), "rm -rf ./x"))
	if ctx.DestructiveDeletePolicy != "ask" {
		t.Fatalf("DestructiveDeletePolicy = %q, want ask (env opt-out over warn default)", ctx.DestructiveDeletePolicy)
	}
}

func TestBuildContextDestructiveDeletePolicyFromProjectYAML(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".claude-code-harness.config.yaml"),
		[]byte("safety:\n  protected_branch_push: ask\n  destructive_delete: ask\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx := BuildContext(bashInput(dir, "rm -rf ./x"))
	if ctx.DestructiveDeletePolicy != "ask" {
		t.Fatalf("DestructiveDeletePolicy = %q, want ask (from YAML, opt-out over warn default)", ctx.DestructiveDeletePolicy)
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
		[]byte("[safety.permissions]\ndestructiveDelete = \"ask\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	input := bashInput(project, "rm -rf ./x")
	input.PluginRoot = plugin
	ctx := BuildContext(input)
	if ctx.DestructiveDeletePolicy != "ask" {
		t.Fatalf("DestructiveDeletePolicy = %q, want ask (from plugin harness.toml, opt-out over warn default)", ctx.DestructiveDeletePolicy)
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

// v5.11.0: the unconfigured default is warn — same approve+record contract as
// an explicit warn.
func TestEvaluatePreTool_DestructiveDeleteDefaultWarnsAndRecords(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := t.TempDir()
	result := EvaluatePreTool(bashInput(dir, "cd "+dir+" && echo hi && rm -rf tmp/pdfs/s0-progress"))
	if result.Decision != hookproto.DecisionApprove {
		t.Fatalf("expected approve by default (warn), got %s: %s", result.Decision, result.Reason)
	}
	if !strings.HasPrefix(result.SystemMessage, "R05_WARN:") {
		t.Fatalf("expected R05_WARN warning by default, got %q", result.SystemMessage)
	}
	if records := readDestructiveDeleteRecords(t, dir); len(records) != 1 {
		t.Fatalf("default warn must write exactly 1 record, got %d", len(records))
	}
}

// A repo can opt back out to the pre-v5.11.0 behaviour with an explicit ask.
func TestEvaluatePreTool_DestructiveDeleteExplicitAskOptOutAsksAndDoesNotRecord(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "harness.toml"),
		[]byte("[safety.permissions]\ndestructiveDelete = \"ask\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	result := EvaluatePreTool(bashInput(dir, "cd "+dir+" && echo hi && rm -rf tmp/pdfs/s0-progress"))
	if result.Decision != hookproto.DecisionAsk {
		t.Fatalf("expected ask with explicit opt-out, got %s", result.Decision)
	}
	if records := readDestructiveDeleteRecords(t, dir); len(records) != 0 {
		t.Fatalf("opt-out ask must not write a warn record, got %d", len(records))
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

// ---------------------------------------------------------------------------
// destructive_delete=defer (Phase 140.1): deny + queue, no duplicate on retry
// ---------------------------------------------------------------------------

func readDeferredOps(t *testing.T, dir string) []deferredOpEntry {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, ".claude", "state", deferredOpsFile))
	if err != nil {
		return nil
	}
	var entries []deferredOpEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var e deferredOpEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("bad deferred-ops line %q: %v", line, err)
		}
		entries = append(entries, e)
	}
	return entries
}

func deferProject(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "harness.toml"),
		[]byte("[safety.permissions]\ndestructiveDelete = \"defer\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// DoD (a): defer → deny + exactly one queue line carrying the fields the
// operator needs to review it later.
func TestEvaluatePreTool_DestructiveDeleteDeferDeniesAndQueues(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := deferProject(t)
	command := "cd " + dir + " && rm -rf ./build/*"

	result := EvaluatePreTool(bashInput(dir, command))
	if result.Decision != hookproto.DecisionDeny {
		t.Fatalf("expected deny under defer, got %s: %s", result.Decision, result.Reason)
	}
	if !strings.HasPrefix(result.Reason, "R05_DEFER:") {
		t.Fatalf("expected R05_DEFER reason, got %q", result.Reason)
	}
	ops := readDeferredOps(t, dir)
	if len(ops) != 1 {
		t.Fatalf("expected 1 deferred op, got %d", len(ops))
	}
	op := ops[0]
	if op.Command != command || op.RuleID != "R05:confirm-rm-rf" || op.SessionID != "session-0123456789abcdef" ||
		op.Policy != "defer" || op.Status != "pending" || op.Timestamp == "" || op.Reason == "" || op.CWD != dir {
		t.Fatalf("unexpected deferred op: %+v", op)
	}
	if op.ID == "" || !strings.Contains(result.Reason, op.ID) {
		t.Fatalf("deny reason must cite the queue id %q:\n%s", op.ID, result.Reason)
	}
	if records := readDestructiveDeleteRecords(t, dir); len(records) != 0 {
		t.Fatalf("a deferred deletion is not a warn approval; got %d warn records", len(records))
	}
}

// DoD (b): retrying the same command keeps denying and does not grow the queue.
func TestEvaluatePreTool_DestructiveDeleteDeferRetryDoesNotDuplicate(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := deferProject(t)
	command := "cd " + dir + " && rm -rf ./build/*"
	for i := 0; i < 3; i++ {
		if result := EvaluatePreTool(bashInput(dir, command)); result.Decision != hookproto.DecisionDeny {
			t.Fatalf("retry %d: expected deny, got %s", i, result.Decision)
		}
	}
	if ops := readDeferredOps(t, dir); len(ops) != 1 {
		t.Fatalf("expected the queue to hold 1 entry after retries, got %d", len(ops))
	}
	// A different deletion is a different queue entry.
	if result := EvaluatePreTool(bashInput(dir, "cd "+dir+" && rm -rf ./dist/*")); result.Decision != hookproto.DecisionDeny {
		t.Fatalf("expected deny for the second command, got %s", result.Decision)
	}
	if ops := readDeferredOps(t, dir); len(ops) != 2 {
		t.Fatalf("expected 2 distinct entries, got %d", len(ops))
	}
}

// DoD (c): the existing warn approval (local spelling) and the explicit ask
// opt-out are unchanged by the new value.
func TestEvaluatePreTool_DestructiveDeleteDeferKeepsWarnPathAndAskOptOut(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := deferProject(t)
	result := EvaluatePreTool(bashInput(dir, "cd "+dir+" && echo hi && rm -rf tmp/pdfs/s0-progress"))
	if result.Decision != hookproto.DecisionApprove || !strings.HasPrefix(result.SystemMessage, "R05_WARN:") {
		t.Fatalf("defer must keep the warn approval for a local spelling, got %s / %q", result.Decision, result.SystemMessage)
	}
	if records := readDestructiveDeleteRecords(t, dir); len(records) != 1 {
		t.Fatalf("warn record expected under defer for the local spelling, got %d", len(records))
	}
	if ops := readDeferredOps(t, dir); len(ops) != 0 {
		t.Fatalf("a warn-approved deletion must not be queued, got %d", len(ops))
	}

	askDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(askDir, "harness.toml"),
		[]byte("[safety.permissions]\ndestructiveDelete = \"ask\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if result := EvaluatePreTool(bashInput(askDir, "cd "+askDir+" && rm -rf ./build/*")); result.Decision != hookproto.DecisionAsk {
		t.Fatalf("ask opt-out must still ask, got %s", result.Decision)
	}
	if ops := readDeferredOps(t, askDir); len(ops) != 0 {
		t.Fatalf("ask must not queue, got %d", len(ops))
	}
}

// The env knob reaches defer too (operator override over the file layers).
func TestBuildContextDestructiveDeletePolicyDeferFromEnv(t *testing.T) {
	clearGuardrailKnobEnv(t)
	t.Setenv("HARNESS_DESTRUCTIVE_DELETE_POLICY", "defer")
	if ctx := BuildContext(bashInput(t.TempDir(), "rm -rf ./x")); ctx.DestructiveDeletePolicy != "defer" {
		t.Fatalf("DestructiveDeletePolicy = %q, want defer", ctx.DestructiveDeletePolicy)
	}
}

// 140.2 lifecycle end-to-end through EvaluatePreTool: deny + queue → operator
// approve → the next identical run is allowed exactly once (recorded with
// policy=defer, queue entry consumed) → the run after that is denied again and
// re-queued as a fresh pending line with the same id.
func TestEvaluatePreTool_DeferApproveAllowsExactlyOnce(t *testing.T) {
	clearGuardrailKnobEnv(t)
	dir := deferProject(t)
	command := "cd " + dir + " && rm -rf ./build/*"

	// 1. deny + queue
	if result := EvaluatePreTool(bashInput(dir, command)); result.Decision != hookproto.DecisionDeny {
		t.Fatalf("expected initial deny, got %s", result.Decision)
	}
	ops := readDeferredOps(t, dir)
	if len(ops) != 1 || ops[0].Status != deferredOpStatusPending {
		t.Fatalf("expected 1 pending queue entry, got %+v", ops)
	}
	id := ops[0].ID

	// 2. operator approves
	if err := ApproveDeferredOp(dir, id); err != nil {
		t.Fatalf("ApproveDeferredOp: %v", err)
	}
	ops = readDeferredOps(t, dir)
	if len(ops) != 1 || ops[0].Status != deferredOpStatusApproved || ops[0].ApprovedAt == "" {
		t.Fatalf("expected approved entry with approved_at, got %+v", ops)
	}

	// 3. next identical run is allowed once, recorded with policy=defer
	result := EvaluatePreTool(bashInput(dir, command))
	if result.Decision != hookproto.DecisionApprove {
		t.Fatalf("expected approve after operator approval, got %s: %s", result.Decision, result.Reason)
	}
	if !strings.HasPrefix(result.SystemMessage, "R05_DEFER_APPROVED:") {
		t.Fatalf("expected R05_DEFER_APPROVED message, got %q", result.SystemMessage)
	}
	records := readDestructiveDeleteRecords(t, dir)
	if len(records) != 1 || records[0].Policy != "defer" {
		t.Fatalf("expected 1 record with policy=defer, got %+v", records)
	}
	ops = readDeferredOps(t, dir)
	if len(ops) != 1 || ops[0].Status != deferredOpStatusConsumed || ops[0].ConsumedAt == "" {
		t.Fatalf("expected consumed entry with consumed_at, got %+v", ops)
	}

	// 4. the approval is spent: deny again + fresh pending line, same id
	if result := EvaluatePreTool(bashInput(dir, command)); result.Decision != hookproto.DecisionDeny {
		t.Fatalf("expected deny after the approval was spent, got %s", result.Decision)
	}
	ops = readDeferredOps(t, dir)
	if len(ops) != 2 || ops[1].Status != deferredOpStatusPending || ops[1].ID != id {
		t.Fatalf("expected re-queued pending line with the same id, got %+v", ops)
	}
}

// approve targets only the single pending line with the id: a consumed line
// with the same id is untouched, an unknown id fails loudly, and unparseable
// lines survive the rewrite verbatim.
func TestApproveDeferredOp_FlipsPendingOnlyAndPreservesDamagedLines(t *testing.T) {
	dir := t.TempDir()
	stateDir := filepath.Join(dir, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	queue := filepath.Join(stateDir, deferredOpsFile)
	damaged := "{not json"
	lines := damaged + "\n" +
		`{"id":"aaaaaaaaaaaa","command":"x","rule_id":"R05:confirm-rm-rf","policy":"defer","reason":"r","status":"consumed"}` + "\n" +
		`{"id":"aaaaaaaaaaaa","command":"x","rule_id":"R05:confirm-rm-rf","policy":"defer","reason":"r","status":"pending"}` + "\n"
	if err := os.WriteFile(queue, []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := ApproveDeferredOp(dir, "bbbbbbbbbbbb"); err == nil {
		t.Fatal("expected error for unknown id")
	}
	if err := ApproveDeferredOp(dir, "aaaaaaaaaaaa"); err != nil {
		t.Fatalf("ApproveDeferredOp: %v", err)
	}
	data, err := os.ReadFile(queue)
	if err != nil {
		t.Fatal(err)
	}
	content := string(data)
	if !strings.Contains(content, damaged) {
		t.Fatalf("damaged line was dropped by the rewrite:\n%s", content)
	}
	if strings.Count(content, `"status":"approved"`) != 1 ||
		strings.Count(content, `"status":"consumed"`) != 1 {
		t.Fatalf("expected exactly the pending line flipped, got:\n%s", content)
	}
	// approving again must fail: nothing is pending any more
	if err := ApproveDeferredOp(dir, "aaaaaaaaaaaa"); err == nil {
		t.Fatal("expected error when no pending line remains")
	}
}

// ListDeferredOps returns entries in file order and skips damaged lines for
// display without touching the file.
func TestListDeferredOps_SkipsDamagedLines(t *testing.T) {
	dir := t.TempDir()
	stateDir := filepath.Join(dir, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	queue := filepath.Join(stateDir, deferredOpsFile)
	lines := "{broken\n" +
		`{"id":"cccccccccccc","command":"y","rule_id":"R05:confirm-rm-rf","policy":"defer","reason":"r","status":"pending"}` + "\n"
	if err := os.WriteFile(queue, []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}
	views, err := ListDeferredOps(dir)
	if err != nil {
		t.Fatalf("ListDeferredOps: %v", err)
	}
	if len(views) != 1 || views[0].ID != "cccccccccccc" || views[0].Status != "pending" {
		t.Fatalf("unexpected views: %+v", views)
	}
	if views, err = ListDeferredOps(t.TempDir()); err != nil || views != nil {
		t.Fatalf("missing file must yield nil, nil; got %+v, %v", views, err)
	}
}

// 140.2 review follow-up: the dedup check and the append are one critical
// section under the queue file lock. Concurrent identical deferrals must
// produce exactly one pending line (the old unlocked check-then-append could
// race into duplicates or lose an append against a concurrent flip rewrite).
func TestRecordDeferredOp_ConcurrentIdenticalCommandsQueueOnce(t *testing.T) {
	dir := t.TempDir()
	input := bashInput(dir, "cd "+dir+" && rm -rf ./build/*")
	result := hookproto.HookResult{
		Decision: hookproto.DecisionDeny,
		RuleID:   "R05:confirm-rm-rf",
		Reason:   "R05_DEFER: x",
	}
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			recordDeferredOp(dir, input, result)
		}()
	}
	wg.Wait()
	ops := readDeferredOps(t, dir)
	if len(ops) != 1 || ops[0].Status != deferredOpStatusPending {
		t.Fatalf("expected exactly 1 pending line after concurrent records, got %+v", ops)
	}
}

// approve stamps approved_by so the audit trail distinguishes the operator's
// CLI action.
func TestApproveDeferredOp_StampsApprovedBy(t *testing.T) {
	dir := t.TempDir()
	stateDir := filepath.Join(dir, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	queue := filepath.Join(stateDir, deferredOpsFile)
	line := `{"id":"dddddddddddd","command":"x","rule_id":"R05:confirm-rm-rf","policy":"defer","reason":"r","status":"pending"}` + "\n"
	if err := os.WriteFile(queue, []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ApproveDeferredOp(dir, "dddddddddddd"); err != nil {
		t.Fatalf("ApproveDeferredOp: %v", err)
	}
	ops := readDeferredOps(t, dir)
	if len(ops) != 1 || ops[0].ApprovedBy == "" || !strings.HasPrefix(ops[0].ApprovedBy, "cli") {
		t.Fatalf("expected approved_by stamp, got %+v", ops)
	}
}
