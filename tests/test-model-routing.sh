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

router_help="$(bash "${ROUTER}" --help)"
grep -q -- 'Tiers: .*worker' <<<"${router_help}" || {
  echo "router help must advertise the dedicated worker tier"
  exit 1
}

codex_lite_model="$(bash "${ROUTER}" --host codex --role explorer --field model)"
[ "${codex_lite_model}" = "gpt-5.6-luna" ] || {
  echo "codex explorer must route to gpt-5.6-luna"
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

# Breezing implementation workers use the worker route. Keep the reviewer
# route independent so changing worker capacity cannot silently retune review.
codex_worker_model="$(bash "${ROUTER}" --host codex --role worker --field model)"
[ "${codex_worker_model}" = "gpt-5.6-luna" ] || {
  echo "codex worker must route to the luna implementation model"
  exit 1
}

codex_worker_effort="$(bash "${ROUTER}" --host codex --role worker --field effort)"
[ "${codex_worker_effort}" = "max" ] || {
  echo "codex worker must route to max reasoning effort"
  exit 1
}

codex_worker_tier_json="$(bash "${ROUTER}" --host codex --role worker --format json)"
grep -q '"tier":"worker"' <<<"${codex_worker_tier_json}" || {
  echo "codex worker role must resolve the dedicated worker tier"
  exit 1
}

codex_setup_model="$(bash "${ROUTER}" --host codex --role setup --field model)"
[ "${codex_setup_model}" = "gpt-5.6-sol" ] || {
  echo "codex setup role must preserve the standard Sol compatibility model"
  exit 1
}
codex_setup_effort="$(bash "${ROUTER}" --host codex --role setup --field effort)"
[ "${codex_setup_effort}" = "xhigh" ] || {
  echo "codex setup role must preserve xhigh compatibility effort"
  exit 1
}
codex_setup_tier_json="$(bash "${ROUTER}" --host codex --role setup --format json)"
grep -q '"tier":"standard"' <<<"${codex_setup_tier_json}" || {
  echo "codex setup role must remain on the standard compatibility tier"
  exit 1
}

codex_standard_model="$(bash "${ROUTER}" --host codex --tier standard --field model)"
[ "${codex_standard_model}" = "gpt-5.6-sol" ] || {
  echo "codex standard tier must preserve the Sol compatibility model"
  exit 1
}
codex_standard_effort="$(bash "${ROUTER}" --host codex --tier standard --field effort)"
[ "${codex_standard_effort}" = "xhigh" ] || {
  echo "codex standard tier must preserve xhigh compatibility effort"
  exit 1
}

codex_reviewer_model="$(bash "${ROUTER}" --host codex --role reviewer --field model)"
[ "${codex_reviewer_model}" = "gpt-5.6-sol" ] || {
  echo "codex reviewer route must remain on sol"
  exit 1
}

codex_reviewer_effort="$(bash "${ROUTER}" --host codex --role reviewer --field effort)"
[ "${codex_reviewer_effort}" = "xhigh" ] || {
  echo "codex reviewer route must remain xhigh"
  exit 1
}

codex_operator_model="$(bash "${ROUTER}" --host codex --role operator --field model)"
[ "${codex_operator_model}" = "gpt-5.6-sol" ] || {
  echo "codex operator route must preserve the pre-worker Sol model"
  exit 1
}

codex_operator_effort="$(bash "${ROUTER}" --host codex --role operator --field effort)"
[ "${codex_operator_effort}" = "xhigh" ] || {
  echo "codex operator route must preserve xhigh effort"
  exit 1
}
codex_operator_tier_json="$(bash "${ROUTER}" --host codex --role operator --format json)"
grep -q '"tier":"standard"' <<<"${codex_operator_tier_json}" || {
  echo "codex operator role must remain on the standard compatibility tier"
  exit 1
}

# The operator compatibility override is Codex-only. Claude, Cursor, and Grok
# operators must continue to use their shared standard tier.
claude_operator_model="$(bash "${ROUTER}" --host claude --role operator --field model)"
[ "${claude_operator_model}" = "claude-sonnet-5" ] || {
  echo "claude operator route must remain on the standard model"
  exit 1
}
claude_operator_effort="$(bash "${ROUTER}" --host claude --role operator --field effort)"
[ "${claude_operator_effort}" = "medium" ] || {
  echo "claude operator route must remain at standard effort"
  exit 1
}

cursor_operator_model="$(bash "${ROUTER}" --host cursor --role operator --field model)"
[ "${cursor_operator_model}" = "composer-2.5-fast" ] || {
  echo "cursor operator route must remain on the standard model"
  exit 1
}
cursor_operator_effort="$(bash "${ROUTER}" --host cursor --role operator --field effort)"
[ "${cursor_operator_effort}" = "medium" ] || {
  echo "cursor operator route must remain at standard effort"
  exit 1
}

grok_operator_model="$(bash "${ROUTER}" --host grok --role operator --field model)"
[ "${grok_operator_model}" = "grok-4.5" ] || {
  echo "grok operator route must remain on the standard model"
  exit 1
}
grok_operator_effort="$(bash "${ROUTER}" --host grok --role operator --field effort)"
[ "${grok_operator_effort}" = "medium" ] || {
  echo "grok operator route must remain at standard effort"
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
cat > "${TMP_DIR}/home/.codex/plugins/openai-codex/1.0.0/codex-companion.mjs" <<'NODE'
import fs from "node:fs";
if (process.env.COMPANION_STUB_ARGS_FILE) {
  fs.writeFileSync(process.env.COMPANION_STUB_ARGS_FILE, process.argv.slice(2).join("\n") + "\n");
}
process.stdout.write(JSON.stringify(process.argv.slice(2)) + "\n");
NODE

cat > "${TMP_DIR}/bin/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${CODEX_STUB_ARGS_FILE}"
if [ -n "${CODEX_STUB_STDIN_FILE:-}" ]; then
  cat > "${CODEX_STUB_STDIN_FILE}"
fi
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
grep -qx -- 'gpt-5.6-luna' "${TMP_DIR}/args-lite.txt" || {
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
if grep -qx -- 'gpt-5.6-luna' "${TMP_DIR}/args-explicit.txt"; then
  echo "routed model must not override explicit model"
  exit 1
fi
grep -qx -- 'model_reasoning_effort="xhigh"' "${TMP_DIR}/args-explicit.txt" || {
  echo "explicit effort must translate to config"
  exit 1
}

# A worker route at max must bypass the official companion's --effort parser
# and use codex exec with the equivalent config override. This is intentionally
# a non-schema task: max is the routing contract, not a schema-mode side effect.
CODEX_STUB_ARGS_FILE="${TMP_DIR}/args-worker-max.txt" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="worker" \
HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
  bash "${COMPANION}" task --write -C "${TMP_DIR}" "breezing worker max route"

grep -qx -- 'exec' "${TMP_DIR}/args-worker-max.txt" || {
  echo "max worker route must use codex exec"
  exit 1
}
grep -qx -- '-C' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must preserve -C"
  exit 1
}
grep -qx -- "${TMP_DIR}" "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must preserve the target cwd"
  exit 1
}
grep -qx -- '--sandbox' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must preserve --write sandbox intent"
  exit 1
}
grep -qx -- 'workspace-write' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must preserve workspace-write intent"
  exit 1
}
grep -qx -- '--model' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must include the routed model"
  exit 1
}
grep -qx -- 'gpt-5.6-luna' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must use the routed luna model"
  exit 1
}
grep -qx -- '-c' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must include a config override"
  exit 1
}
grep -qx -- 'model_reasoning_effort="max"' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must translate max effort to config"
  exit 1
}
grep -qx -- 'breezing worker max route' "${TMP_DIR}/args-worker-max.txt" || {
  echo "raw max worker route must preserve the task prompt"
  exit 1
}

CODEX_STUB_ARGS_FILE="${TMP_DIR}/args-worker-max-explicit-model.txt" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="worker" \
HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
  bash "${COMPANION}" task --write -C "${TMP_DIR}" --model custom-worker-model "max worker explicit model"

grep -qx -- 'custom-worker-model' "${TMP_DIR}/args-worker-max-explicit-model.txt" || {
  echo "raw max worker route must preserve an explicit model"
  exit 1
}
if grep -qx -- 'gpt-5.6-luna' "${TMP_DIR}/args-worker-max-explicit-model.txt"; then
  echo "raw max worker route must not override an explicit model"
  exit 1
fi

CODEX_STUB_ARGS_FILE="${TMP_DIR}/args-worker-explicit-sandbox.txt" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="worker" \
HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
  bash "${COMPANION}" task --write --sandbox read-only "worker explicit sandbox"
sandbox_flag_count="$(grep -cx -- '--sandbox' "${TMP_DIR}/args-worker-explicit-sandbox.txt")"
[ "${sandbox_flag_count}" -eq 1 ] || {
  echo "raw worker route must emit exactly one explicit sandbox flag"
  exit 1
}
grep -qx -- 'read-only' "${TMP_DIR}/args-worker-explicit-sandbox.txt" || {
  echo "raw worker route must preserve explicit read-only sandbox over --write"
  exit 1
}
if grep -qx -- 'workspace-write' "${TMP_DIR}/args-worker-explicit-sandbox.txt"; then
  echo "raw worker route must not add workspace-write beside an explicit sandbox"
  exit 1
fi

for explicit_sandbox in '--sandbox=read-only' '-s=read-only' '--full-auto' '--dangerously-bypass-approvals-and-sandbox'; do
  sandbox_name="$(printf '%s' "${explicit_sandbox}" | tr -cd '[:alnum:]')"
  sandbox_args_file="${TMP_DIR}/args-worker-sandbox-${sandbox_name}.txt"
  CODEX_STUB_ARGS_FILE="${sandbox_args_file}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="worker" \
  HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
    bash "${COMPANION}" task --write "${explicit_sandbox}" "worker explicit sandbox equals ${sandbox_name}"

  grep -qx -- "${explicit_sandbox}" "${sandbox_args_file}" || {
    echo "raw worker route must preserve ${explicit_sandbox} exactly"
    exit 1
  }
  if grep -qx -- 'workspace-write' "${sandbox_args_file}"; then
    echo "raw worker route must not add workspace-write beside ${explicit_sandbox}"
    exit 1
  fi
done

CODEX_STUB_ARGS_FILE="${TMP_DIR}/args-worker-short-model-equals.txt" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="worker" \
HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
  bash "${COMPANION}" task --write -m=custom-worker-model "worker short model equals"
grep -qx -- '-m=custom-worker-model' "${TMP_DIR}/args-worker-short-model-equals.txt" || {
  echo "raw worker route must preserve -m= explicit model"
  exit 1
}
if grep -qx -- 'gpt-5.6-luna' "${TMP_DIR}/args-worker-short-model-equals.txt"; then
  echo "raw worker route must not override -m= explicit model"
  exit 1
fi

# An explicit xhigh request remains on the official companion path. Its args
# are captured separately so a fake raw Codex binary cannot make this green.
COMPANION_STUB_ARGS_FILE="${TMP_DIR}/args-explicit-xhigh-companion.txt" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="standard" \
HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
  bash "${COMPANION}" task --write -C "${TMP_DIR}" --effort xhigh "explicit xhigh companion path"

grep -qx -- 'task' "${TMP_DIR}/args-explicit-xhigh-companion.txt" || {
  echo "explicit xhigh task must remain on the official companion path"
  exit 1
}
grep -qx -- '--effort' "${TMP_DIR}/args-explicit-xhigh-companion.txt" || {
  echo "explicit xhigh companion path must preserve --effort"
  exit 1
}
grep -qx -- 'xhigh' "${TMP_DIR}/args-explicit-xhigh-companion.txt" || {
  echo "explicit xhigh companion path must preserve xhigh"
  exit 1
}
if [ -e "${TMP_DIR}/args-explicit-xhigh-raw.txt" ]; then
  echo "explicit xhigh task unexpectedly used raw codex exec"
  exit 1
fi

# An invalid routed tier must fail before either official companion or raw
# codex exec is started. Routing-disabled mode remains compatible with the
# existing companion fallback.
invalid_companion_args="${TMP_DIR}/args-invalid-tier-companion.txt"
invalid_raw_args="${TMP_DIR}/args-invalid-tier-raw.txt"
invalid_output="${TMP_DIR}/invalid-tier-output.txt"
invalid_status=0
if COMPANION_STUB_ARGS_FILE="${invalid_companion_args}" \
  CODEX_STUB_ARGS_FILE="${invalid_raw_args}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="invalid-tier" \
  HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
    bash "${COMPANION}" task --write "invalid routed tier" >"${invalid_output}" 2>&1; then
  invalid_status=0
else
  invalid_status=$?
fi
[ "${invalid_status}" -ne 0 ] || {
  echo "invalid Codex route must fail before task dispatch"
  exit 1
}
grep -Fq -- 'model routing failed' "${invalid_output}" || {
  echo "invalid Codex route failure must be explicit"
  exit 1
}
if [ -e "${invalid_companion_args}" ] || [ -e "${invalid_raw_args}" ]; then
  echo "invalid Codex route must not start companion or raw codex"
  exit 1
fi

for invalid_effort_args in \
  "--effort bogus" \
  "--effort"; do
  invalid_effort_companion_args="${TMP_DIR}/args-invalid-effort-${invalid_effort_args// /-}-companion.txt"
  invalid_effort_raw_args="${TMP_DIR}/args-invalid-effort-${invalid_effort_args// /-}-raw.txt"
  invalid_effort_output="${TMP_DIR}/invalid-effort-${invalid_effort_args// /-}-output.txt"
  invalid_effort_status=0
  if COMPANION_STUB_ARGS_FILE="${invalid_effort_companion_args}" \
    CODEX_STUB_ARGS_FILE="${invalid_effort_raw_args}" \
    HOME="${TMP_DIR}/home" \
    PATH="${TMP_DIR}/bin:${PATH}" \
    CODEX_MODEL_TIER="worker" \
    HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
      bash -c 'if [ "$1" = "--effort" ]; then
        bash "$2" task --write "invalid explicit effort" --effort
      else
        bash "$2" task --write --effort bogus "invalid explicit effort"
      fi' _ "${invalid_effort_args}" "${COMPANION}" >"${invalid_effort_output}" 2>&1; then
    invalid_effort_status=0
  else
    invalid_effort_status=$?
  fi
  [ "${invalid_effort_status}" -eq 2 ] || {
    echo "${invalid_effort_args} must fail closed with rc=2"
    exit 1
  }
  grep -Eiq -- 'invalid effort|requires an effort value' "${invalid_effort_output}" || {
    echo "${invalid_effort_args} must explain the invalid or missing effort"
    exit 1
  }
  if [ -e "${invalid_effort_companion_args}" ] || [ -e "${invalid_effort_raw_args}" ]; then
    echo "${invalid_effort_args} must not start a provider"
    exit 1
  fi
done

disabled_companion_args="${TMP_DIR}/args-routing-disabled.txt"
COMPANION_STUB_ARGS_FILE="${disabled_companion_args}" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
HARNESS_DISABLE_MODEL_ROUTING=1 \
CODEX_MODEL_TIER="invalid-tier" \
  bash "${COMPANION}" task "routing disabled compatibility"
grep -qx -- 'task' "${disabled_companion_args}" || {
  echo "routing-disabled task must preserve companion compatibility"
  exit 1
}

# Generic Codex standard remains the historical Sol/xhigh companion route for
# background/resume/fresh state modes.
for mode in --background --resume-last --resume --fresh; do
  mode_name="${mode#--}"
  mode_args_file="${TMP_DIR}/args-${mode_name}-standard.txt"
  COMPANION_STUB_ARGS_FILE="${mode_args_file}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="standard" \
    bash "${COMPANION}" task "${mode}" "${mode_name} standard compatibility path"

  grep -qx -- 'task' "${mode_args_file}" || {
    echo "${mode} standard route must remain on the official companion path"
    exit 1
  }
  if grep -qx -- 'max' "${mode_args_file}"; then
    echo "${mode} standard route must not pass worker max to the official companion"
    exit 1
  fi
  grep -qx -- 'xhigh' "${mode_args_file}" || {
    echo "${mode} standard route must preserve the routed xhigh effort"
    exit 1
  }

  # The dedicated Breezing worker tier is max and must fail closed because raw
  # codex exec cannot resume or queue these stateful jobs.
  mode_worker_companion_args="${TMP_DIR}/args-${mode_name}-worker-companion.txt"
  mode_worker_raw_args="${TMP_DIR}/args-${mode_name}-worker-raw.txt"
  mode_worker_output="${TMP_DIR}/${mode_name}-worker-output.txt"
  mode_worker_status=0
  if COMPANION_STUB_ARGS_FILE="${mode_worker_companion_args}" \
    CODEX_STUB_ARGS_FILE="${mode_worker_raw_args}" \
    HOME="${TMP_DIR}/home" \
    PATH="${TMP_DIR}/bin:${PATH}" \
    CODEX_MODEL_TIER="worker" \
    HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
      bash "${COMPANION}" task "${mode}" --write --json "${mode_name} worker route" >"${mode_worker_output}" 2>&1; then
    mode_worker_status=0
  else
    mode_worker_status=$?
  fi
  [ "${mode_worker_status}" -eq 2 ] || {
    echo "${mode} worker/max route must fail closed with rc=2"
    exit 1
  }
  grep -Fq -- "cannot preserve max effort" "${mode_worker_output}" || {
    echo "${mode} worker/max route must explain the max-effort failure"
    exit 1
  }
  if [ -e "${mode_worker_companion_args}" ] || [ -e "${mode_worker_raw_args}" ]; then
    echo "${mode} worker/max route must not start a provider"
    exit 1
  fi

  # Routing-disabled state modes retain the historical companion contract.
  mode_args_file="${TMP_DIR}/args-${mode_name}-disabled.txt"
  COMPANION_STUB_ARGS_FILE="${mode_args_file}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  HARNESS_DISABLE_MODEL_ROUTING=1 \
    bash "${COMPANION}" task "${mode}" "${mode_name} compatibility path"

  grep -qx -- 'task' "${mode_args_file}" || {
    echo "routing-disabled ${mode} must remain on the official companion path"
    exit 1
  }
  if grep -qx -- 'max' "${mode_args_file}"; then
    echo "routing-disabled ${mode} must not pass max to the official companion"
    exit 1
  fi
done

# An explicit effort wins regardless of whether it appears before or after a
# state flag; the routed standard xhigh must not overwrite caller intent.
for state_effort_order in state-first effort-first; do
  state_effort_args_file="${TMP_DIR}/args-state-effort-${state_effort_order}.txt"
  if [ "${state_effort_order}" = "state-first" ]; then
    state_effort_args=(--background --effort high)
  else
    state_effort_args=(--effort high --background)
  fi
  COMPANION_STUB_ARGS_FILE="${state_effort_args_file}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="standard" \
    bash "${COMPANION}" task "${state_effort_args[@]}" "explicit state effort ${state_effort_order}"
  grep -qx -- 'high' "${state_effort_args_file}" || {
    echo "${state_effort_order} explicit effort must reach the companion"
    exit 1
  }
  if grep -qx -- 'xhigh' "${state_effort_args_file}"; then
    echo "${state_effort_order} explicit effort must not be overwritten by routed xhigh"
    exit 1
  fi
done

# Generic standard prompt-file calls retain the official companion contract.
prompt_file="${TMP_DIR}/loop-prompt.md"
printf '%s\n' 'prompt-file route contract' >"${prompt_file}"

missing_prompt_file="${TMP_DIR}/missing-prompt.md"
missing_prompt_companion_args="${TMP_DIR}/args-missing-prompt-companion.txt"
missing_prompt_raw_args="${TMP_DIR}/args-missing-prompt-raw.txt"
missing_prompt_output="${TMP_DIR}/missing-prompt-output.txt"
missing_prompt_status=0
if COMPANION_STUB_ARGS_FILE="${missing_prompt_companion_args}" \
  CODEX_STUB_ARGS_FILE="${missing_prompt_raw_args}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="worker" \
    bash "${COMPANION}" task --prompt-file "${missing_prompt_file}" >"${missing_prompt_output}" 2>&1; then
  missing_prompt_status=0
else
  missing_prompt_status=$?
fi
[ "${missing_prompt_status}" -eq 2 ] || {
  echo "missing task --prompt-file must fail closed with rc=2"
  exit 1
}
grep -Fq -- "cannot read" "${missing_prompt_output}" || {
  echo "missing task --prompt-file must explain the read failure"
  exit 1
}
if [ -e "${missing_prompt_companion_args}" ] || [ -e "${missing_prompt_raw_args}" ]; then
  echo "missing task --prompt-file must not start a provider"
  exit 1
fi

prompt_companion_args="${TMP_DIR}/args-prompt-file-companion.txt"
COMPANION_STUB_ARGS_FILE="${prompt_companion_args}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="standard" \
  bash "${COMPANION}" task --prompt-file "${prompt_file}"
grep -qx -- 'task' "${prompt_companion_args}" || {
  echo "standard task --prompt-file must remain on the official companion path"
  exit 1
}

# The dedicated worker tier uses raw exec for foreground prompt-file content.
worker_prompt_raw_args="${TMP_DIR}/args-worker-prompt-file-raw.txt"
worker_prompt_stdin="${TMP_DIR}/worker-prompt-file-stdin.txt"
CODEX_STUB_ARGS_FILE="${worker_prompt_raw_args}" \
CODEX_STUB_STDIN_FILE="${worker_prompt_stdin}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="worker" \
  HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
  bash "${COMPANION}" task --prompt-file "${prompt_file}"
grep -qx -- 'exec' "${worker_prompt_raw_args}" || {
  echo "worker task --prompt-file must use raw codex exec"
  exit 1
}
grep -qx -- '-' "${worker_prompt_raw_args}" || {
  echo "worker task --prompt-file must read the prompt from stdin"
  exit 1
}
grep -qx -- 'prompt-file route contract' "${worker_prompt_stdin}" || {
  echo "worker task --prompt-file must preserve file contents"
  exit 1
}

# A stateful max task with --prompt-file cannot preserve both semantics; fail
# before either provider path. This is the codex-loop.sh contract.
state_prompt_companion_args="${TMP_DIR}/args-state-prompt-file-companion.txt"
state_prompt_raw_args="${TMP_DIR}/args-state-prompt-file-raw.txt"
state_prompt_output="${TMP_DIR}/state-prompt-file-output.txt"
state_prompt_status=0
if COMPANION_STUB_ARGS_FILE="${state_prompt_companion_args}" \
  CODEX_STUB_ARGS_FILE="${state_prompt_raw_args}" \
  HOME="${TMP_DIR}/home" \
  PATH="${TMP_DIR}/bin:${PATH}" \
  CODEX_MODEL_TIER="worker" \
  HARNESS_CODEX_ALLOW_NON_PRIMARY_WRITE=1 \
    bash "${COMPANION}" task --background --write --json --prompt-file "${prompt_file}" >"${state_prompt_output}" 2>&1; then
  state_prompt_status=0
else
  state_prompt_status=$?
fi
[ "${state_prompt_status}" -eq 2 ] || {
  echo "background task --prompt-file must fail closed with rc=2"
  exit 1
}
grep -Fq -- "cannot preserve max effort" "${state_prompt_output}" || {
  echo "background task --prompt-file must explain the max-effort failure"
  exit 1
}
if [ -e "${state_prompt_companion_args}" ] || [ -e "${state_prompt_raw_args}" ]; then
  echo "background task --prompt-file must not start a provider"
  exit 1
fi

# Explicit non-max and routing-disabled prompt-file calls retain the official
# companion contract.
nonmax_prompt_args="${TMP_DIR}/args-nonmax-prompt-file.txt"
COMPANION_STUB_ARGS_FILE="${nonmax_prompt_args}" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
CODEX_MODEL_TIER="deep" \
  bash "${COMPANION}" task --effort xhigh --prompt-file "${prompt_file}"
grep -qx -- 'task' "${nonmax_prompt_args}" || {
  echo "non-max task --prompt-file must remain on the official companion path"
  exit 1
}

disabled_prompt_args="${TMP_DIR}/args-disabled-prompt-file.txt"
COMPANION_STUB_ARGS_FILE="${disabled_prompt_args}" \
HOME="${TMP_DIR}/home" \
PATH="${TMP_DIR}/bin:${PATH}" \
HARNESS_DISABLE_MODEL_ROUTING=1 \
  bash "${COMPANION}" task --prompt-file "${prompt_file}"
grep -qx -- 'task' "${disabled_prompt_args}" || {
  echo "routing-disabled task --prompt-file must remain on the official companion path"
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

# Active advisor surfaces must not retain retired model literals. The source
# agents and generated Cursor fallback are runtime inputs in their respective
# hosts, so routing-table tests also pin these direct adapter files.
grep -Fqx 'model: claude-opus-5' "${ROOT_FOR_DOCS}/agents/advisor.md" || {
  echo "Claude advisor agent must use current claude-opus-5"
  exit 1
}
if grep -Fq 'claude-opus-4-8' "${ROOT_FOR_DOCS}/agents/advisor.md"; then
  echo "retired Claude advisor model literal remains"
  exit 1
fi
grep -Fqx 'model: claude-fable-5' "${ROOT_FOR_DOCS}/.cursor/agents/advisor.md" || {
  echo "Cursor advisor agent must use current claude-fable-5"
  exit 1
}
if grep -Fq 'claude-opus-4-7' "${ROOT_FOR_DOCS}/.cursor/agents/advisor.md"; then
  echo "retired Cursor advisor model literal remains"
  exit 1
fi
if grep -Fq 'claude-opus-4-7' "${ROOT_FOR_DOCS}/scripts/build-host-plugin-dist.sh"; then
  echo "generated Cursor advisor fallback contains retired model literal"
  exit 1
fi

echo "OK (docs<->SSOT grok pins consistent)"
