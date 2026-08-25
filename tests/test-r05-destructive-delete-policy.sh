#!/bin/bash
# tests/test-r05-destructive-delete-policy.sh
# 実効性契約テスト: R05 の destructive_delete (v5.11.0〜 既定 warn) が、実際に
# `go build` した bin/harness へ Claude Code の PreToolUse stdin payload をそのまま
# 投入したときに効くことを確認する。
#
# go/internal/guardrail のユニットテスト (destructive_delete_policy_test.go) は
# EvaluatePreTool() を直接呼ぶが、「main.go の hook pre-tool エントリポイントまで
# 配線されているか」(D58: 配線した ≠ 効いている) はプロセス境界を越えて確認する。
#
# 4 点を固定する:
#   1. 既定 (設定なし) = warn: `cd <root> && echo && rm -rf tmp/x` が allow になり、
#      .claude/state/destructive-delete.jsonl に 1 行記録される
#   2. opt-out (harness.toml destructiveDelete=ask): 同じコマンドが ask に戻り、記録されない
#   2b. env HARNESS_DESTRUCTIVE_DELETE_POLICY=ask も既定 warn より優先される
#   3. warn でも root 外の絶対パスは allow にならず、記録もされない
#
# Usage: bash tests/test-r05-destructive-delete-policy.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "✗ $1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/r05-policy-e2e-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"; [ -n "${HARNESS_BIN_TMP:-}" ] && rm -f "$HARNESS_BIN_TMP"' EXIT

# Ambient knobs on the developer machine must not leak into the assertions.
unset HARNESS_DESTRUCTIVE_DELETE_POLICY HARNESS_WORK_MODE ULTRAWORK_MODE HARNESS_SESSION_ID 2>/dev/null || true

if [ -n "${HARNESS_BIN_OVERRIDE:-}" ]; then
  HARNESS_BIN="$HARNESS_BIN_OVERRIDE"
  pass "既存バイナリを使用 (HARNESS_BIN_OVERRIDE=$HARNESS_BIN)"
else
  HARNESS_BIN_TMP="$(mktemp "${TMPDIR:-/tmp}/r05-policy-e2e-bin.XXXXXX")"
  HARNESS_BIN="$HARNESS_BIN_TMP"
  if ! GO111MODULE=on go build -o "$HARNESS_BIN" "$ROOT_DIR/go/cmd/harness" 2>"$WORK_DIR/build.err"; then
    fail "harness CLI のビルドに失敗した: $(cat "$WORK_DIR/build.err")"
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
  fi
  pass "go/cmd/harness から実バイナリをビルドした"
fi

SESSION_ID="r05-policy-test-0123456789abcdef"
# root 外の絶対パス。fixture project の外にあり、セッション ID 成分も持たないので
# agent 所有にならない (実在しなくてよい: hook は評価だけで実行しない)。
OUTSIDE_TARGET="$WORK_DIR/outside-root/data"

# fixture_project <suffix> <policy-or-empty> → 絶対パス
fixture_project() {
  local suffix="$1"
  local policy="$2"
  local dir="$WORK_DIR/proj-$suffix"
  mkdir -p "$dir/tmp/x" "$dir/.claude/state"
  git -C "$dir" init -q 2>/dev/null || true
  if [ -n "$policy" ]; then
    printf '[safety.permissions]\ndestructiveDelete = "%s"\n' "$policy" > "$dir/harness.toml"
  fi
  echo "$dir"
}

# run_hook <project-dir> <command> → permissionDecision
#   exit 0 + JSON   → permissionDecision (allow / ask / deny)
#   exit 2          → "deny" (CC hook protocol: blocking error on stderr, e.g. RUNTIME_FLOOR)
#   その他の exit    → "error(exit N)" (クラッシュは allow にも ask にも化けさせない)
run_hook() {
  local dir="$1"
  local command="$2"
  local out rc
  set +e
  out="$(jq -cn --arg sid "$SESSION_ID" --arg cwd "$dir" --arg cmd "$command" \
    '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$cmd}}' \
    | (cd "$dir" && "$HARNESS_BIN" hook pre-tool 2>"$WORK_DIR/hook.err"))"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    echo "deny"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "error(exit $rc): $(tr '\n' ' ' < "$WORK_DIR/hook.err")"
    return 0
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // .decision // "approve"'
}

record_count() {
  local dir="$1"
  local f="$dir/.claude/state/destructive-delete.jsonl"
  if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi
}

# 1. 既定 (設定なし) = warn: allow + 記録
DEFAULT_DIR="$(fixture_project default "")"
CMD="cd $DEFAULT_DIR && echo hi && rm -rf tmp/x"
decision="$(run_hook "$DEFAULT_DIR" "$CMD")"
if [ "$decision" = "allow" ]; then
  pass "既定 (設定なし, v5.11.0〜 warn): 前置コマンド付き相対 rm -rf が allow になる"
else
  fail "既定: allow を期待したが $decision"
fi
if [ "$(record_count "$DEFAULT_DIR")" = "1" ]; then
  pass "既定 warn: .claude/state/destructive-delete.jsonl に 1 行記録される"
  if jq -e --arg cmd "$CMD" --arg sid "$SESSION_ID" \
       'select(.command == $cmd and .policy == "warn" and .session_id == $sid and .rule_id == "R05:confirm-rm-rf")' \
       "$DEFAULT_DIR/.claude/state/destructive-delete.jsonl" >/dev/null; then
    pass "既定 warn: 記録に command / policy / session_id / rule_id が入っている"
  else
    fail "既定 warn: 記録の内容が期待と違う: $(cat "$DEFAULT_DIR/.claude/state/destructive-delete.jsonl")"
  fi
else
  fail "既定 warn: 記録が 1 行でない ($(record_count "$DEFAULT_DIR"))"
fi

# 2. opt-out (harness.toml destructiveDelete=ask) は ask に戻り、記録されない
ASK_DIR="$(fixture_project askout ask)"
CMD="cd $ASK_DIR && echo hi && rm -rf tmp/x"
decision="$(run_hook "$ASK_DIR" "$CMD")"
if [ "$decision" = "ask" ]; then
  pass "opt-out (harness.toml destructiveDelete=ask): 同じコマンドが ask に戻る"
else
  fail "opt-out: ask を期待したが $decision"
fi
if [ "$(record_count "$ASK_DIR")" = "0" ]; then
  pass "opt-out: destructive-delete.jsonl は書かれない"
else
  fail "opt-out: 記録が書かれてしまった"
fi

# 2b. env override (ask) は既定 warn より優先
ENV_DIR="$(fixture_project env "")"
CMD="cd $ENV_DIR && rm -rf tmp/x"
decision="$(HARNESS_DESTRUCTIVE_DELETE_POLICY=ask run_hook "$ENV_DIR" "$CMD")"
if [ "$decision" = "ask" ]; then
  pass "env HARNESS_DESTRUCTIVE_DELETE_POLICY=ask が既定 warn より優先される"
else
  fail "env opt-out: ask を期待したが $decision"
fi

# 3. warn でも root 外は allow にならない
OUT_DIR="$(fixture_project outside warn)"
CMD="cd $OUT_DIR && rm -rf $OUTSIDE_TARGET"
decision="$(run_hook "$OUT_DIR" "$CMD")"
if [ "$decision" != "allow" ]; then
  pass "warn でも root 外の絶対パスは allow にならない ($decision)"
else
  fail "warn: root 外の絶対パスが allow になってしまった"
fi
if [ "$(record_count "$OUT_DIR")" = "0" ]; then
  pass "warn: allow にならなかった削除は記録されない"
else
  fail "warn: 拒否した削除が記録されてしまった"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
