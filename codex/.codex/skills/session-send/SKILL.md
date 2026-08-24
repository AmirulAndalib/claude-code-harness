---
name: session-send
description: "This skill should be used when the user asks to notify other session, requests a session handoff, says tell other agent, or needs a cross-session message."
description-en: "This skill should be used when the user asks to notify other session, requests a session handoff, says tell other agent, or needs a cross-session message."
description-ja: "他のセッションに知らせる、セッション間連絡、引き継ぎを送る、と依頼されたときに使用する。"
allowed-tools: ["Bash"]
---

# Session Send

確定した事実を別セッションのエージェントへ送る。

## 1. 宛先の確認

まず稼働中のセッションを一覧し、相手の `team` と `agent` を確認する。

```bash
bin/harness session list
```

表示された値から宛先を選ぶ。名前が似ていても推測で送らない。

自分の送信元は、Phase 141.3 の hook が書き出す環境変数から取得する。

```bash
team="${HARNESS_LIVEMSG_TEAM:?HARNESS_LIVEMSG_TEAM is not set}"
from_agent="${HARNESS_LIVEMSG_AGENT:?HARNESS_LIVEMSG_AGENT is not set}"
```

## 2. 送信

確認した宛先へ次の形式で送る。本文は最後の positional 引数にする。

```bash
bin/harness inbox send \
  --team <team> \
  --from <自分のagent> \
  --to <相手のagent> \
  --subject "<件名>" \
  "<本文>"
```

自分の値を環境変数から渡す場合は次の形にする。

```bash
bin/harness inbox send \
  --team "$team" \
  --from "$from_agent" \
  --to <相手のagent> \
  --subject "<件名>" \
  "<本文>"
```

## 3. 送ってよいものの判断基準

送る:

- 完了通知
- これから触る場所の宣言
- 引き継ぎ

送らない:

- 作業中の相談
- 推測
- 未検証の主張

根拠: CooperBench の測定では、同一ファイルを 2 エージェントが触ると成功率が単独の約半分に落ち、失敗の 63% が相手の変更についての誤った思い込みから来ていた。だから「確定した事実」だけを送る。
