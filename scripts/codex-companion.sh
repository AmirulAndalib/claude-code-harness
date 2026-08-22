#!/usr/bin/env bash
# codex-companion.sh — Proxy to official codex-plugin-cc companion
#
# 公式プラグイン openai/codex-plugin-cc の codex-companion.mjs を
# 動的に発見して呼び出す。Harness のスキル・エージェントは
# raw `codex exec` ではなく、このプロキシ経由で Codex を呼び出す。
#
# Usage:
#   bash scripts/codex-companion.sh task --write "Fix the bug"
#   bash scripts/codex-companion.sh review --base HEAD~3
#   bash scripts/codex-companion.sh setup --json
#   bash scripts/codex-companion.sh status
#   bash scripts/codex-companion.sh result <job-id>
#   bash scripts/codex-companion.sh cancel <job-id>
#
# Subcommands: task, review, adversarial-review, setup, status, result, cancel
#
# Effort 伝播:
#   task サブコマンド実行時に calculate-effort.sh で effort を計算し、
#   --effort フラグで companion に渡す。calculate-effort.sh がない場合は
#   環境変数 CODEX_EFFORT（未設定時: medium）にフォールバックする。
#   official companion が受け付けない routed max は raw `codex exec` の
#   `model_reasoning_effort="max"` config override へ正規化する。
#
# Worktree containment (Phase 92.2.2):
#   task 実行の前後で `bin/harness wt fingerprint` を呼び、$HOME 機微パスへの
#   書込変化があれば hard-stop する。`--cwd` / `--cd` は CWD ヒントであり書込境界ではない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_ENV_GUARD="${SCRIPT_DIR}/codex-primary-environment-guard.sh"
MODEL_ROUTER="${SCRIPT_DIR}/model-routing.sh"
EXECUTION_ROOT="${HARNESS_CODEX_EXECUTION_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HARNESS_BIN="${EXECUTION_ROOT}/bin/harness"
FP_BEFORE=""
FP_AFTER=""
CODEX_ROUTE_RESOLVED=0
CODEX_ROUTED_MODEL=""
CODEX_ROUTED_EFFORT=""
CODEX_REVIEW_ROUTE_RESOLVED=0
CODEX_REVIEW_ROUTED_MODEL=""
CODEX_REVIEW_ROUTED_EFFORT=""
CODEX_LEDGER_EMITTED=0
REVIEW_COMPANION_ARGS=()
REVIEW_EXPLICIT_MODEL=0
REVIEW_EXPLICIT_MODEL_VALUE=""
REVIEW_EXPLICIT_EFFORT=""
REVIEW_APP_SERVER_DIR=""
REVIEW_APP_SERVER_SOCKET=""
REVIEW_APP_SERVER_ENDPOINT=""
REVIEW_APP_SERVER_READY_FILE=""
REVIEW_APP_SERVER_STATUS_FILE=""
REVIEW_APP_SERVER_PID=""
REVIEW_COMPANION_PID=""

# Orchestration ledger (Phase 90): record each delegation for the scorecard.
# This path exec()s into codex/node, so exit_code/duration are recorded null.
if [ -f "${SCRIPT_DIR}/lib/orchestration-ledger.sh" ]; then
  # shellcheck source=scripts/lib/orchestration-ledger.sh
  . "${SCRIPT_DIR}/lib/orchestration-ledger.sh" 2>/dev/null || true
fi
if ! command -v orch_emit_ledger >/dev/null 2>&1; then
  orch_emit_ledger() { return 0; }
fi

fingerprint_capture() {
  local output="$1"
  if [ ! -x "${HARNESS_BIN}" ]; then
    echo "ERROR: harness binary not found at ${HARNESS_BIN}" >&2
    return 1
  fi
  "${HARNESS_BIN}" wt fingerprint capture --output "${output}"
}

fingerprint_diff_or_stop() {
  if [ -z "${FP_BEFORE}" ] || [ ! -f "${FP_BEFORE}" ]; then
    return 0
  fi
  FP_AFTER="$(mktemp "${TMPDIR:-/tmp}/codex-companion-fp-after.XXXXXX")"
  if ! fingerprint_capture "${FP_AFTER}"; then
    echo "ERROR: worktree fingerprint capture (after) failed" >&2
    rm -f "${FP_AFTER}"
    return 1
  fi
  if ! "${HARNESS_BIN}" wt fingerprint diff --before "${FP_BEFORE}" --after "${FP_AFTER}"; then
    echo "WORKTREE-ESCAPE detected: see stderr for path list" >&2
    rm -f "${FP_AFTER}"
    return 1
  fi
  rm -f "${FP_AFTER}"
  return 0
}

run_task_with_fingerprint() {
  FP_BEFORE="$(mktemp "${TMPDIR:-/tmp}/codex-companion-fp-before.XXXXXX")"
  if ! fingerprint_capture "${FP_BEFORE}"; then
    rm -f "${FP_BEFORE}"
    echo "ERROR: worktree fingerprint capture (before) failed" >&2
    exit 1
  fi
  set +e
  "$@"
  local rc=$?
  set -e
  if ! fingerprint_diff_or_stop; then
    rm -f "${FP_BEFORE}"
    exit 1
  fi
  rm -f "${FP_BEFORE}"
  exit "${rc}"
}

is_valid_codex_effort() {
  case "${1:-}" in
    none|minimal|low|medium|high|xhigh|max) return 0 ;;
    *) return 1 ;;
  esac
}

is_valid_codex_model() {
  case "${1:-}" in
    ''|-*|*[!A-Za-z0-9._:/-]*) return 1 ;;
    *) return 0 ;;
  esac
}

resolve_codex_route_for_task() {
  if [ "${HARNESS_DISABLE_MODEL_ROUTING:-0}" = "1" ]; then
    return 0
  fi
  if [ ! -x "${MODEL_ROUTER}" ]; then
    return 0
  fi
  if [ "${CODEX_ROUTE_RESOLVED}" -eq 1 ]; then
    return 0
  fi

  local tier
  local routed_output
  tier="${CODEX_MODEL_TIER:-${HARNESS_MODEL_TIER:-standard}}"
  if ! routed_output="$(bash "${MODEL_ROUTER}" --host codex --tier "${tier}" --field model 2>&1)"; then
    echo "ERROR: Codex model routing failed for tier '${tier}'." >&2
    printf '%s\n' "${routed_output}" >&2
    return 1
  fi
  CODEX_ROUTED_MODEL="${routed_output}"

  if ! routed_output="$(bash "${MODEL_ROUTER}" --host codex --tier "${tier}" --field effort 2>&1)"; then
    echo "ERROR: Codex effort routing failed for tier '${tier}'." >&2
    printf '%s\n' "${routed_output}" >&2
    return 1
  fi
  CODEX_ROUTED_EFFORT="${routed_output}"
  CODEX_ROUTE_RESOLVED=1
}

resolve_codex_model_for_task() {
  resolve_codex_route_for_task || return 1
  printf '%s\n' "${CODEX_ROUTED_MODEL}"
}

resolve_codex_effort_for_task() {
  resolve_codex_route_for_task || return 1
  printf '%s\n' "${CODEX_ROUTED_EFFORT}"
}

resolve_codex_route_for_review() {
  if [ "${HARNESS_DISABLE_MODEL_ROUTING:-0}" = "1" ] || [ ! -x "${MODEL_ROUTER}" ]; then
    return 1
  fi
  if [ "${CODEX_REVIEW_ROUTE_RESOLVED}" -eq 1 ]; then
    return 0
  fi

  local routed_output
  if ! routed_output="$(bash "${MODEL_ROUTER}" --host codex --role reviewer --field model 2>&1)"; then
    echo "ERROR: Codex reviewer model routing failed." >&2
    printf '%s\n' "${routed_output}" >&2
    return 2
  fi
  CODEX_REVIEW_ROUTED_MODEL="${routed_output}"

  if ! routed_output="$(bash "${MODEL_ROUTER}" --host codex --role reviewer --field effort 2>&1)"; then
    echo "ERROR: Codex reviewer effort routing failed." >&2
    printf '%s\n' "${routed_output}" >&2
    return 2
  fi
  CODEX_REVIEW_ROUTED_EFFORT="${routed_output}"
  CODEX_REVIEW_ROUTE_RESOLVED=1
  return 0
}

args_have_codex_model() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|-m|--model=*|-m=*) return 0 ;;
    esac
    shift || true
  done
  return 1
}

extract_target_cwd() {
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd|--cd|-C)
        printf '%s\n' "${2:-$PWD}"
        return 0
        ;;
      --cwd=*|--cd=*|-C=*)
        printf '%s\n' "${1#*=}"
        return 0
        ;;
    esac
    shift || true
  done
  printf '%s\n' "$PWD"
}

task_has_write_intent() {
  [ "${1:-}" = "task" ] || return 1
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --write|--full-auto|--dangerously-bypass-approvals-and-sandbox)
        return 0
        ;;
      --sandbox|-s)
        case "${2:-}" in
          workspace-write|danger-full-access) return 0 ;;
        esac
        shift 2
        continue
        ;;
      --sandbox=*|-s=*)
        case "${1#*=}" in
          workspace-write|danger-full-access) return 0 ;;
        esac
        ;;
    esac
    shift || true
  done
  return 1
}

guard_primary_environment_if_needed() {
  if [ ! -x "${PRIMARY_ENV_GUARD}" ]; then
    return 0
  fi
  if task_has_write_intent "$@"; then
    local target_cwd
    target_cwd="$(extract_target_cwd "$@")"
    HARNESS_CODEX_EXECUTION_ROOT="${EXECUTION_ROOT}" \
      bash "${PRIMARY_ENV_GUARD}" --mode write --target-cwd "${target_cwd}"
  fi
}

should_use_structured_task_exec() {
  [ "${1:-}" = "task" ] || return 1
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --output-schema|--output-schema=*) return 0 ;;
      --background|--resume-last|--resume|--fresh) return 1 ;;
    esac
  done

  # The official companion rejects the max effort value. Keep explicit
  # non-max effort requests on that path, but normalize routed max through
  # `codex exec -c model_reasoning_effort="max"` instead.
  local explicit_effort=""
  local expect_effort=0
  for arg in "$@"; do
    if [ "${expect_effort}" -eq 1 ]; then
      explicit_effort="${arg}"
      expect_effort=0
      continue
    fi
    case "$arg" in
      --effort) expect_effort=1 ;;
      --effort=*) explicit_effort="${arg#*=}" ;;
    esac
  done
  if [ -n "${explicit_effort}" ]; then
    [ "${explicit_effort}" = "max" ]
    return
  fi
  if [ "${CODEX_EFFORT:-}" = "max" ]; then
    return 0
  fi
  [ "$(resolve_codex_effort_for_task)" = "max" ]
}

task_requested_effort() {
  local explicit_effort=""
  local expect_effort=0
  local arg
  for arg in "$@"; do
    if [ "${expect_effort}" -eq 1 ]; then
      explicit_effort="${arg}"
      expect_effort=0
      continue
    fi
    case "${arg}" in
      --effort) expect_effort=1 ;;
      --effort=*) explicit_effort="${arg#*=}" ;;
    esac
  done

  if [ -n "${explicit_effort}" ]; then
    printf '%s\n' "${explicit_effort}"
  elif [ "${CODEX_EFFORT:-}" = "max" ]; then
    printf 'max\n'
  elif [ "${HARNESS_DISABLE_MODEL_ROUTING:-0}" != "1" ] && [ -x "${MODEL_ROUTER}" ]; then
    resolve_codex_effort_for_task
  fi
}

task_prompt_file_path() {
  [ "${1:-}" = "task" ] || return 0
  shift || true

  local prompt_file=""
  local expect_prompt_file=0
  local arg
  for arg in "$@"; do
    if [ "${expect_prompt_file}" -eq 1 ]; then
      prompt_file="${arg}"
      expect_prompt_file=0
      continue
    fi
    case "${arg}" in
      --prompt-file) expect_prompt_file=1 ;;
      --prompt-file=*) prompt_file="${arg#*=}" ;;
    esac
  done

  if [ "${expect_prompt_file}" -eq 1 ]; then
    echo "ERROR: task --prompt-file requires a readable file path; refusing provider dispatch." >&2
    return 1
  fi
  printf '%s\n' "${prompt_file}"
}

validate_task_effort() {
  [ "${1:-}" = "task" ] || return 0
  shift || true

  local expect_effort=0
  local arg
  for arg in "$@"; do
    if [ "${expect_effort}" -eq 1 ]; then
      if ! is_valid_codex_effort "${arg}"; then
        echo "ERROR: invalid effort '${arg}'; refusing provider dispatch." >&2
        return 1
      fi
      expect_effort=0
      continue
    fi
    case "${arg}" in
      --effort) expect_effort=1 ;;
      --effort=*)
        if ! is_valid_codex_effort "${arg#*=}"; then
          echo "ERROR: invalid effort '${arg#*=}'; refusing provider dispatch." >&2
          return 1
        fi
        ;;
    esac
  done

  if [ "${expect_effort}" -eq 1 ]; then
    echo "ERROR: task --effort requires an effort value; refusing provider dispatch." >&2
    return 1
  fi
}

validate_task_prompt_file() {
  local prompt_file
  if ! prompt_file="$(task_prompt_file_path "$@")"; then
    return 1
  fi
  [ -n "${prompt_file}" ] || return 0
  if [ ! -f "${prompt_file}" ] || [ ! -r "${prompt_file}" ]; then
    echo "ERROR: task --prompt-file cannot read '${prompt_file}'; refusing provider dispatch." >&2
    return 1
  fi
}

reject_unrepresentable_task_mode() {
  [ "${1:-}" = "task" ] || return 0

  local state_mode=""
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --background|--resume-last|--resume|--fresh)
        state_mode="${arg#--}"
        ;;
    esac
  done

  if [ -n "${state_mode}" ] && [ "$(task_requested_effort "$@")" = "max" ]; then
    echo "ERROR: task --${state_mode} cannot preserve max effort; refusing provider dispatch." >&2
    return 1
  fi
}

run_structured_task_exec() {
  local passthrough=()
  local saw_write=0
  local saw_sandbox=0
  local saw_model=0
  local prompt_file=""
  local current=""
  local explicit_sandbox=0

  # Codex 0.123.0+ inherits root-level shared flags for `codex exec`.
  # These exec-local sandbox defaults are kept only to encode Harness task intent:
  # `task --write` means workspace-write, and read-only remains the safe default.
  # If the caller provides --sandbox/-s/--full-auto/bypass explicitly, preserve it.
  # `--full-auto` is deprecated in current Codex guidance, so Harness must not
  # add it by default here; explicit caller intent is passed through unchanged.
  shift || true # drop "task"
  for current in "$@"; do
    case "${current}" in
      --sandbox|-s|--sandbox=*|-s=*|--full-auto|--dangerously-bypass-approvals-and-sandbox)
        explicit_sandbox=1
        ;;
    esac
  done
  while [ $# -gt 0 ]; do
    current="$1"
    case "$current" in
      --background|--resume-last|--resume|--fresh)
        echo "ERROR: structured task mode does not support ${current}" >&2
        exit 2
        ;;
      --prompt-file)
        if [ -z "${2:-}" ]; then
          echo "ERROR: task --prompt-file requires a readable file path; refusing provider dispatch." >&2
          exit 2
        fi
        prompt_file="${2}"
        shift 2
        ;;
      --prompt-file=*)
        prompt_file="${current#*=}"
        shift
        ;;
      --write)
        saw_write=1
        if [ "${explicit_sandbox}" -eq 0 ]; then
          passthrough+=(--sandbox workspace-write)
        fi
        shift
        ;;
      --sandbox|-s|--sandbox=*|-s=*|--full-auto|--dangerously-bypass-approvals-and-sandbox)
        saw_sandbox=1
        passthrough+=("${current}")
        shift
        if [ "${current}" = "--sandbox" ] || [ "${current}" = "-s" ]; then
          passthrough+=("${1:-}")
          shift || true
        fi
        ;;
      --effort)
        # codex exec does not accept the companion-only --effort flag.
        # Structured task mode goes through codex exec directly, so translate
        # it into the official config override instead of silently dropping it.
        if is_valid_codex_effort "${2:-}"; then
          passthrough+=(-c "model_reasoning_effort=\"${2}\"")
        fi
        shift
        shift || true
        ;;
      --effort=*)
        local effort_value="${current#*=}"
        if is_valid_codex_effort "${effort_value}"; then
          passthrough+=(-c "model_reasoning_effort=\"${effort_value}\"")
        fi
        shift
        ;;
      --cwd)
        passthrough+=(--cd "${2:-}")
        shift 2
        ;;
      --cwd=*)
        passthrough+=(--cd "${current#*=}")
        shift
        ;;
      *)
        case "$current" in
          --model|-m|--model=*|-m=*) saw_model=1 ;;
        esac
        passthrough+=("${current}")
        shift
        if [ "${current}" = "--model" ] || [ "${current}" = "-m" ] || \
           [ "${current}" = "--output-schema" ] || \
           [ "${current}" = "-o" ] || [ "${current}" = "--output-last-message" ] || \
           [ "${current}" = "-c" ] || [ "${current}" = "--config" ] || \
           [ "${current}" = "-C" ] || [ "${current}" = "--cd" ] || \
           [ "${current}" = "--add-dir" ] || [ "${current}" = "-i" ] || \
           [ "${current}" = "--image" ] || [ "${current}" = "--color" ] || \
           [ "${current}" = "--local-provider" ]; then
          passthrough+=("${1:-}")
          shift || true
        fi
        ;;
    esac
  done

  if [ "${saw_write}" -eq 0 ] && [ "${saw_sandbox}" -eq 0 ]; then
    passthrough+=(--sandbox read-only)
  fi

  if [ "${saw_model}" -eq 0 ]; then
    local routed_model
    routed_model="$(resolve_codex_model_for_task)"
    if [ -n "${routed_model}" ]; then
      passthrough+=(--model "${routed_model}")
    fi
  fi

  if [ -n "${prompt_file}" ]; then
    run_task_with_fingerprint codex exec "${passthrough[@]}" - < "${prompt_file}"
  else
    run_task_with_fingerprint codex exec "${passthrough[@]}"
  fi
}

normalize_review_args() {
  REVIEW_COMPANION_ARGS=()
  REVIEW_EXPLICIT_MODEL=0
  REVIEW_EXPLICIT_MODEL_VALUE=""
  REVIEW_EXPLICIT_EFFORT=""

  local expect=""
  local current=""
  while [ "$#" -gt 0 ]; do
    current="$1"
    shift

    if [ -n "${expect}" ]; then
      case "${expect}" in
        effort)
          if ! is_valid_codex_effort "${current}"; then
            echo "ERROR: invalid review effort '${current}'; refusing provider dispatch." >&2
            return 1
          fi
          REVIEW_EXPLICIT_EFFORT="${current}"
          ;;
        model)
          if ! is_valid_codex_model "${current}"; then
            echo "ERROR: invalid review model '${current}'; refusing provider dispatch." >&2
            return 1
          fi
          REVIEW_EXPLICIT_MODEL_VALUE="${current}"
          REVIEW_COMPANION_ARGS+=("${current}")
          ;;
        passthrough)
          REVIEW_COMPANION_ARGS+=("${current}")
          ;;
      esac
      expect=""
      continue
    fi

    case "${current}" in
      --effort)
        expect="effort"
        ;;
      --effort=*)
        REVIEW_EXPLICIT_EFFORT="${current#*=}"
        if ! is_valid_codex_effort "${REVIEW_EXPLICIT_EFFORT}"; then
          echo "ERROR: invalid review effort '${REVIEW_EXPLICIT_EFFORT}'; refusing provider dispatch." >&2
          return 1
        fi
        ;;
      --model|-m)
        REVIEW_EXPLICIT_MODEL=1
        REVIEW_COMPANION_ARGS+=("${current}")
        expect="model"
        ;;
      --model=*|-m=*)
        REVIEW_EXPLICIT_MODEL=1
        REVIEW_EXPLICIT_MODEL_VALUE="${current#*=}"
        if ! is_valid_codex_model "${REVIEW_EXPLICIT_MODEL_VALUE}"; then
          echo "ERROR: invalid review model '${REVIEW_EXPLICIT_MODEL_VALUE}'; refusing provider dispatch." >&2
          return 1
        fi
        if [[ "${current}" == -m=* ]]; then
          REVIEW_COMPANION_ARGS+=(--model "${current#*=}")
        else
          REVIEW_COMPANION_ARGS+=("${current}")
        fi
        ;;
      --commit)
        echo "ERROR: review --commit target is unsupported by official companion; refusing provider dispatch." >&2
        return 1
        ;;
      --commit=*)
        echo "ERROR: review --commit target is unsupported by official companion; refusing provider dispatch." >&2
        return 1
        ;;
      --uncommitted)
        REVIEW_COMPANION_ARGS+=(--scope working-tree)
        ;;
      --base|--scope|--cwd|--cd|-C)
        REVIEW_COMPANION_ARGS+=("${current}")
        expect="passthrough"
        ;;
      --base=*|--scope=*|--cwd=*|--cd=*|-C=*)
        REVIEW_COMPANION_ARGS+=("${current}")
        ;;
      *)
        REVIEW_COMPANION_ARGS+=("${current}")
        ;;
    esac
  done

  if [ -n "${expect}" ]; then
    case "${expect}" in
      effort) echo "ERROR: review --effort requires an effort value; refusing provider dispatch." >&2 ;;
      commit) echo "ERROR: review --commit target is unsupported by official companion; refusing provider dispatch." >&2 ;;
      model) echo "ERROR: review --model requires a model value; refusing provider dispatch." >&2 ;;
      passthrough) echo "ERROR: review option requires a value; refusing provider dispatch." >&2 ;;
    esac
    return 1
  fi

  if [ "${REVIEW_EXPLICIT_MODEL}" -eq 0 ]; then
    REVIEW_COMPANION_ARGS+=(--model "${CODEX_REVIEW_ROUTED_MODEL}")
  fi
}

stop_review_app_server() {
  local pid="${REVIEW_APP_SERVER_PID:-}"
  local attempts=0
  local proxy_wait_status=0
  local proxy_status=""
  local wait_status=0
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    # The proxy gives its app-server child up to 1s for TERM, then up to 1s
    # for KILL. Wait for its status marker instead of polling kill -0, which
    # remains true for an unreaped zombie on some hosts.
    while [ "${attempts}" -lt 60 ]; do
      if [ -s "${REVIEW_APP_SERVER_STATUS_FILE:-}" ]; then
        proxy_status="$(tr -d '[:space:]' <"${REVIEW_APP_SERVER_STATUS_FILE}")"
        break
      fi
      if ! kill -0 "${pid}" 2>/dev/null; then
        break
      fi
      attempts=$((attempts + 1))
      sleep 0.05
    done
    if [ -z "${proxy_status}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  fi
  if [ -n "${pid}" ]; then
    wait "${pid}" 2>/dev/null || wait_status=$?
    if [ -z "${proxy_status}" ] && [ -s "${REVIEW_APP_SERVER_STATUS_FILE:-}" ]; then
      proxy_status="$(tr -d '[:space:]' <"${REVIEW_APP_SERVER_STATUS_FILE}")"
    fi
    if [ -n "${proxy_status}" ]; then
      case "${proxy_status}" in
        0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) proxy_wait_status="${proxy_status}" ;;
        *) proxy_wait_status=1 ;;
      esac
    elif [ "${wait_status}" -ne 0 ]; then
      proxy_wait_status="${wait_status}"
    elif [ -n "${REVIEW_APP_SERVER_STATUS_FILE:-}" ]; then
      proxy_wait_status=1
    fi
    if [ "${proxy_wait_status}" -ne 0 ]; then
      echo "ERROR: reviewer app-server proxy exited with status ${proxy_wait_status}." >&2
    fi
  fi
  if [ -n "${REVIEW_APP_SERVER_SOCKET:-}" ]; then
    rm -f -- "${REVIEW_APP_SERVER_SOCKET}"
  fi
  if [ -n "${REVIEW_APP_SERVER_READY_FILE:-}" ]; then
    rm -f -- "${REVIEW_APP_SERVER_READY_FILE}"
  fi
  if [ -n "${REVIEW_APP_SERVER_STATUS_FILE:-}" ]; then
    rm -f -- "${REVIEW_APP_SERVER_STATUS_FILE}"
  fi
  if [ -n "${REVIEW_APP_SERVER_DIR:-}" ]; then
    rm -f -- "${REVIEW_APP_SERVER_DIR}/app-server.log"
  fi
  if [ -n "${REVIEW_APP_SERVER_DIR:-}" ]; then
    rmdir "${REVIEW_APP_SERVER_DIR}" 2>/dev/null || true
  fi
  REVIEW_APP_SERVER_PID=""
  REVIEW_APP_SERVER_SOCKET=""
  REVIEW_APP_SERVER_ENDPOINT=""
  REVIEW_APP_SERVER_READY_FILE=""
  REVIEW_APP_SERVER_STATUS_FILE=""
  REVIEW_APP_SERVER_DIR=""
  return "${proxy_wait_status}"
}

start_review_app_server() {
  local codex_bin
  local app_server_log
  local config_model config_review_model config_effort effective_model
  local proxy_script
  local i

  codex_bin="$(command -v codex 2>/dev/null || true)"
  if [ -z "${codex_bin}" ]; then
    echo "ERROR: Codex CLI is required for the reviewer app-server." >&2
    return 1
  fi

  REVIEW_APP_SERVER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-app-server.XXXXXX")"
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
      REVIEW_APP_SERVER_SOCKET=""
      REVIEW_APP_SERVER_ENDPOINT="pipe:\\\\.\\pipe\\codex-review-${PPID}-${RANDOM}"
      ;;
    *)
      REVIEW_APP_SERVER_SOCKET="${REVIEW_APP_SERVER_DIR}/review.sock"
      REVIEW_APP_SERVER_ENDPOINT="unix:${REVIEW_APP_SERVER_SOCKET}"
      ;;
  esac
  REVIEW_APP_SERVER_READY_FILE="${REVIEW_APP_SERVER_DIR}/ready"
  REVIEW_APP_SERVER_STATUS_FILE="${REVIEW_APP_SERVER_DIR}/status"
  app_server_log="${REVIEW_APP_SERVER_DIR}/app-server.log"
  proxy_script="${SCRIPT_DIR}/codex-review-app-server-proxy.mjs"
  if [ ! -f "${proxy_script}" ]; then
    echo "ERROR: reviewer app-server proxy is missing at ${proxy_script}." >&2
    stop_review_app_server || true
    return 1
  fi
  effective_model="${CODEX_REVIEW_ROUTED_MODEL}"
  if [ "${REVIEW_EXPLICIT_MODEL}" -eq 1 ]; then
    effective_model="${REVIEW_EXPLICIT_MODEL_VALUE}"
  fi
  config_model="model=\"${effective_model}\""
  config_review_model="review_model=\"${effective_model}\""

  if [ -n "${REVIEW_EXPLICIT_EFFORT}" ]; then
    config_effort="model_reasoning_effort=\"${REVIEW_EXPLICIT_EFFORT}\""
  else
    config_effort="model_reasoning_effort=\"${CODEX_REVIEW_ROUTED_EFFORT}\""
  fi

  if [ -n "${config_effort}" ]; then
    node "${proxy_script}" --endpoint "${REVIEW_APP_SERVER_ENDPOINT}" \
      --ready-file "${REVIEW_APP_SERVER_READY_FILE}" --codex "${codex_bin}" \
      --status-file "${REVIEW_APP_SERVER_STATUS_FILE}" \
      --config "${config_model}" --config "${config_review_model}" --config "${config_effort}" \
      >"${app_server_log}" 2>&1 &
  else
    node "${proxy_script}" --endpoint "${REVIEW_APP_SERVER_ENDPOINT}" \
      --ready-file "${REVIEW_APP_SERVER_READY_FILE}" --codex "${codex_bin}" \
      --status-file "${REVIEW_APP_SERVER_STATUS_FILE}" \
      --config "${config_model}" --config "${config_review_model}" \
      >"${app_server_log}" 2>&1 &
  fi
  REVIEW_APP_SERVER_PID=$!

  # Codex app-server startup is bounded but can exceed two seconds on a loaded
  # host. Keep a finite ten-second readiness contract so startup signals are
  # handled by the scoped trap instead of being misreported as a race.
  for i in $(seq 1 200); do
    if [ -e "${REVIEW_APP_SERVER_READY_FILE}" ]; then
      return 0
    fi
    if ! kill -0 "${REVIEW_APP_SERVER_PID}" 2>/dev/null; then
      echo "ERROR: reviewer app-server exited before its endpoint became ready." >&2
      sed -n '1,80p' "${app_server_log}" >&2 || true
      stop_review_app_server || true
      return 1
    fi
    sleep 0.05
  done

  echo "ERROR: reviewer app-server endpoint did not become ready." >&2
  stop_review_app_server || true
  return 1
}

run_review_with_app_server() {
  if ! normalize_review_args "$@"; then
    return 2
  fi
  local rc cleanup_rc=0 app_server_failed=0
  local app_server_status=""
  local previous_exit_trap previous_int_trap previous_term_trap
  previous_exit_trap="$(trap -p EXIT || true)"
  previous_int_trap="$(trap -p INT || true)"
  previous_term_trap="$(trap -p TERM || true)"
  trap 'review_forward_signal TERM 143' TERM
  trap 'review_forward_signal INT 130' INT
  trap review_app_server_exit_cleanup EXIT

  # Install the scoped cleanup handlers before proxy startup. A TERM/INT
  # arriving while the endpoint is becoming ready must still terminate the
  # proxy and its app-server child; the empty companion PID is intentional.
  if ! start_review_app_server; then
    stop_review_app_server || true
    if [ -n "${previous_exit_trap}" ]; then eval "${previous_exit_trap}"; else trap - EXIT; fi
    if [ -n "${previous_int_trap}" ]; then eval "${previous_int_trap}"; else trap - INT; fi
    if [ -n "${previous_term_trap}" ]; then eval "${previous_term_trap}"; else trap - TERM; fi
    return 2
  fi

  set +e
  CODEX_COMPANION_APP_SERVER_ENDPOINT="${REVIEW_APP_SERVER_ENDPOINT}" \
    node "${COMPANION}" "${REVIEW_COMPANION_ARGS[@]}" &
  REVIEW_COMPANION_PID=$!
  wait "${REVIEW_COMPANION_PID}"
  rc=$?
  REVIEW_COMPANION_PID=""
  set -e
  if [ -s "${REVIEW_APP_SERVER_STATUS_FILE}" ]; then
    app_server_status="$(tr -d '[:space:]' <"${REVIEW_APP_SERVER_STATUS_FILE}")"
    case "${app_server_status}" in
      0) app_server_failed=0 ;;
      *) app_server_failed=1 ;;
    esac
  fi
  if ! stop_review_app_server; then
    cleanup_rc=1
  fi
  # Emit only after proxy shutdown has reported a clean transport. A crash can
  # occur just after the companion returns, so emitting before stop would
  # count failed app-server work as a real delegation.
  if [ "${cleanup_rc}" -eq 0 ] && [ "${app_server_failed}" -eq 0 ] && [ "${rc}" -eq 0 ]; then
    emit_codex_ledger_once "${SUBCOMMAND}" "$@"
  fi
  if [ -n "${previous_exit_trap}" ]; then eval "${previous_exit_trap}"; else trap - EXIT; fi
  if [ -n "${previous_int_trap}" ]; then eval "${previous_int_trap}"; else trap - INT; fi
  if [ -n "${previous_term_trap}" ]; then eval "${previous_term_trap}"; else trap - TERM; fi
  if [ "${cleanup_rc}" -ne 0 ]; then return 1; fi
  if [ "${app_server_failed}" -ne 0 ]; then return 1; fi
  return "${rc}"
}

review_forward_signal() {
  local signal="$1"
  local exit_code="$2"
  local pid="${REVIEW_COMPANION_PID:-}"
  local app_server_pid="${REVIEW_APP_SERVER_PID:-}"
  local attempts=0
  # Stop the proxy at the same time as the official companion. This keeps
  # signal handling bounded by the two independent TERM -> KILL grace windows
  # instead of serializing companion shutdown before proxy cleanup.
  if [ -n "${app_server_pid}" ] && kill -0 "${app_server_pid}" 2>/dev/null; then
    kill -"${signal}" "${app_server_pid}" 2>/dev/null || true
  fi
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    kill -"${signal}" "${pid}" 2>/dev/null || true
    while kill -0 "${pid}" 2>/dev/null && [ "${attempts}" -lt 20 ]; do
      attempts=$((attempts + 1))
      sleep 0.05
    done
    if kill -0 "${pid}" 2>/dev/null; then
      kill -KILL "${pid}" 2>/dev/null || true
    fi
    wait "${pid}" 2>/dev/null || true
  fi
  REVIEW_COMPANION_PID=""
  exit "${exit_code}"
}

emit_codex_ledger_once() {
  [ "${CODEX_LEDGER_EMITTED}" -eq 0 ] || return 0
  [ -n "${1:-}" ] || return 0
  local subcommand="$1"
  shift
  local write_flag=0
  if task_has_write_intent "$@"; then write_flag=1; fi
  orch_emit_ledger "codex" "${subcommand}" "${write_flag}" "" "" || true
  CODEX_LEDGER_EMITTED=1
}

review_app_server_exit_cleanup() {
  stop_review_app_server || true
}

build_codex_task_model_args() {
  if args_have_codex_model "$@"; then
    return 0
  fi
  local routed_model
  routed_model="$(resolve_codex_model_for_task)"
  if [ -n "${routed_model}" ]; then
    printf '%s\n' "--model" "${routed_model}"
  fi
}

SUBCOMMAND="${1:-}"
if [ "${SUBCOMMAND}" = "task" ] && ! resolve_codex_route_for_task; then
  exit 2
fi
if [ "${SUBCOMMAND}" = "task" ] && ! validate_task_effort "$@"; then
  exit 2
fi
if [ "${SUBCOMMAND}" = "task" ] && ! validate_task_prompt_file "$@"; then
  exit 2
fi
if [ "${SUBCOMMAND}" = "task" ] && ! reject_unrepresentable_task_mode "$@"; then
  exit 2
fi
if should_use_structured_task_exec "$@"; then
  STRUCTURED_TASK_EXEC=1
else
  STRUCTURED_TASK_EXEC=0
fi

# 公式プラグインの companion を検索
# Claude/Codex どちらの plugin ディレクトリでも見つかるようにし、
# cache と marketplace 配下の両方を対象にする。
PLUGIN_DIRS=()
[ -d "${HOME}/.claude/plugins" ] && PLUGIN_DIRS+=("${HOME}/.claude/plugins")
[ -d "${HOME}/.codex/plugins" ] && PLUGIN_DIRS+=("${HOME}/.codex/plugins")

COMPANION=""
if [ "${#PLUGIN_DIRS[@]}" -gt 0 ]; then
  # パスからバージョンセグメントを抽出し数値比較（macOS BSD sort 互換）
  COMPANION=$(find "${PLUGIN_DIRS[@]}" -name "codex-companion.mjs" \
    \( -path "*/openai-codex/*" -o -path "*/codex-plugin-cc/*" -o -path "*/plugins/codex/*" \) \
    2>/dev/null \
    | awk -F/ '{version="0.0.0"; for(i=1;i<=NF;i++){if($i~/^[0-9]+\.[0-9]+(\.[0-9]+)?$/){version=$i}} print version,$0}' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1 \
    | cut -d' ' -f2-)
fi

if [ -z "$COMPANION" ] && [ "${STRUCTURED_TASK_EXEC}" -ne 1 ]; then
  echo "ERROR: codex-plugin-cc が見つかりません。" >&2
  echo "インストール: plugin marketplace add openai/codex-plugin-cc" >&2
  echo "または: /codex:setup を実行してください" >&2
  exit 1
fi

REVIEW_APP_SERVER_ENABLED=0
if [ "$SUBCOMMAND" = "review" ] || [ "$SUBCOMMAND" = "adversarial-review" ]; then
  if resolve_codex_route_for_review; then
    REVIEW_APP_SERVER_ENABLED=1
  else
    review_route_rc=$?
    if [ "${review_route_rc}" -ne 1 ]; then
      exit 2
    fi
  fi
fi
if [ "${REVIEW_APP_SERVER_ENABLED}" -eq 1 ]; then
  run_review_with_app_server "$@"
  exit $?
fi

# Compatibility paths emit only after all preflight validation has completed.
# Routed reviews emit from run_review_with_app_server after their app-server is
# ready, so rejected or failed transports do not inflate delegation counts.
emit_codex_ledger_once "${SUBCOMMAND}" "$@"

# ---- Effort 伝播（task サブコマンドのみ）----
  # task サブコマンドの場合、タスク説明から effort を計算して --effort フラグで渡す。
  # calculate-effort.sh が存在しない場合は CODEX_EFFORT 環境変数（デフォルト: medium）を使う。
  guard_primary_environment_if_needed "$@"

if [ "$SUBCOMMAND" = "task" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  EFFORT_SCRIPT="${SCRIPT_DIR}/calculate-effort.sh"

  # 既に --effort フラグが指定されている場合、または --resume-last の場合はスキップ
  # --resume-last は継続プロンプト（「続きをやって」等）が入るため effort 計算が不正確になる
  EFFORT_ALREADY_SET=0
  STATE_MODE_PRESENT=0
  EXPLICIT_EFFORT_SET=0
  for arg in "$@"; do
    if [ "$arg" = "--effort" ] || grep -qE '^--effort=' <<<"$arg"; then
      EFFORT_ALREADY_SET=1
      EXPLICIT_EFFORT_SET=1
      continue
    fi
    if [ "$arg" = "--background" ] || [ "$arg" = "--fresh" ] || \
       [ "$arg" = "--resume-last" ] || [ "$arg" = "--resume" ]; then
      STATE_MODE_PRESENT=1
      EFFORT_ALREADY_SET=1
    fi
  done

  if [ "$EFFORT_ALREADY_SET" -eq 0 ]; then
    # タスク説明を引数から抽出（最後の非フラグ引数）
    # Boolean フラグ（値を取らない）: --write, --resume-last, --json, --full-auto, --ephemeral, --oss, --skip-git-repo-check
    # 値付きフラグ（次の引数を消費）: --base, --effort, --model, -m, -i, --image, -c, --config, -C, --cwd, --cd, --add-dir, --output-schema, -o, --output-last-message, --color, --enable, --disable, --local-provider, --prompt-file
    # 未知の --* フラグ → 安全側で値付き（次引数を消費）として扱う
    TASK_DESC=""
    EXPECT_VALUE=""
	    for arg in "${@:2}"; do
	      if [ -n "$EXPECT_VALUE" ]; then
	        # 前のフラグの値なのでスキップ
	        EXPECT_VALUE=""
	        continue
	      fi
	      case "$arg" in
	        --write|--resume-last|--json|--full-auto|--ephemeral|--oss|--skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--background|--resume|--fresh)
	          # 値を取らない boolean フラグ → スキップするだけ
	          ;;
        --base=*|--effort=*|--model=*|-m=*|-i=*|--image=*|-c=*|--config=*|-C=*|--cwd=*|--cd=*|--add-dir=*|--output-schema=*|-o=*|--output-last-message=*|--color=*|--enable=*|--disable=*|--local-provider=*|--prompt-file=*)
	          # 値付きフラグの --flag=value 形式。次引数は消費しない。
	          ;;
        --base|--effort|--model|-m|-i|--image|-c|--config|-C|--cwd|--cd|--add-dir|--output-schema|-o|--output-last-message|--color|--enable|--disable|--local-provider|--prompt-file)
	          # 明示的に値を取るフラグ
	          EXPECT_VALUE="$arg"
	          ;;
        --*)
          # 未知のフラグ → 安全側で値付きとして扱う（誤って次引数を TASK_DESC にしない）
          EXPECT_VALUE="$arg"
          ;;
        *)
          # 非フラグ引数 = タスク説明
          TASK_DESC="$arg"
          ;;
      esac
    done

    # effort を計算
    COMPUTED_EFFORT=""
    if [ -f "$EFFORT_SCRIPT" ]; then
      if [ -n "$TASK_DESC" ]; then
        COMPUTED_EFFORT=$(bash "$EFFORT_SCRIPT" "$TASK_DESC" 2>/dev/null || true)
      elif [ ! -t 0 ]; then
        # stdin が利用可能（パイプ）: 内容を読み取って effort を計算
        STDIN_CONTENT=$(cat)
        if [ -n "$STDIN_CONTENT" ]; then
          COMPUTED_EFFORT=$(echo "$STDIN_CONTENT" | bash "$EFFORT_SCRIPT" 2>/dev/null || true)
          if ! is_valid_codex_effort "${COMPUTED_EFFORT:-}"; then
            COMPUTED_EFFORT="medium"
          fi
          if [ "$(resolve_codex_effort_for_task)" = "max" ]; then
            COMPUTED_EFFORT="max"
          fi
          MODEL_ARGS=()
          while IFS= read -r arg; do
            MODEL_ARGS+=("$arg")
          done < <(build_codex_task_model_args "$@")
          # stdin を再セットアップ（here-string 経由で companion に渡す）
          if [ "${STRUCTURED_TASK_EXEC}" -eq 1 ]; then
            run_structured_task_exec "$@" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --effort "${COMPUTED_EFFORT}" <<< "$STDIN_CONTENT"
          else
            run_task_with_fingerprint node "$COMPANION" "$@" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --effort "${COMPUTED_EFFORT}" <<< "$STDIN_CONTENT"
          fi
        fi
        # stdin が空の場合（</dev/null 等）はフォールスルーして通常フローへ
      fi
    fi

    # フォールバック: 環境変数 CODEX_EFFORT → medium
    if [ -z "$COMPUTED_EFFORT" ]; then
      COMPUTED_EFFORT="${CODEX_EFFORT:-medium}"
    fi

    # A routed max worker must not be sent to the official companion's
    # --effort parser; run_structured_task_exec translates it to the Codex
    # config override instead.
    if [ "$(resolve_codex_effort_for_task)" = "max" ]; then
      COMPUTED_EFFORT="max"
    fi

    if ! is_valid_codex_effort "$COMPUTED_EFFORT"; then
      COMPUTED_EFFORT="medium"
    fi

    MODEL_ARGS=()
    while IFS= read -r arg; do
      MODEL_ARGS+=("$arg")
    done < <(build_codex_task_model_args "$@")

    if [ "${STRUCTURED_TASK_EXEC}" -eq 1 ]; then
      run_structured_task_exec "$@" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --effort "$COMPUTED_EFFORT"
    else
      run_task_with_fingerprint node "$COMPANION" "$@" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --effort "$COMPUTED_EFFORT"
    fi
  fi
fi

if [ "${STRUCTURED_TASK_EXEC}" -eq 1 ]; then
  run_structured_task_exec "$@"
fi

if [ "$SUBCOMMAND" = "task" ]; then
  if [ "${STATE_MODE_PRESENT:-0}" -eq 1 ] && [ "${EXPLICIT_EFFORT_SET:-0}" -eq 0 ] && \
     [ "${HARNESS_DISABLE_MODEL_ROUTING:-0}" != "1" ] && [ -x "${MODEL_ROUTER}" ] && \
     [ -n "${CODEX_ROUTED_EFFORT}" ]; then
    MODEL_ARGS=()
    while IFS= read -r arg; do
      MODEL_ARGS+=("$arg")
    done < <(build_codex_task_model_args "$@")
    run_task_with_fingerprint node "$COMPANION" "$@" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --effort "${CODEX_ROUTED_EFFORT}"
  fi
  MODEL_ARGS=()
  while IFS= read -r arg; do
    MODEL_ARGS+=("$arg")
  done < <(build_codex_task_model_args "$@")
  run_task_with_fingerprint node "$COMPANION" "$@" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}"
fi

exec node "$COMPANION" "$@"
