package guardrail

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/policy"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/config"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

// destructiveDeleteRecordFile is the after-the-fact review log for deletions
// that destructive_delete=warn let through without a human prompt. It lives
// next to scope-leash.jsonl and follows the same best-effort contract.
const destructiveDeleteRecordFile = "destructive-delete.jsonl"

// resolveDestructiveDeletePolicy mirrors resolveProtectedBranchPushPolicy:
// env override → project YAML → project harness.toml → plugin harness.toml →
// default ask. The env knob is an operator override; the configuration files
// are the primary producers (see templates/registry/operator-supplied-knobs).
func resolveDestructiveDeletePolicy(input hookproto.HookInput, projectRoot string) string {
	if value := os.Getenv("HARNESS_DESTRUCTIVE_DELETE_POLICY"); value != "" {
		return policy.NormalizeDestructiveDeletePolicy(value)
	}

	if value := readSafetyValueFromYAML(projectRoot, "destructive_delete", "destructiveDelete"); value != "" {
		return policy.NormalizeDestructiveDeletePolicy(value)
	}

	if value := readDestructiveDeletePolicyFromHarnessTOML(filepath.Join(projectRoot, "harness.toml")); value != "" {
		return policy.NormalizeDestructiveDeletePolicy(value)
	}

	if input.PluginRoot != "" && input.PluginRoot != projectRoot {
		if value := readDestructiveDeletePolicyFromHarnessTOML(filepath.Join(input.PluginRoot, "harness.toml")); value != "" {
			return policy.NormalizeDestructiveDeletePolicy(value)
		}
	}

	// Product default (v5.11.0, operator decision 2026-08-22): warn. The
	// HOTL contract treats a human prompt that the operator cannot actually
	// evaluate as a stall, not a safeguard — so an UNSET policy relaxes to
	// warn (allow + record). An explicitly configured but invalid value still
	// normalizes to ask (fail-safe parse) in NormalizeDestructiveDeletePolicy,
	// and any repo can opt back out with destructive_delete/destructiveDelete
	// = "ask". The always-ask backstop (out-of-root spelling, `..`, unresolved
	// $VAR, glob, bare `.`) is unaffected by this default.
	return policy.DestructiveDeletePolicyWarn
}

func readDestructiveDeletePolicyFromHarnessTOML(path string) string {
	cfg, err := config.ParseFile(path)
	if err != nil || cfg == nil {
		return ""
	}
	return cfg.Safety.Permissions.DestructiveDelete
}

// destructiveDeleteRecordEntry is one line of .claude/state/destructive-delete.jsonl.
type destructiveDeleteRecordEntry struct {
	Timestamp string `json:"timestamp"`
	SessionID string `json:"session_id,omitempty"`
	AgentID   string `json:"agent_id,omitempty"`
	CWD       string `json:"cwd,omitempty"`
	Command   string `json:"command"`
	Policy    string `json:"policy"`
	RuleID    string `json:"rule_id"`
}

// recordDestructiveDeleteWarning appends a warn-approved deletion to
// .claude/state/destructive-delete.jsonl. Best-effort: write failures are
// ignored so the hook fast-path stays available (same contract as
// recordScopeLeashWarning / track_changes.go).
func recordDestructiveDeleteWarning(projectRoot string, input hookproto.HookInput, result hookproto.HookResult) {
	if projectRoot == "" {
		return
	}
	command, _ := input.ToolInput["command"].(string)
	stateDir := filepath.Join(projectRoot, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return
	}
	entry := destructiveDeleteRecordEntry{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		SessionID: input.SessionID,
		AgentID:   input.AgentID,
		CWD:       input.CWD,
		Command:   command,
		Policy:    policy.DestructiveDeletePolicyWarn,
		RuleID:    result.RuleID,
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return
	}
	f, err := os.OpenFile(filepath.Join(stateDir, destructiveDeleteRecordFile), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s\n", data)
}

// isDestructiveDeleteWarnApproval reports whether a policy result is the R05
// warn-mode approval (approve + warning from the R05 rule), i.e. a deletion
// that must be recorded for after-the-fact review.
func isDestructiveDeleteWarnApproval(result hookproto.HookResult) bool {
	return result.RuleID == "R05:confirm-rm-rf" &&
		result.Decision == hookproto.DecisionApprove &&
		result.SystemMessage != ""
}
