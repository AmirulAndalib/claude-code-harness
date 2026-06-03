#!/usr/bin/env bash
# test-orchestration-summary.sh
# Phase 90.1.5: completion summary (once at full completion) + on-demand skill.
#
# Verifies:
#   - harness-orchestration skill exists and follows skill-editing conventions
#     (name matches dir, triggers in description, NOT disable-model-invocation)
#   - the completion summary fires ONCE at full completion (task_completed.go
#     all-done branch calls orchestration.Summary) and is NEVER per-task or at
#     session end (cleanup.go must not call Summary)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/harness-orchestration/SKILL.md"
TASK_GO="${REPO_ROOT}/go/internal/hookhandler/task_completed.go"
CLEANUP_GO="${REPO_ROOT}/go/internal/session/cleanup.go"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
ng() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# --- skill conventions ---
[ -f "${SKILL}" ] && ok "harness-orchestration SKILL.md exists" || ng "SKILL.md missing"
if [ -f "${SKILL}" ]; then
  grep -qE '^name:[[:space:]]*harness-orchestration' "${SKILL}" && ok "name matches directory" || ng "name mismatch"
  grep -qiE 'scorecard|オーケストレーション' "${SKILL}" && ok "description has trigger phrases" || ng "no triggers"
  # read-only/judgment skill: must NOT carry disable-model-invocation (P27 non-application)
  if grep -qE '^disable-model-invocation:[[:space:]]*true' "${SKILL}"; then
    ng "must not set disable-model-invocation (read-only skill)"
  else
    ok "no disable-model-invocation (P27 non-application)"
  fi
fi

# --- completion summary fires once at all-done, never per-task / session-end ---
if [ -f "${TASK_GO}" ] && grep -q 'orchestration\.Summary' "${TASK_GO}"; then
  ok "task_completed.go emits completion summary"
  # Summary must appear AFTER the all-tasks-complete gate, not in the per-task path.
  gate_ln="$(grep -nE 'completedCount >= totalTasks' "${TASK_GO}" | head -1 | cut -d: -f1)"
  sum_ln="$(grep -nE 'orchestration\.Summary' "${TASK_GO}" | head -1 | cut -d: -f1)"
  if [ -n "${gate_ln}" ] && [ -n "${sum_ln}" ] && [ "${sum_ln}" -gt "${gate_ln}" ]; then
    ok "summary is inside the all-done branch (fires once, not per-task)"
  else
    ng "summary not gated by all-done (gate=${gate_ln} summary=${sum_ln})"
  fi
else
  ng "task_completed.go does not emit completion summary"
fi

# cleanup.go (SessionEnd) rolls up but must NOT display a summary (record-only)
if [ -f "${CLEANUP_GO}" ] && grep -q 'orchestration\.Summary' "${CLEANUP_GO}"; then
  ng "cleanup.go must not emit a summary (session-end is record-only)"
else
  ok "cleanup.go does not emit a summary (record-only rollup)"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
