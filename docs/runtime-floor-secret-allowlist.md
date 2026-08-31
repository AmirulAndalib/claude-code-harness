# Runtime Floor Secret-Read Allowlist

The Runtime Floor treats secret reads the same way it treats network egress:
explicit allowlist first, default deny. The egress side uses `isAllowlistedHost`
to require named hosts before outbound calls; the secret-read side requires named
project-local paths before a pipeline may read files that contain credentials,
tokens, keys, or other operator-provided secrets.

## Contract

- Project config should declare only the specific project-local file paths a run
  needs. `HARNESS_RUNTIME_FLOOR_SECRET_ALLOW` additionally accepts
  comma-separated path prefixes for operator-managed work roots.
- Empty strings, `*`, `**`, `/`, `~`, and `~/` are invalid. Treat any all-open style
  declaration as deny, not as a wildcard.
- The effective allowlist is the union of:
  - `HARNESS_RUNTIME_FLOOR_SECRET_ALLOW`
  - `.claude-code-harness.config.json` `runtimefloor.secretAllow`
- If project config is missing, unreadable, malformed, or `runtimefloor.secretAllow`
  is not a string array, the config contribution is fail-safe empty. Secret reads
  remain denied unless the environment declaration provides a valid path.
- Project-config relative paths resolve under the project root.
  Project-config absolute paths outside the project root are invalid and
  ignored. Environment entries are lexical prefixes or globs and may name an
  operator-managed root outside the current project.

## Operator Flow

Before starting work, list the secret files the task will need and declare them
once in project config or in the environment. After that, the run should not stop
mid-task for repeated secret-read approvals, because the Runtime Floor can decide
from the predeclared contract.

Use project config when the same pipeline needs the same secret files across
runs:

```json
{
  "$schema": "./claude-code-harness.config.schema.json",
  "runtimefloor": {
    "secretAllow": [
      ".env.local",
      "secrets/pipeline.key"
    ]
  }
}
```

Use the environment for one-off CI or local runs. Separate multiple paths with
commas:

```bash
export HARNESS_RUNTIME_FLOOR_SECRET_ALLOW=".env.local,secrets/pipeline.key"
```

The two sources are additive. For example, if project config declares
`.env.local` and CI exports `secrets/pipeline.key`, both paths are allowed for
that run.

When adding a new work root, add that root as one comma-separated prefix in
`HARNESS_RUNTIME_FLOOR_SECRET_ALLOW`. Keep the trailing path separator so a
similarly named sibling does not match by prefix:

```bash
export HARNESS_RUNTIME_FLOOR_SECRET_ALLOW="/Users/alice/orca/workspaces/,/Users/alice/new-worktrees/"
```

The environment match expands a leading `~/` on both the command token and the
declaration (process home directory) before prefix comparison. Absolute and
`~/` spellings of the same named root therefore match. That does not add
undeclared paths. `$HOME` and `~user` are not expanded. Home resolution
failure keeps the lexical form (fail-closed). This declaration cannot disable
the category: `*`, `**`, `/`, `~`, and `~/` are discarded.

A `cat` that only writes a file (`cat > out`, `cat >> out`, `cat > out <<EOF`,
with no positional input and no stdin `<`) is not a secret-read. `cat FILE`,
`cat FILE > out`, `cat FILE>/out`, `cat > out FILE`, and `cat < FILE` still
deny when FILE is a secret path.

## Pipeline Example

Declare the secrets before invoking the pipeline:

```bash
export HARNESS_RUNTIME_FLOOR_SECRET_ALLOW="secrets/deploy-token,config/private.env"
bash scripts/pipeline/deploy-preview.sh
```

Inside the pipeline, keep the read path identical to the declaration:

```bash
DEPLOY_TOKEN="$(cat secrets/deploy-token)"
set -a
. config/private.env
set +a
```

Prefer project-relative paths for project config. For the environment variable,
use a narrow file path or a trailing-separator work-root prefix. An absolute path
outside the project is valid only through the environment source.

## Bad Declarations

These examples must not grant access:

```bash
export HARNESS_RUNTIME_FLOOR_SECRET_ALLOW=""
export HARNESS_RUNTIME_FLOOR_SECRET_ALLOW="*"
export HARNESS_RUNTIME_FLOOR_SECRET_ALLOW="/"
```

```json
{
  "runtimefloor": {
    "secretAllow": ["*", "/Users/alice/.ssh/id_rsa"]
  }
}
```

The shell examples are all-open or empty declarations. The JSON example
combines a bare wildcard with an absolute path outside the project. Both JSON
entries are invalid, so the effective project-config contribution is empty.

## R04: Writes Outside the Project

R04 (`R04:confirm-write-outside-project`) skips confirmation for three
categories of external path:

- **OS-managed scratch roots**: `/tmp`, `/var/tmp`, `/private/tmp`,
  `/private/var/tmp`, `$TMPDIR`, `~/.cache`, and `~/Library/Caches`
  (`shellscan.IsAllowlistedTempPath`).
- **Claude-Code-managed agent state** (`shellscan.IsAgentStatePath`):
  `~/.claude/projects/<slug>/memory/**` and `~/.claude/plans/**`. These hold
  data the agent is expected to write during normal operation, and `<slug>`
  matches any single segment because the memory slug is not derivable from
  `ProjectRoot`. Everything else under `~/.claude` stays confirmable — in
  particular `settings*`, `skills/`, `agents/`, `commands/`, `hooks/`,
  `plugins/`, and `output-styles/`, which change *behavior* rather than
  storing data.
- **Everything outside the project, when `WorkMode` is on.**

Other external paths still ask.

R04 resolves symlinks before classifying a scratch or agent-state path. If the
final file does not exist, it resolves the nearest existing ancestor and appends
the missing suffix. A scratch-path symlink that resolves outside the scratch
roots does not receive the skip. Resolution errors retain the `ask` result.

### `WorkMode` wiring (fixed 2026-08-11, Plans.md 132.7)

`WorkMode` is set from the `HARNESS_WORK_MODE` / `ULTRAWORK_MODE` environment
variables, or from the `work_states` row matching the session ID. Historical
note: as of 2026-08-10 neither source was ever populated — no skill, script,
or hook set those variables, and `state.SetWorkState` had no call site outside
its own package. The skip path existed but was unreachable in a normal `/work`
or `/breezing` run, which is why those runs kept stopping on R04
confirmations — 1,099 firings measured across 3,099 session logs, of which 299
were the agent writing to its own memory directory.

The wiring now works end to end: the SessionStart hook exports the real
session id as `HARNESS_SESSION_ID` via `CLAUDE_ENV_FILE`
(`internal/event/session_env.go`), `harness work-mode on/off` writes the
`work_states` row under that id (fallbacks: `--session-id` flag, then a fresh
`.claude/state/last-session-id.json` written on every UserPromptSubmit), and
the guardrail looks the row up by the hook payload's session id — the same
value. The legacy `.claude/state/session.json` id is rejected: it never
matches the hook's id. SessionEnd clears the row; a 24h TTL is the backstop.

An operator can still set `HARNESS_WORK_MODE=1` in the `env` block of
`~/.claude/settings.json` as a manual override. That turns the skip on for
*every* session, not just work runs, so it also removes the cross-repository
write confirmation in interactive sessions — with the wiring fixed, prefer
removing it once the fixed binary is deployed. Destructive deletion is
unaffected: R05 and the
protected-path deny tier still block `rm -rf` outside the worktree.

R02 and R03 run before R04. Their protected-path decisions remain in force even
when R04 would skip an OS scratch path or `WorkMode` would skip an external-path
confirmation.

## R05: Recursive Deletion Inside the Worktree

R05 (`R05:confirm-rm-rf`) uses the same dangerous-removal detector and target
extractor as the Runtime Floor. Outside `WorkMode`, R05 skips confirmation only
when every extracted target resolves inside `ProjectRoot`, which is the task
worktree. Both the target and project root are resolved through symlinks before
comparison. For a target that does not exist, R05 resolves the nearest existing
ancestor and then appends the missing suffix. The shared `find` target extractor
recognizes GNU global options and combined BSD `-E`, `-H`, `-L`, `-P`, `-X`,
`-d`, `-s`, and `-x`. A combined option containing `-L` retains `ask`. A BSD
`-f path`, `-fpath`, or combined `-Efpath` argument is collected as a search
root rather than discarded as an option value.

R05 retains `ask` when no target can be extracted, a target requires shell
expansion or can be appended by `xargs` or `parallel`, a relative target follows
a directory-changing command, a raw target contains a `..` component, the
project root is empty, symlink resolution fails, any resolved target is outside
the worktree, or `find` may follow descendant symlinks or read roots through
`-files0-from`. Dynamic command names and backtick command substitution also
retain `ask`. A removal nested in a general-purpose interpreter also retains
`ask`. R05 also retains `ask` when a non-removal shell segment precedes a
dangerous removal or an unknown launcher precedes `rm` or `find`. Such a segment
could replace a missing target ancestor with an external symlink after policy
evaluation but before deletion. Pipelines and background execution retain `ask`
because their concurrent segments can create the same race. Process substitution
through `<(` or `>(` is treated the same way. An executable path such as
`/custom/rm` and an environment assignment before the removal program are
indeterminate because they can replace or inject into the expected program.
File-descriptor duplication such as `2>&1` is parsed as redirection, not
background execution. Commands launched by `find -exec`, `-execdir`, `-ok`, or
`-okdir` receive the same executable-path, launcher, and environment checks.
These actions may launch a validated bare `rm`; nested `find` removal retains
`ask` because its roots are not part of the outer target extraction.
These execution-context checks use the same shell tokenizer as target
extraction, so line continuations, quoting, and escape concatenation cannot
change the command name seen by R05. A worktree-local symlink to an external
directory therefore does not receive the skip.

### `destructive_delete=warn` (HOTL; the default since v5.11.0)

Every `ask` listed above exists because the static analysis cannot *prove* the
target is agent-owned, not because the target is known to be dangerous. In
practice the operator answers those prompts with "yes" without being able to
evaluate the symlink scenario either. `destructive_delete = warn`
(`.claude-code-harness.config.yaml` `safety.destructive_delete`, `harness.toml`
`[safety.permissions] destructiveDelete`, or the env override
`HARNESS_DESTRUCTIVE_DELETE_POLICY`) replaces that prompt with the agent's own
judgement plus a review trail:

- Targets whose *spelling* is relative, under the project root, or inside this
  session's scratch are approved with an `R05_WARN` system message, and the
  command is appended to `.claude/state/destructive-delete.jsonl`
  (`timestamp`, `session_id`, `agent_id`, `cwd`, `command`, `policy`, `rule_id`).
- Targets spelled outside the project root, containing `..`, an unresolved
  `$VAR`, a glob, or the bare `.` / `/` still `ask` (the blast-radius backstop
  of the HOTL contract, `spec.md` invariant 3). The Runtime Floor deny for
  out-of-worktree deletion is unchanged and runs before R05.
- The 133.10 residual (a preceding segment planting a symlink so an in-root
  spelling resolves outside the worktree) is accepted knowingly under `warn`;
  the record is what makes it reviewable afterwards. Since v5.11.0 `warn` is
  the product default (operator decision 2026-08-22); repos that keep
  unrecoverable non-git data under the project root, or sessions developing
  the guardrails themselves, opt back out with `destructive_delete = ask`.
- `WorkMode` continues to skip R05 entirely; `warn` only matters outside a run.

### `destructive_delete=defer` (unattended runs; Phase 140.1)

`defer` is a superset of `warn`. Everything `warn` approves, `defer` approves
the same way (same `R05_WARN` message, same `destructive-delete.jsonl` record).
The difference is what happens where `warn` would still `ask`:

- R05 returns **deny** instead of `ask`. A deny does not stall the run: the
  agent receives the reason and continues; only `ask` blocks on a human.
- The reason starts with `R05_DEFER:` and carries the behavioural contract the
  agent is expected to follow: the operation is queued, do not retry or rewrite
  it into another deletion, continue with the remaining tasks, report the
  deferred-ops list at the end of the run.
- The guardrail layer appends one line to `.claude/state/deferred-ops.jsonl`
  (`id`, `timestamp`, `session_id`, `agent_id`, `cwd`, `command`, `rule_id`,
  `policy`, `reason`, `status: pending`). `id` is the first 12 hex characters of
  `sha256(rule_id \0 cwd \0 command)`, so a retry of the same command in the same
  cwd finds its pending entry and is not queued twice while still being denied.
- Without a resolvable project root there is nowhere to queue, so the rule
  falls back to `ask` exactly like `warn` does.
- Approval of a queued entry is the 140.2 CLI: `bin/harness deferred list`
  shows pending entries with a copy-paste approve command, and
  `bin/harness deferred approve <id>` flips the single pending line with that
  id to `approved`. The **next identical run** (same rule, cwd and command) is
  then allowed exactly once: the guardrail consumes the approval
  (`approved → consumed`, one-shot, same consume shape as plan preapproval),
  injects an `R05_DEFER_APPROVED` message and records the execution in
  `destructive-delete.jsonl` with `policy: defer`. After that the same command
  denies and re-queues again. There is no "approve all" and no auto-approval
  path. The progress surface lists pending entries with the approve command
  (`deferred_ops_pending`, additive, Phase 140.2). Like the warn approval, the
  consumed approval is advisory: a later deny rule in the same compound command
  still wins (and spends the approval — accepted, same trade-off as plan
  preapproval).

`WorkMode` retains its existing
R05 bypass. Destruction outside the task worktree remains a hard deny in the
Runtime Floor, which runs before the policy rules and does not depend on
`WorkMode`.

Worktree-local approval is not a recovery guarantee. A linked worktree stores
its `.git` entry as a pointer to metadata in the main repository, so committed
objects and the staged index snapshot remain outside the deleted working tree.
Unstaged changes and untracked files, including generated artifacts and
in-progress files, have no recoverable Git copy and can be lost permanently.
