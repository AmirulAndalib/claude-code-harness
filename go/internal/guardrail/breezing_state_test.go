package guardrail

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/internal/hookcodec"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

func writeStateFile(t *testing.T, projectRoot, name, body string) {
	t.Helper()
	stateDir := filepath.Join(projectRoot, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func srcWriteInput(root, sessionID string) hookproto.HookInput {
	return hookproto.HookInput{
		SessionID: sessionID,
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, "src", "x.ts"),
			"content":   "code",
		},
	}
}

// --- R08 producer: roles file -------------------------------------------

// RED baseline (2026-08-11 実測): roles ファイルに reviewer を登録しても、
// Go ガードレールは env しか見ないため R08 は発火しなかった。
// このテストは file-based producer の復元を pin する。
func TestR08_FiresViaRolesFile(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-session-roles.json",
		`{"sess-rev-1":{"role":"reviewer"}}`)

	result := EvaluatePreTool(srcWriteInput(root, "sess-rev-1"))
	if result.Decision != hookproto.DecisionDeny {
		t.Fatalf("reviewer write must be denied, got %+v", result)
	}
	if result.RuleID != "R08:breezing-reviewer-no-write" {
		t.Fatalf("rule = %q, want R08", result.RuleID)
	}
}

// 別セッションの登録はこのセッションに波及しない。
func TestR08_RolesFileDoesNotLeakAcrossSessions(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-session-roles.json",
		`{"sess-other":{"role":"reviewer"}}`)

	result := EvaluatePreTool(srcWriteInput(root, "sess-mine"))
	if result.Decision == hookproto.DecisionDeny {
		t.Fatalf("other session's reviewer role must not leak: %+v", result)
	}
}

// agent_id は session_id より優先して引く (shell parity: AGENT_ID → SESSION_ID)。
func TestR08_AgentIDLookupWins(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-session-roles.json",
		`{"agent-42":{"role":"reviewer"}}`)

	input := srcWriteInput(root, "sess-parent")
	input.AgentID = "agent-42"
	result := EvaluatePreTool(input)
	if result.Decision != hookproto.DecisionDeny {
		t.Fatalf("agent-id keyed reviewer must be denied, got %+v", result)
	}
}

// CC-native: breezing 実行中の reviewer subagent は agent_type だけで判定される。
func TestR08_ReviewerAgentTypeDuringBreezing(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-active.json", `{"phase":"A"}`)

	input := srcWriteInput(root, "sess-parent")
	input.AgentType = "reviewer"
	result := EvaluatePreTool(input)
	if result.Decision != hookproto.DecisionDeny {
		t.Fatalf("reviewer subagent during breezing must be denied, got %+v", result)
	}

	// breezing 非実行時は agent_type=reviewer でも発火しない (scope 限定)
	root2 := t.TempDir()
	input2 := srcWriteInput(root2, "sess-parent")
	input2.AgentType = "reviewer"
	result2 := EvaluatePreTool(input2)
	if result2.Decision == hookproto.DecisionDeny {
		t.Fatalf("reviewer agent_type outside breezing must not deny: %+v", result2)
	}
}

// shell parity: reviewer でも .claude/state/ への書き込み (verdict artifact 等)
// は許可される。
func TestR08_ReviewerMayWriteStateArtifacts(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-session-roles.json",
		`{"sess-rev-2":{"role":"reviewer"}}`)

	input := hookproto.HookInput{
		SessionID: "sess-rev-2",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "review-report.json"),
			"content":   `{"verdict":"APPROVE"}`,
		},
	}
	result := EvaluatePreTool(input)
	if result.Decision == hookproto.DecisionDeny {
		t.Fatalf("reviewer must be able to write state artifacts, got %+v", result)
	}
}

// traversal を含む file_path で R08 の state 例外をすり抜けられないこと
// (2026-08-11 レビューで発見・実測されたバイパスの回帰網)。
func TestR08_StateExemptionNotBypassedByTraversal(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-session-roles.json",
		`{"sess-rev-trav":{"role":"reviewer"}}`)

	for _, target := range []string{
		filepath.Join(root, ".claude", "state", "..", "..", "src", "x.ts"),
		root + "/.claude/state/../../src/x.ts",
		".claude/state/../../src/x.ts",
	} {
		input := hookproto.HookInput{
			SessionID: "sess-rev-trav",
			CWD:       root,
			ToolName:  "Write",
			ToolInput: map[string]interface{}{"file_path": target, "content": "evil"},
		}
		result := EvaluatePreTool(input)
		if result.Decision != hookproto.DecisionDeny {
			t.Fatalf("traversal path %q must still be denied by R08, got %+v", target, result)
		}
	}
}

// --- wire round-trip: hookcodec → guardrail ------------------------------

// agent_id / agent_type は実配線 (hookcodec.Normalize) を通って guardrail に
// 届かなければならない。hand-built HookInput だけの unit test は wire の欠落を
// 見逃す (2026-08-11 レビューで実測: Normalize が両 field を落としていた)。
func TestAgentFieldsSurviveWireNormalize(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-active.json", `{"phase":"A"}`)

	raw := []byte(`{"session_id":"sess-wire","cwd":` + jsonString(root) + `,` +
		`"agent_id":"agent-wire-1","agent_type":"reviewer",` +
		`"tool_name":"Write","tool_input":{"file_path":` + jsonString(filepath.Join(root, "src", "x.ts")) + `,"content":"a"}}`)

	input, _, err := hookcodec.Normalize(raw, "claude")
	if err != nil {
		t.Fatalf("Normalize: %v", err)
	}
	if input.AgentID != "agent-wire-1" || input.AgentType != "reviewer" {
		t.Fatalf("agent fields dropped on the wire: %+v", input)
	}

	// wire を通った input で R08 (agent_type=reviewer + breezing active) が発火する
	result := EvaluatePreTool(input)
	if result.Decision != hookproto.DecisionDeny || result.RuleID != "R08:breezing-reviewer-no-write" {
		t.Fatalf("wire-normalized reviewer subagent must hit R08, got %+v", result)
	}
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// --- R07 producer: breezing-active impl_mode ----------------------------

// RED baseline (2026-08-11 実測): impl_mode=codex でも Go ガードレールは
// env しか見ないため R07 は発火しなかった。
func TestR07_FiresViaBreezingActiveImplMode(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-active.json", `{"impl_mode":"codex"}`)

	result := EvaluatePreTool(srcWriteInput(root, "sess-any"))
	if result.Decision != hookproto.DecisionDeny {
		t.Fatalf("codex-mode write must be denied, got %+v", result)
	}
	if result.RuleID != "R07:codex-mode-no-write" {
		t.Fatalf("rule = %q, want R07", result.RuleID)
	}

	// impl_mode が無ければ発火しない
	root2 := t.TempDir()
	writeStateFile(t, root2, "breezing-active.json", `{"phase":"A"}`)
	result2 := EvaluatePreTool(srcWriteInput(root2, "sess-any"))
	if result2.Decision == hookproto.DecisionDeny {
		t.Fatalf("non-codex breezing must not deny, got %+v", result2)
	}
}

// codex host (委譲先 worker) 自身の書き込みは R07 の対象外。
func TestR07_CodexHostItselfExempt(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-active.json", `{"impl_mode":"codex"}`)

	input := srcWriteInput(root, "sess-any")
	input.Host = "codex"
	result := EvaluatePreTool(input)
	if result.Decision == hookproto.DecisionDeny {
		t.Fatalf("codex host's own writes must not be blocked by R07: %+v", result)
	}
}

// --- role self-registration ---------------------------------------------

func TestRegisterBreezingRole_HappyPath(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	regInput := hookproto.HookInput{
		SessionID: "sess-reg-1",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "breezing-role-reviewer.json"),
			"content":   `{"role":"reviewer"}`,
		},
	}
	result := EvaluatePreTool(regInput)
	if result.Decision != hookproto.DecisionApprove {
		t.Fatalf("registration write must be approved, got %+v", result)
	}

	// 登録後、この session の src 書き込みは R08 で拒否される
	after := EvaluatePreTool(srcWriteInput(root, "sess-reg-1"))
	if after.Decision != hookproto.DecisionDeny || after.RuleID != "R08:breezing-reviewer-no-write" {
		t.Fatalf("post-registration write must hit R08, got %+v", after)
	}
}

// 登録キーは payload 由来のみ: content に他セッションの ID を書いても
// そのセッションに role は付かない。
func TestRegisterBreezingRole_CannotAssignToOtherSession(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	regInput := hookproto.HookInput{
		SessionID: "sess-attacker",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "breezing-role-x.json"),
			// content 内の session_id は無視されなければならない
			"content": `{"role":"reviewer","session_id":"sess-victim"}`,
		},
	}
	_ = EvaluatePreTool(regInput)

	data, err := os.ReadFile(filepath.Join(root, ".claude", "state", "breezing-session-roles.json"))
	if err != nil {
		t.Fatalf("roles file not written: %v", err)
	}
	var roles map[string]json.RawMessage
	if err := json.Unmarshal(data, &roles); err != nil {
		t.Fatal(err)
	}
	if _, ok := roles["sess-victim"]; ok {
		t.Fatalf("role must never be assigned to an id taken from content: %s", data)
	}
	if _, ok := roles["sess-attacker"]; !ok {
		t.Fatalf("role must be keyed by the payload session id: %s", data)
	}
}

// state dir の外への breezing-role-*.json Write は登録として扱わない。
func TestRegisterBreezingRole_OutsideStateDirIgnored(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	regInput := hookproto.HookInput{
		SessionID: "sess-reg-3",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, "src", "breezing-role-evil.json"),
			"content":   `{"role":"reviewer"}`,
		},
	}
	result := EvaluatePreTool(regInput)
	if result.RuleID == "BREEZING:role-register" {
		t.Fatalf("registration outside .claude/state must not be consumed: %+v", result)
	}
	if _, err := os.Stat(filepath.Join(root, ".claude", "state", "breezing-session-roles.json")); !os.IsNotExist(err) {
		t.Fatalf("roles file must not be created for out-of-state writes")
	}
}

// 不正な role 文字列は登録しない。
func TestRegisterBreezingRole_RejectsInvalidRole(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	regInput := hookproto.HookInput{
		SessionID: "sess-reg-4",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "breezing-role-x.json"),
			"content":   `{"role":"Reviewer; rm -rf /"}`,
		},
	}
	result := EvaluatePreTool(regInput)
	if result.RuleID == "BREEZING:role-register" {
		t.Fatalf("invalid role must not register: %+v", result)
	}
}

// --- env override precedence -------------------------------------------

// env の HARNESS_BREEZING_ROLE / HARNESS_CODEX_MODE は引き続き最優先
// (worktree spawn 経路の producer)。
func TestBreezingEnvOverridesStillWork(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	t.Setenv("HARNESS_BREEZING_ROLE", "reviewer")
	result := EvaluatePreTool(srcWriteInput(root, "sess-env"))
	if result.Decision != hookproto.DecisionDeny || result.RuleID != "R08:breezing-reviewer-no-write" {
		t.Fatalf("env-driven R08 must still fire, got %+v", result)
	}

	t.Setenv("HARNESS_BREEZING_ROLE", "")
	t.Setenv("HARNESS_CODEX_MODE", "1")
	result2 := EvaluatePreTool(srcWriteInput(root, "sess-env"))
	if result2.Decision != hookproto.DecisionDeny || result2.RuleID != "R07:codex-mode-no-write" {
		t.Fatalf("env-driven R07 must still fire, got %+v", result2)
	}
}
