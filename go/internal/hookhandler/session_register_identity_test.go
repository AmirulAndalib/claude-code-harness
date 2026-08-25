package hookhandler

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/deliveryidentity"
	"github.com/Chachamaru127/claude-code-harness/go/internal/gitport"
)

func TestHandleSessionRegisterWithIdentity_WritesExportedTeamAndAgent(t *testing.T) {
	root := t.TempDir()
	envFile := filepath.Join(t.TempDir(), "claude-env")
	if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte("[livemsg]\nteam = \"configured-team\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("HARNESS_LIVEMSG_TEAM", "")
	t.Setenv("HARNESS_LIVEMSG_AGENT", "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("BREEZING_ROLE", "")

	if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"session-abc"}`), nil); err != nil {
		t.Fatalf("register with identity: %v", err)
	}

	content, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != 2 {
		t.Fatalf("env file must contain exactly two identity lines, got %d:\n%s", len(lines), content)
	}
	for _, want := range []string{
		"export HARNESS_LIVEMSG_TEAM='configured-team'",
		"export HARNESS_LIVEMSG_AGENT='session-abc'",
	} {
		if !strings.Contains(string(content), want+"\n") && !strings.HasSuffix(string(content), want) {
			t.Errorf("expected exported identity %q, got:\n%s", want, content)
		}
	}
	if strings.Contains(string(content), "\nHARNESS_LIVEMSG_TEAM=") || strings.Contains(string(content), "\nHARNESS_LIVEMSG_AGENT=") {
		t.Errorf("identity must use export form, got:\n%s", content)
	}
}

func TestHandleSessionRegisterWithIdentity_FallsBackToRepoNameAndResolvesFromEnv(t *testing.T) {
	root := filepath.Join(t.TempDir(), "repo-name")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	envFile := filepath.Join(t.TempDir(), "claude-env")
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv("HARNESS_LIVEMSG_TEAM", "")
	t.Setenv("HARNESS_LIVEMSG_AGENT", "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("BREEZING_ROLE", "")

	if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"session-from-payload"}`), nil); err != nil {
		t.Fatalf("register with identity: %v", err)
	}

	content, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(deliveryidentity.EnvTeam, envValueFromExport(t, string(content), deliveryidentity.EnvTeam))
	t.Setenv(deliveryidentity.EnvAgent, envValueFromExport(t, string(content), deliveryidentity.EnvAgent))

	team, agent, err := deliveryidentity.Resolve()
	if err != nil {
		t.Fatalf("Resolve from producer env: %v", err)
	}
	if team != "repo-name" || agent != "session-from-payload" {
		t.Fatalf("Resolve() = team=%q agent=%q, want repo-name/session-from-payload", team, agent)
	}
}

func TestHandleSessionRegisterWithIdentity_OperatorEnvWinsOverBreezing(t *testing.T) {
	root := t.TempDir()
	envFile := filepath.Join(t.TempDir(), "claude-env")
	if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte("[livemsg]\nteam = \"env-team\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv(deliveryidentity.EnvTeam, "operator-team")
	t.Setenv(deliveryidentity.EnvAgent, "operator-agent")
	t.Setenv("BREEZING_SESSION_ID", "breezing-team")
	t.Setenv("BREEZING_ROLE", "breezing-agent")

	if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"payload-agent"}`), nil); err != nil {
		t.Fatalf("register with identity: %v", err)
	}
	team, agent, err := deliveryidentity.Resolve()
	if err != nil {
		t.Fatalf("Resolve with operator env and breezing fallback present: %v", err)
	}
	if team != "operator-team" || agent != "operator-agent" {
		t.Fatalf("Resolve() = team=%q agent=%q, want operator-team/operator-agent", team, agent)
	}
	if _, err := os.Stat(envFile); !os.IsNotExist(err) {
		t.Fatalf("operator env identity must not create an override env file, stat err=%v", err)
	}
}

func TestResolveLiveMessageTeam_LinkedWorktreesUseSharedRepoName(t *testing.T) {
	repoRoot := filepath.Join(t.TempDir(), "shared-repo")
	if err := os.MkdirAll(repoRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := gitport.Run(repoRoot, "init", "-q"); err != nil {
		t.Fatalf("git init: %v", err)
	}
	if err := os.WriteFile(filepath.Join(repoRoot, "README.md"), []byte("seed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := gitport.Run(repoRoot, "add", "README.md"); err != nil {
		t.Fatalf("git add: %v", err)
	}
	if err := gitport.Run(repoRoot, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "seed"); err != nil {
		t.Fatalf("git commit: %v", err)
	}
	linkedRoot := filepath.Join(t.TempDir(), "linked-worktree")
	if err := gitport.Run(repoRoot, "worktree", "add", "-q", linkedRoot); err != nil {
		t.Fatalf("git worktree add: %v", err)
	}

	want := filepath.Base(repoRoot)
	if got := resolveLiveMessageTeam(repoRoot); got != want {
		t.Fatalf("main checkout team = %q, want shared repo name %q", got, want)
	}
	if got := resolveLiveMessageTeam(linkedRoot); got != want {
		t.Fatalf("linked worktree team = %q, want shared repo name %q", got, want)
	}
}

func TestHandleSessionRegisterWithIdentity_PreservesExplicitEnvIdentity(t *testing.T) {
	root := t.TempDir()
	envFile := filepath.Join(t.TempDir(), "claude-env")
	if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte("[livemsg]\nteam = \"configured-team\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(envFile, []byte("export HARNESS_LIVEMSG_TEAM='file-team'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv(deliveryidentity.EnvTeam, "explicit-team")
	t.Setenv(deliveryidentity.EnvAgent, "explicit-agent")
	t.Setenv("BREEZING_SESSION_ID", "breezing-team")
	t.Setenv("BREEZING_ROLE", "breezing-agent")

	if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"payload-agent"}`), nil); err != nil {
		t.Fatalf("register with identity: %v", err)
	}

	content, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(content); got != "export HARNESS_LIVEMSG_TEAM='file-team'\n" {
		t.Fatalf("explicit env identity must not rewrite env file, got %q", got)
	}
	team, agent, err := deliveryidentity.Resolve()
	if err != nil {
		t.Fatalf("Resolve with explicit env: %v", err)
	}
	if team != "explicit-team" || agent != "explicit-agent" {
		t.Fatalf("Resolve() = team=%q agent=%q, want explicit-team/explicit-agent", team, agent)
	}
}

func TestHandleSessionRegisterWithIdentity_BreezingIdentityBeatsStandaloneDefaults(t *testing.T) {
	root := t.TempDir()
	envFile := filepath.Join(t.TempDir(), "claude-env")
	if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte("[livemsg]\nteam = \"standalone-team\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv(deliveryidentity.EnvTeam, "")
	t.Setenv(deliveryidentity.EnvAgent, "")
	t.Setenv("BREEZING_SESSION_ID", "breezing-session")
	t.Setenv("BREEZING_ROLE", "worker")

	if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"payload-agent"}`), nil); err != nil {
		t.Fatalf("register with breezing identity: %v", err)
	}
	content, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := envValueFromExport(t, string(content), deliveryidentity.EnvTeam); got != "breezing-session" {
		t.Fatalf("exported team = %q, want breezing-session\n%s", got, content)
	}
	if got := envValueFromExport(t, string(content), deliveryidentity.EnvAgent); got != "worker" {
		t.Fatalf("exported agent = %q, want worker\n%s", got, content)
	}
	if strings.Contains(string(content), "standalone-team") || strings.Contains(string(content), "payload-agent") {
		t.Fatalf("standalone identity must not override breezing identity:\n%s", content)
	}

	// Emulate the next process sourcing CLAUDE_ENV_FILE: Resolve must see the
	// same Breezing identity through env and therefore cannot misroute to the
	// standalone defaults.
	t.Setenv(deliveryidentity.EnvTeam, envValueFromExport(t, string(content), deliveryidentity.EnvTeam))
	t.Setenv(deliveryidentity.EnvAgent, envValueFromExport(t, string(content), deliveryidentity.EnvAgent))
	team, agent, err := deliveryidentity.Resolve()
	if err != nil {
		t.Fatalf("Resolve after sourcing breezing identity: %v", err)
	}
	if team != "breezing-session" || agent != "worker" {
		t.Fatalf("Resolve() = team=%q agent=%q, want breezing-session/worker", team, agent)
	}
}

func TestHandleSessionRegisterWithIdentity_RefreshesGeneratedAgentAfterFork(t *testing.T) {
	root := t.TempDir()
	envFile := filepath.Join(t.TempDir(), "claude-env")
	if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte("[livemsg]\nteam = \"team-a\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv(deliveryidentity.EnvTeam, "")
	t.Setenv(deliveryidentity.EnvAgent, "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("BREEZING_ROLE", "")

	if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"parent-agent"}`), nil); err != nil {
		t.Fatalf("parent register: %v", err)
	}
	first, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	// The next hook process receives the previous handler-generated exports.
	t.Setenv(deliveryidentity.EnvTeam, envValueFromExport(t, string(first), deliveryidentity.EnvTeam))
	t.Setenv(deliveryidentity.EnvAgent, envValueFromExport(t, string(first), deliveryidentity.EnvAgent))

	if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"child-agent"}`), nil); err != nil {
		t.Fatalf("child register: %v", err)
	}
	second, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := envValueFromExport(t, string(second), deliveryidentity.EnvAgent); got != "child-agent" {
		t.Fatalf("effective generated agent = %q, want child-agent\n%s", got, second)
	}
	if got := exportValues(string(second), deliveryidentity.EnvAgent); strings.Join(got, ",") != "parent-agent,child-agent" {
		t.Fatalf("agent export history = %v, want [parent-agent child-agent]\n%s", got, second)
	}
}

func TestHandleSessionRegisterWithIdentity_AtoBtoAUsesLatestAssignments(t *testing.T) {
	root := t.TempDir()
	envFile := filepath.Join(t.TempDir(), "claude-env")
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", envFile)
	t.Setenv(deliveryidentity.EnvTeam, "")
	t.Setenv(deliveryidentity.EnvAgent, "")
	t.Setenv("BREEZING_SESSION_ID", "")
	t.Setenv("BREEZING_ROLE", "")

	writeTeam := func(team string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, "harness.toml"), []byte("[livemsg]\nteam = \""+team+"\"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	register := func(team, agent string) {
		t.Helper()
		writeTeam(team)
		if err := HandleSessionRegisterWithIdentity(strings.NewReader(`{"session_id":"`+agent+`"}`), nil); err != nil {
			t.Fatalf("register %s/%s: %v", team, agent, err)
		}
	}
	register("team-a", "agent-a")
	register("team-b", "agent-b")
	register("team-a", "agent-a")

	content, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := exportValues(string(content), deliveryidentity.EnvTeam); strings.Join(got, ",") != "team-a,team-b,team-a" {
		t.Fatalf("team export history = %v, want [team-a team-b team-a]\n%s", got, content)
	}
	if got := exportValues(string(content), deliveryidentity.EnvAgent); strings.Join(got, ",") != "agent-a,agent-b,agent-a" {
		t.Fatalf("agent export history = %v, want [agent-a agent-b agent-a]\n%s", got, content)
	}
	if got := envValueFromExport(t, string(content), deliveryidentity.EnvTeam); got != "team-a" {
		t.Fatalf("effective team = %q, want team-a", got)
	}
	if got := envValueFromExport(t, string(content), deliveryidentity.EnvAgent); got != "agent-a" {
		t.Fatalf("effective agent = %q, want agent-a", got)
	}
}

func envValueFromExport(t *testing.T, content, key string) string {
	t.Helper()
	values := exportValues(content, key)
	if len(values) > 0 {
		return values[len(values)-1]
	}
	t.Fatalf("missing %s export in %q", key, content)
	return ""
}

func exportValues(content, key string) []string {
	prefix := "export " + key + "='"
	values := make([]string, 0)
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(line, prefix) && strings.HasSuffix(line, "'") {
			values = append(values, strings.TrimSuffix(strings.TrimPrefix(line, prefix), "'"))
		}
	}
	return values
}

// TestPresenceCardCarriesDeliveryIdentity pins that peers can actually address
// this session. Under Breezing the identity is BREEZING_SESSION_ID/ROLE, not
// the session id, so a roster that showed only the session id let a sender
// address a recipient that does not exist.
func TestPresenceCardCarriesDeliveryIdentity(t *testing.T) {
	root := initGitRepoForPresence(t)
	t.Setenv("HARNESS_PROJECT_ROOT", root)
	t.Setenv("CLAUDE_ENV_FILE", filepath.Join(t.TempDir(), "env"))
	t.Setenv("HARNESS_LIVEMSG_TEAM", "")
	t.Setenv("HARNESS_LIVEMSG_AGENT", "")
	t.Setenv("BREEZING_SESSION_ID", "sprint-team")
	t.Setenv("BREEZING_ROLE", "worker-7")

	payload := `{"session_id":"presence-identity-session-01","cwd":"` + root + `"}`
	var out bytes.Buffer
	if err := HandleSessionRegisterWithIdentity(strings.NewReader(payload), &out); err != nil {
		t.Fatalf("register: %v", err)
	}

	listing := FormatSessionTeamList(root, time.Now())
	if !strings.Contains(listing, "sprint-team") || !strings.Contains(listing, "worker-7") {
		t.Fatalf("session list must expose the delivery identity, got:\n%s", listing)
	}
}

// TestPresenceIdentityPreservesDeclaredTask keeps the 141.2 guarantee: writing
// the identity must not wipe what `session declare` recorded.
func TestPresenceIdentityPreservesDeclaredTask(t *testing.T) {
	root := initGitRepoForPresence(t)
	dir := sharedLiveSessionsDirFromRoot(root)
	if dir == "" {
		t.Fatal("sharedLiveSessionsDirFromRoot returned empty")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionID := "presence-identity-session-02"
	card := encodePresenceCard(PresenceCard{Label: "lead", Task: "141.8", Since: "2026-08-24T00:00:00Z"})
	if err := os.WriteFile(filepath.Join(dir, sessionID), card, 0o600); err != nil {
		t.Fatal(err)
	}

	recordPresenceIdentity(root, sessionID, "team-x", "agent-y")

	data, err := os.ReadFile(filepath.Join(dir, sessionID))
	if err != nil {
		t.Fatal(err)
	}
	got := ParsePresenceCardBody(data)
	if got.Task != "141.8" || got.Label != "lead" || got.Since != "2026-08-24T00:00:00Z" {
		t.Fatalf("declare metadata was clobbered: %#v", got)
	}
	if got.Team != "team-x" || got.Agent != "agent-y" {
		t.Fatalf("identity was not recorded: %#v", got)
	}
}
