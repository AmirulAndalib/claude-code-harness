package hostgen

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sampleAgentProfileHostsTOML = `
[codex]
hook_event = "PreToolUse"
hook_path  = ".codex/hooks.json"
matcher    = "*"
deny       = "permissionDecision"
transport  = "stdin-json"
model      = "gpt-5.6-sol"

[codex.agent_profiles.worker]
output_path = "codex/.codex/agents/worker.toml"
name = "worker"
description = "Managed implementation worker for one Harness Breezing task."
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
developer_instructions = """
Implement only the assigned Harness task in the provided worktree.
Read the task contract and relevant project spec before editing.
Run focused tests or checks, report exact changed files and residual risks,
and create the requested commit before returning. Do not spawn subagents.
"""

[codex.agent_profiles.reviewer]
output_path = "codex/.codex/agents/reviewer.toml"
name = "reviewer"
description = "Read-only reviewer for diffs, risk, and missing tests."
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
sandbox_mode = "read-only"
developer_instructions = "Review evidence-first. Report prioritized findings with file and line references. Do not edit files."
`

func TestLoadAndGenerateAgentProfile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hosts.toml")
	if err := os.WriteFile(path, []byte(sampleAgentProfileHostsTOML), 0o644); err != nil {
		t.Fatal(err)
	}

	hosts, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	profile, ok := hosts["codex"].AgentProfiles["worker"]
	if !ok {
		t.Fatal("missing codex worker agent profile")
	}
	if profile.OutputPath != "codex/.codex/agents/worker.toml" {
		t.Fatalf("OutputPath = %q", profile.OutputPath)
	}

	got, err := GenerateAgentProfile(profile)
	if err != nil {
		t.Fatalf("GenerateAgentProfile: %v", err)
	}
	want := `name = "worker"
description = "Managed implementation worker for one Harness Breezing task."
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
developer_instructions = """
Implement only the assigned Harness task in the provided worktree.
Read the task contract and relevant project spec before editing.
Run focused tests or checks, report exact changed files and residual risks,
and create the requested commit before returning. Do not spawn subagents.
"""
`
	if !bytes.Equal(got, []byte(want)) {
		t.Fatalf("generated profile mismatch:\n--- want ---\n%s--- got ---\n%s", want, got)
	}
}

func TestGenerateReviewerAgentProfile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hosts.toml")
	if err := os.WriteFile(path, []byte(sampleAgentProfileHostsTOML), 0o644); err != nil {
		t.Fatal(err)
	}
	hosts, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	profile, ok := hosts["codex"].AgentProfiles["reviewer"]
	if !ok {
		t.Fatal("missing codex reviewer agent profile")
	}
	if profile.SandboxMode != "read-only" {
		t.Fatalf("SandboxMode = %q, want read-only", profile.SandboxMode)
	}
	got, err := GenerateAgentProfile(profile)
	if err != nil {
		t.Fatalf("GenerateAgentProfile: %v", err)
	}
	want := `name = "reviewer"
description = "Read-only reviewer for diffs, risk, and missing tests."
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
sandbox_mode = "read-only"
developer_instructions = "Review evidence-first. Report prioritized findings with file and line references. Do not edit files."
`
	if !bytes.Equal(got, []byte(want)) {
		t.Fatalf("generated reviewer profile mismatch:\n--- want ---\n%s--- got ---\n%s", want, got)
	}
}

func TestRepositoryFrontierAgentProfiles(t *testing.T) {
	hosts, err := Load(filepath.Join("..", "..", "..", "hosts.toml"))
	if err != nil {
		t.Fatalf("Load repository hosts.toml: %v", err)
	}
	for host, want := range map[string]string{
		"claude": "claude-fable-5-1",
		"codex":  "gpt-6-astra",
	} {
		if got := hosts[host].Model; got != want {
			t.Errorf("%s host model = %q, want %q", host, got, want)
		}
	}
	for _, tc := range []struct {
		role    string
		model   string
		effort  string
		sandbox string
	}{
		{role: "worker", model: "gpt-5.6-luna", effort: "max"},
		{role: "reviewer", model: "gpt-6-astra", effort: "xhigh", sandbox: "read-only"},
	} {
		t.Run(tc.role, func(t *testing.T) {
			profile, ok := hosts["codex"].AgentProfiles[tc.role]
			if !ok {
				t.Fatalf("missing codex %s profile", tc.role)
			}
			if profile.Model != tc.model || profile.ModelReasoningEffort != tc.effort || profile.SandboxMode != tc.sandbox {
				t.Errorf("%s profile = model %q, effort %q, sandbox %q; want %q, %q, %q",
					tc.role, profile.Model, profile.ModelReasoningEffort, profile.SandboxMode, tc.model, tc.effort, tc.sandbox)
			}
			generated, err := GenerateAgentProfile(profile)
			if err != nil {
				t.Fatalf("GenerateAgentProfile: %v", err)
			}
			for _, want := range []string{
				`model = "` + tc.model + `"`,
				`model_reasoning_effort = "` + tc.effort + `"`,
			} {
				if !strings.Contains(string(generated), want+"\n") {
					t.Errorf("generated %s profile missing %s:\n%s", tc.role, want, generated)
				}
			}
			if tc.sandbox != "" && !strings.Contains(string(generated), `sandbox_mode = "`+tc.sandbox+"\"\n") {
				t.Errorf("generated %s profile must retain %s sandbox:\n%s", tc.role, tc.sandbox, generated)
			}
		})
	}
}

func TestLoadRejectsAgentProfileParentPath(t *testing.T) {
	for _, invalidPath := range []string{"../worker.toml", "/tmp/worker.toml", `C:\\worker.toml`} {
		t.Run(invalidPath, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "hosts.toml")
			contents := strings.Replace(sampleAgentProfileHostsTOML, "codex/.codex/agents/worker.toml", invalidPath, 1)
			if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(path); err == nil {
				t.Fatalf("Load should reject agent profile output path %q", invalidPath)
			}
		})
	}
}
