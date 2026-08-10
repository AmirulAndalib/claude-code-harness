#!/bin/bash
# scripts/ci/check-config-knob-wiring.sh
# Phase 132.4 - 「実装はあるが配線されていない」欠陥の再発防止ゲート。
#
# 実際に踏んだ事故 (2026-08-10): go/internal/guardrail/pre_tool.go の R04/R05
# confirmation-skip 経路が HARNESS_WORK_MODE / ULTRAWORK_MODE を読むが、
# repo 内のどの skill/script/hook もこの 2 変数を設定していなかった。
# escape hatch は実装済みだったのに一度も配線されておらず、/breezing 実行が
# 数ヶ月間 Yes/No ダイアログで止まり続けた (3,099 session log 中 1,099 件の
# R04 発火)。同型の欠陥は他にも複数回発生している
# (.claude-plugin/settings.json の permissions が Claude Code に読まれない /
# delivery hook gen の誤認)。
#
# 何を検証するか:
#   1. go/internal/guardrail/ と go/internal/policy/ で os.Getenv("KEY") 形の
#      呼び出しがあり、KEY が ^(HARNESS_|ULTRAWORK_) にマッチするものを consumer
#      として収集する
#   2. 各 KEY について、consumer scan 対象 (go/internal/guardrail,
#      go/internal/policy) の外側 — scripts/, hooks/, skills/, skills-codex/,
#      templates/, go/cmd/, または *.json/*.toml/*.yaml/*.yml — に代入・export
#      形の記述 (`KEY=`, `"KEY":`, `export KEY`, `Setenv("KEY"`) があれば
#      producer ありと判定する。prose 中の単なる言及 (代入形でない) は producer
#      とみなさない
#   3. producer が無い KEY は templates/registry/operator-supplied-knobs.v1.yaml
#      に registered であれば pass する (operator が手動設定する運用上の
#      escape hatch。reason と consumer の記録を必須にする)
#   4. producer も registry 登録も無い KEY は FAIL する
#
# Usage: bash scripts/ci/check-config-knob-wiring.sh [path/to/repo/root]
# Env:
#   CONFIG_KNOB_REGISTRY  registry ファイルのパスを上書き (テスト用)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ROOT_DIR="${1:-$DEFAULT_ROOT}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

REGISTRY_FILE="${CONFIG_KNOB_REGISTRY:-$ROOT_DIR/templates/registry/operator-supplied-knobs.v1.yaml}"

CONSUMER_DIRS=("go/internal/guardrail" "go/internal/policy")
PRODUCER_DIRS=("scripts" "hooks" "skills" "skills-codex" "templates" "go/cmd")

KEY_PATTERN='^(HARNESS_|ULTRAWORK_)'

# ---- 1. consumer 収集 ----
# 各 consumer dir を走査し、os.Getenv("KEY") 形式の呼び出しから KEY を抽出する。
# consumer の場所 (file:line) も記録する (フェイル時の resolve メッセージに使う)。

KEYS_FILE="$(mktemp "${TMPDIR:-/tmp}/config-knob-keys.XXXXXX")"
trap 'rm -f "$KEYS_FILE"' EXIT

for d in "${CONSUMER_DIRS[@]}"; do
  dir="$ROOT_DIR/$d"
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' f; do
    while IFS=: read -r lineno content; do
      # 1 行に複数の os.Getenv("...") がある場合も全て拾う
      key=""
      rest="$content"
      while [[ "$rest" =~ os\.Getenv\(\"([A-Za-z0-9_]+)\"\) ]]; do
        key="${BASH_REMATCH[1]}"
        rest="${rest#*"${BASH_REMATCH[0]}"}"
        if [[ "$key" =~ $KEY_PATTERN ]]; then
          printf '%s\t%s:%s\n' "$key" "${f#"$ROOT_DIR"/}" "$lineno" >> "$KEYS_FILE"
        fi
      done
    done < <(grep -n 'os\.Getenv(' "$f" 2>/dev/null || true)
  done < <(find "$dir" -type f -name '*.go' -print0)
done

if [ ! -s "$KEYS_FILE" ]; then
  echo "check-config-knob-wiring: consumer 対象の os.Getenv(\"HARNESS_*\"|\"ULTRAWORK_*\") 呼び出しが見つかりません (not_observed)"
  exit 0
fi

DISTINCT_KEYS_FILE="$(mktemp "${TMPDIR:-/tmp}/config-knob-distinct.XXXXXX")"
trap 'rm -f "$KEYS_FILE" "$DISTINCT_KEYS_FILE"' EXIT
cut -f1 "$KEYS_FILE" | sort -u > "$DISTINCT_KEYS_FILE"

consumer_location() {
  # 与えた KEY の consumer 出現箇所 (最初の1件) を "file:line" で返す
  local key="$1"
  awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$KEYS_FILE"
}

# ---- 2. producer 探索 ----

has_producer() {
  local key="$1"
  local d
  for d in "${PRODUCER_DIRS[@]}"; do
    local dir="$ROOT_DIR/$d"
    [ -d "$dir" ] || continue
    if grep -rlE "(^|[^A-Za-z0-9_])${key}=|\"${key}\"[[:space:]]*:|export[[:space:]]+${key}([^A-Za-z0-9_]|\$)|Setenv\(\"${key}\"" "$dir" >/dev/null 2>&1; then
      return 0
    fi
  done
  # repo 直下の *.json / *.toml / *.yaml / *.yml (producer dir に含まれないもの)
  local f
  while IFS= read -r -d '' f; do
    if grep -lE "(^|[^A-Za-z0-9_])${key}=|\"${key}\"[[:space:]]*:|export[[:space:]]+${key}([^A-Za-z0-9_]|\$)" "$f" >/dev/null 2>&1; then
      return 0
    fi
  done < <(find "$ROOT_DIR" -maxdepth 1 \( -iname '*.json' -o -iname '*.toml' -o -iname '*.yaml' -o -iname '*.yml' \) -type f -print0 2>/dev/null)
  return 1
}

# ---- 3. registry 登録探索 ----

is_registered() {
  local key="$1"
  [ -f "$REGISTRY_FILE" ] || return 1
  grep -qE "^[[:space:]]*-?[[:space:]]*key:[[:space:]]*\"?${key}\"?[[:space:]]*\$" "$REGISTRY_FILE"
}

# ---- 4. 判定 ----

TOTAL=0
VIOLATIONS=0
VIOLATION_LIST=""

while IFS= read -r key; do
  [ -z "$key" ] && continue
  TOTAL=$((TOTAL + 1))

  if has_producer "$key"; then
    continue
  fi

  if is_registered "$key"; then
    continue
  fi

  VIOLATIONS=$((VIOLATIONS + 1))
  loc="$(consumer_location "$key")"
  VIOLATION_LIST="${VIOLATION_LIST}  - ${key} (consumer: ${loc}): producer が repo 内に見つからず、${REGISTRY_FILE#"$ROOT_DIR"/} にも未登録です。
      解決策: (a) scripts/hooks/skills/templates/go/cmd 等に producer を追加する、
      または (b) operator が手動設定する運用なら registry に理由付きで登録する。
"
done < "$DISTINCT_KEYS_FILE"

echo "check-config-knob-wiring: ${TOTAL} key(s) scanned, ${VIOLATIONS} violation(s)"

if [ "$VIOLATIONS" -gt 0 ]; then
  printf '%s' "$VIOLATION_LIST" >&2
  echo "check-config-knob-wiring: FAIL — producer/registry のどちらも無い設定ノブが存在します" >&2
  exit 1
fi

echo "check-config-knob-wiring: OK"
exit 0
