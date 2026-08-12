package shellscan

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIsAgentStatePath(t *testing.T) {
	home := filepath.Join(t.TempDir(), "harness-agentstate-home")
	t.Setenv("HOME", home)

	accepted := []string{
		filepath.Join(home, ".claude", "projects", "any-slug", "memory", "note.md"),
		filepath.Join(home, ".claude", "projects", "other-slug", "memory", "nested", "deep.md"),
		filepath.Join(home, ".claude", "plans", "plan.md"),
	}
	for _, path := range accepted {
		t.Run(path, func(t *testing.T) {
			if !IsAgentStatePath(path) {
				t.Errorf("expected %q to be recognized as an agent state path", path)
			}
		})
	}
}

func TestIsAgentStatePathRejectsBehaviorDirectories(t *testing.T) {
	home := filepath.Join(t.TempDir(), "harness-agentstate-home")
	t.Setenv("HOME", home)

	rejected := []string{
		filepath.Join(home, ".claude", "settings.json"),
		filepath.Join(home, ".claude", "settings.local.json"),
		filepath.Join(home, ".claude", "skills", "x", "SKILL.md"),
		filepath.Join(home, ".claude", "agents", "w.md"),
		filepath.Join(home, ".claude", "commands", "c.md"),
		filepath.Join(home, ".claude", "hooks", "h.json"),
		filepath.Join(home, ".claude", "plugins", "p", "x.json"),
		filepath.Join(home, ".claude", "projects", "slug", "session.jsonl"),
		filepath.Join(home, "Documents", "important.md"),
	}
	for _, path := range rejected {
		t.Run(path, func(t *testing.T) {
			if IsAgentStatePath(path) {
				t.Errorf("expected %q to NOT be recognized as an agent state path", path)
			}
		})
	}
}

func TestIsAgentStatePathRejectsPrefixCollision(t *testing.T) {
	home := filepath.Join(t.TempDir(), "harness-agentstate-home")
	t.Setenv("HOME", home)

	rejected := []string{
		filepath.Join(home, ".claude", "plans-backup", "x.md"),
		filepath.Join(home, ".claude", "projects", "slug", "memory-extra", "x.md"),
	}
	for _, path := range rejected {
		t.Run(path, func(t *testing.T) {
			if IsAgentStatePath(path) {
				t.Errorf("expected %q to remain outside agent state paths (prefix collision)", path)
			}
		})
	}
}

func TestIsAgentStatePathSymlinkedHome(t *testing.T) {
	physicalHome := t.TempDir()
	if err := os.MkdirAll(filepath.Join(physicalHome, ".claude", "plans"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(physicalHome, ".claude", "projects", "slug", "memory"), 0o755); err != nil {
		t.Fatal(err)
	}
	resolvedHome, err := filepath.EvalSymlinks(physicalHome)
	if err != nil {
		t.Fatal(err)
	}
	linkParent := t.TempDir()
	linkedHome := filepath.Join(linkParent, "home")
	if err := os.Symlink(physicalHome, linkedHome); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	t.Setenv("HOME", linkedHome)

	tests := []struct {
		name string
		path string
	}{
		{
			name: "symlink path plans",
			path: filepath.Join(linkedHome, ".claude", "plans", "plan.md"),
		},
		{
			name: "resolved path plans",
			path: filepath.Join(resolvedHome, ".claude", "plans", "plan.md"),
		},
		{
			name: "symlink path memory",
			path: filepath.Join(linkedHome, ".claude", "projects", "slug", "memory", "note.md"),
		},
		{
			name: "resolved path memory",
			path: filepath.Join(resolvedHome, ".claude", "projects", "slug", "memory", "note.md"),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if !IsAgentStatePath(tt.path) {
				t.Errorf("expected %q to be recognized as agent state path under symlinked home", tt.path)
			}
		})
	}
}
