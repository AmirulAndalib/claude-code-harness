#!/usr/bin/env bash
# resolve-impl-backend.sh
# 実装バックエンド（claude|codex|cursor）を優先順位に従って解決し、stdout に 1 行で出力する。
#
# 使い方:
#   bash scripts/resolve-impl-backend.sh [--backend <v>] [--role <role>]
#
# 優先順位（高い順）:
#   1. --backend <v> フラグ
#   2. HARNESS_IMPL_BACKEND 環境変数
#   3. ${REPO_ROOT}/env.local の `^export HARNESS_IMPL_BACKEND=` 行
#   4. 既定値 claude
#
# 妥当性:
#   - 解決値は {claude, codex, cursor} のいずれかでなければならない
#   - env / file の値が不正な場合は stderr に警告し claude にフォールバックする
#   - --backend に不正値が渡された場合はエラー終了する（exit 2）
#
# --role:
#   - 前方互換のために受理するが、現時点では解決結果に影響しない（reserved）
#
# テスト用オーバーライド:
#   - HARNESS_ENV_LOCAL が設定されている場合、env.local のパスとしてそれを使う
#     （${REPO_ROOT}/env.local の代わり）。テストが実 env.local に触れないようにするため。

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/.." && pwd)")"
ENV_LOCAL="${HARNESS_ENV_LOCAL:-${REPO_ROOT}/env.local}"
KEY="HARNESS_IMPL_BACKEND"
DEFAULT="claude"

# 妥当な値かどうか判定する
is_valid_backend() {
  case "$1" in
    claude | codex | cursor) return 0 ;;
    *) return 1 ;;
  esac
}

flag_backend=""
# shellcheck disable=SC2034  # role is reserved for forward-compat; not yet used in resolution
role=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend)
      flag_backend="${2:-}"
      shift 2
      ;;
    --role)
      role="${2:-}"
      shift 2
      ;;
    *)
      echo "[resolve-impl-backend] 不明な引数: $1" >&2
      exit 2
      ;;
  esac
done

# 1. --backend フラグ（不正値はエラー終了）
if [ -n "${flag_backend}" ]; then
  if is_valid_backend "${flag_backend}"; then
    echo "${flag_backend}"
    exit 0
  fi
  echo "[resolve-impl-backend] 不正な --backend 値: '${flag_backend}'（claude|codex|cursor のいずれかを指定）" >&2
  exit 2
fi

# 2. 環境変数（不正値は警告して claude にフォールバック）
if [ -n "${HARNESS_IMPL_BACKEND:-}" ]; then
  if is_valid_backend "${HARNESS_IMPL_BACKEND}"; then
    echo "${HARNESS_IMPL_BACKEND}"
    exit 0
  fi
  echo "[resolve-impl-backend] 警告: 環境変数 ${KEY}='${HARNESS_IMPL_BACKEND}' が不正です。'${DEFAULT}' にフォールバックします。" >&2
  echo "${DEFAULT}"
  exit 0
fi

# 3. env.local の設定行（不正値は警告して claude にフォールバック）
if [ -f "${ENV_LOCAL}" ]; then
  file_line="$(grep -E "^export ${KEY}=" "${ENV_LOCAL}" 2>/dev/null | tail -1 || true)"
  if [ -n "${file_line}" ]; then
    file_value="${file_line#export ${KEY}=}"
    if is_valid_backend "${file_value}"; then
      echo "${file_value}"
      exit 0
    fi
    echo "[resolve-impl-backend] 警告: ${ENV_LOCAL} の ${KEY}='${file_value}' が不正です。'${DEFAULT}' にフォールバックします。" >&2
    echo "${DEFAULT}"
    exit 0
  fi
fi

# 4. 既定値
echo "${DEFAULT}"
