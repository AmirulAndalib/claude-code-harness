#!/usr/bin/env bash
# test-orchestration-render.sh
# Phase 90.1.4: HTML scorecard surface (smoke test).
#
# Verifies templates/html/orchestration.html.template renders via render-html.sh
# from the scorecard's html-data projection into a standalone, shareable HTML
# that surfaces the backend names, counts, tri-state, and lifetime figures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE="${REPO_ROOT}/templates/html/orchestration.html.template"
CARD="${REPO_ROOT}/scripts/orchestration-scorecard.sh"
RENDER="${REPO_ROOT}/scripts/render-html.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
ng() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq required"; exit 0; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orch-render-test.XXXXXX")"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

[ -f "${TEMPLATE}" ] && ok "template exists" || ng "template missing"
[ -f "${RENDER}" ] && ok "render-html.sh exists" || ng "render-html.sh missing"
if [ ! -f "${TEMPLATE}" ] || [ ! -f "${RENDER}" ]; then
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  exit 1
fi

LEDGER="${TMP}/ledger.jsonl"
TOTALS="${TMP}/totals.json"
cat >"${LEDGER}" <<'EOF'
{"ts":"2026-06-03T00:00:00Z","backend":"codex","subcommand":"task","write":true,"exit_code":null,"duration_ms":null,"session_id":"S","counts":true}
{"ts":"2026-06-03T00:00:02Z","backend":"cursor","subcommand":"task","write":true,"exit_code":0,"duration_ms":120,"session_id":"S","counts":true}
EOF
cat >"${TOTALS}" <<'EOF'
{"version":1,"totals":{"codex":12,"cursor":38},"rolled_up_sessions":["S"],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-03T00:00:00Z"}
EOF

DATA="${TMP}/html-data.json"
HARNESS_ORCHESTRATION_LEDGER="${LEDGER}" HARNESS_ORCHESTRATION_TOTALS="${TOTALS}" \
  HARNESS_ORCH_FORCE_AVAIL="codex,cursor" \
  bash "${CARD}" --format html-data S >"${DATA}" 2>/dev/null
[ -s "${DATA}" ] && jq -e . "${DATA}" >/dev/null 2>&1 && ok "html-data is valid JSON" || ng "html-data invalid"

# Scorecard data is structurally non-sensitive (counts + backend names + repo
# basename + ISO timestamp only — no prompt/path/secret; the no-secret guarantee
# is enforced upstream by the ledger contract). Output redaction is therefore not
# applied: --with-redaction would false-positive on the Japanese UI labels.
OUT="${TMP}/scorecard.html"
bash "${RENDER}" --template orchestration --data "${DATA}" --out "${OUT}" >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ] && [ -s "${OUT}" ] && ok "render-html produced HTML" || ng "render failed (rc=${rc})"

if [ -s "${OUT}" ]; then
  grep -q '<html' "${OUT}" && ok "output is an HTML document" || ng "no <html>"
  grep -q 'Codex' "${OUT}" && ok "mentions Codex" || ng "missing Codex"
  grep -q 'Cursor' "${OUT}" && ok "mentions Cursor" || ng "missing Cursor"
  grep -q 'Claude' "${OUT}" && ok "mentions Claude (host)" || ng "missing Claude"
  # lifetime figures present (12 / 38)
  grep -q '12' "${OUT}" && grep -q '38' "${OUT}" && ok "lifetime figures rendered (12/38)" || ng "lifetime figures missing"
  # tri-state class rendered
  grep -q 'status-used' "${OUT}" && ok "tri-state used class rendered" || ng "tri-state class missing"
  grep -q 'status-host' "${OUT}" && ok "claude host class rendered" || ng "host class missing"
  # standalone: no external http(s) resource references
  if grep -qiE 'src="https?:|href="https?:|@import|//fonts\.' "${OUT}"; then
    ng "not standalone (external resource reference found)"
  else
    ok "standalone (no external resource refs)"
  fi
  # no unrendered mustache tags left
  if grep -qE '\{\{[#/]?[a-zA-Z_]' "${OUT}"; then
    ng "unrendered mustache tags remain"
  else
    ok "no unrendered mustache tags"
  fi
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
