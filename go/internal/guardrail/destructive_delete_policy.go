package guardrail

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/auditlog"
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
	// A consumed defer approval (R05_DEFER_APPROVED prefix) is the operator's
	// one-shot approval being spent, not the agent's own warn judgement; label
	// it policy=defer so the audit trail stays truthful.
	recordPolicy := policy.DestructiveDeletePolicyWarn
	if strings.HasPrefix(result.SystemMessage, "R05_DEFER_APPROVED:") {
		recordPolicy = policy.DestructiveDeletePolicyDefer
	}
	entry := destructiveDeleteRecordEntry{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		SessionID: input.SessionID,
		AgentID:   input.AgentID,
		CWD:       input.CWD,
		Command:   command,
		Policy:    recordPolicy,
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
	ID         string `json:"id"`
	Timestamp  string `json:"timestamp"`
	SessionID  string `json:"session_id,omitempty"`
	AgentID    string `json:"agent_id,omitempty"`
	CWD        string `json:"cwd,omitempty"`
	Command    string `json:"command"`
	RuleID     string `json:"rule_id"`
	Policy     string `json:"policy"`
	Reason     string `json:"reason"`
	Status     string `json:"status"`
	ApprovedAt string `json:"approved_at,omitempty"`
	ConsumedAt string `json:"consumed_at,omitempty"`
}

// Deferred-op lifecycle (140.2): pending → approved (bin/harness deferred
// approve <id>) → consumed (the guardrail lets the next identical run through
// exactly once). History is flipped in place, never deleted; a later identical
// command re-queues a NEW pending line with the same id, because the dedup
// check only looks at pending entries. By construction at most one pending
// line per id exists at a time, so "approve <id>" flips that single line.
const (
	deferredOpStatusPending  = "pending"
	deferredOpStatusApproved = "approved"
	deferredOpStatusConsumed = "consumed"
)

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

// deferredOpLine is one physical line of deferred-ops.jsonl. Unparseable lines
// are carried through rewrites verbatim: a damaged line must never cost the
// operator queued history.
type deferredOpLine struct {
	raw   string
	entry *deferredOpEntry
}

func readDeferredOpLines(path string) ([]deferredOpLine, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var lines []deferredOpLine
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		raw := scanner.Text()
		if strings.TrimSpace(raw) == "" {
			continue
		}
		line := deferredOpLine{raw: raw}
		var e deferredOpEntry
		if err := json.Unmarshal([]byte(raw), &e); err == nil {
			line.entry = &e
		}
		lines = append(lines, line)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return lines, nil
}

func writeDeferredOpLines(path string, lines []deferredOpLine) error {
	var buf strings.Builder
	for _, line := range lines {
		if line.entry != nil {
			data, err := json.Marshal(line.entry)
			if err != nil {
				return err
			}
			buf.Write(data)
		} else {
			buf.WriteString(line.raw)
		}
		buf.WriteByte('\n')
	}
	tempFile, err := os.CreateTemp(filepath.Dir(path), ".deferred-ops-*.tmp")
	if err != nil {
		return err
	}
	tempPath := tempFile.Name()
	defer os.Remove(tempPath)
	if err := tempFile.Chmod(0o644); err != nil {
		tempFile.Close()
		return err
	}
	if _, err := tempFile.WriteString(buf.String()); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

// flipDeferredOpStatus rewrites the single line with the given id and expected
// current status under the queue's file lock. Returns true when a line was
// flipped.
func flipDeferredOpStatus(projectRoot, id, fromStatus, toStatus string) (bool, error) {
	path := filepath.Join(projectRoot, ".claude", "state", deferredOpsFile)
	if _, err := os.Stat(path); err != nil {
		return false, nil
	}
	flipped := false
	now := time.Now().UTC().Format(time.RFC3339)
	err := auditlog.WithFileLock(path+".lock", func() error {
		lines, err := readDeferredOpLines(path)
		if err != nil {
			return err
		}
		for _, line := range lines {
			if line.entry == nil || line.entry.ID != id || line.entry.Status != fromStatus {
				continue
			}
			line.entry.Status = toStatus
			switch toStatus {
			case deferredOpStatusApproved:
				line.entry.ApprovedAt = now
			case deferredOpStatusConsumed:
				line.entry.ConsumedAt = now
			}
			flipped = true
			break
		}
		if !flipped {
			return nil
		}
		return writeDeferredOpLines(path, lines)
	})
	if err != nil {
		return false, err
	}
	return flipped, nil
}

// ApproveDeferredOp flips a pending queue entry to approved. It is the CLI
// entry point for `bin/harness deferred approve <id>`: the operator's explicit
// action, so unlike the hook-side helpers it returns errors loudly.
func ApproveDeferredOp(projectRoot, id string) error {
	if strings.TrimSpace(id) == "" {
		return fmt.Errorf("deferred op id is required")
	}
	flipped, err := flipDeferredOpStatus(projectRoot, id, deferredOpStatusPending, deferredOpStatusApproved)
	if err != nil {
		return err
	}
	if !flipped {
		return fmt.Errorf("no pending deferred op with id %s in .claude/state/%s", id, deferredOpsFile)
	}
	return nil
}

// ListDeferredOps returns the parsed queue entries in file order. The CLI's
// list view filters by status; unparseable lines are skipped for display but
// preserved on disk.
func ListDeferredOps(projectRoot string) ([]DeferredOpView, error) {
	path := filepath.Join(projectRoot, ".claude", "state", deferredOpsFile)
	lines, err := readDeferredOpLines(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var views []DeferredOpView
	for _, line := range lines {
		if line.entry == nil {
			continue
		}
		views = append(views, DeferredOpView{
			ID:        line.entry.ID,
			Timestamp: line.entry.Timestamp,
			CWD:       line.entry.CWD,
			Command:   line.entry.Command,
			Status:    line.entry.Status,
		})
	}
	return views, nil
}

// DeferredOpView is the read-only projection of a queue entry for the CLI.
type DeferredOpView struct {
	ID        string `json:"id"`
	Timestamp string `json:"timestamp"`
	CWD       string `json:"cwd,omitempty"`
	Command   string `json:"command"`
	Status    string `json:"status"`
}

// newDeferredOpConsumer supplies ctx.ConsumeDeferredOp: the R05 defer branch
// calls it with the operation's DeferredOpID right before returning deny, and
// an operator-approved entry is spent (approved → consumed) to let exactly one
// run through. Mirrors newPlanPreapprovalConsumer: consuming inside Evaluate
// means a compound command that a LATER deny rule (R06 etc.) still blocks
// burns the approval without executing — accepted, same as plan preapproval.
func newDeferredOpConsumer(projectRoot string) func(id string) bool {
	if projectRoot == "" {
		return nil
	}
	return func(id string) bool {
		flipped, err := flipDeferredOpStatus(projectRoot, id, deferredOpStatusApproved, deferredOpStatusConsumed)
		if err != nil {
			return false
		}
		return flipped
	}
}
