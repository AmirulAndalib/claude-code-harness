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
#   4. defer (140.1): warn なら ask になる場面が deny + .claude/state/deferred-ops.jsonl 1 行に
#      なる。同一コマンド再試行でキューが増えない。局所綴りの warn 経路は不変
#   5. 140.2: `harness deferred approve <id>` の後、同一コマンドの再実行が「次の 1 回だけ」
#      allow になり (consume)、その次はまた deny + 再キューされる。未 approve の別 id は deny のまま
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

# 4. defer (Phase 140.1): warn なら ask になる場面 (glob) を deny + 保留キューに変える
deferred_count() {
  local dir="$1"
  local f="$dir/.claude/state/deferred-ops.jsonl"
  if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi
}

DEFER_DIR="$(fixture_project defer defer)"
mkdir -p "$DEFER_DIR/build/x"
CMD="cd $DEFER_DIR && rm -rf ./build/*"
decision="$(run_hook "$DEFER_DIR" "$CMD")"
if [ "$decision" = "deny" ]; then
  pass "defer: warn なら ask になる glob 削除が deny になる"
else
  fail "defer: deny を期待したが $decision"
fi
if [ "$(deferred_count "$DEFER_DIR")" = "1" ]; then
  pass "defer: .claude/state/deferred-ops.jsonl に 1 行積まれる"
  if jq -e --arg cmd "$CMD" --arg sid "$SESSION_ID" \
       'select(.command == $cmd and .policy == "defer" and .status == "pending" and .session_id == $sid and .rule_id == "R05:confirm-rm-rf" and (.id | length) == 12 and .reason != "")' \
       "$DEFER_DIR/.claude/state/deferred-ops.jsonl" >/dev/null; then
    pass "defer: キュー行に id / command / policy / status / session_id / rule_id / reason が入っている"
  else
    fail "defer: キュー行の内容が期待と違う: $(cat "$DEFER_DIR/.claude/state/deferred-ops.jsonl")"
  fi
else
  fail "defer: キューが 1 行でない ($(deferred_count "$DEFER_DIR"))"
fi
if [ "$(record_count "$DEFER_DIR")" = "0" ]; then
  pass "defer: 保留した削除は destructive-delete.jsonl (warn 記録) には書かれない"
else
  fail "defer: 保留した削除が warn 記録に混ざった"
fi

# 4b. 同一コマンドの再試行: deny 継続、キューは増えない
decision="$(run_hook "$DEFER_DIR" "$CMD")"
if [ "$decision" = "deny" ] && [ "$(deferred_count "$DEFER_DIR")" = "1" ]; then
  pass "defer: 同一コマンドの再試行は deny のまま、キューは 1 行のまま"
else
  fail "defer: 再試行で decision=$decision / キュー $(deferred_count "$DEFER_DIR") 行"
fi

# 4c. defer でも局所的な綴りは warn 経路のまま (allow + warn 記録)、既存挙動の回帰なし
CMD="cd $DEFER_DIR && echo hi && rm -rf tmp/x"
decision="$(run_hook "$DEFER_DIR" "$CMD")"
if [ "$decision" = "allow" ] && [ "$(record_count "$DEFER_DIR")" = "1" ] && [ "$(deferred_count "$DEFER_DIR")" = "1" ]; then
  pass "defer: 局所的な綴りは warn のまま allow + 記録、キューには積まれない"
else
  fail "defer: 局所綴りで decision=$decision / warn 記録 $(record_count "$DEFER_DIR") / キュー $(deferred_count "$DEFER_DIR")"
fi

# ============================================================
# 5. 140.2: deferred approve → 次の 1 回だけ allow (consume)
# ============================================================

QUEUE_FILE="$DEFER_DIR/.claude/state/deferred-ops.jsonl"
DEFER_ID="$(jq -r 'select(.status == "pending") | .id' "$QUEUE_FILE" | head -1)"
CMD_GLOB="cd $DEFER_DIR && rm -rf ./build/*"

# 5-pre. list CLI: pending 1 件が出る
list_out="$("$HARNESS_BIN" deferred list "$DEFER_DIR" 2>&1)" || true
if grep -q "$DEFER_ID" <<< "$list_out"; then
  pass "140.2: deferred list が pending の id を表示する"
else
  fail "140.2: deferred list に id が出ない: $list_out"
fi

# 5a. approve CLI が pending → approved に flip する
if "$HARNESS_BIN" deferred approve "$DEFER_ID" "$DEFER_DIR" >/dev/null 2>"$WORK_DIR/approve.err"; then
  pass "140.2: deferred approve <id> が成功する"
else
  fail "140.2: deferred approve が失敗した: $(cat "$WORK_DIR/approve.err")"
fi
if jq -e --arg id "$DEFER_ID" 'select(.id == $id and .status == "approved")' "$QUEUE_FILE" >/dev/null 2>&1; then
  pass "140.2: キュー行が status=approved に更新される (履歴は消えない)"
else
  fail "140.2: approved 行が無い: $(cat "$QUEUE_FILE")"
fi

# 5b. approve 後の再実行は allow になり、defer として記録される
decision="$(run_hook "$DEFER_DIR" "$CMD_GLOB")"
if [ "$decision" = "allow" ]; then
  pass "140.2 (a): approve 後の同一コマンド再実行が allow になる"
else
  fail "140.2 (a): approve 後も $decision のまま"
fi
if jq -e 'select(.policy == "defer")' "$DEFER_DIR/.claude/state/destructive-delete.jsonl" >/dev/null 2>&1; then
  pass "140.2: consume された実行が policy=defer で destructive-delete.jsonl に記録される"
else
  fail "140.2: defer-approved の実行記録が無い: $(cat "$DEFER_DIR/.claude/state/destructive-delete.jsonl" 2>/dev/null)"
fi
if jq -e --arg id "$DEFER_ID" 'select(.id == $id and .status == "consumed")' "$QUEUE_FILE" >/dev/null 2>&1; then
  pass "140.2: consume でキュー行が status=consumed になる"
else
  fail "140.2: consumed 行が無い: $(cat "$QUEUE_FILE")"
fi

# 5c. consume は 1 回きり: 次の実行は deny に戻り、新しい pending 行が積まれる
decision="$(run_hook "$DEFER_DIR" "$CMD_GLOB")"
pending_after="$(jq -r --arg id "$DEFER_ID" 'select(.id == $id and .status == "pending") | .id' "$QUEUE_FILE" | wc -l | tr -d ' ')"
if [ "$decision" = "deny" ] && [ "$pending_after" = "1" ]; then
  pass "140.2: consume は 1 回きり。次の実行は deny に戻り、pending が 1 行だけ再キューされる"
else
  fail "140.2: consume 後の再実行 decision=$decision / 再キュー pending $pending_after 行"
fi

# 5d. 未 approve の別操作は deny のまま (b)
mkdir -p "$DEFER_DIR/dist/y"
CMD_OTHER="cd $DEFER_DIR && rm -rf ./dist/*"
decision="$(run_hook "$DEFER_DIR" "$CMD_OTHER")"
decision2="$(run_hook "$DEFER_DIR" "$CMD_OTHER")"
if [ "$decision" = "deny" ] && [ "$decision2" = "deny" ]; then
  pass "140.2 (b): 未 approve の保留操作は何度実行しても deny のまま"
else
  fail "140.2 (b): 未 approve が deny でない ($decision / $decision2)"
fi

# 5e2. R16: agent の Bash 経由 approve は hook が deny する (operator の直接実行は対象外)
decision="$(run_hook "$DEFER_DIR" "bin/harness deferred approve $DEFER_ID $DEFER_DIR")"
if [ "$decision" = "deny" ]; then
  pass "R16: agent の Bash 経由 'deferred approve' は deny される (self-approve 遮断)"
else
  fail "R16: self-approve が deny されない ($decision)"
fi
decision="$(run_hook "$DEFER_DIR" "bin/harness deferred list $DEFER_DIR")"
if [ "$decision" != "deny" ]; then
  pass "R16: 'deferred list' (報告経路) は deny されない ($decision)"
else
  fail "R16: list まで deny された"
fi

# 5e. 存在しない / pending でない id の approve は失敗する
if "$HARNESS_BIN" deferred approve "ffffffffffff" "$DEFER_DIR" >/dev/null 2>&1; then
  fail "140.2: 存在しない id の approve が成功してしまった"
else
  pass "140.2: 存在しない id の approve は非ゼロ終了する"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
