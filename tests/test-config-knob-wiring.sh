#!/bin/bash
# tests/test-config-knob-wiring.sh
# Phase 132.4 の契約テスト: scripts/ci/check-config-knob-wiring.sh
#
# 検証する不変条件:「go/internal/guardrail・go/internal/policy が
# os.Getenv("HARNESS_*"|"ULTRAWORK_*") で読む key は、repo 内に producer
# (代入/export 形の記述) があるか、templates/registry/operator-supplied-knobs.v1.yaml
# に登録されているかのどちらかでなければ fail する」。
#
# 実リポジトリの現状値には依存せず、使い捨ての fixture ディレクトリ
# (consumer dir / producer dir / registry) を組み立てて gate に渡す。
#
# Usage: bash tests/test-config-knob-wiring.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT_DIR/scripts/ci/check-config-knob-wiring.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "✗ $1" >&2; }

if [ ! -f "$GATE" ]; then
  fail "gate script not found: $GATE"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/config-knob-wiring-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# fixture repo のひな型を作る: 常に必要な consumer dir だけ用意し、
# 各ケースで producer / registry を足し引きする。
make_fixture_root() {
  local root="$1"
  mkdir -p "$root/go/internal/guardrail" "$root/go/internal/policy"
  cat > "$root/go/internal/guardrail/pre_tool.go" <<'GOEOF'
package guardrail

import "os"

func resolveWorkMode() bool {
	return os.Getenv("HARNESS_WORK_MODE") != "" || os.Getenv("ULTRAWORK_MODE") != ""
}
GOEOF
}

# ---- (a) consumed key, no producer, no registry → FAIL ----
ROOT_A="$WORK_DIR/case-a"
make_fixture_root "$ROOT_A"

if bash "$GATE" "$ROOT_A" > "$WORK_DIR/out-a.log" 2>&1; then
  fail "(a) producer/registry のどちらも無い key が pass してしまった (期待は fail)"
else
  if grep -q "HARNESS_WORK_MODE" "$WORK_DIR/out-a.log" && grep -q "ULTRAWORK_MODE" "$WORK_DIR/out-a.log"; then
    pass "(a) producer/registry のどちらも無い key は fail し、違反 key を報告する"
  else
    fail "(a) fail はしたが違反 key が出力に含まれない: $(cat "$WORK_DIR/out-a.log")"
  fi
fi

# ---- (b) 同じ key を fixture registry に登録 → PASS ----
ROOT_B="$WORK_DIR/case-b"
make_fixture_root "$ROOT_B"
mkdir -p "$ROOT_B/templates/registry"
cat > "$ROOT_B/templates/registry/operator-supplied-knobs.v1.yaml" <<'YAMLEOF'
version: 1
entries:
  - key: "HARNESS_WORK_MODE"
    consumer: "go/internal/guardrail/pre_tool.go:1"
    reason: "test fixture: operator sets this by hand"
    registered: "2026-08-10"
  - key: "ULTRAWORK_MODE"
    consumer: "go/internal/guardrail/pre_tool.go:1"
    reason: "test fixture: operator sets this by hand"
    registered: "2026-08-10"
YAMLEOF

if bash "$GATE" "$ROOT_B" > "$WORK_DIR/out-b.log" 2>&1; then
  pass "(b) registry に登録した key は pass する"
else
  fail "(b) registry 登録済みの key が fail した: $(cat "$WORK_DIR/out-b.log")"
fi

# ---- (c) 同じ key に fixture producer を追加 (registry 無し) → PASS ----
ROOT_C="$WORK_DIR/case-c"
make_fixture_root "$ROOT_C"
mkdir -p "$ROOT_C/scripts"
cat > "$ROOT_C/scripts/set-work-mode.sh" <<'SHEOF'
#!/bin/bash
export HARNESS_WORK_MODE=1
export ULTRAWORK_MODE=1
SHEOF

if bash "$GATE" "$ROOT_C" > "$WORK_DIR/out-c.log" 2>&1; then
  pass "(c) producer を追加した key は registry 無しでも pass する"
else
  fail "(c) producer 追加済みの key が fail した: $(cat "$WORK_DIR/out-c.log")"
fi

# ---- (d) scan-coverage 回帰: consumer scope に新規 key を追加すると検出される ----
ROOT_D="$WORK_DIR/case-d"
make_fixture_root "$ROOT_D"
cat >> "$ROOT_D/go/internal/guardrail/pre_tool.go" <<'GOEOF'

func resolveSomethingNew() string {
	return os.Getenv("HARNESS_SOMETHING_NEW")
}
GOEOF

if bash "$GATE" "$ROOT_D" > "$WORK_DIR/out-d.log" 2>&1; then
  fail "(d) 新規 key 追加後の fixture が pass してしまった (走査漏れの疑い)"
else
  if grep -q "HARNESS_SOMETHING_NEW" "$WORK_DIR/out-d.log"; then
    pass "(d) 新規に増やした os.Getenv(\"HARNESS_SOMETHING_NEW\") が検出される (走査漏れの回帰網)"
  else
    fail "(d) fail はしたが新規 key が出力に含まれない (走査漏れ): $(cat "$WORK_DIR/out-d.log")"
  fi
fi

# ---- サマリ ----

echo
echo "============================================"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "All assertions passed."
  exit 0
fi
exit 1
