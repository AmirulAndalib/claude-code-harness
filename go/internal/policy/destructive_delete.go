package policy

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

// Destructive-delete (R05) policy values. These are the canonical strings that
// RuleContext.DestructiveDeletePolicy may hold after the configuration layer
// (internal/guardrail) resolves the setting.
//
// The vocabulary is ask|warn|defer. There is no "allow": warn mode is the
// HOTL (human-on-the-loop) half of the contract — the agent's own judgement
// (issuing the command) is accepted in place of a human prompt, but every such
// deletion is recorded so the operator can review it afterwards. A silent
// allow would drop the record and defeat that review.
//
// defer (Phase 140.1) is a superset of warn for unattended runs: everything
// warn approves, defer approves the same way; where warn would still ask (the
// blast-radius backstop: out-of-root spelling, `..`, unresolved $VAR, glob,
// bare `.`), defer returns deny with a behavioural contract in the reason and
// the guardrail layer queues the operation in .claude/state/deferred-ops.jsonl.
// A deny does not stall the run (the agent receives the reason and moves on);
// only ask does. The operator reviews the queue afterwards.
const (
	DestructiveDeletePolicyAsk   = "ask"
	DestructiveDeletePolicyWarn  = "warn"
	DestructiveDeletePolicyDefer = "defer"
)

// NormalizeDestructiveDeletePolicy maps a raw configuration value to one of the
// canonical policy values. Unknown or empty values default to "ask" so that an
// unset configuration keeps the pre-existing R05 behaviour unchanged.
func NormalizeDestructiveDeletePolicy(value string) string {
	normalized := strings.ToLower(strings.Trim(strings.TrimSpace(value), `"'`))
	switch normalized {
	case DestructiveDeletePolicyWarn:
		return DestructiveDeletePolicyWarn
	case DestructiveDeletePolicyDefer:
		return DestructiveDeletePolicyDefer
	default:
		return DestructiveDeletePolicyAsk
	}
}

// DeferredOpID is the stable identity of a deferred operation: the same rule,
// working directory and command always map to the same id, so a retry finds
// its existing queue entry and a later approve CLI (140.2) can address it.
func DeferredOpID(ruleID, cwd, command string) string {
	sum := sha256.Sum256([]byte(ruleID + "\x00" + cwd + "\x00" + command))
	return hex.EncodeToString(sum[:])[:12]
}

// DeferredOpReason is the reason text returned with a defer deny. It is the
// behavioural contract the agent is expected to follow instead of stopping:
// the operation is queued, must not be retried or rewritten, the run continues,
// and the queue is reported at the end.
func DeferredOpReason(id, command string) string {
	return fmt.Sprintf(`R05_DEFER: destructive delete deferred, not executed (destructive_delete=defer). Queued as deferred op %s in .claude/state/deferred-ops.jsonl for operator review.
Behavioural contract:
1. Do not retry this command and do not rewrite it into another deletion; it stays deferred (a retry is not re-queued).
2. Continue with the remaining tasks that do not depend on this deletion.
3. At the end of the run, report the deferred-ops list (id + command) to the operator.
Command:
%s`, id, command)
}
