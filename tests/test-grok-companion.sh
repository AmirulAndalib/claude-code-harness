#!/usr/bin/env bash
# test-grok-companion.sh
# scripts/grok-companion.sh の挙動を MOCK grok で検証する。
#
# 隔離: 実 grok は呼ばない。temp dir に偽の grok を置き、PATH の先頭に挿すことで
#       ラッパーの command -v 解決がモックを拾う。この test は grok CLI が
#       絶対に存在しない環境（CI）でも green で通ることが必須契約
#       （absence-degradation。tests/test-cursor-companion.sh (h) と同じ形）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="${PROJECT_ROOT}/scripts/grok-companion.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$WRAPPER" ] || fail "missing script: $WRAPPER"

command -v jq >/dev/null 2>&1 || fail "jq is required for these tests"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grok-companion-test.XXXXXX")"
MOCK_BIN_DIR="${TMP_DIR}/bin"
MOCK_AGENT="${MOCK_BIN_DIR}/grok"
ARGS_FILE="${TMP_DIR}/captured-args.txt"
WORKSPACE_DIR="${TMP_DIR}/ws"
mkdir -p "${MOCK_BIN_DIR}" "${WORKSPACE_DIR}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# モック grok を生成するヘルパ。
#   $1 = stdout に出す内容（空なら何も出さない）
#   $2 = exit code
#   $3 = stderr に出す内容（省略可）
make_mock() {
  local stdout_body="$1"
  local exit_code="$2"
  local stderr_body="${3:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf %s "$*" > %s\n' "'%s\\n'" "${ARGS_FILE}"
    if [ -n "${stderr_body}" ]; then
      printf 'echo %s >&2\n' "${stderr_body}"
    fi
    if [ -n "${stdout_body}" ]; then
      printf 'cat <<'\''JSON_EOF'\''\n%s\nJSON_EOF\n' "${stdout_body}"
    fi
    printf 'exit %s\n' "${exit_code}"
  } >"${MOCK_AGENT}"
  chmod +x "${MOCK_AGENT}"
}

# ラッパーをモック PATH 付きで実行するヘルパ。
run_wrapper() {
  PATH="${MOCK_BIN_DIR}:${PATH}" bash "${WRAPPER}" "$@"
}

# ---------------------------------------------------------------------------
# (a) success: {"text":"DONE","stopReason":"end_turn"} / exit 0
#     → ラッパーは DONE を出力し exit 0
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE","stopReason":"end_turn","sessionId":"s1","requestId":"r1"}' 0
set +e
out="$(run_wrapper task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(a) success should exit 0, got $rc"
[ "$out" = "DONE" ] || fail "(a) success should print 'DONE', got '$out'"

# ---------------------------------------------------------------------------
# (b) error-no-json: stdout 空 / stderr=boom / exit 1
#     → ラッパーは非ゼロ終了し、偽の空 success を出力しない
# ---------------------------------------------------------------------------
make_mock '' 1 'boom'
set +e
out="$(run_wrapper task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "(b) error-no-json should exit non-zero, got 0"
[ "$out" != "DONE" ] || fail "(b) error must not print a bogus 'DONE'"
[ -z "$out" ] || fail "(b) error must not print any stdout result, got '$out'"

# ---------------------------------------------------------------------------
# (c) type=error (公式契約: 失敗は非ゼロ終了。防御的に rc==0 でも捕捉する):
#     {"type":"error","message":"nope"} / exit 0 → ラッパーは failure 扱いで exit 1
# ---------------------------------------------------------------------------
make_mock '{"type":"error","message":"nope"}' 0
set +e
out="$(run_wrapper task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "(c) type=error should exit 1, got $rc"
[ "$out" != "nope" ] || fail "(c) type=error must not print message as success"

# ---------------------------------------------------------------------------
# (c2) exit 非ゼロ + type=error stdout（公式契約どおりの現実的な失敗形）
#      → ラッパーはその rc をそのまま伝播する
# ---------------------------------------------------------------------------
make_mock '{"type":"error","message":"Could not start session"}' 1
set +e
out="$(run_wrapper task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "(c2) exit!=0 + type=error should propagate rc=1, got $rc"
[ -z "$out" ] || fail "(c2) failure must not print any stdout result, got '$out'"

# ---------------------------------------------------------------------------
# (d) read-only default は --permission-mode plan を構築する / write では付けない
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE"}' 0
run_wrapper task "do the thing" >/dev/null 2>&1
grep -q -- "--permission-mode plan" "${ARGS_FILE}" \
  || fail "(d) read-only default should build '--permission-mode plan', args were: $(cat "${ARGS_FILE}")"

make_mock '{"text":"DONE"}' 0
run_wrapper task --write --workspace "${WORKSPACE_DIR}" "do the thing" >/dev/null 2>&1
if grep -q -- "--permission-mode plan" "${ARGS_FILE}"; then
  fail "(d) write mode must NOT build '--permission-mode plan', args were: $(cat "${ARGS_FILE}")"
fi

# ---------------------------------------------------------------------------
# (e) --yolo / --always-approve / bypassPermissions は read-only / write の
#     どちらでも決して構築されない
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE"}' 0
run_wrapper task "do the thing" >/dev/null 2>&1
if grep -qE -- "--yolo|--always-approve|bypassPermissions" "${ARGS_FILE}"; then
  fail "(e) read-only must never build --yolo/--always-approve/bypassPermissions, args were: $(cat "${ARGS_FILE}")"
fi
make_mock '{"text":"DONE"}' 0
run_wrapper task --write --workspace "${WORKSPACE_DIR}" "do the thing" >/dev/null 2>&1
if grep -qE -- "--yolo|--always-approve|bypassPermissions" "${ARGS_FILE}"; then
  fail "(e) write mode must never build --yolo/--always-approve/bypassPermissions, args were: $(cat "${ARGS_FILE}")"
fi

# ---------------------------------------------------------------------------
# (f) --write without --workspace → exit 2 (guard)
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE"}' 0
set +e
run_wrapper task --write "do the thing" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "(f) --write without --workspace should exit 2, got $rc"

# ---------------------------------------------------------------------------
# (g) --write --workspace=<repo root> → exit 2 (guard)
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE"}' 0
set +e
run_wrapper task --write --workspace "${PROJECT_ROOT}" "do the thing" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "(g) --write --workspace=repo-root should exit 2, got $rc"

# ---------------------------------------------------------------------------
# (h) grok 不在 → exit 3 (not-configured), ハングしない
#     PATH からモックを外し、$HOME も temp に差し替えてフォールバックも外す。
#     CI で grok CLI が絶対に存在しない前提の absence-degradation テスト本体。
# ---------------------------------------------------------------------------
set +e
PATH="/usr/bin:/bin" HOME="${TMP_DIR}/empty-home" \
  bash "${WRAPPER}" task "do the thing" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "(h) missing grok should exit 3, got $rc"

# ---------------------------------------------------------------------------
# (i) --debug 引数: 成功パスで wrapper stderr に [grok-companion DEBUG] と cmd:
#     が含まれ、ARGS_FILE には --debug が混入していない（grok に渡らない）
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE"}' 0
DEBUG_ERR="${TMP_DIR}/debug-flag-stderr.txt"
set +e
out="$(run_wrapper --debug task "do the thing" 2>"${DEBUG_ERR}")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(i) --debug success path should exit 0, got $rc"
[ "$out" = "DONE" ] || fail "(i) --debug success path should still print 'DONE', got '$out'"
grep -q "\[grok-companion DEBUG\]" "${DEBUG_ERR}" \
  || fail "(i) --debug wrapper stderr should contain '[grok-companion DEBUG]', got: $(cat "${DEBUG_ERR}")"
grep -q "cmd:" "${DEBUG_ERR}" \
  || fail "(i) --debug wrapper stderr should contain 'cmd:', got: $(cat "${DEBUG_ERR}")"
if grep -q -- "--debug" "${ARGS_FILE}"; then
  fail "(i) --debug must NOT be passed to grok, args were: $(cat "${ARGS_FILE}")"
fi

# (i-b) --debug は task の後ろにも置ける
make_mock '{"text":"DONE"}' 0
DEBUG_ERR2="${TMP_DIR}/debug-flag-after-task-stderr.txt"
set +e
out="$(run_wrapper task --debug "do the thing" 2>"${DEBUG_ERR2}")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(i-b) 'task --debug' should exit 0, got $rc"
grep -q "\[grok-companion DEBUG\]" "${DEBUG_ERR2}" \
  || fail "(i-b) 'task --debug' should also trigger debug output, got: $(cat "${DEBUG_ERR2}")"
if grep -q -- "--debug" "${ARGS_FILE}"; then
  fail "(i-b) 'task --debug' must NOT be passed to grok, args were: $(cat "${ARGS_FILE}")"
fi

# ---------------------------------------------------------------------------
# (ii) HARNESS_GROK_DEBUG=1 env: --debug フラグなしでも同じ debug 出力
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE"}' 0
DEBUG_ENV_ERR="${TMP_DIR}/debug-env-stderr.txt"
set +e
out="$(HARNESS_GROK_DEBUG=1 run_wrapper task "do the thing" 2>"${DEBUG_ENV_ERR}")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(ii) HARNESS_GROK_DEBUG=1 success path should exit 0, got $rc"
[ "$out" = "DONE" ] || fail "(ii) HARNESS_GROK_DEBUG=1 should still print 'DONE', got '$out'"
grep -q "\[grok-companion DEBUG\]" "${DEBUG_ENV_ERR}" \
  || fail "(ii) HARNESS_GROK_DEBUG=1 stderr should contain '[grok-companion DEBUG]', got: $(cat "${DEBUG_ENV_ERR}")"
if grep -q -- "--debug" "${ARGS_FILE}"; then
  fail "(ii) HARNESS_GROK_DEBUG=1 must NOT pass --debug to grok, args were: $(cat "${ARGS_FILE}")"
fi

# ---------------------------------------------------------------------------
# (iii) secret マスキング: mask_args() を直接 source して call する
# ---------------------------------------------------------------------------
(
  GROK_COMPANION_SOURCED_FOR_TEST=1
  export GROK_COMPANION_SOURCED_FOR_TEST
  # shellcheck disable=SC1090
  . "${WRAPPER}"
  masked="$(mask_args "--api-key" "SUPERSECRET" "--header" "Authorization: Bearer ABCDEFG" "prompt-text")"
  if grep -q "SUPERSECRET" <<<"${masked}"; then
    echo "FAIL: (iii) --api-key value 'SUPERSECRET' must be masked, masked='${masked}'" >&2
    exit 1
  fi
  if grep -q "ABCDEFG" <<<"${masked}"; then
    echo "FAIL: (iii) Authorization bearer 'ABCDEFG' must be masked, masked='${masked}'" >&2
    exit 1
  fi
  if ! grep -q "\[REDACTED\]" <<<"${masked}"; then
    echo "FAIL: (iii) mask_args must emit '[REDACTED]', masked='${masked}'" >&2
    exit 1
  fi
  if ! grep -q "prompt-text" <<<"${masked}"; then
    echo "FAIL: (iii) prompt body 'prompt-text' must NOT be masked, masked='${masked}'" >&2
    exit 1
  fi
) || fail "(iii) mask_args unit test failed"

# ---------------------------------------------------------------------------
# (iv) Default-off: --debug もなく env も無い → wrapper stderr に DEBUG marker なし
# ---------------------------------------------------------------------------
make_mock '{"text":"DONE"}' 0
DEFAULT_ERR="${TMP_DIR}/default-off-stderr.txt"
set +e
out="$(run_wrapper task "do the thing" 2>"${DEFAULT_ERR}")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(iv) default-off success path should exit 0, got $rc"
if grep -q "\[grok-companion DEBUG\]" "${DEFAULT_ERR}"; then
  fail "(iv) default-off (no --debug, no env) must NOT emit DEBUG marker, stderr was: $(cat "${DEFAULT_ERR}")"
fi

# ---------------------------------------------------------------------------
# (v) Model-routing failure surfacing:
#     HARNESS_GROK_COMPANION_MODEL_ROUTER で偽の model-routing.sh を差し込む。
# ---------------------------------------------------------------------------
FAKE_MR="${TMP_DIR}/fake-model-routing.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "ERROR: bogus" >&2\n'
  printf 'exit 2\n'
} >"${FAKE_MR}"
chmod +x "${FAKE_MR}"

make_mock '{"text":"DONE"}' 0
MR_ERR="${TMP_DIR}/model-routing-debug-stderr.txt"
set +e
HARNESS_GROK_COMPANION_MODEL_ROUTER="${FAKE_MR}" \
  run_wrapper --debug task "do the thing" >/dev/null 2>"${MR_ERR}"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "(v) bogus model-routing should still exit 2, got $rc"
grep -q "model-routing.sh stderr:" "${MR_ERR}" \
  || fail "(v) --debug should surface 'model-routing.sh stderr:' prefix, stderr was: $(cat "${MR_ERR}")"
grep -q "could not resolve a Grok model" "${MR_ERR}" \
  || fail "(v) existing 'could not resolve a Grok model' error must still be emitted, stderr was: $(cat "${MR_ERR}")"

# (v-b) DEBUG=0 のときは model-routing.sh の stderr を呑む
make_mock '{"text":"DONE"}' 0
MR_ERR2="${TMP_DIR}/model-routing-silent-stderr.txt"
set +e
HARNESS_GROK_COMPANION_MODEL_ROUTER="${FAKE_MR}" \
  run_wrapper task "do the thing" >/dev/null 2>"${MR_ERR2}"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "(v-b) bogus model-routing without --debug should still exit 2, got $rc"
if grep -q "model-routing.sh stderr:" "${MR_ERR2}"; then
  fail "(v-b) DEBUG=0 must NOT surface model-routing.sh stderr, stderr was: $(cat "${MR_ERR2}")"
fi

# ---------------------------------------------------------------------------
# (w) exit code ゲート単独の検出。既存の失敗系ケース ((b)/(c)/(c2)) はどれも
#     JSON 形状チェックでも落ちるため、exit code ゲートを丸ごと削っても
#     素通りしてしまう（Phase D レビューが変異検査で実証）。
#     ここでは「stdout は整形された成功 JSON なのにプロセスは非ゼロ終了」
#     という、exit code でしか捕まえられない失敗形を作る。
#     現実の例: 出力を flush した直後に OOM kill された場合。
# ---------------------------------------------------------------------------
make_mock '{"text":"LOOKS-FINE","stopReason":"end_turn"}' 137
set +e
out="$(run_wrapper task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -ne 0 ] \
  || fail "(w) grok exited 137 with well-formed success JSON; wrapper must fail closed, got exit 0"
[ "$out" != "LOOKS-FINE" ] \
  || fail "(w) wrapper printed a fabricated success payload from a process that died (exit 137)"

# ---------------------------------------------------------------------------
# 任意: 実ネットワーク smoke（default skip）
# ---------------------------------------------------------------------------
if [ "${HARNESS_GROK_SMOKE:-0}" = "1" ]; then
  echo "running real grok smoke..."
  bash "${WRAPPER}" task "Reply with the single word READY" || fail "(smoke) real grok failed"
fi

echo "ok"
