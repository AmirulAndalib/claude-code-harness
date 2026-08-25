#!/usr/bin/env bash
# Focused static contract for Codex-host Breezing native workers.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_WORK="${ROOT_DIR}/skills/harness-work/SKILL.md"
CODEX_WORKER_AGENT="${ROOT_DIR}/codex/.codex/agents/worker.toml"

# Every implementation/retry/manual Codex task call in the Breezing and
# harness-work skill families must pin the dedicated worker tier. Ignore prose
# and table references; count executable-looking call lines, including the
# continuation line after an environment assignment.
assert_codex_task_calls_pinned() {
  local file="$1"
  local stats calls pinned
  if ! stats="$(awk '
    function is_task_call(line) {
      return line ~ /codex-companion[.]sh.*task/ &&
        line !~ /^[[:space:]]*[>|]/ && line !~ /^[[:space:]]*\|/
    }
    is_task_call($0) {
      calls++
      if ($0 ~ /CODEX_MODEL_TIER=worker/ || previous ~ /CODEX_MODEL_TIER=worker/) {
        pinned++
      }
    }
    { previous = $0 }
    END {
      if (calls == 0 || calls != pinned) {
        exit 1
      }
      printf "%d %d\n", calls, pinned
    }
  ' "$file")"; then
    echo "${file}: every Breezing Codex task call must pin CODEX_MODEL_TIER=worker"
    exit 1
  fi
  read -r calls pinned <<<"${stats}"
  [ "${calls}" -gt 0 ] || {
    echo "${file}: Breezing Codex task calls are missing"
    exit 1
  }
  [ "${calls}" = "${pinned}" ] || {
    echo "${file}: Codex task calls ${calls} != pinned calls ${pinned}"
    exit 1
  }
}

[ -f "${CODEX_WORKER_AGENT}" ] || {
  echo "managed Codex worker agent profile is missing"
  exit 1
}
grep -Fq -- 'name = "worker"' "${CODEX_WORKER_AGENT}" || {
  echo "managed Codex worker agent profile must define name=worker"
  exit 1
}
grep -Fq -- 'description = ' "${CODEX_WORKER_AGENT}" || {
  echo "managed Codex worker agent profile must define a description"
  exit 1
}
grep -Fq -- 'developer_instructions = ' "${CODEX_WORKER_AGENT}" || {
  echo "managed Codex worker agent profile must define developer instructions"
  exit 1
}
grep -Fq -- 'model = "gpt-5.6-luna"' "${CODEX_WORKER_AGENT}" || {
  echo "managed Codex worker agent profile must route to luna"
  exit 1
}
grep -Fq -- 'model_reasoning_effort = "max"' "${CODEX_WORKER_AGENT}" || {
  echo "managed Codex worker agent profile must route to max effort"
  exit 1
}

# Every shared harness-work Codex implementation/retry call must pin the
# dedicated worker tier. The previous/continuation line is included because the
# long stdin example puts the environment assignment before a continued bash.
shared_codex_call_count="$(awk '/codex-companion\.sh.*task/ && $0 !~ /^\|/ { calls++ } END { print calls + 0 }' "${SHARED_WORK}")"
shared_pinned_call_count="$(awk '
  /codex-companion\.sh.*task/ && $0 !~ /^\|/ {
    calls++
    if ($0 ~ /CODEX_MODEL_TIER=worker/ || previous ~ /CODEX_MODEL_TIER=worker/) {
      pinned++
    }
  }
  { previous = $0 }
  END {
    if (calls != pinned) {
      exit 1
    }
    print calls
  }
' "${SHARED_WORK}" || true)"
[ "${shared_codex_call_count}" -gt 0 ] || {
  echo "shared harness-work Codex companion calls are missing"
  exit 1
}
[ "${shared_pinned_call_count}" = "${shared_codex_call_count}" ] || {
  echo "shared harness-work Codex companion calls must pin CODEX_MODEL_TIER=worker"
  exit 1
}

for skill in \
  "${ROOT_DIR}/skills/breezing/SKILL.md" \
  "${ROOT_DIR}/skills-codex/breezing/SKILL.md" \
  "${ROOT_DIR}/codex/.codex/skills/breezing/SKILL.md" \
  "${ROOT_DIR}/opencode/skills/breezing/SKILL.md" \
  "${ROOT_DIR}/skills/harness-work/SKILL.md" \
  "${ROOT_DIR}/skills-codex/harness-work/SKILL.md" \
  "${ROOT_DIR}/codex/.codex/skills/harness-work/SKILL.md" \
  "${ROOT_DIR}/opencode/skills/harness-work/SKILL.md"
do
  assert_codex_task_calls_pinned "${skill}"
done

for skill in \
  "${ROOT_DIR}/skills-codex/harness-work/SKILL.md" \
  "${ROOT_DIR}/skills-codex/breezing/SKILL.md" \
  "${ROOT_DIR}/codex/.codex/skills/harness-work/SKILL.md" \
  "${ROOT_DIR}/codex/.codex/skills/breezing/SKILL.md"
do
  if grep -Fq -- '--host codex --role worker --format json' "${skill}"; then
    echo "${skill} must not resolve worker model JSON in skill prose"
    exit 1
  fi
  if grep -Fq -- 'codex_worker_route' "${skill}"; then
    echo "${skill} must not carry a native worker router cache"
    exit 1
  fi
  grep -Fq -- 'fork_turns: "3"' "${skill}" || {
    echo "${skill} must bound native worker fork depth"
    exit 1
  }
  worker_spawn_block="$(awk '
    /worker_id = spawn_agent\(\{/ { capture = 1 }
    capture { print }
    capture && /^[[:space:]]*\}\)/ { exit }
  ' "${skill}")"
  [ -n "${worker_spawn_block}" ] || {
    echo "${skill} must define a native worker spawn block"
    exit 1
  }
  if ! printf '%s\n' "${worker_spawn_block}" | grep -F -- 'agent_type: "worker"' >/dev/null; then
    echo "${skill} native worker spawn must select the managed worker agent"
    exit 1
  fi
  if printf '%s\n' "${worker_spawn_block}" | grep -E '^[[:space:]]*(model|reasoning_effort):' >/dev/null; then
    echo "${skill} native worker spawn must not override managed model/effort"
    exit 1
  fi
  branch_info="$(awk '
    /^    if backend == "cursor":$/ { cursor_line = NR }
    /^    elif backend == "codex":$/ && cursor_line { print cursor_line ":" NR; exit }
  ' "${skill}")"
  [ -n "${branch_info}" ] || {
    echo "${skill} must define cursor/codex companion branches"
    exit 1
  }
  cursor_branch_start="${branch_info%%:*}"
  codex_branch_start="${branch_info##*:}"
  native_branch_start="$(awk -v codex_start="${codex_branch_start}" '
    NR > codex_start && /^    else:$/ { print NR; exit }
  ' "${skill}")"
  [ -n "${native_branch_start}" ] || {
    echo "${skill} must define a native worker branch after companion branches"
    exit 1
  }
  companion_branch_block="$(sed -n "${cursor_branch_start},$((native_branch_start - 1))p" "${skill}")"
  if printf '%s\n' "${companion_branch_block}" | grep -E 'codex_worker_route|worker_model|worker_effort|spawn_agent|--host codex --role worker --format json' >/dev/null; then
    echo "${skill} companion branches must not depend on native worker spawn configuration"
    exit 1
  fi
  if printf '%s\n' "${worker_spawn_block}" | grep -F -- 'fork_context' >/dev/null; then
    echo "${skill} native worker spawn must not pass unsupported fork_context"
    exit 1
  fi
  if grep -Fq -- 'fork_context' "${skill}"; then
    echo "${skill} must not use the retired Codex fork_context API"
    exit 1
  fi
  if grep -Fq -- 'gpt-5.6-luna' "${skill}"; then
    echo "${skill} must not hardcode a model id"
    exit 1
  fi
done

for skill in \
  "${ROOT_DIR}/skills-codex/harness-work/SKILL.md" \
  "${ROOT_DIR}/skills-codex/breezing/SKILL.md" \
  "${ROOT_DIR}/codex/.codex/skills/harness-work/SKILL.md" \
  "${ROOT_DIR}/codex/.codex/skills/breezing/SKILL.md"
do
  grep -Fq -- 'CODEX_MODEL_TIER=worker' "${skill}" || {
    echo "${skill} must pin breezing --codex workers to the routed worker tier"
    exit 1
  }
done

echo "test-breezing-codex-worker-route: ok"
