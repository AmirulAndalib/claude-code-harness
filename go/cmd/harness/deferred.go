package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/Chachamaru127/claude-code-harness/go/internal/guardrail"
)

// runDeferred implements "harness deferred <list|approve <id>> [project-root]"
// (Plans.md 140.2): the operator side of destructive_delete=defer. R05 queues
// refused deletions in .claude/state/deferred-ops.jsonl; `list` shows them and
// `approve <id>` flips one pending entry to approved so the NEXT identical run
// is allowed exactly once (the guardrail consumes the approval, approved →
// consumed). There is deliberately no "approve all" and no auto-approval path.
func runDeferred(args []string) {
	os.Exit(runDeferredCommand(args, os.Stdout, os.Stderr))
}

func runDeferredCommand(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "Usage: harness deferred <list|approve <id>> [project-root] [--json]")
		return 1
	}
	action := args[0]
	rest := args[1:]

	jsonOut := false
	var positional []string
	for _, arg := range rest {
		if arg == "--json" {
			jsonOut = true
			continue
		}
		positional = append(positional, arg)
	}

	switch action {
	case "list":
		root, err := resolveDeferredRoot(positional, 0)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return runDeferredList(root, jsonOut, stdout, stderr)
	case "approve":
		if len(positional) == 0 {
			fmt.Fprintln(stderr, "Usage: harness deferred approve <id> [project-root]")
			return 1
		}
		id := positional[0]
		root, err := resolveDeferredRoot(positional, 1)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		if err := guardrail.ApproveDeferredOp(root, id); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintf(stdout, "approved %s: the next identical run is allowed once and recorded in .claude/state/destructive-delete.jsonl\n", id)
		return 0
	default:
		fmt.Fprintf(stderr, "Unknown deferred subcommand: %s\n", action)
		return 1
	}
}

// resolveDeferredRoot picks the optional positional project root at the given
// index (after the action's own arguments), defaulting to the working
// directory.
func resolveDeferredRoot(positional []string, index int) (string, error) {
	root := ""
	if len(positional) > index {
		root = positional[index]
	}
	if root == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("could not resolve project root: %w", err)
		}
		root = cwd
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("could not resolve project root: %w", err)
	}
	return abs, nil
}

func runDeferredList(root string, jsonOut bool, stdout, stderr io.Writer) int {
	views, err := guardrail.ListDeferredOps(root)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	pending := make([]guardrail.DeferredOpView, 0, len(views))
	for _, view := range views {
		if view.Status == "pending" {
			pending = append(pending, view)
		}
	}
	if jsonOut {
		data, err := json.MarshalIndent(pending, "", "  ")
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintln(stdout, string(data))
		return 0
	}
	if len(pending) == 0 {
		fmt.Fprintln(stdout, "no pending deferred ops")
		return 0
	}
	fmt.Fprintf(stdout, "%d pending deferred op(s) in .claude/state/deferred-ops.jsonl:\n", len(pending))
	for _, view := range pending {
		fmt.Fprintf(stdout, "  %s  %s  %s\n", view.ID, view.Timestamp, view.Command)
		fmt.Fprintf(stdout, "    approve: bin/harness deferred approve %s\n", view.ID)
	}
	return 0
}
