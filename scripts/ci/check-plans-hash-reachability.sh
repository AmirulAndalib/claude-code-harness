#!/bin/bash
# scripts/ci/check-plans-hash-reachability.sh
# Phase 128 台帳訂正の副産物 (2026-08-02): Plans.md の Status 欄に記録された
# commit hash (`cc:done [<hash>; ...]` / `cc:完了 [<hash>; ...]`) が、現在の
# HEAD から到達可能であることを検証する。
#
# 背景: Phase 128 (128.1-128.5) が `7702ca45` / `476ea403` を記録していたが、
# PR #282 が squash merge されたため worktree 側の commit は main の祖先ではなく
# なった (main に入った実体は `1f085a35`)。この種の不整合を機械検知するゲート
# が存在しなかったため新設する。
#
# なぜ origin/main ではなく HEAD を基準にするか:
#   feature branch 上では、cherry-pick 済みの commit は HEAD の祖先だが
#   まだ main には入っていない。origin/main を基準にすると進行中の PR の
#   Plans.md 記録がすべて誤検出で落ちる。HEAD 基準なら feature branch 上でも
#   main 上でも正しく判定でき、かつ squash merge で祖先から消える今回のケース
#   (main 上では到達可能、worktree 側 commit のみ祖先から消える) も確実に
#   検出できる。
#
# 抽出対象: `cc:done [` / `cc:完了 [` の直後から行末までの範囲 (Status 欄は
# table の最終列のため、マーカー以降が丸ごと Status セルの中身になる) に
# 現れる 7〜40 文字・単語境界で区切られた 16 進文字列のみ。PR 番号 (#282)・
# 日付 (2026-07-31)・日本語・`[lane:gate]` のようなタグは Status 欄の外
# (DoD/内容欄) にあるため対象に含まれない。
#
# baseline (grandfather) 運用:
#   既存の到達不可 hash が残っている場合は scripts/ci/plans-hash-baseline.txt
#   に列挙して除外する (1 行 1 hash、# 始まりはコメント)。新規追加のテスト
#   自体はいつでも自由 (workflow-test-wiring.md の direction-asymmetric rule)
#   だが、baseline への「既存 drift を見逃す」追加は人間の判断で行う。
#
# Usage: bash scripts/ci/check-plans-hash-reachability.sh [path/to/Plans.md]
# Env:
#   PLANS_HASH_BASELINE  baseline ファイルのパスを上書き (テスト用)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLANS_FILE="${1:-$ROOT_DIR/Plans.md}"
BASELINE_FILE="${PLANS_HASH_BASELINE:-$ROOT_DIR/scripts/ci/plans-hash-baseline.txt}"

if [ ! -f "$PLANS_FILE" ]; then
  echo "check-plans-hash-reachability: Plans.md not found at $PLANS_FILE" >&2
  exit 1
fi

# Plans.md が属する git リポジトリを解決する (テストでは実プロジェクトと
# 別の一時 git リポジトリを指すため、常に ROOT_DIR を使うわけにはいかない)。
PLANS_DIR="$(cd "$(dirname "$PLANS_FILE")" && pwd)"
GIT_ROOT="$(git -C "$PLANS_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$GIT_ROOT" ]; then
  GIT_ROOT="$ROOT_DIR"
fi

# shallow clone は commit object が存在しないため検証不能。not_observed として
# skip する (project 規約: not_observed != absent)。
IS_SHALLOW="$(git -C "$GIT_ROOT" rev-parse --is-shallow-repository 2>/dev/null || echo false)"
if [ "$IS_SHALLOW" = "true" ]; then
  echo "check-plans-hash-reachability: not_observed (shallow clone のため commit 到達可能性は未検証)"
  exit 0
fi

# baseline (既存の grandfather 対象) を読み込む
BASELINE_HASHES=()
if [ -f "$BASELINE_FILE" ]; then
  while IFS= read -r _line; do
    case "$_line" in
      ''|'#'*) continue ;;
    esac
    BASELINE_HASHES+=("$_line")
  done < "$BASELINE_FILE"
fi

is_baselined() {
  local target="$1"
  local b
  for b in "${BASELINE_HASHES[@]:-}"; do
    [ -z "$b" ] && continue
    if [ "$b" = "$target" ]; then
      return 0
    fi
  done
  return 1
}

HASHES_FILE="$(mktemp "${TMPDIR:-/tmp}/plans-hash.XXXXXX")"
trap 'rm -f "$HASHES_FILE"' EXIT

perl -ne '
  if (/cc:(?:done|完了)\s*\[(.*)$/) {
    my $rest = $1;
    while ($rest =~ /\b([0-9a-f]{7,40})\b/g) {
      print "$1\n";
    }
  }
' "$PLANS_FILE" | sort -u > "$HASHES_FILE"

TOTAL=0
VIOLATIONS=0
SKIPPED_BASELINE=0
VIOLATION_LIST=""

while IFS= read -r h; do
  [ -z "$h" ] && continue
  TOTAL=$((TOTAL + 1))

  if is_baselined "$h"; then
    SKIPPED_BASELINE=$((SKIPPED_BASELINE + 1))
    continue
  fi

  if ! git -C "$GIT_ROOT" cat-file -e "${h}^{commit}" 2>/dev/null; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}  - ${h}: commit object not found locally
"
    continue
  fi

  if ! git -C "$GIT_ROOT" merge-base --is-ancestor "$h" HEAD 2>/dev/null; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}  - ${h}: not an ancestor of HEAD
"
  fi
done < "$HASHES_FILE"

echo "check-plans-hash-reachability: ${TOTAL} hash(es) scanned, ${SKIPPED_BASELINE} baselined, ${VIOLATIONS} violation(s)"

if [ "$VIOLATIONS" -gt 0 ]; then
  printf '%s' "$VIOLATION_LIST" >&2
  echo "check-plans-hash-reachability: FAIL — Plans.md references commit(s) unreachable from HEAD (see scripts/ci/plans-hash-baseline.txt to grandfather known-existing drift)" >&2
  exit 1
fi

echo "check-plans-hash-reachability: OK"
exit 0
