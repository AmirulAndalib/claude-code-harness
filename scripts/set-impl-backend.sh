#!/usr/bin/env bash
# set-impl-backend.sh
# 実装バックエンド（claude|codex|cursor）を env.local に永続化する（冪等）。
#
# 使い方:
#   bash scripts/set-impl-backend.sh <claude|codex|cursor>
#   bash scripts/set-impl-backend.sh --show     # 現在解決されるバックエンドを表示
#   bash scripts/set-impl-backend.sh --unset     # 設定を削除
#
# 効果:
#   - プロジェクトルートの env.local に `export HARNESS_IMPL_BACKEND=<value>` を書き込む
#   - すでに同じ値が設定済みの場合は何もしない（冪等）
#   - 別の値が設定されている場合は in-place で置換する（重複行を残さない）
#   - env.local が存在しない場合は新規作成する
#
# 注意:
#   - env.local はリポジトリにコミットしない（.gitignore 対象）
#   - グローバル設定は変更しない。このプロジェクトのセッションにのみ適用される
#
# テスト用オーバーライド:
#   - HARNESS_ENV_LOCAL が設定されている場合、env.local のパスとしてそれを使う
#     （${REPO_ROOT}/env.local の代わり）。テストが実 env.local に触れないようにするため。

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/.." && pwd)")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_LOCAL="${HARNESS_ENV_LOCAL:-${REPO_ROOT}/env.local}"
KEY="HARNESS_IMPL_BACKEND"

usage() {
  echo "使い方: $0 <claude|codex|cursor> | --show | --unset" >&2
}

# 妥当な値かどうか判定する
is_valid_backend() {
  case "$1" in
    claude | codex | cursor) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

case "$1" in
  --show)
    # 現在解決されるバックエンドを resolve-impl-backend.sh に委譲して表示する
    exec bash "${SCRIPT_DIR}/resolve-impl-backend.sh"
    ;;
  --unset)
    if [ -f "${ENV_LOCAL}" ] && grep -qE "^export ${KEY}=" "${ENV_LOCAL}" 2>/dev/null; then
      # 一時ファイルは env.local と同じディレクトリに作り、mv を atomic に保つ
      tmp_file="$(mktemp "${ENV_LOCAL}.XXXXXX")"
      grep -vE "^export ${KEY}=" "${ENV_LOCAL}" > "${tmp_file}" || true
      mv "${tmp_file}" "${ENV_LOCAL}"
      echo "[set-impl-backend] ${KEY} を ${ENV_LOCAL} から削除しました。"
    else
      echo "[set-impl-backend] ${KEY} は ${ENV_LOCAL} に設定されていません（変更なし）。"
    fi
    exit 0
    ;;
esac

VALUE="$1"
if ! is_valid_backend "${VALUE}"; then
  echo "[set-impl-backend] 不正な値: '${VALUE}'（claude|codex|cursor のいずれかを指定）" >&2
  exit 2
fi

# Use `export KEY=VALUE` so that `source env.local` propagates the variable
# to subprocesses. Without `export`, `source env.local` only sets a
# shell-local variable and spawned processes never see it.
ENTRY="export ${KEY}=${VALUE}"

# すでに同じ値の設定行が存在するか確認（冪等）
if grep -qE "^export ${KEY}=${VALUE}$" "${ENV_LOCAL}" 2>/dev/null; then
  echo "[set-impl-backend] ${ENTRY} はすでに ${ENV_LOCAL} に設定されています（変更なし）。"
  exit 0
fi

# 既存の設定行（別の値）があれば in-place で置換し、重複を残さない
if grep -qE "^export ${KEY}=" "${ENV_LOCAL}" 2>/dev/null; then
  # 一時ファイルは env.local と同じディレクトリに作り、mv を atomic に保つ
  tmp_file="$(mktemp "${ENV_LOCAL}.XXXXXX")"
  # 既存の設定行を新しい値に置換する。最初の 1 行だけ ENTRY に差し替え、残りの設定行は除去する。
  awk -v entry="${ENTRY}" -v key="export ${KEY}=" '
    index($0, key) == 1 {
      if (!replaced) { print entry; replaced = 1 }
      next
    }
    { print }
  ' "${ENV_LOCAL}" > "${tmp_file}"
  mv "${tmp_file}" "${ENV_LOCAL}"
  echo "[set-impl-backend] ${ENV_LOCAL} の ${KEY} を ${VALUE} に更新しました。"
  exit 0
fi

# env.local に追記（ファイルが存在しない場合は新規作成）
{
  echo ""
  echo "# 実装バックエンドの永続選択（claude|codex|cursor）"
  echo "${ENTRY}"
} >> "${ENV_LOCAL}"

echo "[set-impl-backend] ${ENTRY} を ${ENV_LOCAL} に追記しました。"
