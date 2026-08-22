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
