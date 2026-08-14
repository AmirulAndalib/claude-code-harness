package shellscan

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// IsAllowlistedTempPath reports whether path is inside an OS-managed scratch
// root. Callers that accept user-controlled paths must resolve symlinks before
// calling this function. Allowlisted roots are compared in both their original
// and symlink-resolved forms.
func IsAllowlistedTempPath(path string) bool {
	cleanPath := filepath.Clean(path)
	for _, root := range allowlistedTempRoots() {
		cleanRoot := filepath.Clean(root)
		if cleanPath == cleanRoot ||
			strings.HasPrefix(cleanPath, cleanRoot+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

// SessionIDComponentPattern bounds what may be treated as a session-identifying
// path component. Claude Code session ids are UUIDs; requiring that shape stops
// a short or attacker-chosen component (".", "a", "tmp") from turning an
// unrelated temp directory into "the agent's own scratch".
var SessionIDComponentPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{15,127}$`)

// IsWithinSessionScratch reports whether path is the current session's own
// scratch space: nested inside an OS-managed ephemeral temp root AND carrying
// sessionID as an exact path component.
//
// It exists for callers deciding whether a RECURSIVE DELETE may proceed without
// confirmation, and is deliberately narrower than IsAllowlistedTempPath on
// three axes:
//
//  1. The temp root itself is excluded — `rm -rf /tmp` or `rm -rf $TMPDIR`
//     would wipe every other session's and tool's scratch space.
//  2. Someone else's temp directory is excluded. /tmp is SHARED: other Claude
//     sessions, other agents, and unrelated tools keep state there. Requiring
//     the session id as a component means the agent may churn only the
//     directory tree Claude Code handed it.
//  3. The cache directories (~/.cache, ~/Library/Caches) are not temp roots
//     here; they hold state other tools rebuild over time.
//
// Callers that accept user-controlled paths must resolve symlinks BEFORE
// calling this function; a symlink inside the scratchpad pointing at $HOME must
// not be treated as session scratch.
func IsWithinSessionScratch(path, sessionID string) bool {
	sessionID = strings.TrimSpace(sessionID)
	if !SessionIDComponentPattern.MatchString(sessionID) {
		return false
	}
	cleanPath := filepath.Clean(path)

	withinTemp := false
	for _, root := range ephemeralScratchRoots() {
		cleanRoot := filepath.Clean(root)
		if cleanPath == cleanRoot {
			continue
		}
		if strings.HasPrefix(cleanPath, cleanRoot+string(filepath.Separator)) {
			withinTemp = true
			break
		}
	}
	if !withinTemp {
		return false
	}

	for _, component := range strings.Split(cleanPath, string(filepath.Separator)) {
		if component == sessionID {
			return true
		}
	}
	return false
}

// ephemeralScratchRoots returns the OS-managed temp roots only — deliberately a
// subset of allowlistedTempRoots (see IsWithinSessionScratch).
func ephemeralScratchRoots() []string {
	roots := []string{
		"/tmp",
		"/var/tmp",
		"/private/tmp",
		"/private/var/tmp",
	}
	if tempDir := strings.TrimSpace(os.Getenv("TMPDIR")); tempDir != "" {
		if abs, err := filepath.Abs(tempDir); err == nil {
			roots = append(roots, filepath.Clean(abs))
		} else {
			roots = append(roots, filepath.Clean(tempDir))
		}
	}
	return resolveBothForms(roots)
}

func allowlistedTempRoots() []string {
	roots := []string{
		"/tmp",
		"/var/tmp",
		"/private/tmp",
		"/private/var/tmp",
	}
	if tempDir := strings.TrimSpace(os.Getenv("TMPDIR")); tempDir != "" {
		if abs, err := filepath.Abs(tempDir); err == nil {
			roots = append(roots, filepath.Clean(abs))
		} else {
			roots = append(roots, filepath.Clean(tempDir))
		}
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		roots = append(roots, filepath.Join(home, ".cache"))
		roots = append(roots, filepath.Join(home, "Library", "Caches"))
	}

	return resolveBothForms(roots)
}

// resolveBothForms returns each root in its cleaned and symlink-resolved forms,
// because macOS resolves /tmp to /private/tmp and home directories can be
// symlinked.
func resolveBothForms(roots []string) []string {
	resolvedRoots := make([]string, 0, len(roots)*2)
	for _, root := range roots {
		cleanRoot := filepath.Clean(root)
		resolvedRoots = append(resolvedRoots, cleanRoot)
		if resolvedRoot, err := filepath.EvalSymlinks(cleanRoot); err == nil {
			resolvedRoots = append(resolvedRoots, filepath.Clean(resolvedRoot))
		}
	}
	return resolvedRoots
}
