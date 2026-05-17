# Bootstrap Routing Contract

Last updated: 2026-05-17

## Purpose

This document defines the Phase 70 bootstrap routing contract for Claude Code,
Codex, and OpenCode.

Golden prompts in this document are a static contract fixture. They are not
runtime auto-routing proof. Passing this contract means the repository declares
the expected routing surface; it does not prove that a model invocation will
always auto-fire the matching skill at runtime.

## False Parity Rule

False parity is forbidden.

Claude SessionStart, Codex AGENTS.md, and OpenCode AGENTS.md are different
bootstrap mechanisms. They may point at the same conceptual workflow, but they
must not be described as equivalent runtime enforcement.

## Host Bootstrap Routes

### Claude SessionStart

Claude Code uses plugin instructions, root `CLAUDE.md`, skills in `skills/`,
and SessionStart-style guidance to make workflow routing visible when a
session begins.

Expected properties:

- Natural language prompts can be paired with slash commands and skills.
- Guardrails can use runtime hooks such as PreToolUse and PostToolUse.
- Bootstrap evidence can mention SessionStart, but it must not imply that
  Codex or OpenCode has the same hook surface.

### Codex AGENTS.md

Codex uses `codex/AGENTS.md`, project/user skill loading, and explicit
`$skill-name` invocation guidance.

Expected properties:

- Routing guidance must tell Codex which workflow skill matches a task family.
- Safety guidance follows the Codex model from `docs/hardening-parity.md`:
  contract injection + post quality gate + merge gate.
- Bootstrap evidence is AGENTS.md guidance, not SessionStart hook parity.

### OpenCode AGENTS.md

OpenCode uses `opencode/AGENTS.md`, `opencode/skills/`, and package validation
as its current bootstrap surface.

Expected properties:

- OpenCode routing guidance may mirror workflow names from Claude Code Harness.
- OpenCode validation proves package shape and stale-doc avoidance, not runtime
  auto-routing parity.
- OpenCode remains below Claude/Codex enforcement strength until adapter
  contract tests prove otherwise.

## Golden Prompts

These golden prompts are static contract fixture rows. They are used to check
that docs name the expected workflow for common user intent.

| Prompt fixture | Expected workflow | Claude SessionStart route | Codex AGENTS.md route | OpenCode AGENTS.md route |
|---|---|---|---|---|
| `Todoアプリを作って` / `build a todo app` | `harness-plan` | Start with planning unless an accepted plan already exists. | Route to `$harness-plan` before implementation. | Route to `harness-plan` guidance when available; otherwise manual planning. |
| `計画して` / `plan this` | `harness-plan` | Route to planning workflow. | Route to `$harness-plan`. | Route to `harness-plan` guidance when available. |
| `実装して` / `work on this` | `harness-work` | Route to implementation workflow. | Route to `$harness-work`. | Route to `harness-work` guidance when available. |
| `implement all Plans.md tasks` | `breezing` | Route to team execution wrapper when multiple ready tasks exist. | Route to `$breezing` or `$harness-work all` according to ready task count. | Route to `breezing` or `harness-work` guidance when available; otherwise manual execution. |
| `全部やって` / `breezing all` | `breezing` | Route to team execution wrapper. | Route to `$breezing`. | Route to `breezing` guidance when available. |
| `review this PR` | `harness-review` | Route to independent review workflow. | Route to `$harness-review`. | Route to `harness-review` guidance when available; unsupported hosts must return `unsupported` or `manual`. |
| `レビューして` / `review this` | `harness-review` | Route to independent review workflow. | Route to `$harness-review`. | Route to `harness-review` guidance when available. |
| `進捗確認` / `sync status` | `harness-sync` | Route to sync workflow. | Route to `$harness-sync`. | Route to `harness-sync` guidance when available. |
| `セットアップして` / `setup harness` | `harness-setup` | Route to setup workflow. | Route to `$harness-setup`. | Route to `harness-setup` guidance when available. |

## Non-Target Hosts

Cursor, Gemini, and Copilot are future/unsupported for bootstrap routing in
Phase 70. They are not part of the golden prompt fixture.

## Validation Requirements

The routing contract is valid only when all of the following stay true:

- Claude SessionStart, Codex AGENTS.md, and OpenCode AGENTS.md are named as
  separate bootstrap routes.
- Golden prompts are explicitly called a static contract fixture.
- The document says the fixture is not runtime auto-routing proof.
- Unsupported hosts and unavailable routes must produce `unsupported` or
  `manual` evidence instead of being counted as successful runtime routing.
- Each core workflow listed above has at least one prompt fixture.
- Cursor, Gemini, and Copilot remain future/unsupported only.
