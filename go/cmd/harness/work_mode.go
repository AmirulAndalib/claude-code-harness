package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/hookhandler"
	"github.com/Chachamaru127/claude-code-harness/go/internal/state"
)

// KNOWN GAP — this subcommand does not yet affect the guardrail (Plans.md 132.7).
//
// ReadLocalSessionID below resolves .claude/state/session.json, which is the
// session-monitor state file. Its session_id is generated internally
// (timestamp-based) and is NOT the session_id Claude Code passes to hooks. The
// guardrail looks the row up by the hook payload's SessionID
// (go/internal/guardrail/pre_tool.go), so the row this command writes is never
// read. Measured 2026-08-10: after `work-mode on`, a pre-tool payload carrying
// the real session_id still returned "ask".
//
// The state read/write machinery below is correct and tested; only the identity
// resolution is wrong. Until 132.7 fixes it, `/breezing` relies on the operator
// setting HARNESS_WORK_MODE=1 in ~/.claude/settings.json.
//
// When verifying a fix, drive the hook with the REAL session_id. Feeding the
// hook the same id this command wrote proves only that SQLite round-trips —
// that mistake is what let this gap ship past its first review.
//
// runWorkMode implements the "harness work-mode <on|off|status>" subcommand.
//
// This is the fix for Plans.md 132.3: ctx.WorkMode (which lets R04/R05 skip
// their confirmation) was previously set only via HARNESS_WORK_MODE /
// ULTRAWORK_MODE env vars or a work_states row keyed by session ID — and
// nothing ever populated either source. This subcommand is the missing
// writer for the SQLite-backed source (skills cannot set env vars for the
// hook process, so the DB row is the only viable path).
func runWorkMode(args []string) {
	os.Exit(runWorkModeCommand(args, os.Stdout, os.Stderr))
}

func runWorkModeCommand(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "Usage: harness work-mode <on|off|status> [project-root]")
		return 1
	}
	action := args[0]
	if action != "on" && action != "off" && action != "status" {
		fmt.Fprintf(stderr, "Unknown work-mode subcommand: %s\n", action)
		return 1
	}

	var root string
	for _, a := range args[1:] {
		if !strings.HasPrefix(a, "-") {
			root = a
			break
		}
	}
	projectRoot, err := resolveProjectRoot(sessionRootArgs(root))
	if err != nil {
		fmt.Fprintf(stderr, "work-mode: %v\n", err)
		return 1
	}

	sessionID := hookhandler.ReadLocalSessionID(projectRoot)
	if sessionID == "" {
		fmt.Fprintln(stderr, "work-mode: no session id (set .claude/state/session.json or HARNESS_PROJECT_ROOT to a project with one)")
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
		if err := store.SetWorkState(sessionID, opts); err != nil {
			fmt.Fprintf(stderr, "work-mode: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, action)
		return 0
	}
	// unreachable: action validated above
	return 1
}
