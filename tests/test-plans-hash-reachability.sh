#!/bin/bash
# tests/test-plans-hash-reachability.sh
# Phase 128 台帳訂正 (2026-08-02) の副産物: scripts/ci/check-plans-hash-reachability.sh
# の契約テスト。Plans.md の `cc:done [<hash>; ...]` / `cc:完了 [<hash>; ...]` から
# 抽出した commit hash が HEAD から到達可能かどうかを、fixture 用の使い捨て
# git リポジトリを作って検証する（本リポジトリの実 Plans.md には依存しない）。
#
# 検証する不変条件: Status 欄に記録された commit hash は現在の HEAD の祖先で
# なければならない。origin/main を基準にしない理由は
# scripts/ci/check-plans-hash-reachability.sh 冒頭のコメントを参照。
#
# Usage: bash tests/test-plans-hash-reachability.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT_DIR/scripts/ci/check-plans-hash-reachability.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "✗ $1" >&2; }

if [ ! -x "$GATE" ] && [ ! -f "$GATE" ]; then
  fail "gate script not found: $GATE"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plans-hash-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- fixture git repo (reachable/unreachable hash の判定基盤) ----
# c1 (root) -> c2 (HEAD) の 2 commit だけを持つ使い捨てリポジトリ。
# c1/c2 は HEAD から到達可能、UNREACHABLE_HASH はこのリポジトリに存在しない
# 16 進文字列 (git object としてもコミットとしても不在)。
REPO_DIR="$WORK_DIR/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.name "test"
git -C "$REPO_DIR" config user.email "test@test.local"
git -C "$REPO_DIR" config commit.gpgsign false

echo "c1" > "$REPO_DIR/a.txt"
git -C "$REPO_DIR" add a.txt
git -C "$REPO_DIR" commit -q -m "c1"
C1="$(git -C "$REPO_DIR" rev-parse --short=8 HEAD)"

echo "c2" > "$REPO_DIR/a.txt"
git -C "$REPO_DIR" add a.txt
git -C "$REPO_DIR" commit -q -m "c2"
C2="$(git -C "$REPO_DIR" rev-parse --short=8 HEAD)"

UNREACHABLE_HASH="0badc0de"

write_plans() {
  # $1: 出力先パス, $2: Status 欄の中身 (cc:done [...] の [] の中)
  local out="$1" status_body="$2"
  cat > "$out" <<EOF
# Plans.md (test fixture)

| Task | 内容 | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 1.1 | \`[lane:gate]\` \`[tdd:required]\` \`[security]\` fixture row | (a) fixture DoD | - | cc:done [${status_body}] |
EOF
}

# fixture の Plans.md は REPO_DIR の中に置く。git rev-parse --show-toplevel が
# REPO_DIR を指すために必要 (WORK_DIR 直下は git リポジトリではないため、
# そこに置くと gate がリポジトリ解決に失敗してこのプロジェクト自身の repo に
# フォールバックしてしまう)。

# ---- (a) 到達可能な hash のみ → pass ----
PLANS_A="$REPO_DIR/plans-a.md"
write_plans "$PLANS_A" "${C1}; RED 実測... fixed by ${C2}"

if bash "$GATE" "$PLANS_A" > "$WORK_DIR/out-a.log" 2>&1; then
  pass "(a) 到達可能な hash のみの Plans.md は pass する"
else
  fail "(a) 到達可能な hash のみの Plans.md が fail した: $(cat "$WORK_DIR/out-a.log")"
fi

# ---- (b) 到達不可な hash を含む → fail ----
PLANS_B="$REPO_DIR/plans-b.md"
write_plans "$PLANS_B" "${UNREACHABLE_HASH}; squash merge で祖先から消えた想定"

if bash "$GATE" "$PLANS_B" > "$WORK_DIR/out-b.log" 2>&1; then
  fail "(b) 到達不可な hash を含む Plans.md が pass してしまった (期待は fail)"
else
  if grep -Fq "$UNREACHABLE_HASH" "$WORK_DIR/out-b.log"; then
    pass "(b) 到達不可な hash を含む Plans.md は fail し、違反 hash を報告する"
  else
    fail "(b) fail はしたが違反 hash が出力に含まれない: $(cat "$WORK_DIR/out-b.log")"
  fi
fi

# ---- (c) タグ ([lane:gate] 等) を hash と誤認しない ----
# DoD/内容欄に hex 風のタグ [deadbeef] を仕込む。Status 欄の外にあるため
# 抽出対象に含まれてはいけない。仮に誤検出されると、このリポジトリには
# 存在しない "deadbeef" が違反として報告され gate は fail するはず。
PLANS_C="$REPO_DIR/plans-c.md"
cat > "$PLANS_C" <<EOF
# Plans.md (test fixture)

| Task | 内容 | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 1.1 | \`[lane:gate]\` \`[tdd:required]\` \`[deadbeef]\` タグに見える文字列を含む fixture row | (a) fixture DoD、hex 風タグ [deadbeef] をここに置く | - | cc:done [${C1}; Status 欄には hex 風タグを含めない] |
EOF

if bash "$GATE" "$PLANS_C" > "$WORK_DIR/out-c.log" 2>&1; then
  if grep -Fq "deadbeef" "$WORK_DIR/out-c.log"; then
    fail "(c) Status 欄の外のタグ風文字列 [deadbeef] を hash として拾ってしまった (出力に混入)"
  else
    pass "(c) [lane:gate] 等のタグ、および Status 欄外の hex 風タグは hash と誤認されない"
  fi
else
  fail "(c) タグ誤認と思われる原因で fail した: $(cat "$WORK_DIR/out-c.log")"
fi

# ---- (d) shallow clone 相当の状況ではスキップ (not_observed) ----
SHALLOW_DIR="$WORK_DIR/shallow"
git clone -q --depth 1 "file://$REPO_DIR" "$SHALLOW_DIR" 2>/dev/null
PLANS_D="$SHALLOW_DIR/plans-d.md"
write_plans "$PLANS_D" "${UNREACHABLE_HASH}; shallow clone なので本来は検証できないはず"

if OUT_D="$(bash "$GATE" "$PLANS_D" 2>&1)"; then
  if grep -Fq "not_observed" <<<"$OUT_D"; then
    pass "(d) shallow clone では検証をスキップし not_observed で exit 0 になる"
  else
    fail "(d) shallow clone で exit 0 だったが not_observed の文言が無い: $OUT_D"
  fi
else
  fail "(d) shallow clone なのに fail してしまった (skip すべき): $OUT_D"
fi

# ---- (e) baseline による除外が効く ----
PLANS_E="$REPO_DIR/plans-e.md"
write_plans "$PLANS_E" "${UNREACHABLE_HASH}; baseline で除外される想定"

BASELINE_FILE="$WORK_DIR/plans-hash-baseline.txt"
cat > "$BASELINE_FILE" <<EOF
# test baseline
${UNREACHABLE_HASH}
EOF

if OUT_E="$(PLANS_HASH_BASELINE="$BASELINE_FILE" bash "$GATE" "$PLANS_E" 2>&1)"; then
  if grep -Fq "1 baselined" <<<"$OUT_E"; then
    pass "(e) baseline に列挙した到達不可 hash は除外され pass する"
  else
    fail "(e) pass はしたが baseline 除外件数が出力に反映されていない: $OUT_E"
  fi
else
  fail "(e) baseline を指定したのに fail した: $OUT_E"
fi

# baseline が対象を含まない場合は引き続き fail することも確認 (baseline が
# 「全部無視」の裏口にならないことの非退行)。
BASELINE_EMPTY="$WORK_DIR/plans-hash-baseline-empty.txt"
cat > "$BASELINE_EMPTY" <<EOF
# test baseline (empty, target hash not listed)
EOF

if PLANS_HASH_BASELINE="$BASELINE_EMPTY" bash "$GATE" "$PLANS_E" > "$WORK_DIR/out-e2.log" 2>&1; then
  fail "(e2) baseline に列挙されていない到達不可 hash まで pass してしまった (baseline が裏口になっている)"
else
  pass "(e2) baseline に列挙されていない到達不可 hash は引き続き fail する"
fi

# ---- サマリ ----
echo
echo "============================================"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "All assertions passed."
  exit 0
fi
exit 1
