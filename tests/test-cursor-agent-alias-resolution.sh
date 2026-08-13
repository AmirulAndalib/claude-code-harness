#!/usr/bin/env bash
# test-cursor-agent-alias-resolution.sh
# 133.1: Cursor 公式ドキュメントが 2026-08-11 時点で全例を `agent` 表記に統一し、
# `cursor-agent` を install script 内で "legacy alias" と明記したことを受けて、
# scripts/cursor-companion.sh の resolve_cursor_agent() と
# scripts/orchestration-scorecard.sh の cursor_agent_probe() が
#   (1) `agent` を優先探索する
#   (2) `agent` は汎用的な名前なので、resolve 後の実パスに "cursor-agent" が
#       含まれるかで identity を検証し、通らなければ `cursor-agent` へ
#       フォールバックする
# ことを検証する。
#
# 隔離: 実 agent / cursor-agent は一切呼ばない。すべて PATH を
# "${MOCK_BIN_DIR}:/usr/local/bin:/usr/bin:/bin" に絞り、$HOME も temp に差し替えることで、
# 開発機に本物の Cursor CLI がインストール済みでも（本タスクの実測環境がまさに
# そうだった）モックだけが解決されることを保証する。CI で両バイナリとも
# 不在の環境でも同じ理由でそのまま動く。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="${PROJECT_ROOT}/scripts/cursor-companion.sh"
SCORECARD="${PROJECT_ROOT}/scripts/orchestration-scorecard.sh"

fail() {
  echo "test-cursor-agent-alias-resolution: FAIL: $1" >&2
  exit 1
}

[ -f "$WRAPPER" ] || fail "missing script: $WRAPPER"
[ -f "$SCORECARD" ] || fail "missing script: $SCORECARD"
command -v jq >/dev/null 2>&1 || fail "jq is required for these tests"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cursor-alias-resolution-test.XXXXXX")"
# 安全ネット: TMP_DIR のパス自体に "cursor-agent" という部分文字列が偶然含まれると
# (h)/(g2) の identity-check-fail シナリオが誤って pass してしまう。先に検査する。
case "${TMP_DIR}" in
  *cursor-agent*) fail "TMP_DIR unexpectedly contains 'cursor-agent' substring: ${TMP_DIR}" ;;
esac

MOCK_BIN_DIR="${TMP_DIR}/bin"
ISOLATED_HOME="${TMP_DIR}/empty-home"
WORKSPACE_DIR="${TMP_DIR}/ws"
mkdir -p "${MOCK_BIN_DIR}" "${ISOLATED_HOME}" "${WORKSPACE_DIR}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

reset_bin() {
  rm -rf "${MOCK_BIN_DIR}"
  mkdir -p "${MOCK_BIN_DIR}"
}

# 隔離 PATH（本物の ~/.local/bin 等を一切含まない）でラッパーを叩くヘルパ。
# /usr/local/bin は model-routing.sh が hosts/registry.json を読むのに使う node
# 用に必要（/usr/local/bin に agent/cursor-agent が無いことは事前に確認済み）。
ISOLATED_PATH="${MOCK_BIN_DIR}:/usr/local/bin:/usr/bin:/bin"

run_wrapper_isolated() {
  PATH="${ISOLATED_PATH}" HOME="${ISOLATED_HOME}" bash "${WRAPPER}" "$@"
}

# 隔離 PATH + 空の ledger/totals + HARNESS_ORCH_FORCE_AVAIL 未設定（実 probe を
# 通す）で scorecard を叩くヘルパ。
run_scorecard_isolated() {
  env -u HARNESS_ORCH_FORCE_AVAIL \
    PATH="${ISOLATED_PATH}" \
    HOME="${ISOLATED_HOME}" \
    HARNESS_ORCHESTRATION_LEDGER="${TMP_DIR}/no-ledger.jsonl" \
    HARNESS_ORCHESTRATION_TOTALS="${TMP_DIR}/no-totals.json" \
    bash "${SCORECARD}" --format json "test-session"
}

# 実 Cursor CLI のレイアウト（~/.local/bin/agent が
# ~/.local/share/cursor-agent/versions/<ver>/cursor-agent への symlink）を模した
# 「正しい」agent バイナリを設置する。
#   $1 = ARGS_FILE (呼ばれたら引数をここへ記録する)
#   $2 = stdout に出す JSON body
install_valid_agent() {
  local args_file="$1"
  local json_body="$2"
  local real_dir="${MOCK_BIN_DIR}/versions/2026.08.04-test"
  mkdir -p "${real_dir}"
  local real_bin="${real_dir}/cursor-agent"
  cat >"${real_bin}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${args_file}"
cat <<'JSON_EOF'
${json_body}
JSON_EOF
exit 0
EOF
  chmod +x "${real_bin}"
  ln -sf "${real_bin}" "${MOCK_BIN_DIR}/agent"
}

# 名前は `cursor-agent` だが Cursor とは無関係な実体（実パスに "cursor-agent" を
# 含む legacy alias のモック）。
install_valid_cursor_agent() {
  local args_file="$1"
  local json_body="$2"
  local bin="${MOCK_BIN_DIR}/cursor-agent"
  cat >"${bin}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${args_file}"
cat <<'JSON_EOF'
${json_body}
JSON_EOF
exit 0
EOF
  chmod +x "${bin}"
}

# identity check に落ちるべき「無関係な agent」。実パスがそのまま
# ${MOCK_BIN_DIR}/agent なので "cursor-agent" 部分文字列を含まない。
# 呼ばれてしまった場合の検出用に WRONG_MARKER を書く。
install_wrong_agent() {
  local marker="$1"
  local bin="${MOCK_BIN_DIR}/agent"
  cat >"${bin}" <<EOF
#!/usr/bin/env bash
touch "${marker}"
echo '{"is_error":false,"result":"WRONG-AGENT-INVOKED"}'
exit 0
EOF
  chmod +x "${bin}"
}

# ===========================================================================
# Group A: scripts/cursor-companion.sh resolve_cursor_agent()
# ===========================================================================

# ---------------------------------------------------------------------------
# (A1) `agent` のみ存在し、実パスが .../cursor-agent を指す（identity OK）
#      → wrapper は agent 経由で成功する
# ---------------------------------------------------------------------------
reset_bin
ARGS_A1="${TMP_DIR}/args-a1.txt"
install_valid_agent "${ARGS_A1}" '{"is_error":false,"result":"AGENT-OK"}'
set +e
out="$(run_wrapper_isolated task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(A1) agent-only should exit 0, got $rc"
[ "$out" = "AGENT-OK" ] || fail "(A1) agent-only should print 'AGENT-OK', got '$out'"
[ -f "${ARGS_A1}" ] || fail "(A1) agent mock should have been invoked (ARGS_A1 missing)"

# ---------------------------------------------------------------------------
# (A2) `cursor-agent` のみ存在（`agent` は不在）
#      → wrapper は cursor-agent 経由で成功する（legacy alias フォールバック）
# ---------------------------------------------------------------------------
reset_bin
ARGS_A2="${TMP_DIR}/args-a2.txt"
install_valid_cursor_agent "${ARGS_A2}" '{"is_error":false,"result":"CURSOR-AGENT-OK"}'
set +e
out="$(run_wrapper_isolated task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(A2) cursor-agent-only should exit 0, got $rc"
[ "$out" = "CURSOR-AGENT-OK" ] || fail "(A2) cursor-agent-only should print 'CURSOR-AGENT-OK', got '$out'"
[ -f "${ARGS_A2}" ] || fail "(A2) cursor-agent mock should have been invoked (ARGS_A2 missing)"

# ---------------------------------------------------------------------------
# (A3) `agent` は存在するが無関係な実体（identity check NG）。
#      `cursor-agent` は別途正しく存在する。
#      → wrapper は wrong-agent を絶対に呼ばず、cursor-agent へフォールバックし
#        成功する
# ---------------------------------------------------------------------------
reset_bin
WRONG_MARKER_A3="${TMP_DIR}/wrong-marker-a3.txt"
ARGS_A3="${TMP_DIR}/args-a3.txt"
install_wrong_agent "${WRONG_MARKER_A3}"
install_valid_cursor_agent "${ARGS_A3}" '{"is_error":false,"result":"FALLBACK-OK"}'
set +e
out="$(run_wrapper_isolated task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(A3) wrong-agent + valid cursor-agent should exit 0, got $rc"
[ "$out" = "FALLBACK-OK" ] || fail "(A3) should fall back to cursor-agent and print 'FALLBACK-OK', got '$out'"
[ ! -f "${WRONG_MARKER_A3}" ] || fail "(A3) wrong 'agent' binary must NEVER be invoked (identity check must reject it), but its marker was created"
[ -f "${ARGS_A3}" ] || fail "(A3) cursor-agent fallback mock should have been invoked (ARGS_A3 missing)"

# ---------------------------------------------------------------------------
# (A3b) --debug 有効時、wrapper stderr に identity-check-fail の debug ログが
#       出ること（フォールバックの理由が観測可能であることの確認）
# ---------------------------------------------------------------------------
reset_bin
WRONG_MARKER_A3B="${TMP_DIR}/wrong-marker-a3b.txt"
ARGS_A3B="${TMP_DIR}/args-a3b.txt"
install_wrong_agent "${WRONG_MARKER_A3B}"
install_valid_cursor_agent "${ARGS_A3B}" '{"is_error":false,"result":"FALLBACK-OK"}'
DEBUG_ERR_A3B="${TMP_DIR}/debug-a3b.txt"
set +e
out="$(PATH="${ISOLATED_PATH}" HOME="${ISOLATED_HOME}" bash "${WRAPPER}" --debug task "do the thing" 2>"${DEBUG_ERR_A3B}")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(A3b) --debug fallback path should still exit 0, got $rc"
[ "$out" = "FALLBACK-OK" ] || fail "(A3b) --debug fallback path should print 'FALLBACK-OK', got '$out'"
grep -q "failed identity check" "${DEBUG_ERR_A3B}" \
  || fail "(A3b) --debug stderr should mention the identity check failure, got: $(cat "${DEBUG_ERR_A3B}")"
[ ! -f "${WRONG_MARKER_A3B}" ] || fail "(A3b) wrong 'agent' binary must NEVER be invoked, but its marker was created"

# ---------------------------------------------------------------------------
# (A3c) 部分文字列衝突による identity check 突破の回帰テスト。
#       `agent` の実パスが .../cursor-agent-tools-but-not-really/agent という
#       「cursor-agent を部分文字列として含むが成分としては一致しない」場所に
#       ある場合、identity check は必ず落ちなければならない。
#       cursor-agent 側は用意しないので、正しい実装なら exit 3 (not-found)。
#       部分文字列一致の実装ではここで無関係バイナリが実行され rc=0 になる。
#       (Phase 133 Phase D レビュー指摘の再発防止)
# ---------------------------------------------------------------------------
reset_bin
COLLIDE_DIR="${TMP_DIR}/cursor-agent-tools-but-not-really"
mkdir -p "${COLLIDE_DIR}"
WRONG_MARKER_A3C="${TMP_DIR}/wrong-marker-a3c.txt"
cat >"${COLLIDE_DIR}/agent" <<EOF
#!/usr/bin/env bash
touch "${WRONG_MARKER_A3C}"
echo '{"is_error":false,"result":"SUBSTRING-BYPASS"}'
exit 0
EOF
chmod +x "${COLLIDE_DIR}/agent"
set +e
out="$(PATH="${COLLIDE_DIR}:${ISOLATED_PATH}" HOME="${ISOLATED_HOME}" bash "${WRAPPER}" task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ ! -f "${WRONG_MARKER_A3C}" ] \
  || fail "(A3c) substring-colliding path must NOT satisfy the identity check, but the binary was invoked"
[ "$out" != "SUBSTRING-BYPASS" ] \
  || fail "(A3c) substring-colliding 'agent' output leaked through — identity check is a substring match"
[ "$rc" -eq 3 ] || fail "(A3c) with no genuine cursor-agent present, wrapper should exit 3, got $rc"

# ---------------------------------------------------------------------------
# (A4) `agent` も `cursor-agent` も存在しない → exit 3 (not-found)
#      隔離 PATH ($ISOLATED_PATH) と $HOME 両方から本物排除。
# ---------------------------------------------------------------------------
reset_bin
set +e
out="$(run_wrapper_isolated task "do the thing" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "(A4) neither binary present should exit 3, got $rc"

# ===========================================================================
# Group B: scripts/orchestration-scorecard.sh cursor_agent_probe()
# ===========================================================================

# ---------------------------------------------------------------------------
# (B1) `agent` のみ存在し identity OK → session.cursor.status = "available"
#      (session/lifetime ともに 0 件なので used にはならない)
# ---------------------------------------------------------------------------
reset_bin
install_valid_agent "${TMP_DIR}/args-b1.txt" '{"is_error":false,"result":"unused"}'
json_b1="$(run_scorecard_isolated)"
status_b1="$(echo "${json_b1}" | jq -r '.session.cursor.status')"
[ "${status_b1}" = "available" ] || fail "(B1) agent-only (identity OK) should report cursor status 'available', got '${status_b1}': ${json_b1}"

# ---------------------------------------------------------------------------
# (B2) `cursor-agent` のみ存在（legacy alias） → status = "available"
# ---------------------------------------------------------------------------
reset_bin
install_valid_cursor_agent "${TMP_DIR}/args-b2.txt" '{"is_error":false,"result":"unused"}'
json_b2="$(run_scorecard_isolated)"
status_b2="$(echo "${json_b2}" | jq -r '.session.cursor.status')"
[ "${status_b2}" = "available" ] || fail "(B2) cursor-agent-only should report cursor status 'available', got '${status_b2}': ${json_b2}"

# ---------------------------------------------------------------------------
# (B3) `agent` は無関係な実体のみ、`cursor-agent` は不在
#      → identity check が正しく落ち、status = "not-configured"
# ---------------------------------------------------------------------------
reset_bin
install_wrong_agent "${TMP_DIR}/wrong-marker-b3.txt"
json_b3="$(run_scorecard_isolated)"
status_b3="$(echo "${json_b3}" | jq -r '.session.cursor.status')"
[ "${status_b3}" = "not-configured" ] || fail "(B3) wrong agent + no cursor-agent should report 'not-configured', got '${status_b3}': ${json_b3}"

echo "test-cursor-agent-alias-resolution: ok"
