# Claude Code Harness — Plans.md

最終アーカイブ: 2026-07-23（Phase 62-116 → `.claude/memory/archive/Plans-2026-07-23-phase62-116.md`）
前回アーカイブ: 2026-05-29（Phase 80/81/82/84 → `.claude/memory/archive/Plans-2026-05-29-phase80-84.md`）

---

## North Star（3 層の野望）

この task ledger 全体が目指す到達点。古い順（土台 → てっぺん）。詳細契約は `spec.md` を正本とし、ここは参照ブロック。

- **L1 判断専念**: AI が plan / 実装 / 比較 / 検証 evidence を準備し、operator（人間）は最終判断のみ行う（`spec.md` Purpose / Users And Workflows）。
- **L2 ツール非依存（tool-agnostic）**: 同一 Harness（R01-R13 guardrails + plan/work/review/release）が Claude / Codex / Cursor の「どれからでも」効く。1 つの policy engine が 3 host を native hook 経由で adjudicate する（複製でなく routing）。2 つの向きを対等にサポート — #1 harness が駆動（Lead が他ツールを engine として spawn）/ #2 host から使う（Codex/Cursor「から」harness を使う）（`spec.md` Execution Backend Contract / Host Adapter）。
- **L3 協調（collaboration, 将来の本丸）**: 複数ツールが同一プロジェクトを、人間をコピペ係にせず協調する。Mode 1 = 完全自律オーケストレーション（v1 は Lead=Claude 固定、Codex/Cursor は外向き spawn API 無し）。Mode 2 = 人間在席の peer co-drive（live notice messaging）。フル peer-Lead 協調は段階導入で後回し（Phase 92 Purpose / `spec.md` Mode 1/Mode 2）。

> ~~既知 follow-up: delivery hook gen 未配線~~ **解消済み (2026-07-21 訂正)**: `GenerateDeliveryHooksJSON` は Phase 105.9 [b82143fe] で `harness gen` に配線済みだった（このメモ自体が stale だった）。identity placeholder no-op は Phase 121.2（`--from-env` runtime 解決）で解消、Claude host の Stop 配線は Phase 121.3 で追加。Mode 2 turn 境界 delivery は 3 host に配達される（live monitor は opt-in・既定 OFF）。

---

## 📦 アーカイブ

完了済み Phase は以下のファイルへ切り出し済み（git history にも残存）:

- [Phase 62-116](.claude/memory/archive/Plans-2026-07-23-phase62-116.md) — CC 2.1.112+ 追従 / 3-surface HTML / backend resolver + Cursor 昇格 / Session Coordination / Zero-Base Redesign + Plan B stage a-c (Phase 92-103) / S1-S5 gate + v5.0.0-v5.1.0 release 線 (Phase 104-114) / LSP 配線 / test-wiring auditor。Breezing 自律完走契約 (2026-06-12 承認) は運転規約として本ファイルに残置
- [Phase 80/81/82/84](.claude/memory/archive/Plans-2026-05-29-phase80-84.md) — Claude 2.1.143-2.1.152 + Codex 0.131-0.134 upstream refresh / Cursor CCH Adapter candidate / cursor-agent CLI workflow smoke 検証 (candidate, 配布なし) / harness-review closeout fixes + Cursor ACP boundary record
- [Phase 63/64/66-71/73-76/78/79](.claude/memory/archive/Plans-2026-05-29-phase63-79.md) — stale harness-mem 参照整理 / Plans archive-aware / 3-surface HTML cross-project safety 関連 / Open Issue closeout / Codex 0.130 / harness-review TeamAgent + lightweight / Hokage Core boundary / R03 break-glass / Superpowers tool-first onboarding / repo-health gates / README front door / spec.md+Plans.md co-required / Dependabot benchmark / harness-plan team gates
- [Phase 47-61](.claude/memory/archive/Plans-2026-05-08-phase47-61.md) — Session Monitor 能動監視 / XR-003 / 3-state 依存テスト規約 / CC 2.1.112-2.1.126 + Codex 0.121-0.128 upstream 追従 / Issue #105 English default + Japanese opt-in / External Issue closeout / Skill orchestration design contract / harness-mem managed companion (v4.6.0-v4.7.0) / Sandbagging-Aware Weak-Supervision Harness
- [Phase 44 + 45 + 46](.claude/memory/archive/Plans-2026-04-19-phase44-46.md) — Opus 4.7 / CC 2.1.99-110 追従 "Arcana" (v4.2.0) + Plugin Manifest 公式準拠 + Worker 3 層防御 (#84-#87, v4.3.0)
- [Phase 37 + 41 + 42 + 43](.claude/memory/archive/Plans-2026-04-17-phase37-41-42-43.md) — Hokage 完全体 / Long-Running Harness / Go hot-path migration / Advisor Strategy
- [Phase 39 + 40 + 41.0](.claude/memory/archive/Plans-2026-04-15-phase39-40-41.0.md) — レビュー体験改善 / Migration Residue Scanner / Long-Running Harness Spike

---

## マーカー凡例

PM ↔ Impl 運用で使用する標準マーカー:

| マーカー | 意味 | 誰が付ける |
|---------|------|-----------|
| `pm:requested` / `pm:依頼中` | PM がタスクを起票し、Impl へ依頼中 | PM |
| `cc:todo` / `cc:TODO` | Impl の未着手タスク | Impl |
| `cc:wip` / `cc:WIP` | Impl（Claude Code）が着手中 | Impl |
| `cc:done` / `cc:完了` | Impl が作業完了し、PM の確認待ち | Impl |
| `pm:approved` / `pm:確認済` | PM が最終確認を完了 | PM |
| `cc:withdrawn` | Impl が判断で取り下げたタスク（superseded / 別タスクで吸収）。breezing は cc:withdrawn を pickup しない | Impl |

**状態遷移**: 新規・更新時の正規出力は `pm:requested → cc:todo → cc:wip → cc:done → pm:approved`。既存 `pm:依頼中 → cc:TODO → cc:WIP → cc:完了 → pm:確認済` も read-compatible。`cc:withdrawn` は terminal state（再開しない）。

**後方互換**: `cursor:依頼中` / `cursor:確認済` は `pm:依頼中` / `pm:確認済` の同義として扱う（Cursor PM 運用時の表記）。

---

## Breezing 自律完走契約（2026-06-12 ユーザー承認 — 実装セクション運転規約）

`/breezing all --cursor` が**途中の人間判断なしに実装セクションを完走する**ための運転規約。ユーザー指示（2026-06-12「途中で聞かれてもわからないから実装は終わらせてほしい。レビューとチェックは後でまとめてやる」）に基づく事前承認の記録。

**スコープ 2 分割**:
- **実装セクション**（breezing 完走対象）: 93.1.1 / 93.1.2 / 93.2.1 / 93.3.1-93.3.5 / 92.5.1-92.5.3 / 92.6.1-92.6.4 / 95.1.1-95.1.3 / 95.2.1-95.2.3 / 95.4.1 / 96.1.1-96.1.4 ＋ 旧 backlog（88.1 / 88.3 / 72.1.2-72.1.6 / 83.7）
- **検証セクション**（ユーザー review window、breezing は触らない）: 93.3.6 / 95.5.1 / 96.1.5 / 96.1.6（いずれも `[lane:release]` e2e・公開 claim 更新）＋ Phase 94（92.4.x、user GO 待ち scope 外）

**mid-run 質問禁止 + 分岐既定値**:
- 実装セクション中は AskUserQuestion を使わない。分岐は以下の既定値で進める
- review REQUEST_CHANGES → 最大 3 回修正 → 未収束は Status に `blocked(理由)` 注記 + **次タスクへ続行**（停止しない）
- companion 起動失敗 → 1 回 retry → 失敗なら blocked + 続行
- blocked 一覧は最終報告に集約しユーザー review へ渡す

**Risk Gate 事前承認**（92.6.4 / 96.1.4、2026-06-12 ユーザー指示による）: breezing は停止せず実装してよい。ただし 3 条件を厳守: (i) default-OFF / opt-in 設計を変えない（auto-approve は 96.1.3 実装後も default OFF）、(ii) 実ユーザー設定ファイル（`~/.claude/settings*.json`・実 repo の `.claude/settings.local.json`）への実書込はせず fixture/tempdir 内 test で検証、(iii) 5 カテゴリ floor・fingerprint 封じ込め・deny ルールの弱体化を伴わない。逸脱が必要になったらそのタスクだけ blocked にして続行。

**共有ファイル lane**（Invariant 1 運用）: `skills/harness-work/` / `skills/breezing/` / `agents/*.md` を編集するタスクは **prose lane として直列**: 92.5.3 → 88.1 → 88.3 → 72.1.2 → 72.1.3 → 72.1.4 → 72.1.5 → 72.1.6。Go core lane（92.5.1-2 / 92.6.x / 95.1.x / 95.2.x / 96.1.x）とは並列可。93.3.1 / 93.3.4 も breezing/review SKILL を触るため prose lane タスクとは同時実行しない。`Plans.md` / `CHANGELOG.md` / `spec.md` は worker 編集禁止（Lead が統合時に編集）。

**推奨 wave 順**（Depends 整合済み）: W1: 93.1.1 ∥ 93.1.2 ∥ 93.2.1 ∥ 83.7 → W2: 93.3.1 → (93.3.2 ∥ 93.3.4) → 93.3.3 → 93.3.5 → W3: 92.5.1 → 92.5.2 → 92.5.3 → W4: 92.6.1 → 92.6.2 → (92.6.3 ∥ 92.6.4) ∥ prose lane（88.1 → 88.3 → 72.1.2-72.1.6） → W5: (95.1.1 → 95.1.2 → 95.1.3) ∥ (95.2.2 → 95.2.1) → 95.2.3 → 95.4.1 → W6: (96.1.1 ∥ 96.1.4) → 96.1.2 → 96.1.3

**終了条件**: 実装セクション全タスクが `cc:done` または `blocked(理由)`。最終報告 = 全 commit hash + blocked 一覧 + 検証セクション（93.3.6 → 95.5.1 → 96.1.5 → 96.1.6）への引き継ぎ手順。

---

## Phase 132 — 無人実行を止めない guardrail 調整（2026-08-10）

**Purpose**: `/breezing` などの無人実行が確認ダイアログで停止する事象を、実測に基づいて解消する。
全 3,099 セッションのログをルール出力文言で走査した結果、停止機構の発火数は R04（`Write outside the project root`）が 1,099 件で最多。
その内訳は `~/.claude/projects/<slug>/memory/` が 299 件、`~/.claude/plans/` が 14 件で、**いずれもエージェント自身の状態ディレクトリ**への書き込みだった。
`/private/tmp` 系 271 件は Phase 126.3 で解消済み。残る `~/.claude` 配下がこの Phase の対象。

**判断軸**: 人が承認し続けた `ask` は制御ではない。299 回連続で承認された確認は、残りの確認の信号価値を下げるノイズである。

| Task | 内容 | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 132.1 | `[lane:gate]` `[tdd:required]` `[security]` R04 agent-state skip: CC 管理下のエージェント状態ディレクトリ（`<home>/.claude/projects/*/memory/**` と `<home>/.claude/plans/**`）への Write/Edit/MultiEdit を approve に変更する。`go/pkg/shellscan/` に `IsAgentStatePath` を新設し、`rules.go` の R04 呼び出し点（`IsAllowlistedTempPath` チェック直後、`ctx.WorkMode` skip の手前）でのみ参照する。**`allowlistedTempRoots` には追加しない**（`runtimefloor.go:537` の worktree-escape 判定と共有しており、拡張するとその床まで緩む）。slug は任意にマッチさせる（memory の slug は `ctx.ProjectRoot` から導出できず、実際に別 slug へ書く運用が存在する） | (a) RED: `~/.claude/projects/<any-slug>/memory/x.md` への Write が現行 ask になる実測記録 → 修正後 approve, (b) negative test: `~/.claude/settings.json` / `~/.claude/skills/x/SKILL.md` / `~/.claude/agents/` / `~/.claude/commands/` / `~/.claude/hooks/` / `~/.claude/plugins/` が approve に**ならない**, (c) 接頭辞衝突 test: `~/.claude/plans-backup/x.md` と `~/.claude/projects/<slug>/memory-extra/x.md` が対象外, (d) symlink 解決後の形でも判定される（temproots と同様に original / resolved 両形で比較）, (e) `~/Documents` 等プロジェクト外への Write は従来どおり ask の非退行, (f) `cd go && go test ./...` PASS + gofmt/vet clean, (g) Spec delta: auto-approve scope 節へ agent-state 例外を追記 | - | cc:done [62f86eb1; RED 実測: ~/.claude/projects/<slug>/memory/note.md が ask → 実装後 approve。negative 3 種 (settings/skills 等の behavior dir、plans-backup と memory-extra の接頭辞衝突、symlinked home) すべて PASS。go test ./... 47 pkg PASS / 0 FAIL、gofmt+vet clean。レビューで既存テスト 1 件の期待値誤りを発見・訂正 (下記)] |
| 132.2 | `[lane:fast]` `[tdd:skip:docs-only]` 132.1 の例外を docs に反映する。Phase 126.3 が書いた「WorkMode バイパスとの併存関係」の記述へ agent-state 例外を追加し、除外対象（settings/skills/agents/commands/hooks/plugins）を明記する。`scripts/ci/check-consistency.sh` が guardrail 記述を pin していないか確認し、pin していれば同 commit で更新する | (a) 該当 docs に agent-state 例外と除外対象が記載, (b) `bash scripts/ci/check-consistency.sh` PASS, (c) `bash tests/validate-plugin.sh` PASS | 132.1 | cc:done [62f86eb1; docs/runtime-floor-secret-allowlist.md の R04 節に agent-state 例外を追記。あわせて「/work や /breezing では WorkMode が skip する」という既存記述が事実に反することを実測で確認し訂正した] |
| 132.3 | `[lane:gate]` `[tdd:required]` `WorkMode` を実際に配線する。**現状 `ctx.WorkMode` を立てる経路が 2 つとも死んでいる**: (a) `HARNESS_WORK_MODE` / `ULTRAWORK_MODE` env を設定する箇所が skills / scripts / hooks に皆無、(b) `state.SetWorkState` の呼び出し元が自パッケージ外にゼロ (2026-08-10 実測)。`/work` と `/breezing` の run 中だけ work mode を立て、run 終了時 (成功・失敗・中断の全経路) に解除する。**設計判断が必要**: skill は env を設定できないため SQLite 経路を使うことになるが、skill 側が session ID をどう取得するかが未解決 (`bin/harness session declare` 等の既存 surface が解決済みなら流用する) | (a) RED: `/breezing` 相当の run 中に R04 対象の書き込みが ask になる実測記録 → 配線後 approve, (b) run 終了の 3 経路すべてで解除されることの test, (c) 別セッションの work state を誤って読まないこと (session ID 一致) の test, (d) `cd go && go test ./...` PASS, (e) 配線後、ユーザースコープの `HARNESS_WORK_MODE=1` を外しても breezing が止まらないことを実走で確認 | 132.1 | cc:TODO |

**Spec delta**: `spec.md` の guardrail auto-approve scope に「CC 管理のエージェント状態ディレクトリ（memory / plans）は R04 の確認対象外。設定・能力ディレクトリ（settings / skills / agents / commands / hooks / plugins）は対象のまま」を追記する。R04 の判定範囲が変わるため product contract 側の更新が要る。

**この Phase に含めない（理由つき）**:

- **worker で `WorkMode` が立つかの検証**: `WorkMode` は `SessionID` で SQLite を引く実装のため、独立 session ID を持つ worker では立たない疑いがある。ただし hook 由来 `ask` が `bypassPermissions` の worker を実際に止めるかが未確定で、公式ドキュメントにも記述がない。**breezing 実走 1 本の実測で確定してから起票する**（推測で例外を足すと不要な緩和を残す）
- **`runtimefloor.secretReadVerbs` への `awk` / `jq` 追加**: 実在する穴（`jq . creds.json` は現状素通り）だが、これは**停止を増やす**変更であり、無人実行の摩擦を減らすという本 Phase の目的と逆向き。誤検知の実測（1 週間の試用中）が出てから別 Phase で判断する
- **CCH の permissions 配布経路（Plan A / Plan B）**: operator が「ローカルで運用してから判断」として保留中

**終了条件**: 132.1 / 132.2 が `cc:done`。稼働中セッションへの反映にはリリースとプラグイン更新が必要なため、本 Phase の完了は「コードが main に入ること」までとする。

---


## Archived Phases

Phase 125-131 (2026-07-26 〜 2026-08-08、全 task `cc:done`) は
[.claude/memory/archive/Plans-2026-08-08-phase125-131.md](.claude/memory/archive/Plans-2026-08-08-phase125-131.md) に退避。
Phase 130 は task 表として起票されず、CHANGELOG `[Unreleased]` にのみ記録。

Phase 119-124 (2026-07-19 〜 2026-07-25、全 task `cc:done`) は
[.claude/memory/archive/Plans-2026-07-30-phase119-124.md](.claude/memory/archive/Plans-2026-07-30-phase119-124.md) に退避。
それ以前は `.claude/memory/archive/Plans-*.md` を参照。

現在、進行中の Phase はない。

---
