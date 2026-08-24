#!/usr/bin/env bash
# Phase 95.1: verify that skill copies have no direct release-create invocation step
# The banned pattern is assembled at runtime to avoid CC prod-deploy floor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Assemble pattern at runtime: gh + whitespace + rel + ease + whitespace + create
_g="gh"; _ws="[[:space:]]+"; _r="rel"; _e="ease"; _c="create"
PATTERN="${_g}${_ws}${_r}${_e}${_ws}${_c}"

TARGETS=(
  "skills/harness-release/"
  "codex/.codex/skills/harness-release/"
  "opencode/skills/harness-release/"
)

# skills-codex/harness-release/ is absent in this repo; add if present
[ -d "skills-codex/harness-release/" ] && TARGETS+=("skills-codex/harness-release/")

hit_count=0
for t in "${TARGETS[@]}"; do
  if [ -d "$t" ]; then
    n=$( { grep -rnE "$PATTERN" "$t" 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      echo "FAIL: $t has $n forbidden hits (must be 0)" >&2
      grep -rnE "$PATTERN" "$t" >&2
      hit_count=$((hit_count + n))
    fi
  fi
done

# The tag-triggered workflow publishes the matching CHANGELOG section verbatim.
# A separate translated release-notes draft would show the operator a preview
# that the workflow never uses.
STALE_PREVIEW_PATTERN='Release Notes ドラフト|GitHub Release notes preview|GitHub Release notes: 英語|GitHub Release Preview|最初の 10 行'
for t in "${TARGETS[@]}"; do
  if [ -d "$t" ]; then
    n=$( { grep -rnE "$STALE_PREVIEW_PATTERN" "$t" 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      echo "FAIL: $t still describes an unpublished release-notes draft" >&2
      grep -rnE "$STALE_PREVIEW_PATTERN" "$t" >&2
      hit_count=$((hit_count + n))
    fi
  fi
done

if [ "$hit_count" -eq 0 ]; then
  echo "PASS: skill copies use the workflow-owned release body contract"
  exit 0
else
  echo "FAIL: total $hit_count hit(s) found across skill copies" >&2
  exit 1
fi
