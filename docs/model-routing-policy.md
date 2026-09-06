# Model Routing Policy

Status: adopted
Last updated: 2026-09-05

This document defines the default model and reasoning-effort routing for
Claude Code, Codex, Cursor, and Grok in Harness workflows.

## Decision

Use explicit role tiers, not prompt-text inference.

Harness must route model and effort from the workflow role:

- `lite`: cheap, read-heavy, low-risk work
- `standard`: ordinary implementation and setup
- `worker`: Breezing implementation and retry work
- `deep`: architecture, security, cross-repo, migration, and failure recovery
- `review`: quality gates and adversarial checks
- `release`: procedural release and public-surface checks
- `long-context`: large repository or long-session context work

Do not infer effort from free-text markers such as "think harder". A caller may
still ask for one-off deeper reasoning, but durable routing belongs in config,
agent frontmatter, or wrapper arguments.

## Official Evidence

Claude Code supports model aliases and explicit model IDs. The legacy `opusplan`
alias uses Opus in plan mode and Sonnet in execution mode; the September routes
below select Fable 5.1 explicitly. Claude Code settings can pin `model`, restrict `availableModels`, and set
default alias targets through `ANTHROPIC_DEFAULT_*_MODEL` environment variables.
Official docs: https://code.claude.com/docs/en/model-config

Claude Code effort is configurable through `/effort`, `/model`, `--effort`,
`CLAUDE_CODE_EFFORT_LEVEL`, `effortLevel`, and skill/subagent frontmatter.
Frontmatter overrides the session level, while `CLAUDE_CODE_EFFORT_LEVEL`
overrides both. Official docs: https://code.claude.com/docs/en/model-config

On the verified Claude Code 2.1.261 runtime, a saved
`modelSettings.<canonical-model-id>.effortLevel` takes precedence over the shared
`effortLevel`; an explicit session `--effort` wins over both. The `[1m]` suffix
does not create a separate saved effort key. Preserve an existing per-model
choice instead of reporting the shared setting as the effective value.

Claude subagents can set `model` to an alias, full model ID, or `inherit`.
Since Claude Code 2.1.251, resolution order is per-invocation model,
frontmatter model, `CLAUDE_CODE_SUBAGENT_MODEL`, then main conversation model.
An explicit `inherit` selects the parent model. Since 2.1.257,
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` restores the global forced override.
Keep that force flag unset when using role-specific models. An existing
Sonnet default does not flatten the roles on the verified 2.1.261 runtime.
Official docs: https://code.claude.com/docs/en/sub-agents#choose-a-model

The September 2026 Claude router uses Fable 5.1 for deep-planning and advisor defaults,
Sonnet 5 for workers, and Haiku 4.5 for lightweight reading. The separate
native security reviewer remains Sonnet 5. Fable's standard effort is `high`;
benchmark results do not justify raising every role's effort. Official docs:
https://code.claude.com/docs/en/model-config and
https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1

Codex frontier roles use `gpt-6-astra`. Harness keeps `gpt-5.6-luna` at low
effort for lightweight reading and at `max` for the dedicated implementation
worker. The September refresh retains the existing `xhigh` effort on generic
`standard`, `deep`, `review`, and `advisor` roles rather than inferring a new
effort from the user's prompt. The central router is
the SSOT for these companion role defaults; the managed worker custom agent is
the native worker-route SSOT. Official docs:
https://developers.openai.com/codex/models

Codex config supports `model`, `review_model`, `model_reasoning_effort`, and
agent concurrency settings such as `agents.max_threads` / `agents.max_depth`.
Custom Codex agents can set their own `model` and `model_reasoning_effort`.
Codex 0.153.4 accepts `sandbox_mode` in a role file but does not project it into
the spawned agent's permissions; native children inherit the parent's permission
configuration. A role file alone is not filesystem isolation. Harness's
companion review path supplies the read-only execution context. The managed
worker contract below does not declare `sandbox_mode`. Official docs:
https://developers.openai.com/codex/config-reference and
https://developers.openai.com/codex/subagents
Implementation and permission-inheritance tests:
https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/core/src/agent/role.rs and
https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/core/src/agent/role_tests.rs

Cursor subagents support frontmatter `model: inherit|<model-id>`, `readonly`,
and background execution. The Task tool accepts an explicit `model` parameter.
Cursor CLI supports `--model` for per-run selection. Cloud Agent API accepts
`model.id` and `model.params`. Official docs:
https://cursor.com/docs/subagents ,
https://cursor.com/docs/cli/overview ,
https://cursor.com/docs/cloud-agent/api/endpoints

## Override Priority (All Hosts)

1. **Explicit caller override** — Task/subagent `model`, CLI `--model`, or
   companion `--model` when the wrapper documents it.
2. **Harness routed default** — `scripts/model-routing.sh --host <host> --role …`
3. **Session inherit** — subagent `model: inherit` or host session default.

Residual risk: team/admin/plan-unavailable models may fall back silently unless
smoke or operator checks catch them. Do not treat availability in one account as
guaranteed for every Harness user.

## Claude Code Routing

| Harness tier | Claude model | Effort | Use cases |
| --- | --- | --- | --- |
| `lite` | `claude-haiku-4-5` or `haiku` | `low` or `medium` | read-only search, docs cleanup, simple summaries, cheap side research |
| `standard` | `claude-sonnet-5` | `medium` by default, `high` for code-risk tasks | normal worker implementation, setup, tests, scoped refactors |
| `deep` | `claude-fable-5-1` | `high` | architecture, migration, cross-repo decisions, repeated failures |
| `review` | `claude-fable-5-1` | `high` | routed independent review; native security reviewer remains Sonnet 5 |
| `advisor` | `claude-fable-5-1` | `high` | PLAN / CORRECTION / STOP decisions after blocked execution |
| `release` | `claude-sonnet-5` | `high` | release preflight, changelog, version/tag/GitHub Release checks |
| `long-context` | `sonnet[1m]` | `high` | large repo reading, long sessions, context-heavy comparison |

Recommended Claude session default:

```json
{
  "model": "claude-fable-5-1",
  "availableModels": [
    "opusplan",
    "claude-opus-5",
    "claude-fable-5-1",
    "claude-sonnet-5",
    "claude-haiku-4-5",
    "sonnet[1m]"
  ],
  "effortLevel": "high",
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5"
  }
}
```

Notes:

- Fable 5.1/high is the operator baseline for this refresh. Existing session
  context-window and effort selections stay explicit; this example is not an
  instruction to overwrite user settings. `opusplan` remains an optional
  operator choice.
- A configured `CLAUDE_CODE_SUBAGENT_MODEL=claude-sonnet-5` is compatible with
  role-specific models on Claude Code 2.1.251+. Keep the separate `_FORCE` flag
  unset. Older versions have different precedence and need verification.
- Do not set `max` in shared settings. `max` is session-only and should be used
  only for explicit one-off experiments.
- `ultrathink` is a legacy free-text marker. Do not use it for durable routing.
  On the Claude 5 family, control reasoning depth with `effort` (`high`/`xhigh`),
  not prompt markers. If reasoning looks shallow on a hard task, raise effort
  rather than prompting around it.
- Unset, empty, or `HARNESS_BRAIN_MODEL=fable` uses Fable 5.1/high for `deep` /
  `advisor`. Explicit `opus` or `opus5` uses Opus 5/xhigh. Unknown values exit 2.
  This is Claude-host only and never changes `standard` / `review` tiers.

## Codex Routing

| Harness tier | Codex model | Reasoning effort | Use cases |
| --- | --- | --- | --- |
| `lite` | `gpt-5.6-luna` | `low` | explorer subagents, simple docs, small cleanup, cheap parallel fan-out |
| `standard` | `gpt-6-astra` | `xhigh` | general implementation and setup |
| `worker` | `gpt-5.6-luna` | `max` | Breezing implementation, retries, and focused refactors |
| `deep` | `gpt-6-astra` | `xhigh` | cross-file architecture, security, migrations, failed-loop recovery |
| `review` | `gpt-6-astra` via `review_model` | `xhigh` | `/review`, companion review, adversarial diff review |
| `advisor` | `gpt-6-astra` | `xhigh` | blocked-loop PLAN / CORRECTION / STOP decisions |
| `release` | `gpt-6-astra` | `high` | release-preflight and PR closeout evidence |
| `spark` | `gpt-5.3-codex-spark` | `low` | optional Pro-only real-time UI micro-iteration; never required |

Example Codex baseline for a newly configured session:

```toml
model = "gpt-6-astra"
model_reasoning_effort = "medium"
review_model = "gpt-6-astra"

[agents]
max_threads = 8
max_depth = 1
```

Preserve an existing valid interactive effort; the example is not a migration
that changes low, high, or ultra. This baseline is not the native
Breezing worker definition. `breezing --codex` uses the separate explicit
`worker` route from `scripts/model-routing.sh` instead of inheriting the
session baseline.

The operator may change model or effort while work is in progress. Preserve
that live choice rather than restoring an audit snapshot. CCH's role table is
a default for its own dispatch path, not a lock on interactive settings or
explicit `--model` / `--effort` requests. A change to the parent session alone
does not retune all separately configured child roles. Automated environment
updates modify only their declared CCH keys and preserve unrelated current
values; a conflict on an owned key must be reported instead of overwritten.

Recommended project-scoped Codex custom agents:

The examples below show the configuration fields. For CCH-managed worker and
reviewer roles, install the complete profiles generated from `hosts.toml`;
their task, evidence, and authority instructions are part of the role contract.
Prompt calibration and delivery surfaces are described in
[prompt-calibration.md](prompt-calibration.md).

```toml
# .codex/agents/explorer.toml
name = "explorer"
description = "Read-only codebase exploration and evidence gathering."
model = "gpt-5.6-luna"
model_reasoning_effort = "low"
sandbox_mode = "read-only"
developer_instructions = "Inspect files and return concise evidence with paths. Do not edit files."
```

```toml
# .codex/agents/worker.toml
name = "worker"
description = "Scoped implementation worker for a single task."
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
developer_instructions = "Complete the assigned outcome within owned files and approval. Read the contract, recover missing context, honor required checks, and report changed files, observed results, and remaining gaps."
```

Codex-native Breezing selects this managed custom agent with
`agent_type: worker`. The required custom-agent fields above own the worker's
model, reasoning effort, and instructions; sandbox and permission remain
owned by the execution path. Native Breezing does not pass model or reasoning
fields directly through `spawn_agent`. A bounded
`fork_turns: "3"` fork may remain as an execution limit. Do not configure
`[agents].default_subagent_*`: those global defaults would retune every native
subagent, including reviewer and advisor roles.

This custom agent becomes active only after setup copies it to the user
`$CODEX_HOME/agents/worker.toml` or project `.codex/agents/worker.toml` path.
Codex 0.148 plugin manifests cannot register native agent roles; plugin
installation, cache, or dist inclusion alone does not activate this agent.
Official Subagents configuration:
https://developers.openai.com/codex/subagents

```toml
# .codex/agents/reviewer.toml
name = "reviewer"
description = "Read-only reviewer for diffs, risk, and missing tests."
model = "gpt-6-astra"
model_reasoning_effort = "xhigh"
sandbox_mode = "read-only"
developer_instructions = "Review the actual artifact against the contract in a fresh context. Report actionable findings with file and line references and observed evidence using the requested schema. Do not edit files or invent requirements."
```

Notes:

- An inline `[agents.reviewer]` declaration takes precedence over an automatically
  discovered `agents/reviewer.toml` in the same config layer. Setup binds the
  managed file with `config_file = "agents/reviewer.toml"`; explicit custom
  bindings remain operator-owned. Native loader readback must show the intended
  role model and effort, not just the presence of the TOML file. See
  https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/agent-roles/src/loader.rs
- The reviewer file's `sandbox_mode` declaration does not enforce a separate
  read-only filesystem boundary in Codex 0.153.4. Use the companion review
  execution path when the review contract requires that boundary.
- Codex CLI `codex exec` uses `--model` / `-m` for per-run model selection and
  `-c model_reasoning_effort="<level>"` for per-run effort overrides.
- The official Codex companion 1.0.6 rejects `--effort max` and `--effort ultra`. For the separate
  `breezing --codex` companion path, Harness resolves the central `worker`
  route and normalizes `max` or `ultra` to Codex runtime config
  (`-c model_reasoning_effort="max"`) while preserving the routed model and
  write/sandbox intent. Other explicit effort requests may stay on the
  companion path.
- Any direct `codex exec` path must translate a Harness-level `--effort` into
  `-c model_reasoning_effort=...` rather than silently dropping it.
- `agents.max_depth` stays `1`. Recursive fan-out increases token use and makes
  outcomes less predictable.
- `agents.max_threads = 8` is acceptable for Harness breezing because lite
  routing sends cheap exploration to `gpt-5.6-luna` at low effort; if all children use
  `gpt-6-astra xhigh`, lower concurrency first.
- Do not make Codex fast mode the default. It is a latency/credit trade-off,
  not an intelligence tier.

### Explicit settings and long-running sessions

For a routed task, explicit model/effort arguments win. Supported `-c model=...`
and `-c model_reasoning_effort=...` forms are normalized with the corresponding
flags. An explicit `CODEX_EFFORT` wins over the role default. Invalid or ambiguous
config overrides are rejected before dispatch. Beyond model and effort, only
task `model_verbosity=low|medium|high` is supported; provider, MCP, permission,
approval, and other config keys are not forwarded by this adapter. Prompt-based complexity cannot
replace a resolved role effort. The legacy calculator is relevant only when
model routing has been explicitly disabled.

Task argument normalization also fixes the working directory and write intent
used by both the primary-environment guard and execution. Equivalent write
flags are canonicalized; ambiguous repeated working-directory or sandbox
options are rejected. A relative prompt file is resolved against the selected
working directory, and arguments after `--` are prompt text. Runtime-only
options use Codex execution without being reinterpreted as companion prompt
text. Unknown runtime options and new provider/profile/rule-override entry
points are rejected before dispatch.
`--add-dir` is accepted only for read-only tasks. Combining it with write
intent is rejected because the guard checks one target working directory and
does not authorize additional writable roots.

The native `codex-loop` local driver inherits the interactive Codex configuration.
The companion driver uses the task role. They are deliberate separate policies:
a session configured as Astra/low or Astra/ultra is not evidence that every
Breezing worker uses that combination. Inspect the selected driver and role.

Advisor selection preserves explicit project configuration. A per-run
`CODEX_ADVISOR_MODEL=gpt-6-astra` can select Astra without rewriting protected
project settings; `--model` on the consultation command takes precedence.
A missing project choice falls back to the central advisor route.

The generic `task` path previously let prompt scoring lower the configured role
effort. Honoring the existing `standard/xhigh` route can therefore increase the
effective effort of those calls, including the companion loop driver. This is a
correction to role propagation, not an edit to interactive user settings. Select
a lower explicit effort for a bounded task when that is the intended trade-off.

Codex 0.153.4 on the verified host advertises Astra `ultra` as maximum reasoning
with automatic delegation. Its public model API documents effort only through
`max`; never send Codex-specific values to that API. The official companion
cannot represent every stateful mode with extended effort; reject unsupported
background/resume/fresh combinations instead of silently changing effort.

The optional `features.context_management.experimental_mode` setting enables
experimental history/notes management in supported Codex sessions. The local
CLI accepts the nested setting; this refresh does not enable an experimental
feature or infer the account's plan eligibility. It complements, rather than
replaces, the Harness task ledger and cross-session memory.

### Routed review transport (D70)

Codex `review` and `adversarial-review` routes use a fresh, per-run local
`scripts/codex-review-app-server-proxy.mjs`. The proxy starts `codex
app-server --stdio` and injects the effective `model`, `review_model`, and
`model_reasoning_effort` values for that run. The official Codex companion is
still the protocol endpoint: Harness passes the proxy endpoint through
`CODEX_COMPANION_APP_SERVER_ENDPOINT` and preserves the official companion
request/result envelope rather than inventing a second review protocol.

Review `--commit` is rejected before provider dispatch because the official
companion's `--base` option is not a semantic commit target. A routed review is
written to the orchestration ledger only after the companion and proxy both
finish successfully; rejected calls and failed transports do not count as
successful delegations. On `TERM` or `INT`, the wrapper forwards the signal to
the companion and app-server proxy concurrently, waits at most one second,
then sends `KILL` to any survivor and reaps it. The proxy applies the same
fail-closed child lifecycle to its `codex app-server` child.

The POSIX path uses a Unix socket. The Windows named-pipe path is covered by
fixture/static checks only in this repository; a live Windows provider or
app-server run has not been observed.

## Cursor Routing (adapter candidate)

| Harness tier | Cursor model (router default) | Effort label | Use cases |
| --- | --- | --- | --- |
| `lite` | `composer-2-fast` | `low` | read-only exploration, cheap fan-out |
| `standard` | `composer-2.5-fast` | `medium` | normal worker implementation |
| `deep` | `claude-fable-5` | `xhigh` | architecture, security, recovery |
| `review` | `composer-2.5-fast` | `xhigh` | harness-review / reviewer subagent |
| `advisor` | `claude-fable-5` | `xhigh` | advisor-request decisions |
| `release` | `composer-2.5-fast` | `high` | release preflight wording checks |
| `long-context` | `gemini-3.1-pro` | `high` | large repo reads when available |

Adapter surfaces:

- `.cursor/agents/*.md` frontmatter `model`
- Task tool explicit `model`
- Cursor CLI `--model`
- Cloud Agent API `model.id` / `model.params` (optional evidence)

Notes:

- Cursor remains `candidate`; routing defaults are contract fixtures, not a
  support claim.
- Breezing multitask/background agents may fan out Workers; Reviewer and
  cherry-pick stay serial in core.
- When explicit `model` is set on Task/subagent invocation, routed defaults must
  not override it (`tests/test-model-routing.sh` covers Codex explicit path;
  Cursor uses the same priority rule).
- The `review` tier (`composer-2.5-fast`, `xhigh`) is a fresh-context pre-review
  surface: a reviewer session that shares no conversation state with the
  producing worker may pre-review a diff before the brain's primary review. The
  session that produced a diff never reviews its own output, and the primary
  verdict stays with the brain (spec.md Execution Backend Contract).

## Grok Routing (adapter candidate)

| Harness tier | Grok model (router default) | Effort label | Use cases |
| --- | --- | --- | --- |
| `lite` | `grok-4.5` | `low` | read-only exploration, cheap fan-out |
| `standard` | `grok-4.5` | `medium` | normal worker implementation |
| `deep` | `grok-4.6` | `xhigh` | architecture, security, recovery (`xhigh` は grok-4.6 の既定 effort) |
| `review` | `grok-4.6` | `xhigh` | harness-review / reviewer path |
| `advisor` | `grok-4.6` | `xhigh` | advisor-request decisions |
| `release` | `grok-4.6` | `high` | release preflight wording checks |
| `long-context` | `grok-4.6` | `high` | large repo reads (500k ctx) |

Adapter surfaces:

- Grok CLI `--model`
- `scripts/model-routing.sh --host grok --format json|args|env`
- Skill frontmatter `model` when a skill pins a model (prefer routed default)

Notes:

- Grok remains `candidate`; routing defaults are contract fixtures, not a
  public support claim.
- Verified catalog (2026-08-13, 実際にインストールされている `grok 0.2.118` が取得したアカウントカタログ): **`grok-4.6`** (既定 / frontier / 500k ctx / effort `xhigh`\|`high`\|`medium`\|`low`) と **`grok-4.5`** (500k ctx / effort `high`\|`medium`\|`low`) の **2 つのみ**。
- **訂正 (2026-08-13)**: 2026-08-12 に記載した `grok-4.3` / `grok-4.20-*` / `grok-3-mini` は、`grok-cli` という**同名の別プロダクト** (TypeScript) のカタログだった。その前の `grok-composer-2.5-fast` と同様、実 CLI には存在しない ID で、呼び出し時に必ず失敗する。皮肉なことに、さらにその前の `grok-4.5` は実在した — 当時のコメントが「observed on CLI 0.2.93」= 実バイナリでの観測だったため。**capability もカタログも、実際に動く binary で確かめる** (CLAUDE.md FACT-4)。
- Account catalogs may differ; treat missing models as residual risk, not a
  silent fallback in the router.
- `HARNESS_BRAIN_MODEL` is claude-host only and never changes the Grok catalog.

## Harness Role Defaults

| Harness surface | Claude default | Codex default | Cursor default | Grok default | Why |
| --- | --- | --- | --- | --- | --- |
| Interactive operator session | Fable 5.1; preserve the user's saved effort | `gpt-6-astra`; preserve the user's saved effort | `composer-2.5-fast`, `medium` | `grok-4.5`, `low` | host session settings are separate from delegated role defaults |
| `/harness-plan` deep role | Fable 5.1, `high` | `gpt-6-astra`, `xhigh` | `claude-fable-5`, `xhigh` | `grok-4.6`, `xhigh` | planning quality affects all downstream work |
| `worker` | Sonnet 5, `medium` to `high` | `gpt-5.6-luna`, `max` | `composer-2.5-fast`, `medium` | `grok-4.5`, `medium` | implementation benefits from iteration and tests |
| `explorer` / read-only fan-out | Haiku 4.5, `low` | `gpt-5.6-luna`, `low` | `composer-2-fast`, `low` | `grok-4.5`, `low` | cheap context isolation |
| `reviewer` route | Fable 5.1, `high`; isolated native `agents/reviewer.md` stays Sonnet 5 | `gpt-6-astra`, `xhigh` | `composer-2.5-fast`, `xhigh` (fresh-context pre-review only; primary verdict on brain) | `grok-4.6`, `xhigh` | separate the routed review role from the security isolation exception |
| `advisor` | Fable 5.1, `high`; explicit `HARNESS_BRAIN_MODEL=opus` remains Opus 5/xhigh | `gpt-6-astra`, `xhigh` | `claude-fable-5`, `xhigh` | `grok-4.6`, `xhigh` | blocked-loop decisions need independent evidence |
| `release` | Sonnet 5, `high` | `gpt-6-astra`, `high` | `composer-2.5-fast`, `high` | `grok-4.6`, `high` | procedural but public-facing |

## Non-Goals

- Do not update global user config automatically.
- Do not force every subagent to the most expensive model.
- Do not route by vague prompt words.
- Do not use model routing to bypass sandbox, approval, or review gates.
- Do not treat availability of a model in one account type as guaranteed for
  every Harness user.

## Implementation Surface

Harness implements the routing contract through `scripts/model-routing.sh`.
The router maps:

```text
tier -> claude model/effort
tier -> codex --model / -c model_reasoning_effort
tier -> cursor model (+ effort label for docs/tests)
role -> tier
```

Codex-native Breezing selects the managed `.codex/agents/worker.toml` with
`agent_type: worker`; model and reasoning come from that custom agent rather
than being passed directly by the skill. A bounded `fork_turns: "3"` fork may
remain. Keep `[agents].default_subagent_*` unset so reviewer and advisor routes
are not retuned globally. The separate `breezing --codex` companion path
resolves the central `worker` route and normalizes `max` through raw
`codex exec` config. The skill must not become a second model catalog;
companion-route IDs stay in this policy and `scripts/model-routing.sh`, while
native worker model/effort stay intentionally in the managed
`.codex/agents/worker.toml`.

The router should be tested independently from the current user-level
`~/.codex/config.toml` or `~/.claude/settings.json`, because those files are
operator preferences, not repository truth.

`scripts/codex-companion.sh` uses the Codex route for `task` invocations and
translates companion-level `--effort` into Codex CLI
`-c model_reasoning_effort=...` when structured `codex exec` mode is used.
