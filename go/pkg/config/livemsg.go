package config

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// ResolveLivemsgVerification follows the existing destructiveDelete order:
// env override, project YAML, project TOML, plugin TOML, then default off.
func ResolveLivemsgVerification(projectRoot, pluginRoot string) string {
	if value := os.Getenv("HARNESS_LIVEMSG_VERIFICATION"); value != "" {
		return normalizeLivemsgVerification(value)
	}
	if value := readLivemsgVerificationFromYAML(projectRoot); value != "" {
		return normalizeLivemsgVerification(value)
	}
	if value := readLivemsgVerificationFromHarnessTOML(filepath.Join(projectRoot, "harness.toml")); value != "" {
		return normalizeLivemsgVerification(value)
	}
	if pluginRoot != "" && pluginRoot != projectRoot {
		if value := readLivemsgVerificationFromHarnessTOML(filepath.Join(pluginRoot, "harness.toml")); value != "" {
			return normalizeLivemsgVerification(value)
		}
	}
	return LivemsgVerificationOff
}

func normalizeLivemsgVerification(value string) string {
	if strings.EqualFold(strings.TrimSpace(value), LivemsgVerificationOn) {
		return LivemsgVerificationOn
	}
	return LivemsgVerificationOff
}

func readLivemsgVerificationFromHarnessTOML(path string) string {
	var cfg Config
	meta, err := toml.DecodeFile(path, &cfg)
	if err != nil || !meta.IsDefined("livemsg", "verification") {
		return ""
	}
	return cfg.Livemsg.Verification
}

func readLivemsgVerificationFromYAML(projectRoot string) string {
	f, err := os.Open(filepath.Join(projectRoot, ".claude-code-harness.config.yaml"))
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	inLivemsg := false
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
			inLivemsg = strings.HasPrefix(trimmed, "livemsg:")
			continue
		}
		if inLivemsg {
			if value, ok := parseLivemsgYAMLValue(trimmed, "verification"); ok {
				return value
			}
		}
	}
	return ""
}

func parseLivemsgYAMLValue(line, key string) (string, bool) {
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
