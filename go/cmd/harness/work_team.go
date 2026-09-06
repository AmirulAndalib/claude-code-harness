package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/Chachamaru127/claude-code-harness/go/internal/autoapprove"
	"github.com/Chachamaru127/claude-code-harness/go/internal/breezing"
	"github.com/Chachamaru127/claude-code-harness/go/internal/breezingmem"
	"github.com/Chachamaru127/claude-code-harness/go/internal/companionresult"
	"github.com/Chachamaru127/claude-code-harness/go/internal/floor"
	"github.com/Chachamaru127/claude-code-harness/go/internal/orchestrationledger"
	"github.com/Chachamaru127/claude-code-harness/go/internal/reviewiterate"
	"github.com/Chachamaru127/claude-code-harness/go/internal/runtimefloor"
	"github.com/Chachamaru127/claude-code-harness/go/internal/sublead"
)

// floorGate is the FLOOR pre-merge backstop applied to a successful non-CC
// sub-run's reported changes before the team take-in is allowed to report
// success. It defaults to floor.Gate and is a package var only so tests can
// inject a gate outcome without shelling out to the contract scripts. Production
// never reassigns it.
var floorGate = floor.Gate

// runtimeFloorCheck is the RUNTIME ACTION HARD FLOOR pre-dispatch gate.
// Tests may inject a stub; production uses runtimefloor.CheckCommand.
var runtimeFloorCheck = runtimefloor.CheckCommand

// emitTeamDispatchLedger records team-side orchestration visibility. Tests may
// replace it; production uses orchestrationledger.EmitTeamDispatch.
var emitTeamDispatchLedger = orchestrationledger.EmitTeamDispatch

// emitCompanionResultLedger records per-task companion outcomes. Tests may
// replace it; production uses orchestrationledger.EmitCompanionResult.
var emitCompanionResultLedger = orchestrationledger.EmitCompanionResult

// breezingMemRecorder posts breezing lifecycle events to harness-mem (fail-open).
type breezingMemRecorder interface {
	RecordEvent(ctx context.Context, eventType, project, sessionID, content string)
	IngestBrief(ctx context.Context, project, sessionID string, briefJSON []byte)
}

// breezingMemClient is injectable for tests; production uses breezingmem.New().
var breezingMemClient breezingMemRecorder = breezingmem.New()

// runWorkTeam handles `harness work --team <taskID...>`: fan out N independent
// backend sub-runs through breezing.Orchestrator (the harness owns the fan-out;
// each sub-run is single-threaded), collecting a companion-result.v1 per task.
//
// Invocation shape:
//
//	harness work --team [--backend codex|cursor] t1 t2 t3 ...
//
// One companion-result.v1 JSON line is emitted to stdout per task. Exit code is
// 1 if any task failed (so a caller can gate on the team outcome), else 0.
func runWorkTeam(args []string) {
	if isHelpFlag(args) {
		fmt.Println("Usage: harness work --team [--backend codex|cursor] <taskID...>  — fan out N backend sub-runs, emit one companion-result.v1 per task")
		os.Exit(0)
	}

	backend, tasks, err := parseTeamArgs(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "harness work --team: %v\n", err)
		os.Exit(1)
	}
	if len(tasks) == 0 {
		fmt.Fprintln(os.Stderr, "harness work --team: no task IDs given")
		os.Exit(1)
	}

	results, err := runTeam(tasks, backend, teamMaxParallel())
	if err != nil {
		fmt.Fprintf(os.Stderr, "harness work --team: %v\n", err)
		os.Exit(1)
	}

	anyFailed := false
	for _, r := range results {
		line, mErr := r.Marshal()
		if mErr != nil {
			fmt.Fprintf(os.Stderr, "harness work --team: marshal %s: %v\n", r.TaskID, mErr)
			os.Exit(1)
		}
		fmt.Println(string(line))
		if !r.Success {
			anyFailed = true
		}
	}

	if anyFailed {
		os.Exit(1)
	}
	os.Exit(0)
}

// parseTeamArgs extracts the backend and the task ID list from the args that
// follow `harness work`. It expects `--team` to be present (the caller in
// runWork already detected it, but we tolerate it appearing anywhere) and an
// optional `--backend codex|cursor` (default "codex"). Everything else is a
// task ID. Unknown flags are rejected so typos don't silently become task IDs.
func parseTeamArgs(args []string) (backend string, tasks []string, err error) {
	backend = "codex"
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--team":
			// marker only; consumed here so it never lands in tasks.
		case a == "--backend":
			if i+1 >= len(args) {
				return "", nil, fmt.Errorf("--backend requires a value (codex|cursor)")
			}
			i++
			backend = args[i]
		case strings.HasPrefix(a, "--backend="):
			backend = strings.TrimPrefix(a, "--backend=")
		case strings.HasPrefix(a, "-"):
			return "", nil, fmt.Errorf("unknown flag %q", a)
		default:
			tasks = append(tasks, a)
		}
	}
	if backend != "codex" && backend != "cursor" {
		return "", nil, fmt.Errorf("unsupported backend %q (want codex|cursor)", backend)
	}
	return backend, tasks, nil
}

// teamMaxParallel reads the fan-out width from HARNESS_TEAM_MAX_PARALLEL,
// falling back to the Orchestrator's own default (3) when unset or invalid.
// Returning 0 lets WithMaxParallel keep its default.
func teamMaxParallel() int {
	if v := strings.TrimSpace(os.Getenv("HARNESS_TEAM_MAX_PARALLEL")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 0
}

// resultCarrierPrefix tags the marshaled companion-result.v1 that the worker
// stashes in TaskResult.CommitHash, so runTeam can recover the full envelope
// from the Orchestrator's result shape without widening breezing's types.
const resultCarrierPrefix = "companion-result.v1:"

// teamSubLeadPlanner builds the lane mini-plan planner. Tests inject a fake;
// production uses the headless CLI planner.
var teamSubLeadPlanner = func() sublead.Planner {
	return sublead.NewHeadlessCLIPlanner(productionCommandRunner())
}

// teamSubWorkerFactory builds the per-subtask worker used inside Sub-Lead.
// Tests may replace it; production delegates to productionCompanionWorker.
var teamSubWorkerFactory = productionCompanionWorker

// reviewIterateRunner is the review→iterate loop entry point. Tests replace it.
var reviewIterateRunner = func(ctx context.Context, cfg reviewiterate.Config, initial companionresult.Result) (reviewiterate.Outcome, error) {
	return reviewiterate.Run(ctx, cfg, initial)
}

// teamWorkerFactory builds the per-task worker. The production factory drives
// the backend companion (flat) or a Sub-Lead hierarchy when
// HARNESS_TEAM_HIERARCHY=sublead; tests inject fakes that do not shell out.
// When HARNESS_REVIEW_ITERATE=on the inner worker is wrapped with the
// cross-CLI fresh-context review→iterate loop (brain-only verdict, N-iter
// escalation).
var teamWorkerFactory = func(backend string) breezing.WorkerFunc {
	var worker breezing.WorkerFunc
	if teamHierarchySubLead() {
		worker = sublead.NewSubLeadWorker(
			teamSubLeadPlanner(),
			teamSubWorkerFactory(backend),
			backend,
			teamMaxParallel(),
		)
	} else {
		worker = productionCompanionWorker(backend)
	}
	return wrapWorkerWithReviewIterate(worker, backend)
}

// reviewIterateEnabled reports whether the review→iterate loop wraps workers.
func reviewIterateEnabled() bool {
	return strings.TrimSpace(os.Getenv("HARNESS_REVIEW_ITERATE")) == "on"
}

// teamHierarchySubLead reports whether the Sub-Lead producer hierarchy is active.
func teamHierarchySubLead() bool {
	return strings.TrimSpace(os.Getenv("HARNESS_TEAM_HIERARCHY")) == "sublead"
}

// productionCommandRunner shells out for the headless CLI planner.
func productionCommandRunner() sublead.CommandRunner {
	return func(ctx context.Context, name string, args []string, stdin string) (string, int, error) {
		cmd := exec.CommandContext(ctx, name, args...)
		cmd.Dir = resolveRepoRoot()
		if stdin != "" {
			cmd.Stdin = strings.NewReader(stdin)
		}
		var stdout, stderr strings.Builder
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		err := cmd.Run()
		exitCode := 0
		if err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				exitCode = ee.ExitCode()
				err = nil
			}
		}
		return stdout.String(), exitCode, err
	}
}

// runTeam is the testable orchestration core. It drives breezing.Orchestrator
// across the given task IDs using teamWorkerFactory(backend), then maps each
// Orchestrator TaskResult back into its companion-result.v1, preserving input
// order. This is the production (non-test-internal) caller that proves the
// Orchestrator fans out N independent sub-runs.
func runTeam(tasks []string, backend string, maxParallel int) ([]companionresult.Result, error) {
	recordTeamAutoApproveLedger(backend)

	if payload, err := json.Marshal(map[string]any{
		"backend":    backend,
		"task_count": len(tasks),
	}); err == nil {
		recordBreezingMemEvent(breezingmem.EventRunStarted, string(payload))
	}

	worker := teamWorkerFactory(backend)

	o := breezing.NewOrchestrator(worker, breezing.WithMaxParallel(maxParallel))
	for _, id := range tasks {
		o.AddTask(&breezing.Task{ID: id, AgentType: "worker"})
	}

	if _, err := o.Run(context.Background()); err != nil {
		return nil, err
	}

	// Recover one companion-result.v1 per task from the Orchestrator's results,
	// keyed by task ID, and return them in the caller's input order.
	byID := o.Results()
	out := make([]companionresult.Result, 0, len(tasks))
	for _, id := range tasks {
		tr, ok := byID[id]
		if !ok {
			// The Orchestrator always records a result per dispatched task; a
			// miss means the task never ran. Surface a failed envelope rather
			// than dropping it, so the count stays N.
			r := companionresult.New(backend, id)
			r.Summary = "no result recorded by orchestrator"
			out = append(out, r)
			continue
		}
		r := applyFloorGate(resultFromTaskResult(backend, id, tr))
		recordBreezingMemWorkerResult(id, r)
		out = append(out, r)
	}

	failed := 0
	for _, r := range out {
		if !r.Success {
			failed++
		}
	}
	if payload, err := json.Marshal(map[string]any{
		"task_count": len(out),
		"failed":     failed,
	}); err == nil {
		recordBreezingMemEvent(breezingmem.EventAggregationDone, string(payload))
	}

	return out, nil
}

// recordTeamAutoApproveLedger writes one team-dispatch ledger line for the
// auto-approve fail-safe decision before any companion is spawned.
func recordTeamAutoApproveLedger(backend string) {
	start := time.Now()
	repoRoot := resolveRepoRoot()
	enabled, reason := autoapprove.AutoApproveEnabled(repoRoot)
	exit := 0
	emitTeamDispatchLedger(orchestrationledger.TeamDispatchOpts{
		Backend:    backend,
		Write:      true,
		ExitCode:   &exit,
		DurationMs: time.Since(start).Milliseconds(),
		Reason:     reason,
		Enabled:    enabled,
		RepoRoot:   repoRoot,
	})
}

// resolveWorktreeRoot returns the absolute Harness-managed worktree path for taskID.
func resolveWorktreeRoot(taskID string) string {
	return breezing.ManagerWorktreePath(resolveRepoRoot(), taskID)
}

// applyFloorGate runs the FLOOR pre-merge backstop over a successful sub-run's
// reported changes and downgrades the result to FAILED if the gate does not
// pass. A sub-run that already failed at the companion level is returned
// untouched: the FLOOR only ever turns a success into a failure (it cannot
// rescue a failed run), so an honest take-in never reports success for changes
// that did not clear the gate. The gate detail is folded into Summary so the
// emitted companion-result.v1 explains the downgrade.
func applyFloorGate(r companionresult.Result) companionresult.Result {
	if !r.Success {
		return r
	}
	report := floorGate(resolveRepoRoot(), r.FilesChanged, nil)
	if report.Passed {
		return r
	}

	r.Success = false
	if r.ExitCode == 0 {
		// Distinguish a FLOOR rejection from a companion exit code.
		r.ExitCode = 1
	}
	r.Summary = strings.TrimSpace(r.Summary + " | FLOOR gate failed: " + floorFailureDetail(report))
	return r
}

// floorFailureDetail summarizes the failing FLOOR steps for the result Summary.
func floorFailureDetail(report floor.Report) string {
	var failed []string
	for _, s := range report.Steps {
		if !s.Passed {
			failed = append(failed, s.Name+" ("+s.Detail+")")
		}
	}
	if len(failed) == 0 {
		return "unknown step"
	}
	return strings.Join(failed, "; ")
}

// resultFromTaskResult reconstructs the companion-result.v1 carried in a
// breezing.TaskResult. The worker stores the marshaled envelope in CommitHash
// (tagged with resultCarrierPrefix); if that is missing or unparsable, fall
// back to a best-effort envelope derived from the TaskResult's Err/Duration so
// a caller always gets a well-formed result.
func resultFromTaskResult(backend, taskID string, tr breezing.TaskResult) companionresult.Result {
	if payload, ok := strings.CutPrefix(tr.CommitHash, resultCarrierPrefix); ok {
		if r, err := companionresult.Parse([]byte(payload)); err == nil {
			return r
		}
	}

	// Fallback: synthesize from the bare TaskResult fields.
	r := companionresult.New(backend, taskID)
	r.DurationMs = tr.Duration.Milliseconds()
	if tr.Err != nil {
		r.Success = false
		r.ExitCode = 1
		r.Summary = tr.Err.Error()
	} else {
		r.Success = true
		r.ExitCode = 0
	}
	return r
}

// carryResult packs a companion-result.v1 into a breezing.TaskResult so the
// Orchestrator (which knows nothing about companion-result.v1) can ferry it
// back to runTeam. Success/Err are also set on the TaskResult so the
// Orchestrator's own pending/failed bookkeeping stays accurate.
func carryResult(r companionresult.Result) breezing.TaskResult {
	tr := breezing.TaskResult{
		TaskID:     r.TaskID,
		CommitHash: resultCarrierPrefix + mustMarshal(r),
	}
	if !r.Success {
		tr.Err = fmt.Errorf("backend %s task %s failed (exit %d)", r.Backend, r.TaskID, r.ExitCode)
	}
	return tr
}

// mustMarshal renders r to JSON, returning "" on the (practically impossible)
// marshal error so the carrier degrades to the TaskResult fallback path.
func mustMarshal(r companionresult.Result) string {
	b, err := r.Marshal()
	if err != nil {
		return ""
	}
	return string(b)
}

// productionCompanionWorker returns a WorkerFunc that drives the backend
// companion for one task and wraps its (exitCode, stdout, stderr, duration)
// via companionresult.Normalize. If the companion script cannot be resolved,
// it returns a FAILED companion-result.v1 instead of crashing.
func productionCompanionWorker(backend string) breezing.WorkerFunc {
	return func(ctx context.Context, task *breezing.Task) breezing.TaskResult {
		script := resolveCompanionScript(backend)
		if script == "" {
			r := companionresult.New(backend, task.ID)
			r.Success = false
			r.ExitCode = 127
			r.Summary = fmt.Sprintf("%s companion script not found (scripts/%s-companion.sh)", backend, backend)
			recordCompanionResultLedger(backend, task.ID, r)
			return carryResult(r)
		}

		// Each sub-run is single-threaded: one companion invocation per task.
		// SubLead instructions and review refinements may not exist in Plans.md.
		// Preserve that task body in the same prompt checked by the runtime floor.
		prompt := fmt.Sprintf("Work task %s.", task.ID)
		if strings.TrimSpace(task.Description) != "" {
			prompt += "\n\nTask instructions:\n" + task.Description
		}

		// Pre-dispatch runtime floor check on the prompt + script invocation surface.
		floorStart := time.Now()
		floorCmd := fmt.Sprintf("bash %s task --write %s", script, prompt)
		floorCtx := runtimefloor.Context{WorktreeRoot: resolveWorktreeRoot(task.ID)}
		if decision := runtimeFloorCheck(floorCmd, floorCtx); decision.Stopped {
			reason := fmt.Sprintf("RUNTIME_FLOOR:%s: %s", decision.Category, decision.Reason)
			exit := 2
			emitTeamDispatchLedger(orchestrationledger.TeamDispatchOpts{
				Backend:    backend,
				Write:      true,
				ExitCode:   &exit,
				DurationMs: time.Since(floorStart).Milliseconds(),
				Reason:     reason,
				Enabled:    true,
				RepoRoot:   resolveRepoRoot(),
			})
			r := companionresult.New(backend, task.ID)
			r.Success = false
			r.ExitCode = 2
			r.Summary = reason
			recordCompanionResultLedger(backend, task.ID, r)
			return carryResult(r)
		}

		cmd := exec.CommandContext(ctx, "bash", script, "task", "--write", prompt)
		cmd.Dir = resolveRepoRoot()

		var stdout, stderr strings.Builder
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		start := time.Now()
		runErr := cmd.Run()
		dur := time.Since(start).Milliseconds()

		exitCode := 0
		if runErr != nil {
			if ee, ok := runErr.(*exec.ExitError); ok {
				exitCode = ee.ExitCode()
			} else {
				// Spawn-level failure (bash missing, etc.): non-zero sentinel.
				exitCode = 1
				if stderr.Len() == 0 {
					stderr.WriteString(runErr.Error())
				}
			}
		}

		r := companionresult.Normalize(backend, task.ID, exitCode, stdout.String(), stderr.String(), dur)
		recordCompanionResultLedger(backend, task.ID, r)
		return carryResult(r)
	}
}

// recordCompanionResultLedger appends one companion-result orchestration line.
func recordCompanionResultLedger(backend, taskID string, r companionresult.Result) {
	exit := r.ExitCode
	emitCompanionResultLedger(orchestrationledger.CompanionResultOpts{
		Backend:    backend,
		TaskID:     taskID,
		Write:      true,
		ExitCode:   &exit,
		DurationMs: r.DurationMs,
		Success:    r.Success,
		RepoRoot:   resolveRepoRoot(),
	})
}

func breezingMemSessionID() string {
	for _, key := range []string{
		"HARNESS_BREEZING_SESSION_ID",
		"BREEZING_SESSION_ID",
		"CLAUDE_SESSION_ID",
	} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			return v
		}
	}
	return "local"
}

func recordBreezingMemEvent(eventType, content string) {
	breezingMemClient.RecordEvent(
		context.Background(),
		eventType,
		resolveRepoRoot(),
		breezingMemSessionID(),
		content,
	)
}

func recordBreezingMemWorkerResult(taskID string, r companionresult.Result) {
	payload, err := json.Marshal(map[string]any{
		"task_id":   taskID,
		"success":   r.Success,
		"exit_code": r.ExitCode,
	})
	if err != nil {
		return
	}
	recordBreezingMemEvent(breezingmem.EventWorkerResult, string(payload))
}

// resolveCompanionScript finds scripts/<backend>-companion.sh, mirroring the
// repo-root resolution used elsewhere: relative to the running binary
// (<root>/bin/harness -> <root>/scripts/...), then under the resolved repo
// root, then CLAUDE_PLUGIN_ROOT. Returns "" if not found.
func resolveCompanionScript(backend string) string {
	name := backend + "-companion.sh"
	candidates := []string{}

	if exe, err := os.Executable(); err == nil {
		root := filepath.Dir(filepath.Dir(exe)) // <root>/bin/harness -> <root>
		candidates = append(candidates, filepath.Join(root, "scripts", name))
	}
	candidates = append(candidates, filepath.Join(resolveRepoRoot(), "scripts", name))
	if pr := os.Getenv("CLAUDE_PLUGIN_ROOT"); pr != "" {
		candidates = append(candidates, filepath.Join(pr, "scripts", name))
	}

	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && !info.IsDir() {
			return c
		}
	}
	return ""
}
