package guardrail

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/state"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

// Phase 133.11: the hook payload carries the tool call's cwd, not the project
// root. Resolving the root to that cwd verbatim made every projectRoot-relative
// check look at a directory that holds none of the project's files.

func mkdirAll(t *testing.T, parts ...string) string {
	t.Helper()
	p := filepath.Join(parts...)
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", p, err)
	}
	return p
}

func TestAscendToProjectRoot_FromSubdirectoryFindsGitRoot(t *testing.T) {
	root := t.TempDir()
	mkdirAll(t, root, ".git")
	sub := mkdirAll(t, root, "go", "internal")

	if got := ascendToProjectRoot(sub); got != root {
		t.Fatalf("ascendToProjectRoot(%s) = %s, want %s", sub, got, root)
	}
}

func TestAscendToProjectRoot_HarnessMarkerAlsoCounts(t *testing.T) {
	root := t.TempDir()
	mkdirAll(t, root, ".harness")
	sub := mkdirAll(t, root, "benchmarks", "bench", "agent-eval")

	if got := ascendToProjectRoot(sub); got != root {
		t.Fatalf("ascendToProjectRoot(%s) = %s, want %s", sub, got, root)
	}
}

// A linked git worktree carries `.git` as a FILE, not a directory. Resolving it
// must land on the worktree root, because that worktree is the project.
func TestAscendToProjectRoot_GitFileMarksWorktreeRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: /elsewhere/.git/worktrees/wt\n"), 0o600); err != nil {
		t.Fatalf("write .git file: %v", err)
	}
	sub := mkdirAll(t, root, "scripts")

	if got := ascendToProjectRoot(sub); got != root {
		t.Fatalf("ascendToProjectRoot(%s) = %s, want %s", sub, got, root)
	}
}

// `.claude` must NOT mark a root. The stray `.claude/state/` trees that this
// very bug wrote into subdirectories would otherwise be self-confirming: the
// root would stay pinned to whichever subdirectory a tool call once ran in.
func TestAscendToProjectRoot_ClaudeDirIsNotAMarker(t *testing.T) {
	root := t.TempDir()
	mkdirAll(t, root, ".git")
	sub := mkdirAll(t, root, "go")
	mkdirAll(t, sub, ".claude", "state")

	if got := ascendToProjectRoot(sub); got != root {
		t.Fatalf("ascendToProjectRoot(%s) = %s, want %s (a stray .claude must not pin the root)", sub, got, root)
	}
}

// The nearest marker wins, so a nested repository resolves to itself rather
// than to its parent.
func TestAscendToProjectRoot_NearestMarkerWins(t *testing.T) {
	outer := t.TempDir()
	mkdirAll(t, outer, ".git")
	inner := mkdirAll(t, outer, "vendor", "nested")
	mkdirAll(t, inner, ".git")
	sub := mkdirAll(t, inner, "src")

	if got := ascendToProjectRoot(sub); got != inner {
		t.Fatalf("ascendToProjectRoot(%s) = %s, want %s", sub, got, inner)
	}
}

// No marker anywhere: behavior is unchanged from before 133.11 — the directory
// itself is the root. Widening here would widen R05's allow surface.
func TestAscendToProjectRoot_NoMarkerKeepsDirectory(t *testing.T) {
	dir := mkdirAll(t, t.TempDir(), "plain", "nested")

	if got := ascendToProjectRoot(dir); got != dir {
		t.Fatalf("ascendToProjectRoot(%s) = %s, want %s", dir, got, dir)
	}
}

// ctx.ProjectRoot is what R05 treats as deletable without confirmation, so the
// walk must never climb to the home directory just because a dotfiles repo put
// a `.git` there.
func TestAscendToProjectRoot_StopsBeforeHomeDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir home/.git: %v", err)
	}
	sub := mkdirAll(t, home, "projects", "thing")

	got := ascendToProjectRoot(sub)
	if got == home {
		t.Fatalf("ascendToProjectRoot(%s) resolved to the home directory %s; a stray ~/.git must not make all of $HOME an allow surface", sub, home)
	}
	if got != sub {
		t.Fatalf("ascendToProjectRoot(%s) = %s, want the directory itself", sub, got)
	}
}

// An explicitly declared root is a statement of intent and is honored verbatim;
// only a cwd gets the upward search.
func TestResolveProjectRoot_ExplicitEnvRootIsNotRewritten(t *testing.T) {
	root := t.TempDir()
	mkdirAll(t, root, ".git")
	declared := mkdirAll(t, root, "go")

	t.Setenv("HARNESS_PROJECT_ROOT", declared)
	if got := resolveProjectRoot(hookproto.HookInput{}); got != declared {
		t.Fatalf("resolveProjectRoot with HARNESS_PROJECT_ROOT = %s, want %s", got, declared)
	}
}

func TestResolveProjectRoot_CWDFromSubdirectoryResolvesToRoot(t *testing.T) {
	root := t.TempDir()
	mkdirAll(t, root, ".git")
	sub := mkdirAll(t, root, "go", "internal", "policy")

	got := resolveProjectRoot(hookproto.HookInput{CWD: sub})
	if got != root {
		t.Fatalf("resolveProjectRoot(cwd=%s) = %s, want %s", sub, got, root)
	}
}

// The end-to-end symptom of 133.11: work-mode was recorded for the session, but
// a call made from a subdirectory lost it entirely.
//
// The work state MUST come from the state DB, not from HARNESS_WORK_MODE. The
// env var short-circuits BuildContext before it ever calls ResolveStatePath and
// loadWorkStateFromDB, which is precisely the code path this bug lived in — a
// test that sets it would pass just as well against the broken resolver.
func TestBuildContext_WorkModeSurvivesSubdirectoryCWD(t *testing.T) {
	const sessionID = "s-133-11"

	root := t.TempDir()
	mkdirAll(t, root, ".git")
	sub := mkdirAll(t, root, "go")

	// CLAUDE_PLUGIN_DATA would make ResolveStatePath ignore projectRoot, hiding
	// the very misresolution under test.
	t.Setenv("CLAUDE_PLUGIN_DATA", "")
	t.Setenv("HARNESS_WORK_MODE", "")
	t.Setenv("ULTRAWORK_MODE", "")

	dbPath := state.ResolveStatePath(root)
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		t.Fatalf("mkdir state dir: %v", err)
	}
	store, err := state.NewHarnessStore(dbPath)
	if err != nil {
		t.Fatalf("open state db: %v", err)
	}
	// work_states carries a foreign key into sessions, so the session row has
	// to exist first.
	if err := store.UpsertSession(state.SessionState{
		SessionID:   sessionID,
		Mode:        state.SessionModeWork,
		ProjectRoot: root,
		StartedAt:   time.Now().UTC().Format(time.RFC3339),
	}); err != nil {
		store.Close()
		t.Fatalf("upsert session: %v", err)
	}
	err = store.SetWorkState(sessionID, state.WorkStateOptions{WorkMode: true})
	store.Close()
	if err != nil {
		t.Fatalf("write work state: %v", err)
	}

	ctx := BuildContext(hookproto.HookInput{CWD: sub, SessionID: sessionID})

	if ctx.ProjectRoot != root {
		t.Fatalf("ctx.ProjectRoot = %s, want %s", ctx.ProjectRoot, root)
	}
	if !ctx.WorkMode {
		t.Fatal("ctx.WorkMode = false: the work state recorded at the project root was not found from a subdirectory")
	}
}
