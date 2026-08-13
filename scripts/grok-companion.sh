#!/usr/bin/env bash
# grok-companion.sh — Delegate a whole task to grok (the Grok execution backend)
#
# Harness のスキル・エージェントが Grok をバックエンドとして使うときの
# 唯一の入口。scripts/cursor-companion.sh の役割を Grok 側にミラーする。
#
# Usage:
#   bash scripts/grok-companion.sh task "Explain the failing test"            # read-only (default)
#   bash scripts/grok-companion.sh task --write --workspace <dir> "Fix bug"   # write mode
#   bash scripts/grok-companion.sh task --model <m> "..."                     # model override
#   bash scripts/grok-companion.sh --debug task "..."                        # wrapper debug trace
#   bash scripts/grok-companion.sh task --debug "..."                        # 同上（位置どちらでも可）
#   HARNESS_GROK_DEBUG=1 bash scripts/grok-companion.sh task "..."           # env による debug
#
# Subcommands: task
#
# `--workspace <dir>` は grok の `--cwd` に写す CWD ヒントであり、書込境界ではない。
# grok は `--cwd` 外にも書き込みうる。Harness 側の境界は (1) 専用 worktree、
# (2) 実行前後の fingerprint 比較（`bin/harness wt fingerprint`）、(3) Lead diff review
# + cherry-pick の 3 段で構築する（cursor-companion.sh と同じ契約）。
#
# 実機評価（2026-08-13、Grok CLI 0.2.118 "Grok Build TUI" を直接プローブして確認）:
#   - `grok -p <prompt> --output-format json` の成功レスポンスは
#     `{"text":..., "stopReason":..., "sessionId":..., "requestId":...}`
#     （cursor-agent の `{"is_error":bool,"result":string}` とは別形状）。
#   - 失敗時は「プロセスが非ゼロで終了する」ことが正式契約
#     （~/.grok/docs/user-guide/14-headless-mode.md）。stdout に
#     `{"type":"error","message":"..."}` が乗ることもあるが exit code が一次シグナル。
#   - `--yolo` / `--always-approve` / `--permission-mode bypassPermissions`
#     （grok の "auto-approve all tool executions"）は決して渡さない。
#     auto-run は ~/.grok/config.toml の permission ルール（--allow/--deny や
#     defaultMode）に委ねる。cursor-companion.sh の `--force`/`--yolo` 拒否と同じ設計。
#   - read-only（default）は `--permission-mode plan`（tool 実行なしの gated
#     planning。Claude 互換の意味論）で表現する。grok には cursor-agent の
#     `--trust`（workspace 信頼）に相当する headless 専用フラグは存在しない
#     （`grok --help` / headless-mode doc に `--trust` は無い）ため付与しない。
#
# Observability:
#   --debug / HARNESS_GROK_DEBUG=1 は wrapper 専用の観測フラグで、grok 自身には
#   渡らない。デフォルト挙動（DEBUG=0）は model-routing.sh の stderr を silent に
#   飲み込み、grok の stderr は失敗時のみ出力する。DEBUG=1 の時のみ:
#     (a) model-routing.sh の stderr を [grok-companion DEBUG] prefix で stderr に出す
#     (b) 構築された cmd 配列を secret マスク付きで stderr に出す（実行前）
#     (c) grok の stderr を成功・失敗を問わず stderr に出す
#   secret マスク対象は cursor-companion.sh の mask_args と同じ規約
#   （`--api-key` / `--auth-token` / `Authorization:` ヘッダ）。grok の headless
#   フラグ集合には現時点で該当フラグは無いが、将来の拡張に備えて関数を揃える。
#
# Testability hooks (test-only, do not rely on in production):
#   HARNESS_GROK_COMPANION_MODEL_ROUTER  — model-routing.sh のパスを差し替える
#   GROK_COMPANION_SOURCED_FOR_TEST=1    — 関数定義のみ source して main を実行しない
#
# Exit codes:
#   0  ok            — 成功し、.text を stdout に出力した
#   1  result-error  — 実行は exit 0 だが .text が null・空、または type=="error" 応答
#   2  bad-guard     — --write の workspace ガード違反（未指定 / repo root / $HOME / 非ディレクトリ）
#   3  not-found     — grok バイナリが見つからない（not-configured）
#   その他            — grok プロセス自体が非ゼロ終了した場合はその rc をそのまま伝播する

# ---- DEBUG 既定値（env による初期化）-------------------------------------
DEBUG="${HARNESS_GROK_DEBUG:-0}"

# ---- debug_log: DEBUG=1 のときだけ stderr に prefix 付きで出す ------------
debug_log() {
  if [ "${DEBUG}" != "1" ]; then
    return 0
  fi
  printf '[grok-companion DEBUG] %s\n' "$*" >&2
}

# ---- mask_args: cmd 配列を走査し、secret 系の値を [REDACTED] に置換 -------
# cursor-companion.sh の mask_args と同一規約。PROMPT 本文はマスクしない。
mask_args() {
  local IFS=' '
  local out=()
  local i=0
  local n=$#
  local args=("$@")
  while [ "$i" -lt "$n" ]; do
    local a="${args[$i]}"
    case "$a" in
      --api-key|--auth-token)
        out+=("$a")
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then
          out+=("[REDACTED]")
          i=$((i + 1))
        fi
        ;;
      -H|--header)
        out+=("$a")
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then
          local next="${args[$i]}"
          case "$next" in
            [Aa]uthorization:*)
              out+=("Authorization: [REDACTED]")
              ;;
            *)
              out+=("$next")
              ;;
          esac
          i=$((i + 1))
        fi
        ;;
      [Aa]uthorization:*)
        out+=("Authorization: [REDACTED]")
        i=$((i + 1))
        ;;
      *)
        out+=("$a")
        i=$((i + 1))
        ;;
    esac
  done
  printf '%s' "${out[*]}"
}

# === FUNCTIONS ABOVE === early return for tests ===
if [ "${GROK_COMPANION_SOURCED_FOR_TEST:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_ROUTER="${HARNESS_GROK_COMPANION_MODEL_ROUTER:-${SCRIPT_DIR}/model-routing.sh}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "${SCRIPT_DIR}/.." && pwd))"

# Orchestration ledger (Phase 90): record each delegation for the scorecard.
if [ -f "${SCRIPT_DIR}/lib/orchestration-ledger.sh" ]; then
  # shellcheck source=scripts/lib/orchestration-ledger.sh
  . "${SCRIPT_DIR}/lib/orchestration-ledger.sh" 2>/dev/null || true
fi
if ! command -v orch_emit_ledger >/dev/null 2>&1; then
  orch_emit_ledger() { return 0; }
fi
if ! command -v __orch_now_ms >/dev/null 2>&1; then
  __orch_now_ms() { printf '0'; }
fi

# ---- worktree fingerprint gate (Phase 92.2.2 の cursor-companion.sh と同じ契約) --
HARNESS_BIN="${REPO_ROOT}/bin/harness"
FP_BEFORE=""
FP_AFTER=""

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
  FP_AFTER="$(mktemp "${TMPDIR:-/tmp}/grok-companion-fp-after.XXXXXX")"
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

# ---- grok バイナリ解決 -----------------------------------------------------
# command -v を優先（テストの PATH モックがここで拾われる）。
# 見つからなければ $HOME/.local/bin/grok にフォールバックする
# （このマシンの実インストール経路: ~/.local/bin/grok -> ~/.grok/bin/grok）。
#
# cursor-companion.sh の resolve_cursor_agent との非対称について:
# あちらは `agent` という極めて汎用的な名前を優先探索する必要があるため
# identity check を持つ。`grok` は名前としてはるかに特異なので同じ check は
# 置いていない。ただし PATH の手前を握れる相手が偽の `grok` を置ける点は
# 同じで、この関数はそれを防がない（防御は worktree fingerprint と
# Lead の diff review 側にある）。
resolve_grok() {
  local bin
  if bin="$(command -v grok 2>/dev/null)" && [ -n "${bin}" ]; then
    printf '%s\n' "${bin}"
    return 0
  fi
  local fallback="${HOME}/.local/bin/grok"
  if [ -x "${fallback}" ]; then
    printf '%s\n' "${fallback}"
    return 0
  fi
  return 1
}

# ---- model 解決 -----------------------------------------------------------
resolve_grok_model() {
  if [ ! -x "${MODEL_ROUTER}" ]; then
    return 0
  fi
  if [ "${DEBUG}" = "1" ]; then
    local tmp_stderr
    tmp_stderr="$(mktemp "${TMPDIR:-/tmp}/grok-companion-mr-err.XXXXXX")"
    local model
    model="$(bash "${MODEL_ROUTER}" --host grok --role worker --field model 2>"${tmp_stderr}" || true)"
    if [ -s "${tmp_stderr}" ]; then
      debug_log "model-routing.sh stderr: $(cat "${tmp_stderr}")"
    fi
    rm -f "${tmp_stderr}"
    printf '%s' "${model}"
  else
    bash "${MODEL_ROUTER}" --host grok --role worker --field model 2>/dev/null || true
  fi
}

usage() {
  cat <<'EOF'
Usage:
  grok-companion.sh [--debug] task [--debug] [--write] [--workspace <dir>] [--model <m>] "<prompt>"
EOF
}

# ---- top-level の --debug を最初に剥がす（task の前に置けるように）-------
if [ "${1:-}" = "--debug" ]; then
  DEBUG=1
  shift
fi

SUBCOMMAND="${1:-}"
if [ "${SUBCOMMAND}" != "task" ]; then
  echo "ERROR: unsupported subcommand: '${SUBCOMMAND}' (only 'task' is supported)" >&2
  usage >&2
  exit 2
fi
shift || true

# ---- 引数パース -----------------------------------------------------------
WRITE=0
WORKSPACE=""
MODEL=""
PROMPT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug)
      DEBUG=1
      shift
      ;;
    --write)
      WRITE=1
      shift
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --workspace=*)
      WORKSPACE="${1#*=}"
      shift
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --model=*)
      MODEL="${1#*=}"
      shift
      ;;
    --)
      shift
      [ "$#" -gt 0 ] && PROMPT="$1"
      break
      ;;
    -*)
      echo "ERROR: unknown flag: '$1'" >&2
      usage >&2
      exit 2
      ;;
    *)
      PROMPT="$1"
      shift
      ;;
  esac
done

# ---- WRITE 時の PRE-LAUNCH WORKSPACE GUARD --------------------------------
# cursor-companion.sh と同趣旨: --write を誤って main tree や $HOME に向けることを
# 防ぐ。runtime escape までは防げない点に注意（本当の境界は worktree + Lead レビュー）。
if [ "${WRITE}" -eq 1 ]; then
  if [ -z "${WORKSPACE}" ]; then
    echo "ERROR: --write requires --workspace <dir> (refusing to write without an explicit isolated workspace)" >&2
    exit 2
  fi
  if [ ! -d "${WORKSPACE}" ]; then
    echo "ERROR: --workspace '${WORKSPACE}' is not a directory" >&2
    exit 2
  fi
  ws_abs="$(cd "${WORKSPACE}" 2>/dev/null && pwd -P || true)"
  if [ -z "${ws_abs}" ]; then
    echo "ERROR: --workspace '${WORKSPACE}' could not be resolved to an absolute path" >&2
    exit 2
  fi
  repo_abs="$(cd "${REPO_ROOT}" 2>/dev/null && pwd -P || printf '%s' "${REPO_ROOT}")"
  home_abs="$(cd "${HOME}" 2>/dev/null && pwd -P || printf '%s' "${HOME}")"
  if [ "${ws_abs}" = "${repo_abs}" ]; then
    echo "ERROR: --write --workspace must not point at the repo root ('${repo_abs}'); use an isolated worktree" >&2
    exit 2
  fi
  if [ "${ws_abs}" = "${home_abs}" ]; then
    echo "ERROR: --write --workspace must not point at \$HOME ('${home_abs}')" >&2
    exit 2
  fi
fi

if [ -z "${PROMPT}" ]; then
  echo "ERROR: a prompt is required" >&2
  usage >&2
  exit 2
fi

# ---- grok 解決（ここで初めて行い、ガード違反は早く返す） ------------------
GROK_BIN="$(resolve_grok || true)"
if [ -z "${GROK_BIN}" ]; then
  echo "ERROR: grok not found (not-configured)" >&2
  echo "       Install the Grok CLI or place the binary at \$HOME/.local/bin/grok" >&2
  exit 3
fi

# ---- model 確定 -----------------------------------------------------------
if [ -z "${MODEL}" ]; then
  MODEL="$(resolve_grok_model)"
fi
if [ -z "${MODEL}" ]; then
  echo "ERROR: could not resolve a Grok model (model-routing.sh unavailable)" >&2
  exit 2
fi

# ---- コマンド構築 ---------------------------------------------------------
# 共通: -p（single-turn headless）+ JSON 出力 + model。
# read-only（default）: --permission-mode plan（gated planning、tool 実行なし）。
# write: --permission-mode を付けない（auto-run は ~/.grok/config.toml の
#        permission ルールに委ねる。--yolo / --always-approve は絶対に渡さない）。
cmd=("${GROK_BIN}" -p "${PROMPT}" --output-format json --model "${MODEL}")
if [ "${WRITE}" -eq 0 ]; then
  cmd+=(--permission-mode plan)
fi
if [ -n "${WORKSPACE}" ]; then
  cmd+=(--cwd "${WORKSPACE}")
fi

# ---- DEBUG: 実行前に cmd 配列を secret マスク付きで dump --------------------
if [ "${DEBUG}" = "1" ]; then
  masked="$(mask_args "${cmd[@]}")"
  debug_log "cmd: ${masked}"
fi

# ---- worktree fingerprint: capture before grok ------------------------------
FP_BEFORE="$(mktemp "${TMPDIR:-/tmp}/grok-companion-fp-before.XXXXXX")"
if ! fingerprint_capture "${FP_BEFORE}"; then
  rm -f "${FP_BEFORE}"
  echo "ERROR: worktree fingerprint capture (before) failed" >&2
  exit 1
fi

# ---- 実行（stdout を temp に捕捉し、exit code を先に確認）-----------------
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/grok-companion.XXXXXX")"
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/grok-companion-err.XXXXXX")"
cleanup() {
  rm -f "${OUT_FILE}" "${ERR_FILE}" "${FP_BEFORE}" "${FP_AFTER}"
}
trap cleanup EXIT

__orch_start_ms="$(__orch_now_ms 2>/dev/null || echo 0)"
set +e
"${cmd[@]}" >"${OUT_FILE}" 2>"${ERR_FILE}"
rc=$?
set -e

__orch_dur_ms=$(( $(__orch_now_ms 2>/dev/null || echo 0) - __orch_start_ms ))
[ "${__orch_dur_ms}" -ge 0 ] 2>/dev/null || __orch_dur_ms=0
orch_emit_ledger "grok" "task" "${WRITE}" "${rc}" "${__orch_dur_ms}" || true

# (0) worktree fingerprint diff — hard-stop on $HOME sensitive path changes.
if ! fingerprint_diff_or_stop; then
  exit 1
fi

# (1) exit code を最優先で確認。grok の公式契約は「失敗時は非ゼロ終了」
#     （~/.grok/docs/user-guide/14-headless-mode.md）。
if [ "${rc}" -ne 0 ]; then
  echo "ERROR: grok failed (exit ${rc})" >&2
  if [ -s "${ERR_FILE}" ]; then
    cat "${ERR_FILE}" >&2
  fi
  if [ -s "${OUT_FILE}" ]; then
    cat "${OUT_FILE}" >&2
  fi
  exit "${rc}"
fi

# (2) DEBUG=1 のときは成功時にも grok stderr を出す。
if [ "${DEBUG}" = "1" ] && [ -s "${ERR_FILE}" ]; then
  debug_log "grok stderr: $(cat "${ERR_FILE}")"
fi

# (3) 成功 exit でも結果が不正なら failure 扱い（空 success を出力しない）。
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to parse grok output" >&2
  exit 1
fi

resp_type="$(jq -r 'if .type == "error" then "error" else "ok" end' "${OUT_FILE}" 2>/dev/null || echo "parse-error")"
if [ "${resp_type}" = "parse-error" ]; then
  echo "ERROR: grok produced unparseable output (no valid JSON result)" >&2
  if [ -s "${ERR_FILE}" ]; then
    cat "${ERR_FILE}" >&2
  fi
  exit 1
fi
if [ "${resp_type}" = "error" ]; then
  echo "ERROR: grok reported type=error" >&2
  jq -r '.message // empty' "${OUT_FILE}" >&2 2>/dev/null || true
  exit 1
fi

result="$(jq -r '.text // empty' "${OUT_FILE}" 2>/dev/null || true)"
if [ -z "${result}" ]; then
  echo "ERROR: grok returned a null/empty text result" >&2
  exit 1
fi

# (4) 本当の成功: text を stdout に出力する。
printf '%s\n' "${result}"
