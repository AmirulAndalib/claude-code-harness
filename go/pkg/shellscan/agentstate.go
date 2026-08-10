package shellscan

import (
	"os"
	"path/filepath"
	"strings"
)

// IsAgentStatePath reports whether path is inside a Claude-Code-managed
// AGENT STATE directory:
//
//   - <home>/.claude/projects/<slug>/memory/**  the agent's own per-project
//     memory directory (Claude Code itself instructs agents to persist
//     notes here; <slug> is any single path segment)
//   - <home>/.claude/plans/**                   saved plan-mode output
//
// Both are DATA the agent is expected to write during normal operation, so
// writes there are approved without confirmation by R04:confirm-write-
// outside-project. Everything else under ~/.claude returns false — in
// particular settings.json, skills/, agents/, commands/, hooks/, plugins/,
// and output-styles/ stay confirmable, because those change *behavior*
// (permissions, tool definitions, automation wiring) rather than storing
// data. This function allowlists only the two data shapes above; it does
// not enumerate denials.
//
// Roots are compared in both their original and symlink-resolved forms,
// mirroring allowlistedTempRoots in temproots.go, because macOS home
// directories can be symlinked.
func IsAgentStatePath(path string) bool {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return false
	}
	cleanPath := filepath.Clean(path)
	claudeDir := filepath.Join(home, ".claude")

	for _, claudeRoot := range resolvedDirRoots(claudeDir) {
		if isWithinDirRoot(cleanPath, filepath.Join(claudeRoot, "plans")) {
			return true
		}
		if isWithinAgentMemoryDir(cleanPath, filepath.Join(claudeRoot, "projects")) {
			return true
		}
	}
	return false
}

// isWithinAgentMemoryDir reports whether cleanPath is projectsRoot/<slug>/memory
// or something nested under it, where <slug> is exactly one path segment.
// It is prefix-collision safe: projectsRoot/<slug>/memory-extra/... is rejected
// because the second path segment must equal "memory" exactly, not merely
// start with it.
func isWithinAgentMemoryDir(cleanPath, projectsRoot string) bool {
	cleanRoot := filepath.Clean(projectsRoot)
	rel, err := filepath.Rel(cleanRoot, cleanPath)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return false
	}
	segments := strings.Split(rel, string(filepath.Separator))
	if len(segments) < 2 {
		return false
	}
	slug := segments[0]
	if slug == "" || slug == "." || slug == ".." {
		return false
	}
	return segments[1] == "memory"
}

// isWithinDirRoot reports whether cleanPath equals root or is nested under it,
// using the same separator-suffix technique as IsAllowlistedTempPath so that
// sibling directories sharing a prefix (e.g. "plans-backup") are rejected.
func isWithinDirRoot(cleanPath, root string) bool {
	cleanRoot := filepath.Clean(root)
	return cleanPath == cleanRoot || strings.HasPrefix(cleanPath, cleanRoot+string(filepath.Separator))
}

// resolvedDirRoots returns root in both its original and symlink-resolved
// forms, matching the pattern in allowlistedTempRoots.
func resolvedDirRoots(root string) []string {
	cleanRoot := filepath.Clean(root)
	roots := []string{cleanRoot}
	if resolved, err := filepath.EvalSymlinks(cleanRoot); err == nil {
		roots = append(roots, filepath.Clean(resolved))
	}
	return roots
}
