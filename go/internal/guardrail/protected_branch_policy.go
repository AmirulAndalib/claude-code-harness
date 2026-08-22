package guardrail

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"github.com/Chachamaru127/claude-code-harness/go/internal/policy"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/config"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

func resolveProtectedBranchPushPolicy(input hookproto.HookInput, projectRoot string) string {
	for _, envName := range []string{
		"HARNESS_PROTECTED_BRANCH_PUSH_POLICY",
		"HARNESS_DIRECT_PUSH_POLICY",
	} {
		if value := os.Getenv(envName); value != "" {
			return policy.NormalizeProtectedBranchPushPolicy(value)
		}
	}

	if value := readProtectedBranchPushPolicyFromYAML(projectRoot); value != "" {
		return policy.NormalizeProtectedBranchPushPolicy(value)
	}

	if value := readProtectedBranchPushPolicyFromHarnessTOML(filepath.Join(projectRoot, "harness.toml")); value != "" {
		return policy.NormalizeProtectedBranchPushPolicy(value)
	}

	if input.PluginRoot != "" && input.PluginRoot != projectRoot {
		if value := readProtectedBranchPushPolicyFromHarnessTOML(filepath.Join(input.PluginRoot, "harness.toml")); value != "" {
			return policy.NormalizeProtectedBranchPushPolicy(value)
		}
	}

	return policy.ProtectedBranchPushPolicyAsk
}

func readProtectedBranchPushPolicyFromHarnessTOML(path string) string {
	cfg, err := config.ParseFile(path)
	if err != nil || cfg == nil {
		return ""
	}
	return cfg.Safety.Permissions.ProtectedBranchPush
}

func readProtectedBranchPushPolicyFromYAML(projectRoot string) string {
	return readSafetyValueFromYAML(projectRoot, "protected_branch_push", "protectedBranchPush")
}

// readSafetyValueFromYAML scans .claude-code-harness.config.yaml for the first
// of keys, accepted either at top level or nested under `safety:`. It is a
// line-oriented reader on purpose (no YAML dependency in the hook fast-path).
func readSafetyValueFromYAML(projectRoot string, keys ...string) string {
	configPath := filepath.Join(projectRoot, ".claude-code-harness.config.yaml")
	f, err := os.Open(configPath)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	inSafety := false
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
			for _, key := range keys {
				if value, ok := parseSimpleYAMLValue(trimmed, key); ok {
					return value
				}
			}
			inSafety = strings.HasPrefix(trimmed, "safety:")
			continue
		}
		if !inSafety {
			continue
		}
		for _, key := range keys {
			if value, ok := parseSimpleYAMLValue(trimmed, key); ok {
				return value
			}
		}
	}
	return ""
}

func parseSimpleYAMLValue(line, key string) (string, bool) {
	prefix := key + ":"
	if !strings.HasPrefix(line, prefix) {
		return "", false
	}
	value := strings.TrimSpace(strings.TrimPrefix(line, prefix))
	if idx := strings.Index(value, "#"); idx >= 0 {
		value = strings.TrimSpace(value[:idx])
	}
	return strings.Trim(value, `"'`), true
}
