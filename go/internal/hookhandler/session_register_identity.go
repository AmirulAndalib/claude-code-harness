package hookhandler

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
	"github.com/Chachamaru127/claude-code-harness/go/internal/deliveryidentity"
)

// HandleSessionRegisterWithIdentity runs the session roster registration and
// then publishes the same session's live-message identity to Claude Code's
// environment file. Keeping the producer in a separate wrapper leaves the
// active.json writer owned by session_register.go and makes the CLI call-site
// the only integration point.
func HandleSessionRegisterWithIdentity(in io.Reader, out io.Writer) error {
	data, _ := io.ReadAll(in)
	if err := HandleSessionRegister(bytes.NewReader(data), out); err != nil {
		return err
	}

	var input registerInput
	_ = json.Unmarshal(data, &input)
	sessionID := strings.TrimSpace(input.SessionID)
	if sessionID == "" {
		return nil
	}

	envFile := os.Getenv("CLAUDE_ENV_FILE")
	envTeam := strings.TrimSpace(os.Getenv(deliveryidentity.EnvTeam))
	envAgent := strings.TrimSpace(os.Getenv(deliveryidentity.EnvAgent))
	generatedTeam := generatedIdentityExport(envFile, deliveryidentity.EnvTeam, envTeam)
	generatedAgent := generatedIdentityExport(envFile, deliveryidentity.EnvAgent, envAgent)
	explicitTeam := envTeam != "" && !generatedTeam
	explicitAgent := envAgent != "" && !generatedAgent

	team := ""
	if explicitTeam {
		team = envTeam
	}
	agent := ""
	if explicitAgent {
		agent = envAgent
	}

	// deliveryidentity.Resolve falls back to Breezing only when the explicit
	// env pair is absent. Match that identity before creating standalone
	// defaults, otherwise the generated env file would take precedence later.
	breezingTeam := strings.TrimSpace(os.Getenv("BREEZING_SESSION_ID"))
	breezingAgent := strings.TrimSpace(os.Getenv("BREEZING_ROLE"))
	if breezingTeam != "" {
		if team == "" {
			team = breezingTeam
		}
		if agent == "" {
			agent = breezingAgent
			if agent == "" {
				agent = "solo"
			}
		}
	} else {
		if team == "" {
			team = resolveLiveMessageTeam(resolveProjectRoot())
		}
		if agent == "" {
			agent = sessionID
		}
	}
	if team == "" {
		return nil
	}
	return writeLiveMessageIdentity(
		envFile,
		team,
		agent,
		explicitTeam,
		explicitAgent,
	)
}

type livemsgTeamConfig struct {
	Livemsg struct {
		Team string `toml:"team"`
	} `toml:"livemsg"`
}

// resolveLiveMessageTeam reads the task-defined [livemsg] team setting and
// falls back to the shared Git repository name when the setting is absent or
// unreadable. Using git-common-dir keeps linked worktrees in one team.
func resolveLiveMessageTeam(projectRoot string) string {
	if projectRoot == "" {
		return ""
	}

	var cfg livemsgTeamConfig
	if _, err := toml.DecodeFile(filepath.Join(projectRoot, "harness.toml"), &cfg); err == nil {
		if team := strings.TrimSpace(cfg.Livemsg.Team); team != "" {
			return team
		}
	}

	if commonDir, ok := resolveGitCommonDir(projectRoot); ok {
		commonRoot := filepath.Dir(filepath.Clean(commonDir))
		if name := filepath.Base(commonRoot); name != "." && name != string(filepath.Separator) {
			return name
		}
	}

	cleanRoot := filepath.Clean(projectRoot)
	if absoluteRoot, err := filepath.Abs(cleanRoot); err == nil {
		cleanRoot = absoluteRoot
	}
	name := filepath.Base(cleanRoot)
	if name == "." || name == string(filepath.Separator) {
		return ""
	}
	return name
}

// writeLiveMessageIdentity appends export assignments to CLAUDE_ENV_FILE.
// The last assignment for each key is the effective shell value. Repeating an
// older value must append it again (A -> B -> A), while an explicit process
// environment value is preserved and never rewritten into the file.
func writeLiveMessageIdentity(envFile, team, agent string, skipTeam, skipAgent bool) error {
	if envFile == "" {
		return nil
	}
	if skipTeam && skipAgent {
		return nil
	}
	if (!skipTeam && !safeLiveMessageIdentity(team)) || (!skipAgent && !safeLiveMessageIdentity(agent)) {
		return fmt.Errorf("unsafe live-message identity")
	}
	if isSymlink(envFile) {
		return fmt.Errorf("security: symlinked env file refused: %s", envFile)
	}

	existingBytes, readErr := os.ReadFile(envFile)
	existing := ""
	if readErr == nil {
		existing = string(existingBytes)
	} else if !os.IsNotExist(readErr) {
		return fmt.Errorf("reading env file: %w", readErr)
	}

	f, err := os.OpenFile(envFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("opening env file: %w", err)
	}
	defer f.Close()

	lines := []struct {
		key  string
		line string
		skip bool
	}{
		{
			key:  deliveryidentity.EnvTeam,
			line: fmt.Sprintf("export %s=%s", deliveryidentity.EnvTeam, shellQuoteLiveMessageIdentity(team)),
			skip: skipTeam,
		},
		{
			key:  deliveryidentity.EnvAgent,
			line: fmt.Sprintf("export %s=%s", deliveryidentity.EnvAgent, shellQuoteLiveMessageIdentity(agent)),
			skip: skipAgent,
		},
	}
	needsSeparator := existing != "" && !strings.HasSuffix(existing, "\n")
	for _, assignment := range lines {
		if assignment.skip || lastExportLine(existing, assignment.key) == assignment.line {
			continue
		}
		if needsSeparator {
			if _, err := fmt.Fprintln(f); err != nil {
				return fmt.Errorf("separating env file entries: %w", err)
			}
			needsSeparator = false
		}
		if _, err := fmt.Fprintln(f, assignment.line); err != nil {
			return fmt.Errorf("writing env file: %w", err)
		}
		existing += assignment.line + "\n"
	}
	return nil
}

func lastExportLine(content, key string) string {
	prefix := "export " + key + "="
	last := ""
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(line, prefix) {
			last = line
		}
	}
	return last
}

func generatedIdentityExport(envFile, key, value string) bool {
	if envFile == "" || value == "" || isSymlink(envFile) {
		return false
	}
	data, err := os.ReadFile(envFile)
	if err != nil {
		return false
	}
	want := fmt.Sprintf("export %s=%s", key, shellQuoteLiveMessageIdentity(value))
	return lastExportLine(string(data), key) == want
}

func safeLiveMessageIdentity(value string) bool {
	if value == "" {
		return false
	}
	for _, r := range value {
		if r == '\x00' || r == '\n' || r == '\r' {
			return false
		}
	}
	return true
}

func shellQuoteLiveMessageIdentity(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
