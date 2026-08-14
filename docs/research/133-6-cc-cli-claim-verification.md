# 133.6 — CC CLI Claim Verification (subagent depth/concurrency + sandbox masking)

## 目的

先行 research agent が WebFetch 経由の要約で報告した 2 クラスタの CC CLI 機能について、
一次情報 (raw CHANGELOG.md) を直接 fetch し、リテラル一致で確認する。

## 一次情報

`https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`

**取得方法の注記**: WebFetch ツール自体は内部で小型モデルによる要約を行うため、
それ単体では二次情報と実質的に同じ (幻覚のリスクがある)。今回は WebFetch の要約結果を、
`curl` で取得した raw ファイル (5455 行) への `grep` で独立に裏取りしている。以下の引用は
すべて curl 取得の raw ファイルから確認済み。

## (i) Subagent nested-spawn depth limit + concurrency env var

**状態: `confirmed`**

`CHANGELOG.md` 内、以下のバージョン見出し配下に該当行を確認:

- **`## 2.1.217`**:
  > Added a cap on concurrently-running subagents (default 20, override with `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`) so one message can't fan out unbounded background agents

  > Changed subagents to no longer spawn nested subagents by default; set `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` to allow deeper nesting

- **`## 2.1.219`**:
  > Subagents can now spawn nested subagents up to depth 3 by default (was 1); set CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 to disable nesting

つまり実際の経緯は 2 段階: 2.1.217 でネスト spawn を既定 OFF (depth 1) にしつつ
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` env var を導入 + 同時実行数上限 (既定 20) を
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` で導入。2.1.219 で既定値を depth 3 に緩和。

先行 research agent の報告 (「nested-spawn depth limit + concurrency env var」) は
この 2 バージョンにまたがる実際の変更と一致する。

## (ii) Sandbox credential-masking + strictAllowlist

**状態: `confirmed`**

- **`## 2.1.219`**:
  > Added `sandbox.network.strictAllowlist` setting to deny non-allowlisted hosts for sandboxed commands without prompting

- **`## 2.1.221`**:
  > Added `mode: "mask"` for sandbox credential files on Linux and WSL — sandboxed commands read a sentinel copy (the whole file, or just the spans captured by an `extract` regex) while the sandbox proxy substitutes the real value on egress; on macOS file masking falls back to `deny`

- **`## 2.1.224`**:
  > Added sandbox credential-masking options: `extract` and `onExtractNoMatch` for structured env values, `decode: "jwt"` with `maskClaims` for JWT-aware masking, and `awsPairs`/`sigv4` for AWS SigV4 re-signing; these need `network.tlsTerminate` and are honored only from user, managed, or `--settings` settings

3 バージョンにわたる段階的機能追加: 2.1.219 で `strictAllowlist` (ネットワーク側)、
2.1.221 で credential file の `mode: "mask"` (macOS では `deny` にフォールバック)、
2.1.224 でさらに JWT / AWS SigV4 対応の構造化 masking オプションを追加。

## 注記: バージョンギャップ

本 repo の `docs/CLAUDE-feature-table.md` が現在追跡している最新版は `2.1.152` 台
(Phase 80)。今回確認できた行は `2.1.217`〜`2.1.224` で、その間の `2.1.153`〜`2.1.216`
は本タスクの検証範囲外 (未確認)。本タスクは 2 件の個別 claim の点検証であり、
フルバージョン同期ではない。

## 検証コマンド

```bash
curl -sL https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md -o /tmp/cc-changelog-raw.md
grep -n "MAX_SUBAGENT\|CONCURRENT_SUBAGENT\|SUBAGENT_SPAWN" /tmp/cc-changelog-raw.md
grep -ni "strictAllowlist\|credential.mask\|maskClaims" /tmp/cc-changelog-raw.md
```

## 分類 (Feature Table 反映方針)

`docs/rules/cc-update-policy.md` は Feature Table 追加を A (実装あり) / C (CC 自動継承)
のいずれかに紐付けることを要求する。本タスクは検証のみで実装を伴わないため、
本 repo の既存 addendum セクション (Phase 58/62/69/80 等) が採用している `P: Plans 化`
(今回直接実装せず、後続タスクに引き継ぐ) を用いて Feature Table に追記した。
`B` (書いただけ・実装無しかつ C 明記も無し) には該当しない。
