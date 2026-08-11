package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/state"
)

// runWorkMode implements the "harness work-mode <on|off|status>" subcommand.
//
// This is the writer side of ctx.WorkMode / ctx.CodexMode (Plans.md 132.3 +
// 132.7): the guardrail (go/internal/guardrail/pre_tool.go) looks work_states
// up by the session_id in the hook payload, so the row written here MUST be
// keyed by that same real session ID.
//
// Session-ID resolution (132.7). The legacy source `.claude/state/session.json`
// is intentionally NOT used: its session_id is generated internally by the
// session monitor and never matches the hook payload's ID (measured
// 2026-08-10 — rows written under it are dead). Sources, in order:
//
//  1. --session-id <id> flag (explicit, e.g. tests or cross-session tooling)
//  2. HARNESS_SESSION_ID env — exported into the session's Bash env by the
//     SessionStart hook via CLAUDE_ENV_FILE (internal/event/session_env.go),
//     carrying the exact ID Claude Code passes to hooks.
//  3. .claude/state/last-session-id.json — written on every UserPromptSubmit
//     by the track-command handler; accepted only when fresh (2h) because a
//     concurrent session in the same project root could have written it last.
//
// When verifying, drive the guardrail hook with the REAL session_id from an
// independent source (e.g. the transcript path). Feeding the hook whatever ID
// this command resolved proves only that SQLite round-trips — that mistake is
// what let the 132.3 gap ship past its first review.
func runWorkMode(args []string) {
	os.Exit(runWorkModeCommand(args, os.Stdout, os.Stderr))
}

// lastSessionIDMaxAge bounds how stale a last-session-id.json record may be
// before work-mode refuses to trust it (another session may own it by then).
const lastSessionIDMaxAge = 2 * time.Hour

// lastSessionIDRecord mirrors hookhandler's last-session-id.json schema.
type lastSessionIDRecord struct {
	SessionID string `json:"session_id"`
	UpdatedAt string `json:"updated_at"`
}

func runWorkModeCommand(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "Usage: harness work-mode <on|off|status> [project-root] [--session-id <id>] [--codex]")
		return 1
	}
	action := args[0]
	if action != "on" && action != "off" && action != "status" {
		fmt.Fprintf(stderr, "Unknown work-mode subcommand: %s\n", action)
		return 1
	}

	var root string
	var explicitSessionID string
	var codexFlag bool
	rest := args[1:]
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		switch {
		case a == "--session-id" && i+1 < len(rest):
			explicitSessionID = strings.TrimSpace(rest[i+1])
			i++
		case strings.HasPrefix(a, "--session-id="):
			explicitSessionID = strings.TrimSpace(strings.TrimPrefix(a, "--session-id="))
		case a == "--codex":
			codexFlag = true
		case !strings.HasPrefix(a, "-") && root == "":
			root = a
		}
	}
	projectRoot, err := resolveProjectRoot(sessionRootArgs(root))
	if err != nil {
		fmt.Fprintf(stderr, "work-mode: %v\n", err)
		return 1
	}

	sessionID, source := resolveRealSessionID(projectRoot, explicitSessionID)
	if sessionID == "" {
		fmt.Fprintln(stderr, "work-mode: cannot resolve the real session id.")
		fmt.Fprintln(stderr, "  Tried: --session-id flag, HARNESS_SESSION_ID env, .claude/state/last-session-id.json (fresh <2h).")
		fmt.Fprintln(stderr, "  The legacy .claude/state/session.json id is NOT accepted: it never matches the id the guardrail hook receives.")
		return 1
	}

	dbPath := state.ResolveStatePath(projectRoot)
	store, err := state.NewHarnessStore(dbPath)
	if err != nil {
		fmt.Fprintf(stderr, "work-mode: open state store: %v\n", err)
		return 1
	}
	defer store.Close()

	existing, err := store.GetWorkState(sessionID)
	if err != nil {
		fmt.Fprintf(stderr, "work-mode: read state: %v\n", err)
		return 1
	}

	switch action {
	case "status":
		if existing == nil || !existing.WorkMode {
			fmt.Fprintln(stdout, "off")
		} else {
			fmt.Fprintln(stdout, "on")
		}
		return 0
	case "on", "off":
		// work_states.session_id has a FOREIGN KEY on sessions(session_id).
		// The session-start hook usually creates that row first, but this
		// command must not depend on that ordering (e.g. a very early
		// `work-mode on` at run start). Only create a session row when one
		// is missing — UpsertSession's ON CONFLICT overwrites mode and
		// context_json unconditionally, which would clobber a fuller row
		// (e.g. one carrying meaningful Context) written by session-start.
		existingSession, err := store.GetSession(sessionID)
		if err != nil {
			fmt.Fprintf(stderr, "work-mode: read session: %v\n", err)
			return 1
		}
		if existingSession == nil {
			mode := state.SessionModeNormal
			if action == "on" {
				mode = state.SessionModeWork
			}
			if err := store.UpsertSession(state.SessionState{
				SessionID:   sessionID,
				Mode:        mode,
				ProjectRoot: projectRoot,
				StartedAt:   time.Now().UTC().Format(time.RFC3339),
			}); err != nil {
				fmt.Fprintf(stderr, "work-mode: ensure session: %v\n", err)
				return 1
			}
		}

		opts := state.WorkStateOptions{}
		if existing != nil {
			opts.CodexMode = existing.CodexMode
			opts.BypassRmRf = existing.BypassRmRf
			opts.BypassGitPush = existing.BypassGitPush
		}
		opts.WorkMode = action == "on"
		if codexFlag {
			// --codex marks the run as codex-delegated: R07 then denies
			// direct Write/Edit by the orchestrating Claude session.
			opts.CodexMode = action == "on"
		}
		if err := store.SetWorkState(sessionID, opts); err != nil {
			fmt.Fprintf(stderr, "work-mode: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "%s (session_id=%s via %s)\n", action, sessionID, source)
		return 0
	}
	// unreachable: action validated above
	return 1
}

// resolveRealSessionID resolves the session id the guardrail hook will see.
// Returns the id and a human-readable source label for the audit line.
func resolveRealSessionID(projectRoot, explicit string) (string, string) {
	if explicit != "" {
		return explicit, "--session-id"
	}
	if v := strings.TrimSpace(os.Getenv("HARNESS_SESSION_ID")); v != "" {
		return v, "HARNESS_SESSION_ID env"
	}
	path := filepath.Join(projectRoot, ".claude", "state", "last-session-id.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}
	var rec lastSessionIDRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return "", ""
	}
	rec.SessionID = strings.TrimSpace(rec.SessionID)
	if rec.SessionID == "" {
		return "", ""
	}
	ts, err := time.Parse(time.RFC3339, rec.UpdatedAt)
	if err != nil || time.Since(ts) > lastSessionIDMaxAge {
		return "", ""
	}
	return rec.SessionID, "last-session-id.json"
}
