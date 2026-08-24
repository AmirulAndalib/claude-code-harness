package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/pkg/config"
)

func writeLivemsgConfigFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

func TestResolveLivemsgVerificationPrecedence(t *testing.T) {
	projectRoot := t.TempDir()
	pluginRoot := t.TempDir()
	writeLivemsgConfigFile(t, pluginRoot, "harness.toml", "[livemsg]\nverification = \"on\"\n")
	writeLivemsgConfigFile(t, projectRoot, "harness.toml", "[project]\nname = \"without-livemsg\"\n")

	if got := config.ResolveLivemsgVerification(projectRoot, pluginRoot); got != "on" {
		t.Fatalf("plugin harness.toml fallback = %q, want on", got)
	}

	writeLivemsgConfigFile(t, projectRoot, "harness.toml", "[livemsg]\nverification = \"off\"\n")
	if got := config.ResolveLivemsgVerification(projectRoot, pluginRoot); got != "off" {
		t.Fatalf("project harness.toml = %q, want off", got)
	}

	writeLivemsgConfigFile(t, projectRoot, ".claude-code-harness.config.yaml", "livemsg:\n  verification: on\n")
	if got := config.ResolveLivemsgVerification(projectRoot, pluginRoot); got != "on" {
		t.Fatalf("project YAML = %q, want on", got)
	}

	t.Setenv("HARNESS_LIVEMSG_VERIFICATION", "off")
	if got := config.ResolveLivemsgVerification(projectRoot, pluginRoot); got != "off" {
		t.Fatalf("env override = %q, want off", got)
	}
}

func TestResolveLivemsgVerificationDefaultsOffWithoutHarnessTOML(t *testing.T) {
	t.Setenv("HARNESS_LIVEMSG_VERIFICATION", "")
	if got := config.ResolveLivemsgVerification(t.TempDir(), ""); got != "off" {
		t.Fatalf("default = %q, want off", got)
	}
}
