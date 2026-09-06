# Codex Execution Modes

Codex `harness-work` uses native Codex tools where Claude Code would use
Agent/Task tool wording.

## Shared Preflight

1. Read `Plans.md`.
2. Stop on old table formats that lack `Task`, `DoD`, `Depends`, or `Status`.
3. Check whether a project spec SSOT exists when product behavior can drift.
   Prefer existing project-level docs, then `docs/spec/00-project-spec.md`.
4. If the task changes product behavior, API, data model, permissions, billing,
   integrations, or tenant boundaries and no stable spec exists, create or
   update the spec before implementation.
5. Skip spec creation only for mechanical work such as typo, formatting,
   dependency bump, docs-only, or behavior-preserving refactor tasks. Record
   the skip reason in the task context or sprint contract.
6. Resolve helper scripts from the Harness plugin root.
7. Keep implementation and review separate.

Recover missing inputs from the selected user request, contracts, and read-only
repo context before asking. State minor assumptions and continue authorized
reversible work. A missing authorization, material specification decision, or
protected operation holds only dependent work. Assessment-only requests stay
read-only.

## Solo

Use the current Codex session for one task. Validate locally and run the normal
review loop before completion.

## Parallel / Breezing

Use Codex native subagents:

- `spawn_agent`
- `send_input`
- `wait_agent`
- `close_agent`

Default Breezing worker count is `max`, meaning the number of ready tasks whose
dependencies are already satisfied. It is not unlimited spawning.
Respect the configured concurrency cap and assign an independently verifiable
outcome with explicit file or responsibility ownership to each Worker. The Lead
continues useful work while they run. Reuse the Worker for related follow-up;
keep independent reviewers fresh and read-only.

## Companion Delegation

Use the companion script only through the resolved plugin root:

```bash
# TASK_PROMPT_FILE contains the complete request described below.
bash "${HARNESS_PLUGIN_ROOT}/scripts/codex-companion.sh" task --write < "$TASK_PROMPT_FILE"
```

For both native and companion dispatch, pass the outcome and why, project and
worktree, owned scope, constraints, selected plan/spec/contract paths, DoD,
required checks, available evidence, and authorized operations with their
source instruction. Preserve reviewer refinements and prior advisor guidance.
The executor chooses the method within those bounds. Stop after DoD and
required checks; extra tests require new changes, evidence, or unresolved
concerns. Return concise reasons with actual results and unverified items;
self-report alone is not proof and private reasoning transcripts are not needed.
