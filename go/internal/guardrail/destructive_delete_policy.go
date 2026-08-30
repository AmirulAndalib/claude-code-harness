package guardrail

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/policy"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/config"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

// destructiveDeleteRecordFile is the after-the-fact review log for deletions
// that destructive_delete=warn let through without a human prompt. It lives
// next to scope-leash.jsonl and follows the same best-effort contract.
const destructiveDeleteRecordFile = "destructive-delete.jsonl"

// deferredOpsFile is the queue of operations that destructive_delete=defer
// refused to run. One line per distinct (rule, cwd, command); the operator
// reviews it after the run. It lives next to destructive-delete.jsonl.
const deferredOpsFile = "deferred-ops.jsonl"

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

// deferredOpEntry is one line of .claude/state/deferred-ops.jsonl.
type deferredOpEntry struct {
	ID        string `json:"id"`
	Timestamp string `json:"timestamp"`
	SessionID string `json:"session_id,omitempty"`
	AgentID   string `json:"agent_id,omitempty"`
	CWD       string `json:"cwd,omitempty"`
	Command   string `json:"command"`
	RuleID    string `json:"rule_id"`
	Policy    string `json:"policy"`
	Reason    string `json:"reason"`
	Status    string `json:"status"`
}

// deferredOpStatusPending marks an entry nobody has approved yet. 140.2's
// approve CLI is expected to flip it (or append a resolution line) rather than
// delete history.
const deferredOpStatusPending = "pending"

// isDestructiveDeleteDeferral reports whether a policy result is the R05
// defer-mode deny (deny + R05_DEFER reason), i.e. an operation that must be
// queued for the operator.
func isDestructiveDeleteDeferral(result hookproto.HookResult) bool {
	return result.RuleID == "R05:confirm-rm-rf" &&
		result.Decision == hookproto.DecisionDeny &&
		strings.HasPrefix(result.Reason, "R05_DEFER:")
}

// recordDeferredOp appends the refused operation to
// .claude/state/deferred-ops.jsonl unless a pending entry with the same id is
// already there (a retry of the same command in the same cwd). Best-effort,
// same contract as recordDestructiveDeleteWarning: the deny stands even if the
// write fails.
func recordDeferredOp(projectRoot string, input hookproto.HookInput, result hookproto.HookResult) {
	if projectRoot == "" {
		return
	}
	command, _ := input.ToolInput["command"].(string)
	id := policy.DeferredOpID(result.RuleID, input.CWD, command)
	stateDir := filepath.Join(projectRoot, ".claude", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return
	}
	path := filepath.Join(stateDir, deferredOpsFile)
	if hasPendingDeferredOp(path, id) {
		return
	}
	entry := deferredOpEntry{
		ID:        id,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		SessionID: input.SessionID,
		AgentID:   input.AgentID,
		CWD:       input.CWD,
		Command:   command,
		RuleID:    result.RuleID,
		Policy:    policy.DestructiveDeletePolicyDefer,
		Reason:    "blast-radius backstop: target is not statically inside the project root (out-of-root spelling, `..`, unresolved $VAR, glob, or bare `.`), so warn could not approve it and an unattended run must not stop on a prompt",
		Status:    deferredOpStatusPending,
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s\n", data)
}

// hasPendingDeferredOp scans the queue for a pending entry with the given id.
// Unparseable lines are skipped: a damaged line must not turn a retry into a
// duplicate or hide a new operation.
func hasPendingDeferredOp(path, id string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var e deferredOpEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			continue
		}
		if e.ID == id && e.Status == deferredOpStatusPending {
			return true
		}
	}
	return false
}
