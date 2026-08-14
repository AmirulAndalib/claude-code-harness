#!/usr/bin/env bash
# Task 133.4 — repair-loop state contract tests
#
# Validates:
#   (1) init creates a schema-valid state file
#   (2) record increments the iteration count and stores the verdict/findings
#   (3) check passes (exit 0) while iteration < max_iterations
#   (4) check FAILS (exit non-zero) once iteration >= max_iterations without APPROVE
#   (5) check passes (exit 0) when APPROVE lands, even at the ceiling
#   (6) a path-traversal task id is refused by init/record/check
#   (7) the produced state file validates against templates/schemas/repair-loop.v1.json
#
# Uses a temp project root throughout; never writes into the real .claude/state/.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/repair-loop-state.sh"
SCHEMA="${ROOT_DIR}/templates/schemas/repair-loop.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  echo "test-repair-loop-state: FAIL: $1" >&2
  exit 1
}

pass() {
  echo "✓ $1"
}

[ -f "${SCRIPT}" ] || fail "missing ${SCRIPT}"
[ -x "${SCRIPT}" ] || fail "not executable: ${SCRIPT}"
[ -f "${SCHEMA}" ] || fail "missing ${SCHEMA}"

validate_against_schema() {
  local state_file="$1"
  python3 - "${state_file}" "${SCHEMA}" <<'PY'
import json
import sys

state_path, schema_path = sys.argv[1:3]
with open(state_path, encoding="utf-8") as f:
    data = json.load(f)
with open(schema_path, encoding="utf-8") as f:
    schema = json.load(f)

try:
    import jsonschema  # type: ignore
    jsonschema.validate(instance=data, schema=schema, format_checker=jsonschema.FormatChecker())
except ImportError:
    # jsonschema not installed: fall back to a minimal structural check so the
    # test still catches obviously broken output.
    required = {"schema_version", "task", "max_iterations", "status", "created_at", "updated_at", "iterations"}
    missing = required - set(data)
    if missing:
        raise SystemExit(f"missing top-level fields: {sorted(missing)}")
    if data["schema_version"] != "repair-loop.v1":
        raise SystemExit(f"unexpected schema_version: {data['schema_version']!r}")
print("OK")
PY
}

PROJECT="${TMP_DIR}/project"
mkdir -p "${PROJECT}"

# ---- (1) init creates a valid file ----

STATE_PATH="$("${SCRIPT}" init "${PROJECT}" "133.4" 3)"
[ -f "${STATE_PATH}" ] || fail "init did not create ${STATE_PATH}"
[ "${STATE_PATH}" = "${PROJECT}/.claude/state/repair-loop/133.4.json" ] \
  || fail "init wrote to an unexpected path: ${STATE_PATH}"

STATUS="$(jq -r '.status' "${STATE_PATH}")"
[ "${STATUS}" = "open" ] || fail "init should start status=open, got ${STATUS}"
ITER_COUNT="$(jq -r '.iterations | length' "${STATE_PATH}")"
[ "${ITER_COUNT}" -eq 0 ] || fail "init should start with zero iterations, got ${ITER_COUNT}"
validate_against_schema "${STATE_PATH}" >/dev/null
pass "init creates a schema-valid state file at .claude/state/repair-loop/<task>.json"

# ---- (2) record increments ----

"${SCRIPT}" record "${PROJECT}" "133.4" REQUEST_CHANGES \
  '[{"severity":"major","issue":"missing null check","file":"scripts/foo.sh"}]' >/dev/null
ITER_COUNT="$(jq -r '.iterations | length' "${STATE_PATH}")"
[ "${ITER_COUNT}" -eq 1 ] || fail "record #1 should bring iteration count to 1, got ${ITER_COUNT}"
FIRST_ISSUE="$(jq -r '.iterations[0].findings[0].issue' "${STATE_PATH}")"
[ "${FIRST_ISSUE}" = "missing null check" ] || fail "record did not store findings correctly"
STATUS="$(jq -r '.status' "${STATE_PATH}")"
[ "${STATUS}" = "open" ] || fail "status should remain open below the ceiling, got ${STATUS}"
pass "record increments iteration count and stores verdict/findings"

# ---- (3) check passes below the ceiling ----

if ! "${SCRIPT}" check "${PROJECT}" "133.4" >/dev/null; then
  fail "check should exit 0 while iteration (1) < max_iterations (3)"
fi
pass "check exits 0 while iteration < max_iterations"

# ---- (4) check FAILS at/above the ceiling without APPROVE ----

"${SCRIPT}" record "${PROJECT}" "133.4" REQUEST_CHANGES '[]' >/dev/null
"${SCRIPT}" record "${PROJECT}" "133.4" REQUEST_CHANGES '[]' >/dev/null
ITER_COUNT="$(jq -r '.iterations | length' "${STATE_PATH}")"
[ "${ITER_COUNT}" -eq 3 ] || fail "expected 3 iterations before ceiling check, got ${ITER_COUNT}"
STATUS="$(jq -r '.status' "${STATE_PATH}")"
[ "${STATUS}" = "escalated" ] || fail "status should be escalated at the ceiling without APPROVE, got ${STATUS}"

if "${SCRIPT}" check "${PROJECT}" "133.4" >/dev/null; then
  fail "check should exit non-zero once iteration (3) >= max_iterations (3) without APPROVE"
fi
pass "check exits non-zero once iteration >= max_iterations without APPROVE"

# ---- (5) check passes when APPROVE lands, even at the ceiling ----

STATE_PATH2="$("${SCRIPT}" init "${PROJECT}" "133.4b" 2)"
"${SCRIPT}" record "${PROJECT}" "133.4b" REQUEST_CHANGES '[]' >/dev/null
"${SCRIPT}" record "${PROJECT}" "133.4b" APPROVE '[]' >/dev/null
STATUS2="$(jq -r '.status' "${STATE_PATH2}")"
[ "${STATUS2}" = "approved" ] || fail "status should be approved once APPROVE is recorded, got ${STATUS2}"
if ! "${SCRIPT}" check "${PROJECT}" "133.4b" >/dev/null; then
  fail "check should exit 0 when the loop concluded with APPROVE, even at the ceiling"
fi
pass "check exits 0 when APPROVE lands at the ceiling (matches review-loop.md: escalate only if verdict != APPROVE)"

# ---- (6) path-traversal task id is refused ----

for evil_task in "../../etc/passwd" "../escape" "a/b" "/abs" ".."; do
  if "${SCRIPT}" init "${PROJECT}" "${evil_task}" 3 >/dev/null 2>&1; then
    fail "init accepted a path-traversal task id: ${evil_task}"
  fi
  if "${SCRIPT}" check "${PROJECT}" "${evil_task}" >/dev/null 2>&1; then
    fail "check accepted a path-traversal task id: ${evil_task}"
  fi
done
ESCAPED_PATH="${TMP_DIR}/passwd.json"
[ ! -f "${ESCAPED_PATH}" ] || fail "path-traversal task id actually escaped the state dir"
pass "path-traversal task ids are refused by init/check"

# ---- (7) schema validation ----

validate_against_schema "${STATE_PATH}" >/dev/null
validate_against_schema "${STATE_PATH2}" >/dev/null
pass "produced state files validate against templates/schemas/repair-loop.v1.json"

# ---- (8) 並行 record で iteration が失われない (Phase D レビュー指摘) ----
# atomic_write だけでは read-modify-write を直列化できない。ロックが外れると
# 並行 10 プロセスのうち 1 件しか残らないことが実測されている。

CONC_TASK="conc.task"
"${SCRIPT}" init "${PROJECT}" "${CONC_TASK}" 99 >/dev/null
for _ in $(seq 1 10); do
  "${SCRIPT}" record "${PROJECT}" "${CONC_TASK}" REQUEST_CHANGES >/dev/null 2>&1 &
done
wait
CONC_PATH="${PROJECT}/.claude/state/repair-loop/${CONC_TASK}.json"
conc_count="$(jq -r '.iterations | length' "${CONC_PATH}")"
[ "${conc_count}" -eq 10 ] \
  || fail "(8) concurrent record lost iterations: expected 10, got ${conc_count} (read-modify-write is not serialized)"
jq -e '[.iterations[].iteration] == [range(1;11)]' "${CONC_PATH}" >/dev/null \
  || fail "(8) concurrent record produced duplicate/gapped iteration numbers: $(jq -c '[.iterations[].iteration]' "${CONC_PATH}")"
validate_against_schema "${CONC_PATH}" >/dev/null
pass "concurrent record calls serialize; no iteration is lost and numbering stays 1..N"

# ---- (9) findings は schema と同じ制約で拒否される ----
# schema ファイルがあっても script が検証しなければ、check が読む状態は
# schema を通らなくなる。以下はすべて schema 違反なので record が拒否すべき。

BAD_TASK="bad.findings"
"${SCRIPT}" init "${PROJECT}" "${BAD_TASK}" 3 >/dev/null
while IFS= read -r bad_findings; do
  [ -n "${bad_findings}" ] || continue
  if "${SCRIPT}" record "${PROJECT}" "${BAD_TASK}" REQUEST_CHANGES "${bad_findings}" >/dev/null 2>&1; then
    fail "(9) record accepted schema-invalid findings: ${bad_findings}"
  fi
done <<'BADEOF'
[{"severity":"catastrophic","issue":"unknown severity"}]
[{"severity":"major"}]
[{"issue":"missing severity"}]
[{"severity":"major","issue":"x","note":"extra property"}]
[{"severity":"major","issue":123}]
["not an object"]
[{"severity":"minor","issue":""}]
BADEOF
BAD_PATH="${PROJECT}/.claude/state/repair-loop/${BAD_TASK}.json"
[ "$(jq -r '.iterations | length' "${BAD_PATH}")" -eq 0 ] \
  || fail "(9) a schema-invalid findings payload was written into the state file"
# 逆方向も検査する。過剰な拒否も欠陥であり、schema が許すものは通さねばならない。
# 特に file: null は「多くの JSON シリアライザが未設定の任意フィールドに出す形」で、
# schema は ["string","null"] を許可している。
while IFS= read -r good_findings; do
  [ -n "${good_findings}" ] || continue
  "${SCRIPT}" record "${PROJECT}" "${BAD_TASK}" REQUEST_CHANGES "${good_findings}" >/dev/null \
    || fail "(9) a schema-VALID findings payload was wrongly rejected: ${good_findings}"
done <<'GOODEOF'
[]
[{"severity":"major","issue":"valid","file":"a.sh"}]
[{"severity":"minor","issue":"file omitted"}]
[{"severity":"recommendation","issue":"file is null","file":null}]
[{"severity":"critical","issue":"日本語とバッククォート ` を含む"}]
GOODEOF
validate_against_schema "${BAD_PATH}" >/dev/null
pass "record rejects findings that the schema would reject, and still accepts valid ones"

# ---- (10) check は「上限到達」と「判定不能」を別の終了コードで返す ----
# 両方 1 にすると、init 忘れやパス誤りが「レビュー上限到達」として利用者に
# 誤報される (review-loop.md が exit code だけで分岐しているため)。

ESC_TASK="esc.task"
"${SCRIPT}" init "${PROJECT}" "${ESC_TASK}" 1 >/dev/null
"${SCRIPT}" record "${PROJECT}" "${ESC_TASK}" REQUEST_CHANGES >/dev/null
set +e
"${SCRIPT}" check "${PROJECT}" "${ESC_TASK}" >/dev/null 2>&1; esc_rc=$?
"${SCRIPT}" check "${PROJECT}" "never.initialized" >/dev/null 2>&1; noinit_rc=$?
"${SCRIPT}" check "${TMP_DIR}/no-such-root" "${ESC_TASK}" >/dev/null 2>&1; noroot_rc=$?
printf '{"schema_version":"repair-loop.v1","task":"corrupt.task","max_iterations":3,"status":"garbage","created_at":"x","updated_at":"x","iterations":[]}' \
  > "${PROJECT}/.claude/state/repair-loop/corrupt.task.json"
"${SCRIPT}" check "${PROJECT}" "corrupt.task" >/dev/null 2>&1; corrupt_rc=$?
set -e
[ "${esc_rc}" -eq 1 ] || fail "(10) ceiling escalation should exit 1, got ${esc_rc}"
[ "${noinit_rc}" -ne 1 ] || fail "(10) a missing state file must NOT be reported with the escalation code 1"
[ "${noroot_rc}" -ne 1 ] || fail "(10) a bad project root must NOT be reported with the escalation code 1"
[ "${corrupt_rc}" -ne 1 ] || fail "(10) a corrupt status must NOT be reported with the escalation code 1"
for rc in "${noinit_rc}" "${noroot_rc}" "${corrupt_rc}"; do
  [ "${rc}" -ne 0 ] || fail "(10) an unevaluable check must still fail, got exit 0"
done
pass "check distinguishes escalation (exit 1) from cannot-evaluate (non-1, non-zero)"

# ---- sanity: no writes into the real .claude/state/ happened ----

[ ! -e "${ROOT_DIR}/.claude/state/repair-loop" ] \
  || fail "test leaked into the real .claude/state/repair-loop (must use a temp project root)"

echo "test-repair-loop-state: ok"
