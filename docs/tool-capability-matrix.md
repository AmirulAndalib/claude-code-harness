# Tool Capability Matrix

Last updated: 2026-05-17

## Purpose

This document defines the Phase 70 host capability matrix for Hokage Core
extraction work. It is a contract document, not a marketing support matrix.

The supported planning scope is:

- Claude Code
- Codex
- OpenCode

Cursor, Gemini, and Copilot are future/unsupported only in this phase. They
must not receive setup docs, adapter claims, or public README support language
until Claude Code, Codex, and OpenCode have green contract tests.

## False Parity Rule

False parity is forbidden.

The same capability name does not mean the same enforcement strength. Claude
Code can stop some actions at runtime through hooks. Codex does not have the
same hook model, so the Codex policy from `docs/hardening-parity.md` is
contract injection + post quality gate + merge gate. OpenCode is currently a packaging and instruction surface, not proof of runtime guard parity.

## Capability Status

| Capability | Core meaning | Claude Code | Codex | OpenCode |
|---|---|---|---|---|
| `skill_loading` | Host can discover and load workflow skills. | Supported through the Claude plugin `skills/` surface. | Supported through `codex/.codex/skills/` and project/user skill loading. | Partial through `opencode/skills/` mirror packaging. |
| `bootstrap_notice` | Host can load startup guidance or prove the guidance surface exists. | Supported through Claude SessionStart guidance, plugin instructions, and root `CLAUDE.md`. | Supported through `codex/AGENTS.md`; no SessionStart hook parity claim. | Partial through `opencode/AGENTS.md`; no SessionStart hook parity claim. |
| `prompt_routing` | Host can map user intent to a workflow. | Supported through slash commands, skill triggers, and SessionStart guidance. | Partial through explicit `$skill` invocation and `AGENTS.md` routing guidance. | Partial through `AGENTS.md` routing guidance and mirrored skill names. |
| `pre_use_guard` | Host can block risky actions before execution. | Supported through PreToolUse / permission boundaries. | Partial only by contract injection before execution; not runtime hook parity. | Unsupported for parity; instructions can warn, but no first-class pre-use guard is claimed. |
| `post_use_gate` | Host can inspect outputs after execution. | Supported through PostToolUse and review workflow checks. | Supported through post quality gate checks before merge. | Partial through package validation and release preflight checks. |
| `review_artifact` | Host can produce structured review evidence. | Supported through harness-review and Claude-side review artifacts. | Supported through `scripts/codex-companion.sh review --base` and schema-backed review output. | Partial/static only; OpenCode package validation is not equivalent to an independent reviewer. |
| `memory_bridge` | Host can use a controlled memory surface. | Supported when Agent Memory / harness-mem wiring is configured. | Partial through `AGENTS.md` guidance and harness-mem bridge configuration. | Future/unsupported for runtime memory bridge parity. |

## Non-Target Hosts

| Host | Phase 70 status | Reason |
|---|---|---|
| Cursor | future/unsupported | No adapter contract, setup path, or verification gate is part of Phase 70. |
| Gemini | future/unsupported | No adapter contract, setup path, or verification gate is part of Phase 70. |
| Copilot | future/unsupported | No adapter contract, setup path, or verification gate is part of Phase 70. |

## Validation Requirements

The matrix is valid only when all of the following stay true:

- All required capability names are present exactly as code-formatted labels.
- Claude Code, Codex, and OpenCode are the only active Phase 70 host targets.
- Cursor, Gemini, and Copilot remain future/unsupported only.
- The Codex safety model references contract injection + post quality gate +
  merge gate.
- Any public support wording preserves the false parity rule.
