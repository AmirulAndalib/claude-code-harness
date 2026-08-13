#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTER="${ROOT_DIR}/scripts/model-routing.sh"
COMPANION="${ROOT_DIR}/scripts/codex-companion.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

[ -x "${ROUTER}" ] || {
  echo "model-routing.sh must be executable"
  exit 1
}

codex_lite_model="$(bash "${ROUTER}" --host codex --role explorer --field model)"
[ "${codex_lite_model}" = "gpt-5.4-mini" ] || {
  echo "codex explorer must route to gpt-5.4-mini"
  exit 1
}

claude_advisor_effort="$(bash "${ROUTER}" --host claude --role advisor --field effort)"
[ "${claude_advisor_effort}" = "xhigh" ] || {
  echo "claude advisor must route to xhigh"
  exit 1
}

claude_advisor_model="$(bash "${ROUTER}" --host claude --role advisor --field model)"
[ "${claude_advisor_model}" = "claude-opus-5" ] || {
  echo "claude advisor must route to claude-opus-5"
  exit 1
}

cursor_worker_model="$(bash "${ROUTER}" --host cursor --role worker --field model)"
[ "${cursor_worker_model}" = "composer-2.5-fast" ] || {
  echo "cursor worker must route to composer-2.5-fast"
  exit 1
}

cursor_advisor_model="$(bash "${ROUTER}" --host cursor --role advisor --field model)"
[ "${cursor_advisor_model}" = "claude-fable-5" ] || {
  echo "cursor advisor must route to claude-fable-5"
  exit 1
}

cursor_args="$(bash "${ROUTER}" --host cursor --tier review --format args | tr '\n' ' ')"
grep -q -- '--model composer-2.5-fast' <<<"${cursor_args}" || {
  echo "cursor args must include review model"
  exit 1
}

cursor_env="$(bash "${ROUTER}" --host cursor --tier standard --format env)"
grep -q '^CURSOR_MODEL=composer-2.5-fast$' <<<"${cursor_env}" || {
  echo "cursor env must export CURSOR_MODEL"
  exit 1
}

# Grok expectations pin the catalog of the CLI that is ACTUALLY INSTALLED
# (`grok 0.2.118`, verified 2026-08-13 against the account catalog it fetched
# from cli-chat-proxy.grok.com/v1/models). Operator-ratified.
#
# Two earlier expectation sets were wrong the same way: both were derived from
# `grok-cli` (a TypeScript project with the same name) instead of the installed
# Rust `grok`, so they pinned ids that do not exist and every call would have
# failed while this test stayed green. The catalog here is the whole catalog —
# grok-4.6 and grok-4.5, nothing else.
grok_worker_model="$(bash "${ROUTER}" --host grok --role worker --field model)"
[ "${grok_worker_model}" = "grok-4.5" ] || {
  echo "grok worker must route to grok-4.5"
  exit 1
}

grok_advisor_model="$(bash "${ROUTER}" --host grok --role advisor --field model)"
[ "${grok_advisor_model}" = "grok-4.6" ] || {
  echo "grok advisor must route to grok-4.6"
  exit 1
}

grok_reviewer_model="$(bash "${ROUTER}" --host grok --role reviewer --field model)"
[ "${grok_reviewer_model}" = "grok-4.6" ] || {
  echo "grok reviewer must route to grok-4.6"
  exit 1
}

grok_args="$(bash "${ROUTER}" --host grok --tier review --format args | tr '\n' ' ')"
grep -q -- '--model grok-4.6' <<<"${grok_args}" || {
  echo "grok args must include review model"
  exit 1
}

grok_env="$(bash "${ROUTER}" --host grok --tier standard --format env)"
grep -q '^GROK_MODEL=grok-4.5$' <<<"${grok_env}" || {
  echo "grok env must export GROK_MODEL"
  exit 1
}

grok_lite_model="$(bash "${ROUTER}" --host grok --tier lite --field model)"
[ "${grok_lite_model}" = "grok-4.5" ] || {
  echo "grok lite must route to grok-4.5"
  exit 1
}

# 全 tier が実在するモデル ID だけを返すこと (存在しない ID の再発防止)。
grok_known_ids="grok-4.6 grok-4.5"
for tier in lite standard deep advisor review release long-context; do
  m="$(bash "${ROUTER}" --host grok --tier "${tier}" --field model)"
  case " ${grok_known_ids} " in
    *" ${m} "*) ;;
    *) echo "grok tier ${tier} routes to unknown model id: ${m}"; exit 1 ;;
  esac
done

# effort は「モデルごとに」有効な値であること。平坦な許可リストだと、
# grok-4.5 が受け付けない xhigh を取りこぼす。
#   grok-4.6: xhigh | high | medium | low
#   grok-4.5:         high | medium | low
for tier in lite standard deep advisor review release long-context; do
  m="$(bash "${ROUTER}" --host grok --tier "${tier}" --field model)"
  e="$(bash "${ROUTER}" --host grok --tier "${tier}" --field effort)"
  case "${m}" in
    grok-4.6) valid="xhigh high medium low" ;;
    grok-4.5) valid="high medium low" ;;
    *) echo "grok tier ${tier}: cannot validate effort for unknown model ${m}"; exit 1 ;;
  esac
  case " ${valid} " in
    *" ${e} "*) ;;
    *) echo "grok tier ${tier} (${m}) emits effort ${e}, which ${m} does not accept"; exit 1 ;;
  esac
done

codex_args="$(bash "${ROUTER}" --host codex --tier review --format args | tr '\n' ' ')"
grep -q -- '--model gpt-5.6-sol' <<<"${codex_args}" || {
  echo "codex args must include review model"
  exit 1
}
grep -q -- 'model_reasoning_effort="xhigh"' <<<"${codex_args}" || {
  echo "codex args must include xhigh reasoning config"
  exit 1
}

if bash "${ROUTER}" --host codex --tier unknown >/tmp/model-routing-unknown.out 2>/tmp/model-routing-unknown.err; then
  echo "unknown tier should fail"
  exit 1
fi

# --- Fable brain opt-in (HARNESS_BRAIN_MODEL) ---

unset_default_model="$(env -u HARNESS_BRAIN_MODEL bash "${ROUTER}" --host claude --role advisor --field model)"
[ "${unset_default_model}" = "claude-opus-5" ] || {
  echo "unset HARNESS_BRAIN_MODEL must keep claude-opus-5"
  exit 1
}

empty_default_model="$(HARNESS_BRAIN_MODEL= bash "${ROUTER}" --host claude --role advisor --field model)"
[ "${empty_default_model}" = "claude-opus-5" ] || {
  echo "empty HARNESS_BRAIN_MODEL must keep claude-opus-5"
  exit 1
}

fable_advisor_model="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host claude --role advisor --field model)"
[ "${fable_advisor_model}" = "claude-fable-5" ] || {
  echo "HARNESS_BRAIN_MODEL=fable must route claude advisor to claude-fable-5"
  exit 1
}

fable_deep_model="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host claude --tier deep --field model)"
[ "${fable_deep_model}" = "claude-fable-5" ] || {
  echo "HARNESS_BRAIN_MODEL=fable must route claude deep tier to claude-fable-5"
  exit 1
}

fable_advisor_effort="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host claude --role advisor --field effort)"
[ "${fable_advisor_effort}" = "xhigh" ] || {
  echo "fable brain opt-in must keep xhigh effort"
  exit 1
}

opus_explicit_model="$(HARNESS_BRAIN_MODEL=opus bash "${ROUTER}" --host claude --role advisor --field model)"
[ "${opus_explicit_model}" = "claude-opus-5" ] || {
  echo "HARNESS_BRAIN_MODEL=opus must keep claude-opus-5"
  exit 1
}

fable_worker_model="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host claude --role worker --field model)"
[ "${fable_worker_model}" = "claude-sonnet-5" ] || {
  echo "fable brain opt-in must not touch the claude worker tier"
  exit 1
}

fable_reviewer_model="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host claude --role reviewer --field model)"
[ "${fable_reviewer_model}" = "claude-fable-5" ] || {
  echo "fable brain opt-in must not change the primary review tier (fixed at claude-fable-5)"
  exit 1
}

fable_cursor_advisor="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host cursor --role advisor --field model)"
[ "${fable_cursor_advisor}" = "claude-fable-5" ] || {
  echo "fable brain opt-in must not touch the cursor model catalog"
  exit 1
}

fable_codex_advisor="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host codex --role advisor --field model)"
[ "${fable_codex_advisor}" = "gpt-5.6-sol" ] || {
  echo "fable brain opt-in must not touch the codex model catalog"
  exit 1
}

fable_grok_advisor="$(HARNESS_BRAIN_MODEL=fable bash "${ROUTER}" --host grok --role advisor --field model)"
[ "${fable_grok_advisor}" = "grok-4.6" ] || {
  echo "fable brain opt-in must not touch the grok model catalog"
  exit 1
}

opus5_claude_advisor="$(HARNESS_BRAIN_MODEL=opus5 bash "${ROUTER}" --host claude --role advisor --field model)"
[ "${opus5_claude_advisor}" = "claude-opus-5" ] || {
  echo "opus5 brain opt-in must route the claude advisor tier to claude-opus-5"
  exit 1
}

if HARNESS_BRAIN_MODEL=bogus bash "${ROUTER}" --host claude --role advisor >/dev/null 2>&1; then
  echo "unknown HARNESS_BRAIN_MODEL value should fail loudly"
  exit 1
fi

mkdir -p "${TMP_DIR}/home/.codex/plugins/openai-codex/1.0.0" "${TMP_DIR}/bin"
touch "${TMP_DIR}/home/.codex/plugins/openai-codex/1.0.0/codex-companion.mjs"

cat > "${TMP_DIR}/bin/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${CODEX_STUB_ARGS_FILE}"
EOF
chmod +x "${TMP_DIR}/bin/codex"

SCHEMA_FILE="${TMP_DIR}/schema.json"
printf '{"type":"object"}\n' > "${SCHEMA_FILE}"

CODEX_STUB_ARGS_FILE="${TMP_DIR}/args-lite.txt" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
HARNESS_MODEL_TIER="lite" \
  bash "${COMPANION}" task --output-schema "${SCHEMA_FILE}" "simple docs cleanup"

grep -qx -- '--model' "${TMP_DIR}/args-lite.txt" || {
  echo "structured codex path must include --model"
  exit 1
}
grep -qx -- 'gpt-5.4-mini' "${TMP_DIR}/args-lite.txt" || {
  echo "structured codex path must use routed lite model"
  exit 1
}
grep -qx -- '-c' "${TMP_DIR}/args-lite.txt" || {
  echo "structured codex path must include config override"
  exit 1
}
grep -qx -- 'model_reasoning_effort="low"' "${TMP_DIR}/args-lite.txt" || {
  echo "structured codex path must translate computed effort to config"
  exit 1
}

CODEX_STUB_ARGS_FILE="${TMP_DIR}/args-explicit.txt" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
HARNESS_MODEL_TIER="lite" \
  bash "${COMPANION}" task --output-schema "${SCHEMA_FILE}" --model custom-model --effort xhigh "hard review"

grep -qx -- 'custom-model' "${TMP_DIR}/args-explicit.txt" || {
  echo "explicit model must be preserved"
  exit 1
}
if grep -qx -- 'gpt-5.4-mini' "${TMP_DIR}/args-explicit.txt"; then
  echo "routed model must not override explicit model"
  exit 1
fi
grep -qx -- 'model_reasoning_effort="xhigh"' "${TMP_DIR}/args-explicit.txt" || {
  echo "explicit effort must translate to config"
  exit 1
}

echo "OK"

# --- docs ↔ SSOT consistency (2026-08-12) --------------------------------
# なぜ必要か: 133.3 で grok の pin を実カタログへ直した際、同一ファイル内の
# 2 つ目の表 (Harness Role Defaults) の advisor/release 行だけ直し漏れ、
# 独立レビューで指摘された。当時 docs と SSOT の一致を検査する仕組みは
# 皆無で、修正漏れは grep の打ち切り次第で見逃せた。
#
# 初版のゲートは (i) docs/model-routing-policy.md だけを走査し、
# (ii) 「router が出す ID の集合に属するか」しか見ていなかったため、
# 敵対的再検証で 2 つの回避が実証された:
#   A. 別の doc (docs/research/grok-adapter-candidate.md) に悪い ID を書く
#   B. 実在するが tier の対応が誤った ID を行に入れ替える
# 両方を塞ぐため、(1) 走査対象を doc 集合へ拡張し、(2) tier 名を含む行は
# その tier で router が返す ID と一致することまで検証する。
ROOT_FOR_DOCS="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GROK_TIERS="lite standard deep advisor review release long-context"

# router が出しうる grok モデル ID の集合を SSOT から機械的に作る
router_grok_ids=""
for tier in ${GROK_TIERS}; do
  router_grok_ids="${router_grok_ids} $(bash "${ROUTER}" --host grok --tier "${tier}" --field model)"
done

# 走査対象の doc 集合。grok の pin を表に持つ doc を足したらここに追加する。
scanned_any_doc=0
documented_tiers=""
for doc in \
  "${ROOT_FOR_DOCS}/docs/model-routing-policy.md" \
  "${ROOT_FOR_DOCS}/docs/research/grok-adapter-candidate.md" \
; do
  [ -f "${doc}" ] || continue

  doc_grok_ids="$(grep '^|' "${doc}" | grep -oE 'grok-([0-9]|composer)[A-Za-z0-9._-]*' | sort -u | tr '\n' ' ' || true)"
  [ -n "${doc_grok_ids}" ] || continue
  scanned_any_doc=1

  # (1) 実在検査: 表に、記録済みカタログに無い grok ID が残っていないか。
  #     基準は router の出力集合ではなく **カタログ全体** (grok_known_ids)。
  #     カタログ一覧を載せる doc (grok-adapter-candidate.md) は、router が
  #     意図的に使わない ID (multi-agent 等) を含むのが正しいため。
  #     存在しない ID (grok-4.5 等) はどの doc にあってもここで落ちる。
  for id in ${doc_grok_ids}; do
    case " ${grok_known_ids} " in
      *" ${id} "*) ;;
      *)
        echo "${doc#${ROOT_FOR_DOCS}/} の表に、カタログに存在しない grok ID が残っている: ${id}"
        echo "  カタログ: ${grok_known_ids}"
        exit 1
        ;;
    esac
  done

  # (2) 行対応検査: 先頭セルが tier 名の行は、その tier の実際の ID と一致すること
  #     (実在するが tier の対応が誤った ID を弾く)
  while IFS= read -r line; do
    # 先頭セルを取り出して装飾 (バッククォート / 太字 / 空白) を剥がし、小文字化する。
    # 初版は バッククォート必須かつ小文字限定の正規表現で、`long-context` を
    # 装飾なしや大文字で書くだけで行が黙って skip された (敵対的再検証 round2 で実証)。
    row_tier="$(printf '%s' "${line}" | awk -F'|' '{print $2}' \
      | tr -d '`*' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [ -n "${row_tier}" ] || continue
    case " ${GROK_TIERS} " in *" ${row_tier} "*) ;; *) continue ;; esac

    # 改行区切りのままだと後続の case マッチ (前後空白必須) が外れるため空白へ正規化する
    row_ids="$(printf '%s' "${line}" | grep -oE 'grok-([0-9]|composer)[A-Za-z0-9._-]*' | sort -u | tr '\n' ' ' || true)"
    [ -n "${row_ids}" ] || continue

    # 「記載あり」と数えるのは grok の ID を含む行だけ。同じ doc には claude /
    # cursor 用の同名 tier 行もあるため、行の存在だけで数えると grok 行が
    # 消えても網羅検査が素通りする (変異検査 M6 で実際に素通りした)。
    documented_tiers="${documented_tiers} ${row_tier}"
    expected="$(bash "${ROUTER}" --host grok --tier "${row_tier}" --field model)"
    # 判定は「その tier の正解 ID が行に現れること」。表ごとに grok 列の位置が
    # 違う (tier 表は 2 列目、Role Defaults 表は 5 列目) ため列位置に依存させず、
    # かつ備考セルが別の実在 ID に言及していても誤検知しない形にする。
    # これで「実在するが tier 対応が誤った ID への差し替え」は正解 ID が行から
    # 消えるため検出される。
    # 既知の限界: 正解 ID が備考セルにだけ現れ、モデルセルが誤っている場合は
    # 検出できない。列位置に依存しない代償として受け入れる。
    case " ${row_ids} " in
      *" ${expected} "*) ;;
      *)
        echo "${doc#${ROOT_FOR_DOCS}/} の tier '${row_tier}' 行に、その tier の正解 grok pin が無い"
        echo "  doc の行に現れる ID: ${row_ids}"
        echo "  router が返す ID   : ${expected}"
        exit 1
        ;;
    esac
  done < <(grep '^|' "${doc}")
done

[ "${scanned_any_doc}" = "1" ] || {
  echo "grok の pin を持つ doc を 1 つも走査できなかった (抽出条件が壊れている)"
  exit 1
}

# (3) 網羅検査: 全 tier が doc の表に 1 行以上あること。
#     行が丸ごと消された場合、行単位の検査だけでは黙って通ってしまう
#     (敵対的再検証 round2 の指摘)。
for tier in ${GROK_TIERS}; do
  case " ${documented_tiers} " in
    *" ${tier} "*) ;;
    *)
      echo "grok tier '${tier}' の行が docs の表に無い (行ごと消えると検査が素通りする)"
      exit 1
      ;;
  esac
done

# (4) hosts.toml の grok pin も SSOT と一致すること。
#     markdown の表ではないためゲート本体の走査外だが、ID を持つ 3 つ目の面。
HOSTS_TOML="${ROOT_FOR_DOCS}/hosts.toml"
if [ -f "${HOSTS_TOML}" ]; then
  hosts_grok_model="$(awk '/^\[grok\]/{f=1;next} /^\[/{f=0} f && /^model/{gsub(/[" ]/,"");sub(/^model=/,"");print;exit}' "${HOSTS_TOML}")"
  if [ -n "${hosts_grok_model}" ]; then
    expected_host_model="$(bash "${ROUTER}" --host grok --tier deep --field model)"
    [ "${hosts_grok_model}" = "${expected_host_model}" ] || {
      echo "hosts.toml [grok] model が SSOT と不一致: hosts.toml=${hosts_grok_model} / router(deep)=${expected_host_model}"
      exit 1
    }
  fi
fi

# (5) tier 語彙の drift 検査: このテストが持つ GROK_TIERS は router の case 分岐の
#     二重管理になる。router 側に tier を足してテストを直し忘れると doc 検査から
#     漏れるため、両者が一致することを機械的に確かめる (spark / * は除外)。
router_tier_labels="$(awk '/^elif \[ "\$HOST" = "grok" \]/{f=1} f && /^  esac/{exit} f' "${ROUTER}" \
  | sed -n 's/^    \([a-z|-]*\)).*/\1/p' | tr '|' '\n' | grep -v '^spark$' | sort -u | tr '\n' ' ')"
for t in ${router_tier_labels}; do
  case " ${GROK_TIERS} " in
    *" ${t} "*) ;;
    *) echo "router に grok tier '${t}' があるが、このテストの GROK_TIERS に無い (二重管理の drift)"; exit 1 ;;
  esac
done
for t in ${GROK_TIERS}; do
  case " ${router_tier_labels} " in
    *" ${t} "*) ;;
    *) echo "GROK_TIERS の '${t}' が router の case 分岐に無い"; exit 1 ;;
  esac
done

echo "OK (docs<->SSOT grok pins consistent)"
