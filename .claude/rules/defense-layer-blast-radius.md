# Defense Layer Blast Radius

防御層（permissions / guardrail hook / sandbox）を追加・変更するときの影響確認規約。

## なぜこのルールが必要か

2026-08-10、同型の失敗を 1 日に 2 回起こした。どちらも「何を止めるか」だけを設計し、**「止めた結果、誰が通れなくなるか」を確認しなかった**ことが原因。

| 事故 | 入れた設定 | 実際に壊れたもの |
|---|---|---|
| 1 回目 | `sandbox.filesystem.denyRead` に gh CLI の設定ディレクトリを追加 | gh CLI が自分の設定を読めず、git の credential helper が死亡。別セッションの `git push` が約 30 分不通 |
| 2 回目 | `sandbox.enabled: true` | サンドボックス既定の DNS 遮断と SSH 設定の読取拒否により、ssh_config の alias が解決不能。別セッションが本番サーバーへ到達不能 |

2 回目は逃げ道も同時に塞いでいた（`Bash(dangerouslyDisableSandbox:true)` を `ask` から `deny` へ移していた）ため、hard fail になった。

## 層ごとの強制力と影響範囲

| 層 | 強制するもの | 影響が及ぶ範囲 | 誤爆したときの被害 |
|---|---|---|---|
| `permissions.deny` / `ask` / `allow` | Claude Code のツール呼び出し | **agent のみ**。agent が起動した子プロセスは無関係 | agent が特定操作をできなくなる。外部ツールは無傷 |
| guardrail hook（R01-R13 / runtime floor） | PreToolUse で agent のツール呼び出しを裁定 | **agent のみ**。判定はコマンド文字列への照合 | agent の作業が止まる。文字列マッチなので誤検知しやすい |
| `sandbox`（Seatbelt / OS 隔離） | プロセスのファイル・ネットワークアクセス | **OS がプロセスツリー全体に強制**。agent が起動した任意のプログラムに及ぶ | 無関係な CLI・デーモン・サブプロセスが動かなくなる |

## 原則: 強制力が強い層ほど、適用範囲を狭くする

`permissions.deny` の誤爆は agent に閉じる。`sandbox` の誤爆はマシン上の任意のプロセスに及ぶ。**同じ「読み取り禁止」でも、どの層に置くかで事故の大きさが桁違いになる。**

したがって:

- 秘密ファイルの読み取り防止は、まず `permissions.deny` の `Read(...)` で行う
- Bash 経由を塞ぐ必要があれば guardrail の runtime floor を使う
- `sandbox.filesystem` に落とすのは、上 2 層で足りないと判明したときだけ
- 資格情報のマスクが目的なら `sandbox.credentials`（専用機構）を先に検討する。粗い `denyRead` で代用しない

## 追加前の必須チェック

防御を 1 つ足すごとに、次を書き出してから適用する。

1. **この設定を正当に読む既存プロセスは何か。** 設定ディレクトリ単位で塞ぐと、そのディレクトリを毎回読む本人（CLI 本体）まで巻き添えになる。`~/.config/gh` は設定と資格情報の混在ディレクトリで、gh CLI が毎回読む。同じ罠が `~/.npmrc`(npm) / `~/.ssh`(SSH 経由の git) / `~/.docker/config.json`(docker) / `~/.aws` / `~/.fly` / `~/.vercel` / `~/.wrangler` / `~/.kube` にある。
2. **秘密そのものか、秘密を含む設定か。** 前者はファイル単位で塞げる。後者はディレクトリごと塞ぐと道具が止まる。
3. **default-deny の層では、書いていないものが壊れる。** サンドボックスのネットワークは既定全拒否で、DNS も含まれる。「何を許可し忘れたか」を点検しないと事故が読めない。
4. **逃げ道を同時に塞いでいないか。** 新しい遮断を入れるときに `dangerouslyDisableSandbox` のような安全弁を `deny` へ動かすと、設定に穴があったときに復旧手段が無くなる。片方ずつ入れる。
5. **既存ドキュメントがその設定について何を言っているか。** 例: `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` は codex 子プロセスの 1 時間 prompt cache を壊すと `skills/breezing/SKILL.md` が明記していた。新しい設定を調べる前に、手元の repo を検索するほうが速い。

## `excludedCommands` はサブプロセスに継承されない

`sandbox.excludedCommands` は**起動されたコマンド名にのみ一致**する。そのコマンドが起動する子プロセスには適用されない。

```
git push            ← git は excludedCommands に無い → サンドボックス内
  └─ gh (credential helper として起動)
       └─ 親のサンドボックスを継承 → gh が excludedCommands にあっても無効
```

`gh` を単体で叩けば通るのに、`git` 経由だと落ちる。**制限は継承され、免除は継承されない**という非対称を前提に設計する。

## 段階適用: user scope へ入れる前に 1 プロジェクトで検証する

ユーザースコープ（`~/.claude/settings.json`）は全プロジェクト・全セッションに一斉に効く。間違いも一斉に展開される。

外部プロセスに影響しうる設定は、この順で入れる。

1. 対象 1 プロジェクトの `.claude/settings.json` に入れる（壊れてもそのリポジトリだけ）
2. そこで `git push` / `npm install` / `ssh` など、実際に使う経路を通して確認する
3. 問題なければユーザースコープへ昇格する

何も遮断しない設定（`autoMode.environment` のような判定役への情報提供）は、この手順を通さなくてよい。壊しようがないため。

## PROPOSAL (未適用・提案のみ): credential-masking による denyRead 代替の検討候補 (133.6)

CC CLI `2.1.221`/`2.1.224` で追加された sandbox credential file `mode: "mask"` (一次情報:
raw CHANGELOG.md、`docs/research/133-6-cc-cli-claim-verification.md` で確認済み) は、
上記 2 事故がいずれも「設定とシークレットが同居するディレクトリを丸ごと `denyRead`」した
ことが原因である以上、値単位 masking という**目的に合った専用機構**である可能性がある。

ただし CHANGELOG 原文に「macOS ではファイル masking は `deny` にフォールバックする」と
明記されており、上記 2 事故はいずれも macOS 実行環境。**この提案の実効性は Linux/WSL
限定の可能性が高く、macOS 運用がメインの本 repo では未検証のまま「追加前の必須チェック」
のデフォルト選択肢には昇格させない。** 詳細な機能比較と未検証事項は
`docs/sandbox-allowlist-recipe.md` の PROPOSAL セクションを参照。本ファイルの本文・
チェックリストは今回変更していない (提案の記録のみ)。

## 関連

- [`CLAUDE.md` — Permission Boundaries](../../CLAUDE.md)
- [`docs/sandbox-allowlist-recipe.md`](../../docs/sandbox-allowlist-recipe.md) — サンドボックス allowlist の設定手順
- [`docs/runtime-floor-secret-allowlist.md`](../../docs/runtime-floor-secret-allowlist.md) — runtime floor と R04/R05 の適用範囲
- [`.claude/rules/self-audit.md`](self-audit.md) — deny 面の減少検知
