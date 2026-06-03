#!/usr/bin/env bash
# orchestration-scorecard.sh — render the orchestration visibility scorecard
#
# Phase 90.1.3 (spec.md "Orchestration Visibility Contract"): merges the current
# session's backend mix (from the ledger) with lifetime totals (from the
# accumulator) into an orchestration-scorecard.v1 view.
#
# Usage:
#   bash scripts/orchestration-scorecard.sh [--format json|terminal] [session_id]
#
# Claude is the host runtime and is never counted as a delegation; the headline
# figures are Codex/Cursor delegation counts. Tri-state per backend:
#   used (count>0) / available (configured but unused) / not-configured (absent).
# If nothing is recorded, the scorecard degrades to "no delegations observed".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/orchestration-ledger.sh" ]; then
  # shellcheck source=scripts/lib/orchestration-ledger.sh
  . "${SCRIPT_DIR}/lib/orchestration-ledger.sh" 2>/dev/null || true
fi

FORMAT="json"
SESSION_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-json}"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    -*) shift ;;
    *) SESSION_ID="$1"; shift ;;
  esac
done

if [ -z "${SESSION_ID}" ] && command -v __orch_session_id >/dev/null 2>&1; then
  SESSION_ID="$(__orch_session_id)"
fi

if command -v __orch_ledger_path >/dev/null 2>&1; then
  LEDGER="$(__orch_ledger_path)"
else
  LEDGER="${HARNESS_ORCHESTRATION_LEDGER:-}"
fi
if command -v __orch_totals_path >/dev/null 2>&1; then
  TOTALS="$(__orch_totals_path)"
else
  TOTALS="${HARNESS_ORCHESTRATION_TOTALS:-}"
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"version":1,"observed":false,"note":"jq unavailable"}'
  exit 0
fi

# backend_available <codex|cursor> — HARNESS_ORCH_FORCE_AVAIL overrides for tests.
backend_available() {
  local b="$1"
  if [ "${HARNESS_ORCH_FORCE_AVAIL:-__real__}" != "__real__" ]; then
    case ",${HARNESS_ORCH_FORCE_AVAIL}," in
      *",${b},"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$b" in
    codex) command -v codex >/dev/null 2>&1 ;;
    cursor) command -v cursor-agent >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# session counts for this session (counted delegations only).
session_count() { # $1 = backend
  [ -f "${LEDGER}" ] || { printf '0'; return; }
  jq -s --arg sid "${SESSION_ID}" --arg b "$1" \
    '[.[] | select(.session_id == $sid and .counts == true and .backend == $b)] | length' \
    "${LEDGER}" 2>/dev/null || printf '0'
}

# lifetime count from the accumulator.
lifetime_count() { # $1 = backend
  [ -f "${TOTALS}" ] || { printf '0'; return; }
  jq -r --arg b "$1" '.totals[$b] // 0' "${TOTALS}" 2>/dev/null || printf '0'
}

status_for() { # $1 = count, $2 = backend
  if [ "${1:-0}" -gt 0 ] 2>/dev/null; then printf 'used'; return; fi
  if backend_available "$2"; then printf 'available'; else printf 'not-configured'; fi
}

sc_codex="$(session_count codex)"; sc_codex="${sc_codex:-0}"
sc_cursor="$(session_count cursor)"; sc_cursor="${sc_cursor:-0}"
lt_codex="$(lifetime_count codex)"; lt_codex="${lt_codex:-0}"
lt_cursor="$(lifetime_count cursor)"; lt_cursor="${lt_cursor:-0}"

st_codex="$(status_for "${sc_codex}" codex)"
st_cursor="$(status_for "${sc_cursor}" cursor)"

session_non_claude=$(( sc_codex + sc_cursor ))
lifetime_non_claude=$(( lt_codex + lt_cursor ))

backends_engaged=1 # Claude host is always engaged
[ "${sc_codex}" -gt 0 ] && backends_engaged=$(( backends_engaged + 1 ))
[ "${sc_cursor}" -gt 0 ] && backends_engaged=$(( backends_engaged + 1 ))

if [ "${session_non_claude}" -gt 0 ] || [ "${lifetime_non_claude}" -gt 0 ]; then
  observed="true"
  note="Codex/Cursor への委譲回数。Claude(ホスト)の作業は委譲として計上しない。"
else
  observed="false"
  note="no delegations observed — Codex/Cursor を未使用 (Claude のみで実行)。"
fi

if [ "${FORMAT}" = "terminal" ]; then
  printf 'オーケストレーション活用（このセッション）\n'
  if [ "${observed}" = "false" ]; then
    printf '  %s\n' "${note}"
  else
    printf '  今回: Codex %s / Cursor %s  (Claude=host) — backends engaged %s/3\n' "${sc_codex}" "${sc_cursor}" "${backends_engaged}"
    printf '  累計: Codex %s / Cursor %s\n' "${lt_codex}" "${lt_cursor}"
    printf '  %s\n' "${note}"
  fi
  exit 0
fi

if [ "${FORMAT}" = "html-data" ]; then
  # Flattened shape for scripts/render-html.sh (top-level scalars + a backends
  # array). render-html.sh supports {{var}} and {{#section}} only — no nested
  # dot access — so the nested scorecard.v1 is projected here.
  project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
  gen="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  jq -n \
    --arg project "${project}" --arg gen "${gen}" \
    --argjson observed "${observed}" --arg note "${note}" \
    --argjson sc_codex "${sc_codex}" --arg st_codex "${st_codex}" \
    --argjson sc_cursor "${sc_cursor}" --arg st_cursor "${st_cursor}" \
    --argjson lt_codex "${lt_codex}" --argjson lt_cursor "${lt_cursor}" \
    --argjson snc "${session_non_claude}" --argjson lnc "${lifetime_non_claude}" \
    --argjson be "${backends_engaged}" \
    '{
      kind: "orchestration-scorecard",
      project: $project,
      generated_at: $gen,
      observed: $observed,
      note: $note,
      session_codex: $sc_codex,
      session_cursor: $sc_cursor,
      session_non_claude: $snc,
      backends_engaged: $be,
      lifetime_codex: $lt_codex,
      lifetime_cursor: $lt_cursor,
      lifetime_non_claude: $lnc,
      backends: [
        { name: "Codex", session: ($sc_codex | tostring), lifetime: ($lt_codex | tostring), status: $st_codex },
        { name: "Cursor", session: ($sc_cursor | tostring), lifetime: ($lt_cursor | tostring), status: $st_cursor },
        { name: "Claude", session: "host", lifetime: "—", status: "host" }
      ]
    }'
  exit 0
fi

jq -n \
  --arg sid "${SESSION_ID}" \
  --argjson observed "${observed}" \
  --argjson sc_codex "${sc_codex}" --arg st_codex "${st_codex}" \
  --argjson sc_cursor "${sc_cursor}" --arg st_cursor "${st_cursor}" \
  --argjson lt_codex "${lt_codex}" --argjson lt_cursor "${lt_cursor}" \
  --argjson snc "${session_non_claude}" --argjson lnc "${lifetime_non_claude}" \
  --argjson be "${backends_engaged}" \
  --arg note "${note}" \
  '{
    version: 1,
    session_id: $sid,
    observed: $observed,
    session: {
      codex: { count: $sc_codex, status: $st_codex },
      cursor: { count: $sc_cursor, status: $st_cursor },
      claude: { status: "host" },
      non_claude_delegations: $snc,
      backends_engaged: $be
    },
    lifetime: {
      codex: { count: $lt_codex },
      cursor: { count: $lt_cursor },
      non_claude_delegations: $lnc
    },
    note: $note
  }'
