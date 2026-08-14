package hostgen

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// Phase 133.8: GenerateHooksJSON had no `case "grok"`, so flipping grok's
// hook_generation away from "deferred" made `harness gen` fail closed with
// "unknown host". grok 1.0.3 reports `Harness Compatibility → claude → hooks on`
// and discovers other plugins' hooks in the Claude layout, so the emitted
// document uses the Claude shape and only the routed host differs.

func grokHost() Host {
	return Host{
		Name:      "grok",
		HookEvent: "PreToolUse",
		Matcher:   "Write|Edit|MultiEdit|Bash",
		HookPath:  ".grok/hooks.json",
	}
}

func TestGenerateHooksJSON_GrokIsNotUnknown(t *testing.T) {
	out, err := GenerateHooksJSON(grokHost())
	if err != nil {
		t.Fatalf("GenerateHooksJSON(grok): %v", err)
	}
	if !bytes.HasSuffix(out, []byte("\n")) {
		t.Error("grok hooks.json should end with a trailing newline")
	}
}

// The routed host must reach the policy engine, otherwise the decoder reads the
// missing flag as Claude's default and the calling host is never recorded.
func TestGenerateHooksJSON_GrokCommandCarriesHostFlag(t *testing.T) {
	out, err := GenerateHooksJSON(grokHost())
	if err != nil {
		t.Fatalf("GenerateHooksJSON(grok): %v", err)
	}

	var doc struct {
		Hooks map[string][]struct {
			Matcher string `json:"matcher"`
			Hooks   []struct {
				Type    string `json:"type"`
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatalf("grok hooks.json is not valid JSON: %v\n%s", err, out)
	}

	groups, ok := doc.Hooks["PreToolUse"]
	if !ok || len(groups) == 0 || len(groups[0].Hooks) == 0 {
		t.Fatalf("grok hooks.json is missing a PreToolUse entry:\n%s", out)
	}

	command := groups[0].Hooks[0].Command
	if !strings.Contains(command, "pre-tool") {
		t.Errorf("grok command does not invoke pre-tool: %q", command)
	}
	if !strings.Contains(command, "--host grok") {
		t.Errorf("grok command does not carry --host grok: %q", command)
	}
}

// binCommand excludes claude rather than enumerating the other hosts, so a host
// added later cannot silently lose its --host flag. 133.8 hit exactly that.
func TestBinCommand_RoutesEveryHostExceptClaude(t *testing.T) {
	for _, host := range []string{"codex", "cursor", "grok"} {
		if got := binCommand(host); !strings.Contains(got, "--host "+host) {
			t.Errorf("binCommand(%q) = %q, want it to carry --host %s", host, got, host)
		}
	}
	if got := binCommand("claude"); strings.Contains(got, "--host") {
		t.Errorf("binCommand(claude) = %q, want no --host flag", got)
	}
}

// An unknown host must still fail closed, and the message should list grok now
// that it is supported.
func TestGenerateHooksJSON_UnknownHostStillFailsClosed(t *testing.T) {
	_, err := GenerateHooksJSON(Host{Name: "nosuchhost", HookEvent: "PreToolUse"})
	if err == nil {
		t.Fatal("expected an error for an unknown host, got nil")
	}
	if !strings.Contains(err.Error(), "grok") {
		t.Errorf("unknown-host error should list grok as supported, got: %v", err)
	}
}

// hook_generation = "deferred" keeps its meaning for grok: the caller asked for
// generation to stay off, and that must be reported as the deferred sentinel
// rather than silently emitting a document.
func TestGenerateHooksJSON_GrokDeferredStillReturnsSentinel(t *testing.T) {
	h := grokHost()
	h.HookGeneration = "deferred"

	if _, err := GenerateHooksJSON(h); err == nil {
		t.Fatal("expected an error when hook generation is deferred, got nil")
	}
}
