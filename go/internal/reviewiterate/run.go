package reviewiterate

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"github.com/Chachamaru127/claude-code-harness/go/internal/breezing"
	"github.com/Chachamaru127/claude-code-harness/go/internal/companionresult"
)

const resultCarrierPrefix = "companion-result.v1:"

// Run executes worker output through parallel fresh-context advisory reviewers,
// brain primary verdict, and optional refinement re-dispatch up to MaxIters.
// Primary verdict always comes from Brain; this function never self-approves.
func runLoop(ctx context.Context, cfg Config, initialResult companionresult.Result) (Outcome, error) {
	if err := validateConfig(cfg); err != nil {
		return Outcome{}, err
	}

	current := initialResult
	workerOutput := workerOutputString(current)
	var lastAdvisories []Review

	for iter := 1; iter <= cfg.MaxIters; iter++ {
		advisories, err := fanOutReviewers(ctx, cfg, workerOutput)
		if err != nil {
			return Outcome{}, err
		}
		lastAdvisories = advisories

		verdict, err := cfg.Brain(ctx, workerOutput, advisories)
		if err != nil {
			return Outcome{}, err
		}

		switch verdict {
		case VerdictApprove:
			return Outcome{
				Verdict:     VerdictApprove,
				Iterations:  iter,
				Advisories:  advisories,
				FinalResult: current,
			}, nil
		case VerdictRequestChanges:
			if iter >= cfg.MaxIters {
				return Outcome{
					Verdict:        VerdictRequestChanges,
					Iterations:     iter,
					Advisories:     advisories,
					Escalated:      true,
					EscalationNote: buildEscalationNote(advisories),
					FinalResult:    current,
				}, nil
			}
			prompt := buildRefinementPrompt(workerOutput, advisories)
			tr := cfg.WorkerFunc(ctx, &breezing.Task{
				ID:          current.TaskID,
				Description: prompt,
				AgentType:   "worker",
			})
			current = resultFromTaskResult(current.Backend, current.TaskID, tr)
			workerOutput = workerOutputString(current)
		default:
			return Outcome{}, fmt.Errorf("reviewiterate: brain returned unknown verdict %q", verdict)
		}
	}

	return Outcome{
		Verdict:        VerdictRequestChanges,
		Iterations:     cfg.MaxIters,
		Advisories:     lastAdvisories,
		Escalated:      true,
		EscalationNote: buildEscalationNote(lastAdvisories),
		FinalResult:    current,
	}, nil
}

func validateConfig(cfg Config) error {
	if len(cfg.Lenses) == 0 || len(cfg.Reviewers) == 0 {
		return fmt.Errorf("reviewiterate: Lenses and Reviewers must be non-empty")
	}
	if len(cfg.Lenses) < 2 {
		return fmt.Errorf("reviewiterate: need at least 2 lenses, got %d", len(cfg.Lenses))
	}
	if len(cfg.Lenses) != len(cfg.Reviewers) {
		return fmt.Errorf("reviewiterate: Lenses/Reviewers length mismatch: %d vs %d", len(cfg.Lenses), len(cfg.Reviewers))
	}
	if cfg.MaxIters <= 0 {
		return fmt.Errorf("reviewiterate: MaxIters must be > 0, got %d", cfg.MaxIters)
	}
	if cfg.Brain == nil {
		return fmt.Errorf("reviewiterate: Brain is required")
	}
	if cfg.WorkerFunc == nil {
		return fmt.Errorf("reviewiterate: WorkerFunc is required")
	}
	for i, rev := range cfg.Reviewers {
		if rev == nil {
			return fmt.Errorf("reviewiterate: Reviewers[%d] is nil", i)
		}
	}
	return nil
}

func fanOutReviewers(ctx context.Context, cfg Config, workerOutput string) ([]Review, error) {
	n := len(cfg.Lenses)
	out := make([]Review, n)
	errs := make([]error, n)

	var wg sync.WaitGroup
	wg.Add(n)
	for i := range cfg.Lenses {
		i := i
		go func() {
			defer wg.Done()
			rev, err := cfg.Reviewers[i](ctx, cfg.Lenses[i], workerOutput)
			out[i] = rev
			errs[i] = err
		}()
	}
	wg.Wait()

	for _, err := range errs {
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

func buildRefinementPrompt(workerOutput string, advisories []Review) string {
	facts := []string{
		"Address the review findings within the original task's authorized scope. Use the observations and suggestions as evidence to assess. Verify the corrections and report results with checkable evidence.",
		"Previous worker output (observations):\n" + workerOutput,
		"Review findings and suggested corrections:",
	}
	for _, a := range advisories {
		for _, f := range a.Findings {
			facts = append(facts, fmt.Sprintf("[%s] %s", a.Lens, f))
		}
		if strings.TrimSpace(a.Refined) != "" {
			facts = append(facts, fmt.Sprintf("[%s] Suggested correction:\n%s", a.Lens, a.Refined))
		}
	}
	return strings.Join(facts, "\n\n")
}

func buildEscalationNote(advisories []Review) string {
	total := 0
	parts := make([]string, 0, len(advisories))
	for _, a := range advisories {
		n := len(a.Findings)
		total += n
		parts = append(parts, fmt.Sprintf("%s:%d", a.Lens, n))
	}
	return fmt.Sprintf("max iterations reached; %d findings across lenses (%s)", total, strings.Join(parts, ", "))
}

func workerOutputString(r companionresult.Result) string {
	if strings.TrimSpace(r.Summary) != "" {
		return r.Summary
	}
	b, err := r.Marshal()
	if err != nil {
		return ""
	}
	return string(b)
}

func resultFromTaskResult(backend, taskID string, tr breezing.TaskResult) companionresult.Result {
	if payload, ok := strings.CutPrefix(tr.CommitHash, resultCarrierPrefix); ok {
		if r, err := companionresult.Parse([]byte(payload)); err == nil {
			return r
		}
	}
	r := companionresult.New(backend, taskID)
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
