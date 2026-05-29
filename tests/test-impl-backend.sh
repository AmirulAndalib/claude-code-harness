#!/usr/bin/env bash
# test-impl-backend.sh
# set-impl-backend.sh / resolve-impl-backend.sh の挙動を検証する。
#
# 隔離: HARNESS_ENV_LOCAL で一時 env.local を使い、実 env.local には触れない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SET="${PROJECT_ROOT}/scripts/set-impl-backend.sh"
RESOLVE="${PROJECT_ROOT}/scripts/resolve-impl-backend.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# 隔離した一時 env.local を用意する（TMPDIR を尊重する）
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/impl-backend-test.XXXXXX")"
export HARNESS_ENV_LOCAL="${TMP_DIR}/env.local"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

[ -f "$SET" ] || fail "missing script: $SET"
[ -f "$RESOLVE" ] || fail "missing script: $RESOLVE"

# 各テストの前に env.local をリセットするヘルパ
reset_env_local() {
  rm -f "${HARNESS_ENV_LOCAL}"
}

# ---------------------------------------------------------------------------
# (a) --backend フラグが env と file の両方に勝つ
# ---------------------------------------------------------------------------
reset_env_local
printf 'export HARNESS_IMPL_BACKEND=codex\n' > "${HARNESS_ENV_LOCAL}"
got="$(HARNESS_IMPL_BACKEND=codex bash "$RESOLVE" --backend cursor)"
[ "$got" = "cursor" ] || fail "(a) flag should win over env+file, got '$got'"

# ---------------------------------------------------------------------------
# (b) HARNESS_IMPL_BACKEND env が file に勝つ
# ---------------------------------------------------------------------------
reset_env_local
printf 'export HARNESS_IMPL_BACKEND=cursor\n' > "${HARNESS_ENV_LOCAL}"
got="$(HARNESS_IMPL_BACKEND=codex bash "$RESOLVE")"
[ "$got" = "codex" ] || fail "(b) env should win over file, got '$got'"

# ---------------------------------------------------------------------------
# (c) env / flag が無いとき file の値を使う
# ---------------------------------------------------------------------------
reset_env_local
printf 'export HARNESS_IMPL_BACKEND=cursor\n' > "${HARNESS_ENV_LOCAL}"
got="$(env -u HARNESS_IMPL_BACKEND bash "$RESOLVE")"
[ "$got" = "cursor" ] || fail "(c) file value should be used, got '$got'"

# ---------------------------------------------------------------------------
# (d) 何も設定されていないとき既定値 claude
# ---------------------------------------------------------------------------
reset_env_local
got="$(env -u HARNESS_IMPL_BACKEND bash "$RESOLVE")"
[ "$got" = "claude" ] || fail "(d) default should be claude, got '$got'"

# ---------------------------------------------------------------------------
# (e) set-impl-backend が書き込み、resolve が読み戻す
# ---------------------------------------------------------------------------
reset_env_local
env -u HARNESS_IMPL_BACKEND bash "$SET" codex >/dev/null
got="$(env -u HARNESS_IMPL_BACKEND bash "$RESOLVE")"
[ "$got" = "codex" ] || fail "(e) set then resolve should return codex, got '$got'"
grep -qE "^export HARNESS_IMPL_BACKEND=codex$" "${HARNESS_ENV_LOCAL}" \
  || fail "(e) env.local should contain the export line"

# ---------------------------------------------------------------------------
# (f) set then set-different が置換する（重複行を残さない）
# ---------------------------------------------------------------------------
reset_env_local
env -u HARNESS_IMPL_BACKEND bash "$SET" codex >/dev/null
env -u HARNESS_IMPL_BACKEND bash "$SET" cursor >/dev/null
got="$(env -u HARNESS_IMPL_BACKEND bash "$RESOLVE")"
[ "$got" = "cursor" ] || fail "(f) set-different should replace, got '$got'"
count="$(grep -cE "^export HARNESS_IMPL_BACKEND=" "${HARNESS_ENV_LOCAL}")"
[ "$count" = "1" ] || fail "(f) should have exactly 1 setting line, got $count"

# 冪等性: 同じ値で再実行しても重複を作らない
env -u HARNESS_IMPL_BACKEND bash "$SET" cursor >/dev/null
count="$(grep -cE "^export HARNESS_IMPL_BACKEND=" "${HARNESS_ENV_LOCAL}")"
[ "$count" = "1" ] || fail "(f) idempotent set should keep 1 line, got $count"

# ---------------------------------------------------------------------------
# (g) --unset が設定を削除する
# ---------------------------------------------------------------------------
reset_env_local
env -u HARNESS_IMPL_BACKEND bash "$SET" cursor >/dev/null
env -u HARNESS_IMPL_BACKEND bash "$SET" --unset >/dev/null
count="$(grep -cE "^export HARNESS_IMPL_BACKEND=" "${HARNESS_ENV_LOCAL}" || true)"
[ "$count" = "0" ] || fail "(g) --unset should remove the line, got $count"
got="$(env -u HARNESS_IMPL_BACKEND bash "$RESOLVE")"
[ "$got" = "claude" ] || fail "(g) after unset resolve should default to claude, got '$got'"

# ---------------------------------------------------------------------------
# (h) set-impl-backend に不正な引数を渡すと非ゼロ終了
# ---------------------------------------------------------------------------
reset_env_local
if env -u HARNESS_IMPL_BACKEND bash "$SET" bogus >/dev/null 2>&1; then
  fail "(h) invalid arg should exit non-zero"
fi

# ---------------------------------------------------------------------------
# 追加: --show が解決結果を表示する
# ---------------------------------------------------------------------------
reset_env_local
env -u HARNESS_IMPL_BACKEND bash "$SET" codex >/dev/null
got="$(env -u HARNESS_IMPL_BACKEND bash "$SET" --show)"
[ "$got" = "codex" ] || fail "(--show) should print resolved backend, got '$got'"

# ---------------------------------------------------------------------------
# 追加: file の不正値は警告して claude にフォールバック
# ---------------------------------------------------------------------------
reset_env_local
printf 'export HARNESS_IMPL_BACKEND=bogus\n' > "${HARNESS_ENV_LOCAL}"
got="$(env -u HARNESS_IMPL_BACKEND bash "$RESOLVE" 2>/dev/null)"
[ "$got" = "claude" ] || fail "(invalid-file) should fall back to claude, got '$got'"

echo "ok"
