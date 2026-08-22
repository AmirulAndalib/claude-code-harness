package policy

import "strings"

// Destructive-delete (R05) policy values. These are the canonical strings that
// RuleContext.DestructiveDeletePolicy may hold after the configuration layer
// (internal/guardrail) resolves the setting.
//
// The vocabulary is deliberately ask|warn only. There is no "allow": warn mode
// is the HOTL (human-on-the-loop) half of the contract — the agent's own
// judgement (issuing the command) is accepted in place of a human prompt, but
// every such deletion is recorded so the operator can review it afterwards.
// A silent allow would drop the record and defeat that review.
const (
	DestructiveDeletePolicyAsk  = "ask"
	DestructiveDeletePolicyWarn = "warn"
)

// NormalizeDestructiveDeletePolicy maps a raw configuration value to one of the
// canonical policy values. Unknown or empty values default to "ask" so that an
// unset configuration keeps the pre-existing R05 behaviour unchanged.
func NormalizeDestructiveDeletePolicy(value string) string {
	normalized := strings.ToLower(strings.Trim(strings.TrimSpace(value), `"'`))
	switch normalized {
	case DestructiveDeletePolicyWarn:
		return DestructiveDeletePolicyWarn
	default:
		return DestructiveDeletePolicyAsk
	}
}
