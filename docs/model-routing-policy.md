# Model Routing Policy

Status: adopted
Last updated: 2026-05-28

This document defines the default model and reasoning-effort routing for
Claude Code and Codex in Harness workflows.

## Decision

Use explicit role tiers, not prompt-text inference.

Harness must route model and effort from the workflow role:

- `lite`: cheap, read-heavy, low-risk work
- `standard`: ordinary implementation and setup
- `deep`: architecture, security, cross-repo, migration, and failure recovery
- `review`: quality gates and adversarial checks
- `release`: procedural release and public-surface checks
- `long-context`: large repository or long-session context work

Do not infer effort from free-text markers such as "think harder". A caller may
still ask for one-off deeper reasoning, but durable routing belongs in config,
agent frontmatter, or wrapper arguments.

## Official Evidence

Claude Code supports model aliases and explicit model IDs. `opusplan` uses Opus
in plan mode and Sonnet in execution mode, which matches Harness' Plan -> Work
split. Claude Code settings can pin `model`, restrict `availableModels`, and set
default alias targets through `ANTHROPIC_DEFAULT_*_MODEL` environment variables.
Official docs: https://code.claude.com/docs/en/model-config

Claude Code effort is configurable through `/effort`, `/model`, `--effort`,
`CLAUDE_CODE_EFFORT_LEVEL`, `effortLevel`, and skill/subagent frontmatter.
Frontmatter overrides the session level, while `CLAUDE_CODE_EFFORT_LEVEL`
overrides both. Official docs: https://code.claude.com/docs/en/model-config

Claude subagents can set `model` to an alias, full model ID, or `inherit`.
Resolution order is `CLAUDE_CODE_SUBAGENT_MODEL`, per-invocation model,
frontmatter model, then main conversation model. Therefore Harness must not set
`CLAUDE_CODE_SUBAGENT_MODEL` by default because it would flatten per-agent
routing. Official docs: https://code.claude.com/docs/en/sub-agents

Anthropic's current model table positions Claude Opus 4.7 as the most capable
model for complex reasoning and agentic coding, Sonnet 4.6 as the best speed /
intelligence balance, and Haiku 4.5 as the fastest model. Official docs:
https://platform.claude.com/docs/en/about-claude/models/overview

Codex recommends `gpt-5.5` for most tasks, `gpt-5.4-mini` for lighter coding
tasks and subagents, and `gpt-5.3-codex-spark` as an optional research-preview
fast iteration model for ChatGPT Pro users. Official docs:
https://developers.openai.com/codex/models

Codex config supports `model`, `review_model`, `model_reasoning_effort`, and
agent concurrency settings such as `agents.max_threads` / `agents.max_depth`.
Custom Codex agents can set their own `model`, `model_reasoning_effort`, and
`sandbox_mode`. Official docs:
https://developers.openai.com/codex/config-reference and
https://developers.openai.com/codex/subagents

## Claude Code Routing

| Harness tier | Claude model | Effort | Use cases |
| --- | --- | --- | --- |
| `lite` | `claude-haiku-4-5` or `haiku` | `low` or `medium` | read-only search, docs cleanup, simple summaries, cheap side research |
| `standard` | `claude-sonnet-4-6` | `medium` by default, `high` for code-risk tasks | normal worker implementation, setup, tests, scoped refactors |
| `deep` | `claude-opus-4-7` | `xhigh` | architecture, security, migration, cross-repo decisions, repeated failures |
| `review` | default reviewer: `claude-sonnet-4-6`; adversarial/final reviewer: `claude-opus-4-7` | `xhigh` | normal review stays cost-aware; high-risk gates use Opus |
| `advisor` | `claude-opus-4-7` | `xhigh` | PLAN / CORRECTION / STOP decisions after blocked execution |
| `release` | `claude-sonnet-4-6` | `high` | release preflight, changelog, version/tag/GitHub Release checks |
| `long-context` | `sonnet[1m]` | `high` | large repo reading, long sessions, context-heavy comparison |

Recommended Claude session default:

```json
{
  "model": "opusplan",
  "availableModels": [
    "opusplan",
    "claude-opus-4-7",
    "claude-sonnet-4-6",
    "claude-haiku-4-5",
    "sonnet[1m]"
  ],
  "effortLevel": "high",
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-7",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5"
  }
}
```

Notes:

- `opusplan` is the preferred operator default because it naturally spends Opus
  on planning and Sonnet on execution.
- Keep `CLAUDE_CODE_SUBAGENT_MODEL` unset by default. Use it only as a temporary
  emergency override, because it outranks per-agent model settings.
- Do not set `max` in shared settings. `max` is session-only and should be used
  only for explicit one-off experiments.
- `ultrathink` is allowed for one-off deep reasoning, but it must not become the
  durable routing mechanism.

## Codex Routing

| Harness tier | Codex model | Reasoning effort | Use cases |
| --- | --- | --- | --- |
| `lite` | `gpt-5.4-mini` | `minimal` or `low` | explorer subagents, simple docs, small cleanup, cheap parallel fan-out |
| `standard` | `gpt-5.5` | `medium` | normal implementation, test fixes, focused refactors |
| `deep` | `gpt-5.5` | `high` or `xhigh` | cross-file architecture, security, migrations, failed-loop recovery |
| `review` | `gpt-5.5` via `review_model` | `xhigh` | `/review`, companion review, adversarial diff review |
| `release` | `gpt-5.5` | `high` | release-preflight and PR closeout evidence |
| `spark` | `gpt-5.3-codex-spark` | `low` | optional Pro-only real-time UI micro-iteration; never required |

Recommended Codex baseline:

```toml
model = "gpt-5.5"
model_reasoning_effort = "high"
review_model = "gpt-5.5"

[agents]
max_threads = 8
max_depth = 1
```

Recommended project-scoped Codex custom agents:

```toml
# .codex/agents/explorer.toml
name = "explorer"
description = "Read-only codebase exploration and evidence gathering."
model = "gpt-5.4-mini"
model_reasoning_effort = "low"
sandbox_mode = "read-only"
developer_instructions = "Inspect files and return concise evidence with paths. Do not edit files."
```

```toml
# .codex/agents/worker.toml
name = "worker"
description = "Scoped implementation worker for a single task."
model = "gpt-5.5"
model_reasoning_effort = "medium"
sandbox_mode = "workspace-write"
developer_instructions = "Implement only the assigned task, run focused checks, and report changed files and validation."
```

```toml
# .codex/agents/reviewer.toml
name = "reviewer"
description = "Read-only reviewer for diffs, risk, and missing tests."
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
sandbox_mode = "read-only"
developer_instructions = "Review evidence-first. Report prioritized findings with file and line references. Do not edit files."
```

Notes:

- Codex CLI `codex exec` uses `--model` / `-m` for per-run model selection and
  `-c model_reasoning_effort="<level>"` for per-run effort overrides.
- `scripts/codex-companion.sh` may continue accepting Harness-level `--effort`,
  but any direct `codex exec` path must translate that into
  `-c model_reasoning_effort=...`.
- `agents.max_depth` stays `1`. Recursive fan-out increases token use and makes
  outcomes less predictable.
- `agents.max_threads = 8` is acceptable for Harness breezing because worker
  routing sends cheap exploration to `gpt-5.4-mini`; if all children use
  `gpt-5.5 xhigh`, lower concurrency first.
- Do not make Codex fast mode the default. It is a latency/credit trade-off,
  not an intelligence tier.

## Harness Role Defaults

| Harness surface | Claude default | Codex default | Why |
| --- | --- | --- | --- |
| Interactive operator session | `opusplan`, `high` | `gpt-5.5`, `high` | strong default without forcing max spend |
| `/harness-plan` | `opusplan` or Opus for non-trivial planning | `gpt-5.5`, `high` | planning quality affects all downstream work |
| `worker` | Sonnet 4.6, `medium` to `high` | `gpt-5.5`, `medium` | implementation benefits from iteration and tests |
| `explorer` / read-only fan-out | Haiku 4.5, `low` | `gpt-5.4-mini`, `low` | cheap context isolation |
| `reviewer` | Sonnet 4.6 `xhigh`; Opus 4.7 `xhigh` for high-risk | `gpt-5.5`, `xhigh` | review is where deeper reasoning pays |
| `advisor` | Opus 4.7, `xhigh` | `gpt-5.5`, `xhigh` | blocked-loop decisions need high confidence |
| `release` | Sonnet 4.6, `high` | `gpt-5.5`, `high` | procedural but public-facing |

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
role -> tier
```

The router should be tested independently from the current user-level
`~/.codex/config.toml` or `~/.claude/settings.json`, because those files are
operator preferences, not repository truth.

`scripts/codex-companion.sh` uses the Codex route for `task` invocations and
translates companion-level `--effort` into Codex CLI
`-c model_reasoning_effort=...` when structured `codex exec` mode is used.
