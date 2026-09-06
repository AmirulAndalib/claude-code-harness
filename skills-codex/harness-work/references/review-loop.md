# Codex Review Loop

Codex review follows the same verdict contract as Claude-side `harness-work`.

Pass the original request and why, owned scope, authorization source, selected
plan/spec/contract paths, DoD, actual target diff, and validation evidence to a
fresh read-only reviewer. Recover missing evidence through allowed reads first.
Report locations, failure conditions, concise reasons, and unverified items;
the worker's self-report is not proof.

## Order

1. Run companion structured review when available.
2. Run AI Residuals JSON scan:

```bash
bash "${HARNESS_PLUGIN_ROOT}/scripts/review-ai-residuals.sh" --base-ref "${BASE_REF}" --include-untracked
```

3. Fall back to a read-only reviewer agent only when companion review is not
   available.

## Verdict Threshold

`critical` or `major` means `REQUEST_CHANGES`. `minor` and `recommendation` do
not affect approval.

## Worker Repair

When a spawned Worker needs changes, resume it and use `send_input` with the
critical/major findings only. Then wait again and rerun review.
Preserve the original task constraints and DoD in that follow-up. Use fresh
review context for the updated diff and keep the contract's iteration limit.
Stop when DoD and required checks pass; repeat or broaden tests only for new
changes, evidence, or unresolved concerns.
