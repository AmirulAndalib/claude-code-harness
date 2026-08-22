# Codex Provider Setup Policy

最終更新: 2026-08-22

この文書は Codex `0.123.0` で追加された provider と model metadata、および Codex `0.130.0` stable で明確化された Bedrock 認証の扱いを、Harness の Codex setup guidance として固定するためのものです。

## ひとことで

Harness は Codex の provider 選択を案内しますが、配布用 `config.toml` で `model` や `model_provider` を勝手に固定しません。

## たとえると

Codex 本体は、駅の改札機です。
Harness は、どの改札へ向かえばよいかを書いた案内板です。
案内板が改札機そのものを作り直すと、駅側の改修に追従できなくなるためです。

## 公式参照

- OpenAI Codex `rust-v0.123.0` release: <https://github.com/openai/codex/releases/tag/rust-v0.123.0>
- OpenAI Codex `rust-v0.130.0` stable release: <https://github.com/openai/codex/releases/tag/rust-v0.130.0> (published `2026-05-08T23:09:55Z`)
- Codex Amazon Bedrock provider PR: <https://github.com/openai/codex/pull/18744>
- Codex config basics: <https://developers.openai.com/codex/config-basic>
- Codex config reference: <https://developers.openai.com/codex/config-reference>
- Codex models and ChatGPT-sign-in retirement guidance: <https://developers.openai.com/codex/models>
- Amazon Bedrock OpenAI model docs: <https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-openai.html>

## 対象と判断

| 項目 | 用途 | Harness 判断 |
|------|------|--------------|
| `amazon-bedrock` | Codex の built-in Amazon Bedrock provider | Codex `0.123.0` 以降の標準 provider として案内する |
| `model_provider` | Codex が使う provider を選ぶ設定 | Bedrock を使う人だけが user / project config で設定する。Harness 配布 default には入れない |
| `model_providers.amazon-bedrock.aws.profile` | AWS profile を選ぶ設定 | 認証情報は AWS 側に置き、Harness は profile 名の例だけ示す |
| `aws login` / console-login credentials | AWS console-login credential を AWS profile 経由で使う認証経路 | Codex `0.130.0` stable の Bedrock auth として案内する。Harness は credential 本体を書かない |
| `model` | Codex が使う model を固定する設定 | 再現性が必要な時だけ user / project config で指定する。Harness setup default では固定しない |
| `gpt-5.4` / `gpt-5.4-mini` | ChatGPT サインイン時に 2026-08-31 で Codex から retire する model | `gpt-5.6-terra` / `gpt-5.6-luna` への移行だけを明示し、配布 config の default には固定しない |
| Claude Code Bedrock guidance | Claude Code 側で Bedrock / Vertex / custom gateway を扱う設定 | Codex の `amazon-bedrock` provider と混ぜない。Claude 側は `CLAUDE_CODE_USE_BEDROCK` や Anthropic model overrides の領域 |

## Codex `amazon-bedrock` provider

Codex `0.123.0` では、`amazon-bedrock` が built-in provider になりました。
以前のように、Bedrock 用の provider 定義全体を `config.toml` にコピーする必要はありません。

Bedrock を使う user / project だけが、次のように provider と AWS profile を設定します。

```toml
model_provider = "amazon-bedrock"

[model_providers.amazon-bedrock.aws]
profile = "codex-bedrock"
```

この例の `codex-bedrock` は AWS profile 名です。
実際の profile 名、AWS region、認証情報は、各環境の AWS 設定に合わせます。
Harness は AWS credential、temporary token、secret key を書き込みません。

Codex `0.130.0` stable (`rust-v0.130.0`, published `2026-05-08T23:09:55Z`) では、Bedrock auth が `aws login` profile の AWS console-login credentials を使えるようになりました。
Harness の扱いは変えません。

- `aws login` や AWS console-login credential の実行・保存は AWS 側の責務。
- Harness は profile 名の置き場所だけを示し、AWS access key、secret key、session token、console-login cache を生成・コピー・保存しない。
- `codex/.codex/config.toml` の配布 default では `model_provider = "amazon-bedrock"` を有効化しない。
- Bedrock を使う project / user だけが、自分の config で `model_provider` と profile を明示する。

つまり、console-login credentials は「AWS profile の中身」として扱い、Harness の template や setup は credential material に触れません。

## Model default and migration policy

The official Codex models guidance states:

> GPT-5.4 and GPT-5.4 mini retire from Codex with ChatGPT sign-in on August 31, 2026.
> If you sign in with ChatGPT, replace `gpt-5.4` with `gpt-5.6-terra` and `gpt-5.4-mini` with `gpt-5.6-luna`.
> The OpenAI API and Codex authenticated with your own API key aren't affected.

Harness の方針:

- 未指定の config は provider/account/CLI recommended model を継承し、固定の gpt-5.4 default は仮定しない。
- Harness の配布用 `codex/.codex/config.toml` は `model` を unset のままにする。
- `scripts/setup-codex.sh` や `$harness-setup codex` は、ユーザーの既存 `model` を勝手に置き換えない。
- model を固定したい場合は、ユーザーが自分の `~/.codex/config.toml` または project `.codex/config.toml` に明示する。
- 古い `gpt-5.2-codex` や `gpt-5-codex` を、現在の推奨 sample として新しく案内しない。

ChatGPT サインインの保存済み設定を移行する明示例:

```toml
# 旧 gpt-5.4 の明示 pin を移行する場合
model = "gpt-5.6-terra"

# 旧 gpt-5.4-mini の明示 pin を移行する場合
model = "gpt-5.6-luna"
```

通常は `model` を省略し、provider/account/CLI recommended model に任せます。
API key 認証の Codex は GPT-5.4 retirement の影響を受けません。

## Claude Code guidance との切り分け

Claude Code 側の Bedrock guidance は、Anthropic model を Bedrock / Vertex / custom gateway 経由で使う話です。
Codex の `amazon-bedrock` provider とは、設定キーと責務が違います。

| ランタイム | 主な設定 | Harness の扱い |
|------------|----------|----------------|
| Codex CLI | `model_provider = "amazon-bedrock"`、`[model_providers.amazon-bedrock.aws]` | Codex setup guidance として案内する |
| Claude Code | `CLAUDE_CODE_USE_BEDROCK`、`ANTHROPIC_DEFAULT_*`、`modelOverrides` | Claude Code / Anthropic model guidance として扱う |

両方を同じ repository で使う場合でも、設定は混ぜません。
Codex の provider を変えても、Claude Code の Bedrock mode が自動で有効になるわけではありません。
Claude Code の Bedrock 設定を変えても、Codex の `model_provider` は自動では変わりません。

## Verification record

2026-08-22 に、公式 Codex models guidance と配布設定の model policy を確認しました。

```bash
rg -n "gpt-5\\.2-codex|gpt-5-codex|gpt-5\\.1|codex-mini|gpt-5\\.3-codex|gpt-5\\.4" \
  docs skills codex skills-codex scripts tests templates .claude-plugin opencode .agents -u
```

判断:

- `gpt-5.4` / `gpt-5.4-mini` は ChatGPT サインイン向けの移行元識別子としてのみ残す。
- ChatGPT サインインの明示 pin は `gpt-5.6-terra` / `gpt-5.6-luna` に移行する。
- API key 認証は GPT-5.4 retirement の対象外として案内する。
- 新しい setup guidance では、配布 config に固定 model を追加しない。

## Why this way

Provider と model metadata は、Codex 本体が runtime で判断する領域です。
Harness が配布設定で固定すると、Codex 側の model catalog 更新、provider default、AWS profile support と競合しやすくなります。

そのため Harness は、使うべき設定キーと注意点を説明し、必要な人だけが user / project config に明示する形を取ります。
これが一番、Codex 本体の改善を自然に受け取りやすいからです。
