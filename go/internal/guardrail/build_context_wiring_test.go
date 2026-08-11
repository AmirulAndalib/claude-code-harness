package guardrail

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/state"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

// This file is the rule↔context wiring axis (companion to
// internal/rulecoverage, which covers the rule↔test axis).
//
// Why it exists (2026-08-11): policy rules had 144 hand-built-context tests
// while BuildContext — the code that fills the context from real inputs —
// had zero. Every field BuildContext failed to populate yielded a fully
// tested, completely inert rule: WorkMode (nothing set it → /breezing halted
// on R04 for months), CodexMode (R07 dead), BreezingRole (R08 dead), and the
// work-mode CLI writing rows under an ID the hook never receives.
//
// Contract: every field of hookproto.RuleContext MUST have a case in
// wiringCases below that drives BuildContext THROUGH A REAL PRODUCER
// (env var, state DB row, state file, or harness.toml) and asserts the field
// changes. Adding a field without a producer proof turns this red.

type wiringCase struct {
	field   string
	prepare func(t *testing.T, root string) hookproto.HookInput
	check   func(t *testing.T, ctx hookproto.RuleContext)
}

func wiringInput(root string) hookproto.HookInput {
	return hookproto.HookInput{
		SessionID: "wiring-sess",
		CWD:       root,
		ToolName:  "Write",
		ToolInput: map[string]interface{}{"file_path": filepath.Join(root, "src", "x.ts"), "content": "a"},
	}
}

func seedWorkStateRow(t *testing.T, root, sessionID string, opts state.WorkStateOptions) {
	t.Helper()
	t.Setenv("CLAUDE_PLUGIN_DATA", "")
	dbPath := state.ResolveStatePath(root)
	store, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	if err := store.UpsertSession(state.SessionState{
		SessionID:   sessionID,
		Mode:        state.SessionModeWork,
		ProjectRoot: root,
		StartedAt:   time.Now().UTC().Format(time.RFC3339),
	}); err != nil {
		t.Fatalf("seed session: %v", err)
	}
	if err := store.SetWorkState(sessionID, opts); err != nil {
		t.Fatalf("seed work state: %v", err)
	}
}

var wiringCases = []wiringCase{
	{
		field: "Input",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if ctx.Input.SessionID != "wiring-sess" || ctx.Input.ToolName != "Write" {
				t.Fatalf("Input not carried through: %+v", ctx.Input)
			}
		},
	},
	{
		field: "ProjectRoot",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			return wiringInput(root) // producer: hook payload cwd
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if ctx.ProjectRoot == "" {
				t.Fatalf("ProjectRoot empty")
			}
		},
	},
	{
		field: "WorkMode",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// live producer: `harness work-mode on` writes a work_states row
			// keyed by the REAL session id (delivered to the CLI via
			// HARNESS_SESSION_ID, exported by the SessionStart env hook).
			seedWorkStateRow(t, root, "wiring-sess", state.WorkStateOptions{WorkMode: true})
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if !ctx.WorkMode {
				t.Fatalf("WorkMode not resolved from work_states row")
			}
		},
	},
	{
		field: "CodexMode",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// live producer: breezing --codex writes breezing-active.json
			// with impl_mode=codex (shell parity restored in 132.6).
			writeStateFile(t, root, "breezing-active.json", `{"impl_mode":"codex"}`)
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if !ctx.CodexMode {
				t.Fatalf("CodexMode not resolved from breezing-active.json")
			}
		},
	},
	{
		field: "BreezingRole",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// live producer: reviewer self-registration via
			// .claude/state/breezing-role-*.json (tryRegisterBreezingRole).
			writeStateFile(t, root, "breezing-session-roles.json", `{"wiring-sess":{"role":"reviewer"}}`)
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if ctx.BreezingRole != "reviewer" {
				t.Fatalf("BreezingRole = %q, want reviewer", ctx.BreezingRole)
			}
		},
	},
	{
		field: "ProtectedBranchPushPolicy",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// live producer: harness.toml [safety.permissions] protectedBranchPush
			if err := os.WriteFile(filepath.Join(root, "harness.toml"),
				[]byte("[safety.permissions]\nprotectedBranchPush = \"deny\"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if ctx.ProtectedBranchPushPolicy != "deny" {
				t.Fatalf("ProtectedBranchPushPolicy = %q, want deny (from harness.toml)", ctx.ProtectedBranchPushPolicy)
			}
		},
	},
	{
		field: "ConsumePlanPreapproval",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// live producer: harness-plan writes .claude/state/plan-preapprovals.json
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if ctx.ConsumePlanPreapproval == nil {
				t.Fatalf("ConsumePlanPreapproval consumer not attached")
			}
		},
	},
	{
		field: "ProtectedPathAskList",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// live producer: harness.toml [[safety.guardrail.protectedPathAskList]]
			body := "[[safety.guardrail.protectedPathAskList]]\npath = \"docs/generated/**\"\nreason = \"test\"\n"
			if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if len(ctx.ProtectedPathAskList) != 1 || ctx.ProtectedPathAskList[0].Path != "docs/generated/**" {
				t.Fatalf("ProtectedPathAskList not resolved from harness.toml: %+v", ctx.ProtectedPathAskList)
			}
		},
	},
	{
		field: "TddEnforceLevel",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// live producer: harness.toml [tdd.enforce]
			body := "[tdd.enforce]\nenabled = true\nlevel = \"central\"\n"
			if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if ctx.TddEnforceLevel != "central" {
				t.Fatalf("TddEnforceLevel = %q, want central (from harness.toml)", ctx.TddEnforceLevel)
			}
		},
	},
	{
		field: "TddHookEnabled",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			body := "[tdd.enforce]\nenabled = true\nlevel = \"max\"\nhook_enabled = true\n"
			if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if !ctx.TddHookEnabled {
				t.Fatalf("TddHookEnabled not resolved from harness.toml")
			}
		},
	},
	{
		field: "TddBypass",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			// producer: operator env (documented escape hatch)
			t.Setenv("HARNESS_TDD_BYPASS", "1")
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if !ctx.TddBypass {
				t.Fatalf("TddBypass not resolved from env")
			}
		},
	},
	{
		field: "TddBypassReason",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			t.Setenv("HARNESS_TDD_BYPASS", "1")
			t.Setenv("HARNESS_TDD_BYPASS_REASON", "hotfix")
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if ctx.TddBypassReason != "hotfix" {
				t.Fatalf("TddBypassReason = %q, want hotfix", ctx.TddBypassReason)
			}
		},
	},
	{
		field: "TddBypassReasonRequired",
		prepare: func(t *testing.T, root string) hookproto.HookInput {
			t.Setenv("HARNESS_TDD_BYPASS", "1") // bypass with empty reason → required
			return wiringInput(root)
		},
		check: func(t *testing.T, ctx hookproto.RuleContext) {
			if !ctx.TddBypassReasonRequired {
				t.Fatalf("TddBypassReasonRequired not derived")
			}
		},
	},
}

// TestBuildContext_EveryFieldHasALiveProducer drives BuildContext with each
// field's real producer and asserts the value lands.
func TestBuildContext_EveryFieldHasALiveProducer(t *testing.T) {
	for _, tc := range wiringCases {
		t.Run(tc.field, func(t *testing.T) {
			clearGuardrailKnobEnv(t)
			root := t.TempDir()
			input := tc.prepare(t, root)
			ctx := BuildContext(input)
			tc.check(t, ctx)
		})
	}
}

// TestBuildContext_NoUncoveredFields turns red when a field is added to
// RuleContext without a wiring case above — the exact defect class where a
// rule reads a context field nobody produces.
func TestBuildContext_NoUncoveredFields(t *testing.T) {
	covered := map[string]bool{}
	for _, tc := range wiringCases {
		covered[tc.field] = true
	}
	rt := reflect.TypeOf(hookproto.RuleContext{})
	for i := 0; i < rt.NumField(); i++ {
		name := rt.Field(i).Name
		if !covered[name] {
			t.Errorf("RuleContext.%s has no wiring case in build_context_wiring_test.go — "+
				"prove a live producer exists (env/db/state-file/toml) or the field will be inert", name)
		}
	}
}
