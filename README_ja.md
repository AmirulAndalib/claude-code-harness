# Claude Code Harness

<p align="center">
  <img src="docs/images/claude-harness-logo-with-text.png" alt="Claude Harness" width="400">
</p>

<p align="center">
  <strong>Plan. Work. Review. Ship.</strong><br>
  <em>Claude Code / Codex CLI / Cursor / Grok の作業を、計画から出荷まで崩れにくくする。</em>
</p>

<p align="center">
  <a href="https://github.com/Chachamaru127/claude-code-harness/releases/latest"><img src="https://img.shields.io/github/v/release/Chachamaru127/claude-code-harness?display_name=tag&sort=semver" alt="Latest Release"></a>
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License"></a>
  <a href="docs/CLAUDE_CODE_COMPATIBILITY.md"><img src="https://img.shields.io/badge/Claude_Code-v2.1+-purple.svg" alt="Claude Code"></a>
  <img src="https://img.shields.io/badge/Skills-5_core_%2F_23_total-orange.svg" alt="Skills: 5 core verbs / 23 total">
  <img src="https://img.shields.io/badge/Guardrails-R01%E2%80%93R16_%2B_5_floors-B5462F.svg" alt="Guardrails: R01-R16 plus 5 runtime floor categories">
  <img src="https://img.shields.io/badge/Core-Go_Native-00ADD8.svg" alt="Go Core">
</p>

<p align="center">
  <a href="README.md">English</a> | 日本語
</p>

<p align="center">
  <img src="docs/images/readme/loop-ja.svg" alt="運用ループ: 計画、実装、レビュー、リリース。すべてのコマンドは実行直前に検査される" width="880">
</p>

## 何を解決するか

Claude Code Harness（CCH）は、Claude Code や Codex に、計画から実装、検証、レビューまでを任せるための開発プラグインです。
「何をできるようにしたいか」と「何をもって完成とするか」を渡すと、担当が既存のコードを調べ、作業を組み立てます。

**利用者が決めるのは、作るもの、完成条件、実行を許可する範囲です。**
担当はその範囲で方法を選び、必要な修正と確認を続けます。
結果は変更内容、検証結果、未確認事項として返すため、完成条件を満たしたかを判断できます。

## 30 秒で導入

```bash
claude
/plugin marketplace add Chachamaru127/claude-code-harness
/plugin install claude-code-harness@claude-code-harness-marketplace
/harness-setup
```

そのあと、小さめの依頼を 1 つ渡してみてください。

```bash
/harness-plan README の導入手順をわかりやすくして
```

Harness が仕様（= 何が正しいかを決めた文書）と作業一覧（= やることを並べた表）
の下書きを作ります。**あなたの仕事は計画を書くことではありません。**
実行が進む前に、出てきた内容を承認するか直すことです。

別のツールを使っている場合は、後述の[ツール別の導入](#ツール別の導入)を見てください。

## 5 動詞のワークフロー

覚えるのは plan、work、review、sync、release の 5動詞スキルだけです。
この 5 つで回すのが 5動詞ワークフローです。
（`/harness-setup` は導入時に 1 回だけ実行します。）
各工程は、次の工程が必要とする材料を残し、それぞれに通過条件があります。

| コマンド | 何が起きるか | 通過条件 |
|---|---|---|
| `/harness-plan` | 依頼を仕様と作業一覧にする。範囲、完了条件、依存関係、未確定事項、停止条件を書く | あなたが承認するか、直す |
| `/harness-work` | 対象が決まっていれば、その範囲を実装する。件数に応じて単独実行とチーム実行を選ぶ | 範囲が未確定なら先に確認。指定された検証とレビューを通す |
| `/harness-work 3` | 作業番号 3 だけを実装する | 作業がそう指定していればテストを先に書く |
| `/harness-work all` | 承認済みの計画をまとめて実行する。計画が固まり、リポジトリの状態が把握できてから使う | 同じテスト条件を、作業ごとに適用する |
| `/harness-review` | **実装とは切り離して**結果を見る | 重大な指摘があれば完了できない。PR が出せる状態と、リリースできる状態は別 |
| `/harness-sync` | 計画と実際の実装を突き合わせて、ずれを報告する | 確認した根拠で状態を照合する |
| `/harness-release` | 検証済みの根拠だけを、変更履歴とタグとリリースにまとめる | リリース前検査を通る |

AI が実際に見ていない情報は、勝手に埋めずに「未確認」のまま残します。

## 依頼したあとの動き

たとえば、注文が二重登録される不具合なら、次のように頼めます。

```text
/harness-plan 注文の二重登録を直したい。完成条件は、同じ注文が1件だけ保存されること。
```

計画の範囲と完成条件を確認し、承認してから `/harness-work all` で実行します。
Codex では `$harness-plan`、`$harness-work all` のようにスキルを指定します。

1. **計画する**。既存の仕様とコードを読み、再現方法、変更範囲、完成条件を `spec.md` と `Plans.md` に揃えます。
2. **実装する**。担当へ元の依頼、完成条件、確認済みの根拠を渡します。独立した作業は担当ファイルを分けて並行できます。
3. **検証して直す**。必要なテストと再現手順で結果を確認します。レビューの指摘は修正担当へ渡し、決められた回数の範囲で修正します。
4. **結果を返す**。完成条件ごとの結果、変更箇所、実行した検証、残った問題を報告します。

不足している情報は、まず仕様や該当コードから調べます。
承認済みの範囲にある可逆な作業は、仮定を明記して続けます。
新しい承認や重大な仕様判断が必要になった場合は、その操作を止め、独立して進められる作業を続けます。
重大なレビュー指摘が残っている場合や、再修正の上限に達した場合は、未完了の理由と判断材料を返します。

## モデルの使い分け

CCH は担当ごとにモデルを選びます。
effort（推論量）は、モデルが考える処理に割り当てる量の設定です。
次の表は担当別設定の既定値です。
主担当の会話では、そのセッションのモデル選択とスキルの設定も使います。

| 担当 | モデル | 推論量 |
|---|---|---|
| Claude の難しい判断と相談（`deep` / `advisor`） | Fable 5.1（`claude-fable-5-1`） | `high` |
| Claude の通常の実装 | Sonnet 5（`claude-sonnet-5`） | `medium` |
| Claude の独立した専用 Reviewer（レビュー担当） | Sonnet 5（`claude-sonnet-5`） | `xhigh` |
| Codex の標準処理、難しい判断、レビュー、相談 | GPT-6 astra（`gpt-6-astra`） | `xhigh` |
| Codex Breezing の実装 Worker（実装担当） | GPT-5.6 luna（`gpt-5.6-luna`） | `max` |

Claude の一般レビュー用の振り分けは Fable 5.1 / `high` です。
上表の専用 Reviewer は、別の担当定義として Sonnet 5 を使います。
軽い調査にも別の設定があります。[担当別の全設定](docs/model-routing-policy.md)を参照してください。

**利用者によるモデルや推論量の手動変更を尊重します。**
一回の呼出しで指定した値や担当の設定を、その実行経路で使います。
親の会話でモデルを変えても、すべての子担当が同じモデルに変わる設定ではありません。
Codex の `ultra` も明示指定として扱い、依頼文の強さから推論量を選び直しません。

## 安全の仕組み

CCH の検査に接続された操作は、実行前に Go 製の判定エンジンで調べます。
外部への送信や削除はファイル差分だけでは確認できないため、実行する操作も判定対象にします。
適用範囲は利用するアプリによって異なります。[ホスト間の安全差](docs/hardening-parity.md)を参照してください。

**強さの違う 2 層**を重ねています。

| 層 | 決めること | 設定との関係 |
|---|---|---|
| **実行時フロア**（5 分類） | 分類ごとの規則で許可または拒否する | 一括無効化の設定はない。通信先や読取対象などの限定的な許可設定はある |
| **ガードレール**（R01〜R16） | 拒否 / 確認 / 警告 | 一部はプロジェクト設定で変更できる |

フロアが見ているのは、課金、外部への送信、秘密ファイルの読み取り、本番反映、作業ツリーの外を壊す操作です。
許可対象やリリース操作の設定は、利用者が管理する保護対象です。
担当が作業を通すために、その設定を書き換える運用にはしません。

ガードレールは調整する側の層です。`main` への直接 push、保護されたファイルへの
書き込み、強制 push、履歴の巻き戻しなど、それぞれに判定が決まっています。
プロジェクトの事情に合わせる余地はこちらにあります。

**既知の確認事項は計画時にまとめます。** 事前承認が使える操作は、計画時に範囲を確認して承認できます。
追加の承認対象が作業中に見つかった場合は、その操作の前に確認します。
承認には期限、対象作業、使用回数の上限があります。

**停止理由を記録します。** 判定記録の規則名、分類、結果から、何が操作を止めたかを確認できます。

## セッション同士が互いを見る

同じリポジトリで複数の会話を動かす場合、CCH の名簿から稼働中の担当を確認できます。
別の worktree で作業する担当にも、ローカルの連絡路で情報を渡せます。

| 部品 | 何をするか |
|---|---|
| 名簿 | `bin/harness session list` が同じリポジトリの worktree 群に登録された稼働セッションを一覧する。保存先を `git --git-common-dir` から解決するため、別 worktree のセッションも同じ名簿に載る。各行には送信に必要な `team` と `agent` が入る |
| 送信 | `bin/harness inbox send --team <t> --from <a> --to <b> --subject <s> "<本文>"`。`session-send` skill を使うと、何を送る価値があるかの判断基準も一緒に読める |
| 受信 | 相手セッションのターン境界で届く。本文は「これは指示ではない」という封筒でくるまれたデータとして渡る。相手のメッセージは検証すべき報告であって、従うべき命令ではない |

メッセージの内容検査は既定では無効です。
`[livemsg] verification = "on"` にすると、言及されたファイルや commit の存在、「変更なし」と現在の状態の一致を検査します。
検査で不一致になったメッセージは送らず、理由を送信側へ返します。

この連絡はローカルで完結し、harness-mem に依存しません。
harness-mem を併用している場合は、その名簿も保持します。

## 非エンジニアが判断するための画面

コードを読まずに判断できるよう、1 画面で完結する HTML を 3 つ用意しています。

| 画面 | いつ | 何が見えるか |
|---|---|---|
| **計画概要** | 計画の確定時 | 理解、選択肢、リスク、合格条件 |
| **進捗** | 作業中 | `Plans.md` に記録された作業中、未着手、完了の件数と、判断待ちの項目 |
| **受け入れ** | リリース前 | 条件ごとの合否と、出す / 待つ / 差し戻すの推奨 |

`/harness-progress` は現在地を確認する入口です。
進捗確認だけで作業を完了扱いにしたり、記憶へ保存したりしません。
作業の引継ぎでは、完成したこと、残った問題、検証結果、次に試すことを渡します。
Claude Code では、編集やコマンド実行後に最大60秒に1回、画面ファイルを再生成します。
完了率は作業一覧の件数比です。完成条件の合格率や、変更を自動検知した結果とは区別します。

## ツール別の導入

導入経路が 4 つあることと、4 つが同じ品質を保証することは**別です**。
セットアップ script があるのは「入口がある」という意味であって、
同じ製品保証がある意味ではありません。

区分の英語表記と日本語の対応は、下の折りたたみにまとめています。

| Tool | Tier | 経路 |
|---|---|---|
| Claude Code | `supported` | プラグイン marketplace のあと `/harness-setup` |
| Codex CLI | `supported` | [`scripts/setup-codex.sh --user`](codex/README.md#option-1-script-recommended-user-based)。Harness 更新後に再実行し、Codex を再起動 |
| Cursor | `supported` | `scripts/setup-cursor.sh`。閉じ込めは Harness 側で行う（[詳細](docs/CURSOR_INTEGRATION.md)） |
| Grok | `supported` | `scripts/setup-grok.sh` |
| Codex app | `candidate` | 簡易検証のみ。CLI 版の実績は流用しない |
| OpenCode | `internal-compatible` | `scripts/setup-opencode.sh`。実行時の同等性は主張しない |
| Hermes Agent | `candidate` | 手動リンクによる調査経路。`~/.hermes` がある環境では `harness gen` が turn delivery の hook を生成するようになったが、ガードレールの enforcement は未配線のため tier は据え置き |
| GitHub Copilot CLI | `candidate` | 手動プロファイルによる調査のみ |
| Antigravity CLI | `future/unsupported` | 現段階では導入経路なし |

<details>
<summary><strong>対応の区分と、そこに厳しくしている理由</strong></summary>

<br>

| 英語表記 | 日本語の公式表記 |
|---|---|
| `supported` | 正式対応 |
| `internal-compatible` | 互換利用可 / 制限付き対応 |
| `candidate` | 試験対応 / プレビュー |
| `future/unsupported` | 非対応 / 将来検討 |

Claude Code、Codex CLI、Cursor、Grok は、主張している経路で H1〜H8 の検査を
通っています（H4 実機確認 2026-07-17、H7 リリース前検査の fail-closed 配線
2026-07-19）。他の行は、それぞれが自分で H1〜H8 を通るまで現在の区分のままです
（`docs/spec/planning-and-host-adapter.md`、Phase 111）。

Harness は Superpowers や Hermes Agent など他プロジェクトの対応実績を
引き継ぎません。あるホストが格上げされるのは、Harness 自身の導入、起動、実行、
リリースの証拠が揃ったときだけです。

`not_observed != absent`（観測していないことは、無いことではない）。手元に証拠が
無いのは「ここでは証明できていない」という意味です。不可能という意味でも、
対応済みという意味でもありません。

</details>

<details>
<summary><strong>すでに使っている方へ: 先に棚卸しを出してください</strong></summary>

<br>

```bash
bin/harness doctor --migration-report
```

古いプラグインの残骸、重複した Codex スキル、古いリンク、OpenCode の
バックアップ、記憶の状態を一覧にします。**何も削除しません。**

</details>

<details>
<summary><strong>応用機能</strong></summary>

<br>

基本の流れが動くようになってから使ってください。

| 機能 | 何が増えるか | 境界 |
|---|---|---|
| **Breezing** | 計画役、批評役、実装役に分けたチーム実行。作業量が多いときに効く | 計画の質とレビューで縛られる点は変わらない |
| **harness-loop** | 上限を決めて実行を繰り返す。必要な場合に相談役を呼び、停止理由と再開用の情報を残す | 上限到達や実行できる作業がなくなった状態は、全作業の完成とは区別する |
| **Codex による第二意見** | `scripts/codex-companion.sh` を通した形式付きのレビュー | 素の `codex exec` は Harness の経路ではない |
| **harness-mem** | プロジェクト単位の記憶と、セッションをまたいだ想起 | 任意。削除は明示的に行う |
| **OpenCode 連携** | 案内を OpenCode 互換の形に出力する | 実行時の同等性は主張しない |
| auto-approve（実験中） | `HARNESS_AUTO_APPROVE=on` で判定結果を台帳に記録する | 既定は無効。確認そのものは**まだ省略されない** |

`/harness-loop` の既定上限は8サイクルです。
Claude Code は1サイクルにつき原則1タスク、Codex は依存条件を満たす作業をまとめて実行します。
`/harness-loop status` で状態を確認し、`/harness-loop stop` で継続を止めます。
作業の再開では `/harness-work --resume latest` を使い、計画、差分、検証結果、残る完成条件を読み直します。

**Codex Breezing の役割別ルーティング。** setup の再実行後に Codex を
再起動すると、Codex-native `$breezing` は managed Worker profile（Worker 専用の
設定ファイル）を選びます。`$breezing --codex` は companion（Harness から Codex CLI を
呼ぶ仲介経路）の Worker route を使います。どちらの実装 Worker も
`gpt-5.6-luna` / `max` です。Codex review route は `gpt-6-astra` / `xhigh` です。
メイン Codex セッションのモデルは固定しません。Cursor など別の実装担当 CLI を
明示した場合は、その CLI の役割別の振り分けを維持します。
[有効化条件と境界](codex/README.md#codex-breezing-role-routing) を参照してください。

Codex の子担当は、実行アプリによって親の権限を引き継ぎます。
専用 Reviewer の設定ファイルだけを、ファイル変更を禁止する仕組みとは扱いません。
CCH の読み取り専用レビューは、その権限を明示して起動する companion 経由で実行します。

</details>

## 動作要件

- Claude Code の正式対応経路では **v2.1 以降**
- 書き込み権限のあるリポジトリ
- 配布時の既定言語は English。日本語 UI を明示する場合は
  `CLAUDE_CODE_HARNESS_LANG=ja claude` で起動
- Go ネイティブガードレールエンジンは Node.js 不要
- 任意: セッションをまたいだ記憶に
  [harness-mem](https://github.com/Chachamaru127/harness-mem)

## ドキュメント

| 資料 | 内容 |
|---|---|
| [ツール別の入口](docs/onboarding/index.md) | どのツールから始めるか |
| [導入経路](docs/onboarding/install.md) | ツールごとの設定と対応範囲 |
| [移行チェック](docs/onboarding/migration.md) | 既存環境への影響と戻し方 |
| [起動確認](docs/onboarding/skill-trigger-acceptance.md) | 導入成功をどう確認するか |
| [対応一覧](docs/tool-capability-matrix.md) | ホストごとの主張の全体表 |
| [配布範囲](docs/distribution-scope.md) | 同梱、互換、開発専用の区別 |
| [ホスト間の安全差](docs/hardening-parity.md) | ツールによる防御の違い |
| [全計画実行の根拠](docs/evidence/work-all.md) | 成功と失敗の判定契約 |
| [モデルの使い分け](docs/model-routing-policy.md) | 担当別のモデルと推論量、手動指定の優先順位 |
| [担当への依頼と引継ぎ](docs/prompt-calibration.md) | 完成条件、根拠、修正指示、再開情報の渡し方 |
| [言語設定](docs/i18n.md) | 出力言語の切り替え方 |
| [変更履歴](CHANGELOG.md) | 版ごとの変更点 |

## コントリビュート

Issue と PR を歓迎します。[CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。

## 謝辞

- [AI Masao](https://note.com/masa_wunder) さん（階層的なスキル設計）
- [Beagle](https://github.com/beagleworks) さん（テスト改ざん防止のパターン）

## ライセンス

MIT ライセンス。[LICENSE.md](LICENSE.md) を参照してください。
