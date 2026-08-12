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
		AgentID:   "agent-reg-happy",
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

	// 登録後、この subagent の src 書き込みは R08 で拒否される
	after := srcWriteInput(root, "sess-reg-1")
	after.AgentID = "agent-reg-happy"
	res := EvaluatePreTool(after)
	if res.Decision != hookproto.DecisionDeny || res.RuleID != "R08:breezing-reviewer-no-write" {
		t.Fatalf("post-registration write must hit R08, got %+v", res)
	}
}

// agent_id を持たない呼び出し (= main thread) は自己登録できない。
// session_id で登録できてしまうと、その session を共有する Lead 自身の
// Write が全滅する (2026-08-11 の敵対的再検証で実証したシナリオ)。
func TestRegisterBreezingRole_RefusesWithoutAgentID(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	regInput := hookproto.HookInput{
		SessionID: "sess-no-agent",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "breezing-role-r.json"),
			"content":   `{"role":"reviewer"}`,
		},
	}
	if result := EvaluatePreTool(regInput); result.RuleID == "BREEZING:role-register" {
		t.Fatalf("registration without agent_id must not be consumed: %+v", result)
	}
	if _, err := os.Stat(filepath.Join(root, ".claude", "state", "breezing-session-roles.json")); !os.IsNotExist(err) {
		t.Fatalf("roles file must not be created without agent_id")
	}

	// Lead (同一 session_id, agent fields なし) の Write は影響を受けない
	lead := EvaluatePreTool(srcWriteInput(root, "sess-no-agent"))
	if lead.Decision == hookproto.DecisionDeny {
		t.Fatalf("Lead's write must stay allowed: %+v", lead)
	}
}

// R08 の state 例外は symlink 経由でも破れない。
// (2026-08-11 の敵対的再検証: state 内に repo 内 src を指す symlink を作り、
//
//	その経由で任意ファイルへ書けた)
func TestR08_StateExemptionNotBypassedBySymlink(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-session-roles.json",
		`{"sess-rev-sym":{"role":"reviewer"}}`)
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, ".claude", "state", "escape")
	if err := os.Symlink(filepath.Join(root, "src"), link); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	input := hookproto.HookInput{
		SessionID: "sess-rev-sym",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(link, "x.ts"),
			"content":   "evil",
		},
	}
	if result := EvaluatePreTool(input); result.Decision != hookproto.DecisionDeny {
		t.Fatalf("symlink escape from state dir must be denied, got %+v", result)
	}

	// 正当な state 書き込みは引き続き許可される
	ok := hookproto.HookInput{
		SessionID: "sess-rev-sym",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "report.json"),
			"content":   "{}",
		},
	}
	if result := EvaluatePreTool(ok); result.Decision == hookproto.DecisionDeny {
		t.Fatalf("legit state write must stay allowed, got %+v", result)
	}
}

// reviewer は symlink 作成コマンド自体も実行できない (作成側の防御)。
func TestR08_ReviewerCannotCreateSymlink(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()
	writeStateFile(t, root, "breezing-session-roles.json",
		`{"sess-rev-ln":{"role":"reviewer"}}`)

	input := hookproto.HookInput{
		SessionID: "sess-rev-ln",
		CWD:       root,
		ToolName:  "Bash",
		ToolInput: map[string]interface{}{
			"command": "ln -sf " + root + "/src " + root + "/.claude/state/escape",
		},
	}
	if result := EvaluatePreTool(input); result.Decision != hookproto.DecisionDeny {
		t.Fatalf("reviewer must not create symlinks, got %+v", result)
	}

	// 読み取り系 Bash は引き続き許可される (非退行)
	ro := hookproto.HookInput{
		SessionID: "sess-rev-ln",
		CWD:       root,
		ToolName:  "Bash",
		ToolInput: map[string]interface{}{"command": "git diff --stat"},
	}
	if result := EvaluatePreTool(ro); result.Decision == hookproto.DecisionDeny {
		t.Fatalf("read-only bash must stay allowed, got %+v", result)
	}
}

// subagent からの登録は agent_id で key され、session_id には付かない。
// これが崩れると「subagent の reviewer 登録が同一 session の Lead まで
// 汚染して Lead の Write が全滅する」(2026-08-11 レビューの指摘シナリオ)。
func TestRegisterBreezingRole_SubagentKeysByAgentID(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	regInput := hookproto.HookInput{
		SessionID: "sess-shared",
		AgentID:   "agent-reg-1",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "breezing-role-reviewer.json"),
			"content":   `{"role":"reviewer"}`,
		},
	}
	if result := EvaluatePreTool(regInput); result.RuleID != "BREEZING:role-register" {
		t.Fatalf("registration not consumed: %+v", result)
	}

	data, err := os.ReadFile(filepath.Join(root, ".claude", "state", "breezing-session-roles.json"))
	if err != nil {
		t.Fatal(err)
	}
	var roles map[string]json.RawMessage
	if err := json.Unmarshal(data, &roles); err != nil {
		t.Fatal(err)
	}
	if _, ok := roles["agent-reg-1"]; !ok {
		t.Fatalf("subagent registration must key by agent_id: %s", data)
	}
	if _, ok := roles["sess-shared"]; ok {
		t.Fatalf("subagent registration must NOT pollute the shared session_id: %s", data)
	}

	// 同一 session の Lead (agent fields なし) の Write は影響を受けない
	lead := EvaluatePreTool(srcWriteInput(root, "sess-shared"))
	if lead.Decision == hookproto.DecisionDeny {
		t.Fatalf("Lead's own write must not be denied after subagent registration: %+v", lead)
	}

	// 登録した subagent 自身の Write は R08 で拒否される
	sub := srcWriteInput(root, "sess-shared")
	sub.AgentID = "agent-reg-1"
	if r := EvaluatePreTool(sub); r.Decision != hookproto.DecisionDeny {
		t.Fatalf("registered subagent's write must be denied: %+v", r)
	}
}

// 登録キーは payload 由来のみ: content に他セッションの ID を書いても
// そのセッションに role は付かない。
func TestRegisterBreezingRole_CannotAssignToOtherSession(t *testing.T) {
	clearGuardrailKnobEnv(t)
	root := t.TempDir()

	regInput := hookproto.HookInput{
		SessionID: "sess-attacker",
		AgentID:   "agent-attacker",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{
			"file_path": filepath.Join(root, ".claude", "state", "breezing-role-x.json"),
			// content 内の session_id / agent_id は無視されなければならない
			"content": `{"role":"reviewer","session_id":"sess-victim","agent_id":"agent-victim"}`,
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
	for _, forged := range []string{"sess-victim", "agent-victim"} {
		if _, ok := roles[forged]; ok {
			t.Fatalf("role must never be assigned to an id taken from content: %s", data)
		}
	}
	if _, ok := roles["agent-attacker"]; !ok {
		t.Fatalf("role must be keyed by the payload agent id: %s", data)
	}
	if _, ok := roles["sess-attacker"]; ok {
		t.Fatalf("registration must not key by session_id (Lead pollution): %s", data)
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
