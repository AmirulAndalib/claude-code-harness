package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/internal/breezing"
	"github.com/Chachamaru127/claude-code-harness/go/internal/reviewiterate"
	"github.com/Chachamaru127/claude-code-harness/go/internal/runtimefloor"
	"github.com/Chachamaru127/claude-code-harness/go/internal/sublead"
)

func setupPromptCaptureCompanion(t *testing.T, backend string) string {
	t.Helper()
	skipIfWindows(t)
	root := setupProductionE2ERoot(t, backend)
	capture := filepath.Join(root, "companion-argv")
	t.Setenv("HARNESS_TEST_COMPANION_ARGV", capture)
	script := `#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >> "$HARNESS_TEST_COMPANION_ARGV"
printf 'Observed worker output: implementation requires review\n'
`
	if err := os.WriteFile(filepath.Join(root, "scripts", backend+"-companion.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return capture
}

func capturedWorkerArgs(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
}

func TestProductionCompanionWorker_PromptDelivery(t *testing.T) {
	for _, backend := range []string{"codex", "cursor", "claude"} {
		t.Run(backend, func(t *testing.T) {
			capture := setupPromptCaptureCompanion(t, backend)
			description := "Objective: preserve Japanese task instructions.\nOwned path: src/owned.go\nConstraint: no deployment.\nDone: tests pass with evidence.\nLiteral: `$(printf unexpanded)`"
			var checkedCommand string
			original := runtimeFloorCheck
			runtimeFloorCheck = func(command string, _ runtimefloor.Context) runtimefloor.Decision {
				checkedCommand = command
				return runtimefloor.Decision{}
			}
			t.Cleanup(func() { runtimeFloorCheck = original })
			worker := productionCompanionWorker(backend)
			result := worker(context.Background(), &breezing.Task{ID: "146.2-child", Description: description})
			if result.Err != nil {
				t.Fatal(result.Err)
			}
			args := capturedWorkerArgs(t, capture)
			if len(args) != 3 || args[0] != "task" || args[1] != "--write" {
				t.Fatalf("companion argv = %q; expected task, --write, one prompt", args)
			}
			for _, want := range []string{"Work task 146.2-child.", description} {
				if !strings.Contains(args[2], want) {
					t.Errorf("companion prompt lost %q: %q", want, args[2])
				}
				if !strings.Contains(checkedCommand, want) {
					t.Errorf("runtime floor did not receive %q", want)
				}
			}
		})
	}
}

func TestProductionCompanionWorker_SubLeadPromptDelivery(t *testing.T) {
	capture := setupPromptCaptureCompanion(t, "codex")
	passingRuntimeFloor(t)
	description := "Implement the lane outcome in src/owned.go; verify the regression; report evidence."
	planner := func(_ context.Context, laneID, laneSpec string) (sublead.MiniPlan, error) {
		if laneSpec != "Original lane objective" {
			t.Errorf("lane spec = %q", laneSpec)
		}
		return sublead.MiniPlan{LaneID: laneID, SubTasks: []sublead.SubTask{{ID: laneID + "-child", Prompt: description}}}, nil
	}
	worker := sublead.NewSubLeadWorker(planner, productionCompanionWorker("codex"), "codex", 1)
	result := worker(context.Background(), &breezing.Task{ID: "146.2-lane", Description: "Original lane objective"})
	if result.Err != nil {
		t.Fatal(result.Err)
	}
	args := capturedWorkerArgs(t, capture)
	if len(args) != 3 || !strings.Contains(args[2], "146.2-lane-child") || !strings.Contains(args[2], description) {
		t.Fatalf("SubLead instructions did not reach companion: %q", args)
	}
}

func TestProductionCompanionWorker_RefinementPromptDelivery(t *testing.T) {
	capture := setupPromptCaptureCompanion(t, "codex")
	passingRuntimeFloor(t)
	t.Setenv("HARNESS_REVIEW_ITERATE", "on")
	originalBuilder := reviewIterateConfigBuilder
	t.Cleanup(func() { reviewIterateConfigBuilder = originalBuilder })
	round := 0
	reviewIterateConfigBuilder = func(_ string, worker breezing.WorkerFunc, _ string) reviewiterate.Config {
		return reviewiterate.Config{
			Lenses: []string{"correctness", "scope"},
			Reviewers: []reviewiterate.Reviewer{
				func(_ context.Context, lens, _ string) (reviewiterate.Review, error) {
					return reviewiterate.Review{Lens: lens, Findings: []string{"Missing boundary test at src/owned.go:12"}, Refined: "Add the empty-input regression without changing the API."}, nil
				},
				func(_ context.Context, lens, _ string) (reviewiterate.Review, error) {
					return reviewiterate.Review{Lens: lens}, nil
				},
			},
			Brain: func(context.Context, string, []reviewiterate.Review) (reviewiterate.Verdict, error) {
				round++
				if round == 1 {
					return reviewiterate.VerdictRequestChanges, nil
				}
				return reviewiterate.VerdictApprove, nil
			},
			MaxIters: 2, WorkerFunc: worker,
		}
	}
	description := "Objective: preserve behavior. Owned path: src/owned.go. Do not deploy. Done: regression test passes."
	worker := wrapWorkerWithReviewIterate(productionCompanionWorker("codex"), "codex")
	result := worker(context.Background(), &breezing.Task{ID: "146.2-refine", Description: description})
	if result.Err != nil {
		t.Fatal(result.Err)
	}
	args := capturedWorkerArgs(t, capture)
	if len(args) != 6 {
		t.Fatalf("expected exactly initial and refinement companion calls, got %q", args)
	}
	for _, want := range []string{"146.2-refine", description, "Missing boundary test at src/owned.go:12", "Add the empty-input regression without changing the API.", "Observed worker output: implementation requires review"} {
		if !strings.Contains(args[5], want) {
			t.Errorf("refinement companion prompt lost %q: %q", want, args[5])
		}
	}
}

func TestReviewIterate_DefaultConfigTaskContextDelivery(t *testing.T) {
	skipIfWindows(t)
	passingRuntimeFloor(t)
	root := setupProductionE2ERoot(t, "codex", "claude")
	captureDir := filepath.Join(root, "review-captures")
	if err := os.Mkdir(captureDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_TEST_REVIEW_CAPTURE_DIR", captureDir)
	t.Setenv("HARNESS_REVIEW_ITERATE", "on")
	t.Setenv("HARNESS_REVIEW_ITERATE_MAX", "1")
	script := `#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$HARNESS_TEST_REVIEW_CAPTURE_DIR/argv-$$"
pwd -P > "$HARNESS_TEST_REVIEW_CAPTURE_DIR/cwd-$$"
if [[ "$0" == *claude-companion.sh ]]; then
  printf '{"verdict":"REQUEST_CHANGES"}\n'
elif [[ "${2:-}" == --write ]]; then
  printf 'Observed implementation output\n'
else
  printf '{"findings":[],"refined":""}\n'
fi
`
	for _, name := range []string{"codex", "claude"} {
		if err := os.WriteFile(filepath.Join(root, "scripts", name+"-companion.sh"), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "scripts", "resolve-impl-backend.sh"), []byte("#!/bin/bash\nprintf codex\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	description := "Objective: preserve the public API. Owned path: src/owned.go. DoD: boundary regression passes. No deployment."
	worker := wrapWorkerWithReviewIterate(productionCompanionWorker("codex"), "codex")
	result := worker(context.Background(), &breezing.Task{ID: "146.2-review-context", Description: description})
	if result.Err == nil {
		t.Fatal("REQUEST_CHANGES at the existing iteration cap must remain unsuccessful")
	}
	files, err := filepath.Glob(filepath.Join(captureDir, "argv-*"))
	if err != nil || len(files) != 5 {
		t.Fatalf("expected worker + three advisories + brain, got %v, %v", files, err)
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		args := capturedWorkerArgs(t, file)
		cwd, err := os.ReadFile(filepath.Join(captureDir, "cwd-"+strings.TrimPrefix(filepath.Base(file), "argv-")))
		if err != nil || strings.TrimSpace(string(cwd)) != realRoot {
			t.Errorf("companion cwd = %q, %v; want resolved worker root %q", cwd, err, realRoot)
		}
		if len(args) == 3 && args[1] == "--write" {
			continue
		}
		if len(args) != 2 || args[0] != "task" {
			t.Fatalf("read-only reviewer argv = %q", args)
		}
		for _, want := range []string{"146.2-review-context", description, "Observed implementation output"} {
			if !strings.Contains(args[1], want) {
				t.Errorf("reviewer/brain prompt lost %q: %q", want, args[1])
			}
		}
	}
}
