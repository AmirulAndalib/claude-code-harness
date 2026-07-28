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
- Empty strings, `*`, `**`, and `/` are invalid. Treat any all-open style
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

The environment match is lexical. Use the same absolute or `~/` spelling that
the pipeline command uses. This declaration cannot disable the category:
`*`, `**`, and `/` are discarded.

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

R04 (`R04:confirm-write-outside-project`) distinguishes interactive sessions
from autonomous work:

- During `/work` or `/breezing`, `WorkMode` skips R04 confirmation for every
  path outside the project.
- During an interactive session without `WorkMode`, R04 skips only OS-managed
  scratch roots: `/tmp`, `/var/tmp`, `/private/tmp`, `/private/var/tmp`,
  `$TMPDIR`, `~/.cache`, and `~/Library/Caches`. Other external paths still ask.

R04 resolves symlinks before classifying a scratch path. If the final file does
not exist, it resolves the nearest existing ancestor and appends the missing
suffix. A scratch-path symlink that resolves outside the scratch roots does not
receive the skip. Resolution errors retain the `ask` result.

R02 and R03 run before R04. Their protected-path decisions remain in force even
when R04 would skip an OS scratch path or `WorkMode` would skip an external-path
confirmation.
