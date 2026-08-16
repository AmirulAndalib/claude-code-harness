#!/bin/bash
# tests/test-browser-review-runner-video-artifacts.sh
# Phase 134.6 - scripts/browser-review-runner.sh の Screencast evidence 機械検証
#
# 検証観点:
#   (a) route=playwright + test-results/**/*.webm あり
#       → artifacts == [{kind:"video", path: <該当 .webm>}]
#   (b) route=playwright + 録画なし
#       → artifacts == [{kind:"text", note:"use.video 未設定の可能性"}] (縮退規則)
#   playwright 以外の route (agent-browser) → 録画があっても artifacts == [] (探索自体を行わない)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/browser-review-runner.sh"

PASS=0
FAIL=0
FAIL_MESSAGES=()

pass() { PASS=$((PASS + 1)); echo "✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_MESSAGES+=("$1"); echo "✗ $1" >&2; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -x "$SCRIPT" ]]; then
  fail "browser-review-runner.sh not executable: $SCRIPT"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi
pass "browser-review-runner.sh exists and is executable"

make_artifact() {
  local route="$1"
  local out="$2"
  jq -n --arg route "$route" '{
    task: {id: "134.6", title: "screencast evidence"},
    route: $route,
    browser_mode: "scripted",
    required_artifacts: [],
    execution_instructions: []
  }' > "$out"
}

# ==== Case A: route=playwright, test-results/**/*.webm あり (DoD a) ====

CASE_A_DIR="$TMP_DIR/case-video-present"
mkdir -p "$CASE_A_DIR/test-results/nested/dir"
: > "$CASE_A_DIR/test-results/nested/dir/trace.webm"
make_artifact "playwright" "$CASE_A_DIR/artifact.json"

OUT_A="$(cd "$CASE_A_DIR" && HARNESS_BROWSER_REVIEW_COMMAND="true" bash "$SCRIPT" artifact.json out.json >/dev/null && cat out.json)"

if jq -e '(.artifacts | length) == 1 and .artifacts[0].kind == "video"' <<<"$OUT_A" >/dev/null 2>&1; then
  pass "[video-present] artifacts[].kind == video (DoD a)"
else
  fail "[video-present] artifacts should contain exactly 1 video entry"
fi

if jq -e '.artifacts[0].path == "test-results/nested/dir/trace.webm"' <<<"$OUT_A" >/dev/null 2>&1; then
  pass "[video-present] artifacts[0].path resolves to the found .webm file"
else
  fail "[video-present] artifacts[0].path does not match the found .webm file"
fi

# ==== Case B: route=playwright, 録画なし (DoD b: 縮退規則) ====

CASE_B_DIR="$TMP_DIR/case-video-absent"
mkdir -p "$CASE_B_DIR"
make_artifact "playwright" "$CASE_B_DIR/artifact.json"

OUT_B="$(cd "$CASE_B_DIR" && HARNESS_BROWSER_REVIEW_COMMAND="true" bash "$SCRIPT" artifact.json out.json >/dev/null && cat out.json)"

if jq -e '(.artifacts | length) == 1 and .artifacts[0].kind == "text"' <<<"$OUT_B" >/dev/null 2>&1; then
  pass "[video-absent] no recording degrades to kind:text (DoD b)"
else
  fail "[video-absent] artifacts should degrade to a single kind:text entry"
fi

if jq -e '.artifacts[0].note == "use.video 未設定の可能性"' <<<"$OUT_B" >/dev/null 2>&1; then
  pass "[video-absent] note literal matches the degradation rule (DoD b)"
else
  fail "[video-absent] note should read 'use.video 未設定の可能性'"
fi

# ==== Case C: route=agent-browser (playwright 以外) → 録画があっても artifacts: [] ====

CASE_C_DIR="$TMP_DIR/case-non-playwright"
mkdir -p "$CASE_C_DIR/test-results"
: > "$CASE_C_DIR/test-results/should-be-ignored.webm"
make_artifact "agent-browser" "$CASE_C_DIR/artifact.json"

OUT_C="$(cd "$CASE_C_DIR" && HARNESS_BROWSER_REVIEW_COMMAND="true" bash "$SCRIPT" artifact.json out.json >/dev/null && cat out.json)"

if jq -e '.artifacts == []' <<<"$OUT_C" >/dev/null 2>&1; then
  pass "[non-playwright] artifacts == [] regardless of test-results contents"
else
  fail "[non-playwright] artifacts should be [] for non-playwright routes"
fi

# ==== Summary ====

echo ""
echo "============================================"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "FAIL details:" >&2
  for msg in "${FAIL_MESSAGES[@]}"; do
    echo "  - $msg" >&2
  done
  exit 1
fi
echo "All assertions passed."
exit 0
