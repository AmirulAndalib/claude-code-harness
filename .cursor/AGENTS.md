# AGENTS.md — Cursor Bootstrap Route (Supported)

Status: Cursor adapter **`supported`**. Harness-side containment applies — see
`docs/CURSOR_INTEGRATION.md#containment-disclosure`. PM handoff remains documented in
`docs/CURSOR_INTEGRATION.md`.

## Support Tier

Cursor is `supported` after live H4 (2026-07-17) and H7 release-preflight
fail-closed gate. No traditional FS jail — containment is harness-side.
`not_observed != absent`.

## First Commands

| Intent | Skill / workflow | Notes |
|---|---|---|
| Plan a change | `harness-plan` | Read root `spec.md` + `Plans.md` before adding tasks |
| Implement next task | `harness-work` | Default solo; use breezing for multi-task team runs |
| Review diff / PR | `harness-review` | Independent review; do not self-approve implementation |
| Sync drift | `harness-sync` | Plans vs git vs implementation |
| Setup / init | `harness-setup` | First-time or repair bootstrap |

Golden prompt fixtures (static contract, not auto-routing proof):

- `plan this` / `計画して` → `harness-plan`
- `work on this` / `実装して` → `harness-work`
- `implement all Plans.md tasks` / `全部やって` → `breezing` or `harness-work all`
- `review this PR` / `レビューして` → `harness-review`

## Model Routing

Resolve model from Harness role tier via:

```bash
bash scripts/model-routing.sh --host cursor --role worker --format json
```

Priority:

1. Explicit Task/subagent `model` override from the caller
2. Routed default from `scripts/model-routing.sh`
3. Session inherit (`model: inherit` in subagent frontmatter)

Do not claim Claude/Codex hook or Agent Teams parity from Cursor subagents.

## Breezing (Team Execution)

Core contract (host-neutral):

- Parallel: independent Workers when file groups do not overlap
- Serial: Reviewer verdict, cherry-pick to main, Advisor escalation

Cursor adapter mapping (smoke target only):

- Worker → Task tool / `.cursor/agents/worker.md` subagent (parallel when safe)
- Reviewer → `.cursor/agents/reviewer.md` (`readonly: true`)
- Advisor → `.cursor/agents/advisor.md` on `advisor-request.v1` only
- Multitask / background agents → optional parallel fan-out; not a support claim

## Verification

```bash
bash tests/test-cursor-adapter-candidate.sh
bash tests/test-bootstrap-routing-contract.sh
bash tests/test-model-routing.sh
```

## North Star (3 層の野望)

- L1 判断専念: AI が plan / 実装 / 比較 / 検証 evidence を準備し、人間 (operator) は最終判断のみ行う。
- L2 ツール非依存: 同一 Harness (R01-R15 guardrails + plan/work/review/release) が Claude / Codex / Cursor のどの host からでも効く。1 つの policy engine が 3 host を native hook 経由で adjudicate する (複製でなく routing)。向きは 2 つ対等 — #1 harness が駆動 (Lead が他ツールを engine として spawn) / #2 host から使う (Cursor「から」 harness を呼ぶ)。
- L3 協調 (将来の本丸): 複数ツールが同一プロジェクトを、人間をコピペ係にせず協調する。Mode 1 = 完全自律オーケストレーション (v1 は Lead=Claude 固定)、Mode 2 = 人間在席の peer co-drive (live notice messaging)。フル peer-Lead 協調は段階導入。

## Codex / Cursor hook の事実 (自分の hook 構成を誤解しないための固定知識)

- FACT-1: Codex / Cursor は一級の hook ホストである。hook は config.toml に inline で書かれず、`harness gen` が生成する `.cursor/hooks.json` / `.codex/hooks.json` (gitignore された build artifact) に入る。いずれも `bin/harness hook pre-tool --host <h>` を呼ぶ。
- FACT-2: 「config.toml に inline hook を ship しない」は「config.toml の中には書かない」の意味であり、「hook が無い」ではない。この 2 つを混同しない。
- FACT-3: hook には 2 層あり、状態が層ごとに異なる。(a) enforcement (PreToolUse → `bin/harness hook pre-tool` → R01-R15 policy engine) は 3 host 対称に配線済み・`harness gen` で生成可能。(b) Mode 2 delivery (inbox-check / monitor で受信) は生成関数が実装 + unit test 済みだが本番 caller がゼロで、`harness gen` 未接続のため生成 hook に inbox-check は入らない。Codex/Cursor delivery は turn 境界 (Stop) 受信が設計で、live monitor は Claude 専用。
- FACT-4: あるホストが capability を欠くと結論する前に、必ず `harness gen` 出力を実際に materialize して中身を確認する。config のコメントだけで「無い」と断定しない。`not_observed != absent`。
