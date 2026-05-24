#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "test-readme-product-surface: FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq "$needle" "$file" || fail "missing '$needle' in $file"
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq "$needle" "$file"; then
    fail "unexpected '$needle' in $file"
  fi
}

for file in "$ROOT_DIR/README.md" "$ROOT_DIR/README_ja.md"; do
  [ -f "$file" ] || fail "missing $file"
  assert_contains "$file" "docs/onboarding/index.md"
  assert_contains "$file" "docs/onboarding/migration.md"
  assert_contains "$file" "docs/onboarding/skill-trigger-acceptance.md"
  assert_contains "$file" "Claude Code | \`supported\`"
  assert_contains "$file" "Codex CLI | \`internal-compatible\`"
  assert_contains "$file" "Codex app | \`candidate\`"
  assert_contains "$file" "OpenCode | \`internal-compatible\`"
  assert_contains "$file" "Cursor | \`candidate\`"
  assert_contains "$file" "GitHub Copilot CLI | \`candidate\`"
  assert_contains "$file" "Antigravity CLI | \`future/unsupported\`"
  assert_contains "$file" "docs/images/readme/hero-operating-loop-"
  assert_not_contains "$file" "Hokage"
  assert_not_contains "$file" "v4.2"
  assert_not_contains "$file" "v4.0"
  assert_not_contains "$file" "docs/images/hokage/hokage-hero.jpg"
  assert_not_contains "$file" "only setup"
done

assert_contains "$ROOT_DIR/README.md" "## Quickstart"
assert_contains "$ROOT_DIR/README.md" "## Install in 30 Seconds"
assert_contains "$ROOT_DIR/README.md" "## First 15 Minutes"
assert_contains "$ROOT_DIR/README.md" "## How It Works"
assert_contains "$ROOT_DIR/README.md" "## Commands"
assert_contains "$ROOT_DIR/README.md" "What happens inside"
assert_contains "$ROOT_DIR/README.md" "## Basic Workflow"
assert_contains "$ROOT_DIR/README.md" "## Install By Tool"
assert_contains "$ROOT_DIR/README.md" "## Existing User Migration"
assert_contains "$ROOT_DIR/README.md" "## Support Boundary"
assert_contains "$ROOT_DIR/README.md" "## Advanced"
assert_contains "$ROOT_DIR/README.md" "## Documentation"
assert_contains "$ROOT_DIR/README.md" "Your job is not to hand-write the plan"
assert_contains "$ROOT_DIR/README.md" "run \`/harness-plan\` with one small request"
assert_contains "$ROOT_DIR/README.md" "Harness writes the \`spec.md\` and"
assert_contains "$ROOT_DIR/README.md" "Run the smallest approved task"

assert_contains "$ROOT_DIR/README_ja.md" "## 最短導入"
assert_contains "$ROOT_DIR/README_ja.md" "## 30秒でインストール"
assert_contains "$ROOT_DIR/README_ja.md" "## 最初の15分"
assert_contains "$ROOT_DIR/README_ja.md" "## 中で何が起きるか"
assert_contains "$ROOT_DIR/README_ja.md" "## コマンド"
assert_contains "$ROOT_DIR/README_ja.md" "中でやること"
assert_contains "$ROOT_DIR/README_ja.md" "## 基本フロー"
assert_contains "$ROOT_DIR/README_ja.md" "## ツール別の導入"
assert_contains "$ROOT_DIR/README_ja.md" "## 既存ユーザーの移行"
assert_contains "$ROOT_DIR/README_ja.md" "## サポート境界"
assert_contains "$ROOT_DIR/README_ja.md" "## 高度な使い方"
assert_contains "$ROOT_DIR/README_ja.md" "## ドキュメント"
assert_contains "$ROOT_DIR/README_ja.md" "あなたが一から手で plan を書く前提ではありません"
assert_contains "$ROOT_DIR/README_ja.md" "小さな要望を渡す \`/harness-plan\`"
assert_contains "$ROOT_DIR/README_ja.md" "Harness が \`spec.md\` と"
assert_contains "$ROOT_DIR/README_ja.md" "承認済みの最小 task"
assert_not_contains "$ROOT_DIR/README_ja.md" "## How It Works"
assert_not_contains "$ROOT_DIR/README_ja.md" "## Install By Tool"
assert_not_contains "$ROOT_DIR/README_ja.md" "## Existing User Migration"
assert_not_contains "$ROOT_DIR/README_ja.md" "## Advanced"

echo "test-readme-product-surface: ok"
