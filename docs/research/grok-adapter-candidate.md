# Grok Adapter Evidence Boundary

> **Promotion note (2026-07-19):** Grok promoted to `supported` on 2026-07-19
> (live H4 workflow smoke 2026-07-17 + H7 release-preflight fail-closed gate).
> The tier statements below are historical evidence; public surfaces now pin
> `supported` with Claude-envelope PreToolUse floor caveats.

Status: internal-compatible evidence boundary
Checked at: 2026-07-09 JST
Phase: Grok host completion (goal plan)

## Conclusion

Grok is an **internal-compatible** Harness host.

Harness has a Grok adapter surface (`.grok-plugin/`, `.grok/AGENTS.md`,
`scripts/setup-grok.sh`, host dist build, model routing, static smoke tests).
Package install and skill discovery via `grok plugin install` + `grok inspect`
are observed. It does **not** have CI-gated Plan → Work → Review workflow smoke
or Claude SessionStart / PreToolUse hook parity. Do not claim public `supported`.

## Evidence Boundary

`not_observed != absent`: missing Grok workflow smoke is not proof that Grok
cannot support Harness. It is proof that Harness must not overclaim support.

Do not promote Grok to public `supported` until:

- host-specific bootstrap smoke stays green in release preflight,
- CI-gated workflow smoke proves Plan/Work/Review from Grok alone (or an
  equivalent operator-accepted bar),
- README/onboarding wording still separates install discovery from Claude-tier
  support.

## Observed Runtime Evidence (2026-07-09)

Operator-local / CLI observation (Grok CLI `0.2.93`):

| Observation | Evidence | Limit |
|---|---|---|
| Plugin manifest validate | `grok plugin validate` accepts `.grok-plugin/plugin.json` packages with `skills: "./skills/"` | Shape only |
| Isolated HOME install | `HOME=<tmp> grok plugin install <dist> --trust` writes `~/.grok/installed-plugins/` + registry | Depends on CLI |
| Skill discovery in other project | `HOME=<tmp> grok inspect --json` from a temp cwd lists `harness-plan`, `harness-work`, `harness-review`, `breezing` with `source.type=plugin` | Single-environment proof |
| Model IDs | 実際にインストールされている `grok 0.2.118` のアカウントカタログ (2026-08-13 実測): **`grok-4.6` (既定) と `grok-4.5` の 2 つのみ** | 下の「カタログ訂正」を必ず読むこと |

> **訂正 (2026-08-12)**: 従来この表に載せていた 2 つのモデル ID は、実カタログに存在しないものだった
> (片方は cursor 側 composer の取り違えと見られる)。実在しない ID を表の行に残すと
> `tests/test-model-routing.sh` の docs↔SSOT ゲートが落ちるため、経緯はこの注記に置く。

## Harness Evidence (This Repository)

| Artifact | What it proves | What it does not prove |
|---|---|---|
| `.grok-plugin/plugin.json` | Plugin manifest points at core `skills/` | Marketplace publish or every-account install |
| `.grok/AGENTS.md` | Bootstrap routing guidance for plan/work/review | Automatic runtime routing |
| `scripts/setup-grok.sh` | Isolated build/check + install entrypoint | Live operator HOME install as CI proof |
| `scripts/build-host-plugin-dist.sh --host grok` | Package-local `./skills/` paths (no `..`) | Host runtime beyond package shape |
| `scripts/model-routing.sh --host grok` | Role-tier → Grok model mapping contract | Account-specific model availability |
| `tests/test-grok-adapter-candidate.sh` | Static adapter contract + isolated setup smoke | Full Breezing multitask proof |

## Official Grok Surfaces (Observed 2026-07-09)

Sources checked (local user-guide + CLI help):

- `~/.grok/docs/user-guide/08-skills.md` — skill discovery roots
- `~/.grok/docs/user-guide/09-plugins.md` — plugin install / validate / inspect
- `~/.grok/docs/user-guide/12-project-rules.md` — AGENTS.md project rules
- `grok plugin validate|install|list|details`, `grok inspect --json`

Observed adapter-relevant mechanics:

| Surface | Harness mapping | Notes |
|---|---|---|
| Project rules / `AGENTS.md` | Bootstrap notice + prompt routing | Same conceptual layer as Codex/Cursor AGENTS |
| Skills | Core workflow skills via plugin `skills/` | Slash commands when `user-invocable: true` |
| Plugins | `.grok-plugin/plugin.json` + `skills/` | User install under `~/.grok/installed-plugins/` |
| CLI `--model` | Explicit override surface | Outranks routed default when caller sets it |
| Hooks | Optional future mapping | Not claimed as Claude PreToolUse parity |

## Verification Commands

```bash
bash tests/test-grok-adapter-candidate.sh
bash scripts/setup-grok.sh --check
bash scripts/build-host-plugin-dist.sh --host grok --out /tmp/cch-grok-dist
bash scripts/model-routing.sh --host grok --role worker --format json
# Optional when CLI available:
grok plugin validate /tmp/cch-grok-dist
```

## Hooks Correction (2026-08-13, Phase 133.2)

`hosts.toml`'s `[grok]` descriptor previously cited "grok-cli v1.1.7
src/hooks/{types,config,executor}.ts" as evidence that project-level hooks
are refused. That source is a different, unrelated TypeScript project — not
the CLI this repo integrates with. Re-measured directly against the
installed CLI (`grok 0.2.118`, "Grok Build TUI", Rust):

- `~/.grok/docs/user-guide/10-hooks.md` (bundled CLI docs) documents project
  hooks as supported: `<project>/.grok/hooks/*.json`,
  `<project>/.claude/settings.json` (Claude compat), and hooks bundled
  inside installed plugins are all merged, gated by a one-time folder-trust
  grant. This is the opposite of "intentionally refused".
- `grok inspect --json` on this repo shows `externalCompat.cells` with
  `{vendor:"claude", surface:"hooks", enabled:true, source:"default"}`, and
  its `hooks[]` array shows the claude-compat loader actively firing for
  four other real Claude Code plugins (codex, security-guidance, vercel,
  agentforce-adlc) installed only under `~/.claude/plugins/`.
- `bin/harness hook pre-tool --host grok`, probed directly with a
  Claude-shaped payload, denies `git push --force` with the byte-identical
  envelope `--host claude` produces (exit 2). The policy engine side is
  already correct for grok.
- The gap is packaging, not CLI policy: the grok dist this repo builds
  (`scripts/build-host-plugin-dist.sh` `build_grok()`) never copies a
  `hooks/` directory into the package, so `grok inspect` correctly reports
  `hooks: false` for the installed `claude-code-harness` plugin. Native hook
  parity is therefore a scoped follow-up (ship `hooks/hooks.json` in the
  grok dist + a `grokDoc()` case in `go/internal/hostgen/hostgen.go` + flip
  `hook_generation`), not a blocked path.

Full evidence and citations: `hosts.toml` `[grok]` comment block.

## Blocked Wording

| Allowed | Blocked |
|---|---|
| internal-compatible Grok adapter | public top-tier product claim for this host |
| setup-grok install / package smoke | Claude SessionStart parity |
| skill discovery via inspect | PreToolUse deny parity |
| model-routing host `grok` | Breezing multitask public support claim |

## カタログ訂正 (2026-08-13)

この文書は 2026-08-12 まで、`grok` のモデルカタログを `/Users/tachibanashuuta/LocalWork/Code/grok-cli` の `src/grok/models.ts` から読んで記録していた。**それは同名の別プロダクトだった。**

- 記録していたもの (TypeScript 版 `grok-cli` v1.1.7): flagship 1 種 + 2M ctx 系 3 種 + budget 1 種
- 実際に動く CLI (`grok 0.2.118`, "Grok Build TUI", Rust): **2 種のみ**。`grok-4.6` (既定 / 500k ctx / effort は xhigh・high・medium・low) と `grok-4.5` (500k ctx / effort は high・medium・low)

つまり `scripts/model-routing.sh` に入っていた 5 つの pin は **1 つも実在せず**、grok へ委譲を始めた瞬間に全 tier が失敗する状態だった。さらにその前の世代の pin (`grok-composer-2.5-fast`) も同様に存在しない ID で、これは cursor の `composer-2.5-fast` の取り違えと見られる。

皮肉なことに、2 世代前の `grok-4.5` は**実在した**。当時のコメントは `observed 2026-07-09 on CLI 0.2.93` — つまり実バイナリでの観測だった。source tree を読んで「訂正」したことで、正しい値が誤った値に置き換わっていた。

この表の Model IDs 行には、当初から備考に `Account catalog may differ` と書いてあった。的中している。

**教訓**: capability もカタログも、**実際に動く binary** で確かめる (CLAUDE.md FACT-4)。同名の source tree は根拠にならない。同じ取り違えが hook capability の記述 (Phase 133.2) にも波及していた。
