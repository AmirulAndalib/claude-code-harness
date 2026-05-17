#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${ROOT_DIR}/docs/tool-capability-matrix.md"

fail() {
  echo "test-tool-capability-matrix: FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local pattern="$1"
  if ! grep -Fq "$pattern" "$DOC"; then
    fail "expected '${pattern}' in docs/tool-capability-matrix.md"
  fi
}

[ -f "$DOC" ] || fail "missing docs/tool-capability-matrix.md"

required_capabilities=(
  '`skill_loading`'
  '`bootstrap_notice`'
  '`prompt_routing`'
  '`pre_use_guard`'
  '`post_use_gate`'
  '`review_artifact`'
  '`memory_bridge`'
)

for capability in "${required_capabilities[@]}"; do
  assert_contains "$capability"
done

required_hosts=(
  "Claude Code"
  "Codex"
  "OpenCode"
)

for host in "${required_hosts[@]}"; do
  assert_contains "$host"
done

future_hosts=(
  "| Cursor | future/unsupported |"
  "| Gemini | future/unsupported |"
  "| Copilot | future/unsupported |"
)

for host_row in "${future_hosts[@]}"; do
  assert_contains "$host_row"
done

assert_contains "False parity is forbidden."
assert_contains "contract injection + post quality gate + merge gate"
assert_contains "not a marketing support matrix"
assert_contains "OpenCode is currently a packaging and instruction surface"

echo "test-tool-capability-matrix: ok"
