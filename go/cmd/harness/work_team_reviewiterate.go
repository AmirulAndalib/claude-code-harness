package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync/atomic"

	"github.com/Chachamaru127/claude-code-harness/go/internal/breezing"
	"github.com/Chachamaru127/claude-code-harness/go/internal/companionresult"
	"github.com/Chachamaru127/claude-code-harness/go/internal/reviewiterate"
)

// reviewIterateConfigBuilder builds production reviewiterate.Config. Tests may replace.
var reviewIterateConfigBuilder = defaultReviewIterateConfig

func defaultReviewIterateConfig(backend string, worker breezing.WorkerFunc, taskInstructions string) reviewiterate.Config {
	lenses := []string{"correctness", "security", "scope"}
	reviewers := make([]reviewiterate.Reviewer, len(lenses))
	repoRoot := resolveRepoRoot()
	runner := reviewiterate.ScriptRunnerInDir(repoRoot)
	reviewerBackend, err := reviewiterate.ResolveReviewerBackend(
		context.Background(),
		repoRoot,
		runner,
	)
	if err != nil {
		reviewerBackend = "cursor"
	}
	reviewerScript := resolveCompanionScript(reviewerBackend)
	for i, lens := range lenses {
		lens := lens
		if reviewerScript == "" {
			reviewers[i] = func(_ context.Context, lensName, _ string) (reviewiterate.Review, error) {
				return reviewiterate.Review{Lens: lensName}, nil
			}
			continue
		}
		h := reviewiterate.HeadlessCLIReviewer{
			Runner:           runner,
			CompanionScript:  reviewerScript,
			TaskInstructions: taskInstructions,
			Lens:             lens,
			SessionIDGen:     freshReviewSessionID,
		}
		reviewers[i] = reviewiterate.NewHeadlessCLIReviewerFunc(h)
	}

	brainScript := resolveCompanionScript("claude")
	var brain reviewiterate.BrainVerdict
	if brainScript == "" {
		brain = func(_ context.Context, _ string, _ []reviewiterate.Review) (reviewiterate.Verdict, error) {
			return "", fmt.Errorf("reviewiterate: claude brain companion script not found")
		}
	} else {
		b := reviewiterate.HeadlessCLIBrain{
			Runner:           runner,
			CompanionScript:  brainScript,
			TaskInstructions: taskInstructions,
		}
		brain = reviewiterate.NewHeadlessCLIBrainFunc(b)
	}

	return reviewiterate.Config{
		Lenses:     lenses,
		Reviewers:  reviewers,
		Brain:      brain,
		MaxIters:   reviewIterateMaxIters(),
		WorkerFunc: worker,
	}
}

func reviewIterateMaxIters() int {
	const defaultMax = 3
	if v := strings.TrimSpace(os.Getenv("HARNESS_REVIEW_ITERATE_MAX")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return defaultMax
}

var freshReviewSessionCounter atomic.Uint64

func freshReviewSessionID(lens string) string {
	return fmt.Sprintf("%s-%d", lens, freshReviewSessionCounter.Add(1))
}

// wrapWorkerWithReviewIterate wraps a worker with the review→iterate loop when
// HARNESS_REVIEW_ITERATE=on (default OFF).
func wrapWorkerWithReviewIterate(inner breezing.WorkerFunc, backend string) breezing.WorkerFunc {
	if !reviewIterateEnabled() {
		return inner
	}
	return func(ctx context.Context, task *breezing.Task) breezing.TaskResult {
		originalInstructions := task.Description
		tr := inner(ctx, task)
		initial := resultFromTaskResult(backend, task.ID, tr)

		refinementWorker := func(ctx context.Context, refinement *breezing.Task) breezing.TaskResult {
			copy := *refinement
			if strings.TrimSpace(originalInstructions) != "" {
				copy.Description = "Original task instructions:\n" + originalInstructions +
					"\n\nReview feedback to evaluate within the original scope:\n" + refinement.Description
			}
			return inner(ctx, &copy)
		}
		taskInstructions := fmt.Sprintf("Task %s.\n%s", task.ID, originalInstructions)
		cfg := reviewIterateConfigBuilder(backend, refinementWorker, taskInstructions)
		outcome, err := reviewIterateRunner(ctx, cfg, initial)
		if err != nil {
			r := companionresult.New(backend, task.ID)
			r.Success = false
			r.ExitCode = 1
			r.Summary = fmt.Sprintf("reviewiterate: %v", err)
			return carryResult(r)
		}

		final := outcome.FinalResult
		if final.TaskID == "" {
			final = initial
		}
		if outcome.Escalated {
			final.Success = false
			if final.ExitCode == 0 {
				final.ExitCode = 1
			}
			final.Summary = strings.TrimSpace(final.Summary + " | " + outcome.EscalationNote)
			return carryResult(final)
		}
		switch outcome.Verdict {
		case reviewiterate.VerdictApprove:
			final.Success = true
			final.ExitCode = 0
		case reviewiterate.VerdictRequestChanges:
			final.Success = false
			if final.ExitCode == 0 {
				final.ExitCode = 1
			}
		}
		return carryResult(final)
	}
}
