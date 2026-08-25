package hookhandler

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/gitport"
)

var presenceSessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// validPresenceSessionID gates which session ids may be written or honored as
// shared presence filenames. Invalid ids are skipped silently (fail-open).
func validPresenceSessionID(id string) bool {
	if id == "" || id == "." || id == ".." {
		return false
	}
	return presenceSessionIDPattern.MatchString(id)
}

// resolveGitCommonDir returns an absolute git common dir for projectRoot,
// mirroring leaseStore's resolution path.
func resolveGitCommonDir(projectRoot string) (string, bool) {
	if projectRoot == "" {
		projectRoot = resolveProjectRoot()
	}
	out, err := gitport.Output(projectRoot, "rev-parse", "--git-common-dir")
	if err != nil {
		return "", false
	}
	commonDir := strings.TrimSpace(out)
	if commonDir == "" {
		return "", false
	}
	if !filepath.IsAbs(commonDir) {
		commonDir = filepath.Join(projectRoot, commonDir)
	}
	return commonDir, true
}

// sharedLiveSessionsDirFromRoot resolves the cross-worktree presence directory
// at <git-common-dir parent>/.claude/sessions/live-sessions/. Empty string
// when git is unavailable (fail-open for writers and readers).
func sharedLiveSessionsDirFromRoot(projectRoot string) string {
	commonDir, ok := resolveGitCommonDir(projectRoot)
	if !ok {
		return ""
	}
	repoRoot := filepath.Dir(commonDir)
	return filepath.Join(repoRoot, ".claude", "sessions", "live-sessions")
}

// sharedSessionsDirFromRoot resolves the shared .claude/sessions directory by
// reusing the same git-common-dir resolution as the presence directory. Empty
// string means git is unavailable, so callers can keep their local fallback.
func sharedSessionsDirFromRoot(projectRoot string) string {
	liveDir := sharedLiveSessionsDirFromRoot(projectRoot)
	if liveDir == "" {
		return ""
	}
	return filepath.Dir(liveDir)
}

// sharedLiveSessionsDirFromLeaseCfg resolves the presence dir using the same
// git-common-dir inputs as leaseStore so worktree callers observe the shared
// tree on the main checkout.
func sharedLiveSessionsDirFromLeaseCfg(cfg LeaseConfig) string {
	commonDir := cfg.GitCommonDir
	if commonDir == "" {
		root := cfg.RepoRoot
		if root == "" {
			root = resolveProjectRoot()
		}
		var ok bool
		commonDir, ok = resolveGitCommonDir(root)
		if !ok {
			return ""
		}
	}
	repoRoot := filepath.Dir(commonDir)
	return filepath.Join(repoRoot, ".claude", "sessions", "live-sessions")
}

const presenceFileMode os.FileMode = 0o600
const presenceDirMode os.FileMode = 0o700

// refreshSharedPresence creates or refreshes the caller's presence file under
// the shared live-sessions tree. All errors are swallowed (fail-open).
// label is written only when creating a new file; existing content is preserved
// (mtime refresh only) so declare/task metadata survives register heartbeats.
func refreshSharedPresence(projectRoot, sessionID, label string) {
	if !validPresenceSessionID(sessionID) {
		return
	}
	dir := sharedLiveSessionsDirFromRoot(projectRoot)
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, presenceDirMode); err != nil {
		return
	}
	path := filepath.Join(dir, sessionID)
	now := time.Now()
	if _, err := os.Stat(path); err == nil {
		_ = os.Chtimes(path, now, now)
		return
	}
	body := presenceBodyForNewFile(label)
	if err := os.WriteFile(path, body, presenceFileMode); err != nil {
		return
	}
	_ = os.Chtimes(path, now, now)
}

// pruneStaleSharedPresence removes presence files (other than the current
// session) whose mtime is older than registerStaleCutoff.
func pruneStaleSharedPresence(projectRoot, currentSessionID string) {
	dir := sharedLiveSessionsDirFromRoot(projectRoot)
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-registerStaleCutoff)
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		if name == currentSessionID {
			continue
		}
		if !validPresenceSessionID(name) {
			continue
		}
		info, err := ent.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(dir, name))
		}
	}
}

// removeSharedPresence deletes only the caller's own presence file.
func removeSharedPresence(projectRoot, sessionID string) {
	if !validPresenceSessionID(sessionID) {
		return
	}
	dir := sharedLiveSessionsDirFromRoot(projectRoot)
	if dir == "" {
		return
	}
	_ = os.Remove(filepath.Join(dir, sessionID))
}

// isHolderAliveViaSharedPresence returns true when a fresh presence file exists
// for sessionID under the shared tree. Missing dirs, unreadable state, or
// invalid ids contribute nothing (false).
func isHolderAliveViaSharedPresence(sessionID string, cfg LeaseConfig, now time.Time) bool {
	if !validPresenceSessionID(sessionID) {
		return false
	}
	dir := sharedLiveSessionsDirFromLeaseCfg(cfg)
	if dir == "" {
		return false
	}
	path := filepath.Join(dir, sessionID)
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	if info.IsDir() {
		return false
	}
	cutoff := now.Add(-registerStaleCutoff)
	return !info.ModTime().Before(cutoff)
}

// recordPresenceIdentity stores the session's resolved delivery identity in its
// own presence card, merging into whatever `session declare` already wrote.
// Peers read this to address a message: the identity is not derivable from the
// session id, because Breezing resolves it from BREEZING_SESSION_ID/ROLE.
// Fail-open throughout — presence is a convenience, never a gate.
func recordPresenceIdentity(projectRoot, sessionID, team, agent string) {
	if !validPresenceSessionID(sessionID) || (team == "" && agent == "") {
		return
	}
	dir := sharedLiveSessionsDirFromRoot(projectRoot)
	if dir == "" {
		return
	}
	path := filepath.Join(dir, sessionID)
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	existing, _ := os.ReadFile(path)
	card := ParsePresenceCardBody(existing)
	if card.Team == team && card.Agent == agent {
		return
	}
	card.Team = team
	card.Agent = agent
	body := encodePresenceCard(card)
	if body == nil {
		return
	}
	if err := os.WriteFile(path, body, presenceFileMode); err != nil {
		return
	}
	// Keep the freshness signal the caller already established.
	_ = os.Chtimes(path, info.ModTime(), info.ModTime())
}
