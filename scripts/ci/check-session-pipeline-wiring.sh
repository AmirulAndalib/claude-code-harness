#!/bin/bash
# scripts/ci/check-session-pipeline-wiring.sh
# Phase 141.10 - セッション協調パイプライン (Phase 141.1-141.9) の配線が切れていないかを機械検証する。
#
# このパイプラインは 7 つの継ぎ目で成り立っており、どれか 1 つが外れると
# 「実装はあるのに動かない」状態になる。実際、Phase 141 の起点は
# 「register が SessionStart の once:true で 1 回しか走らず、しかも Stop で
# 消えていたので、名簿が 1 ターン後に空になる」という継ぎ目の断線だった
# (D58「配線した != 効いている」)。このゲートは 7 点の存在確認を行う static gate で、
# 実効性 (RED->GREEN) の確認は go/internal/hookhandler の契約テスト群が担当する。
#
# 7 点:
#   1. 名簿の寿命: hooks.json 2 ファイルが SessionStart/Stop=register, SessionEnd=unregister を持ち、互いに一致する
#   2. 身分証の producer: session_register_identity.go が CLAUDE_ENV_FILE へ `export` 形式で書く
#      (素の KEY=VALUE は子プロセス env に届かないため、export の literal が load-bearing)
#   3. 送る口: skills/session-send/SKILL.md が存在し `harness inbox send` を案内する
#   4. 送る口の実体: go/cmd/harness/inbox.go が send サブコマンドを dispatch する
#   5. broadcast の scope: session_auto_broadcast.go が共有 (git-common-dir 親) の解決関数を使う
#   6. mem 同居: session_register.go が active.json を json.RawMessage で読み、他スキーマを保持する
#   7. 検証の関所と 5 ツール目: [livemsg] verification が config に配線され、hosts.toml に hermes がある
#
# Usage: bash scripts/ci/check-session-pipeline-wiring.sh [path/to/repo/root]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ROOT_DIR="${1:-$DEFAULT_ROOT}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

ERRORS=0

fail() {
  echo "  NG: $1"
  ERRORS=$((ERRORS + 1))
}

ok() {
  echo "  OK: $1"
}

echo "=== Session Pipeline Wiring Check (Phase 141) ==="
echo ""

# ---- 1. 名簿の寿命: hooks.json 2 ファイルのライフサイクル ----
echo "1. roster lifecycle (SessionStart/Stop register, SessionEnd unregister)"
HOOKS_SUMMARY="$(cd "$ROOT_DIR" && python3 - <<'PY' 2>/dev/null || true
import json

def summarize(path):
    try:
        data = json.load(open(path))
    except Exception:
        return None
    found = set()
    for event, groups in data.get("hooks", {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                command = hook.get("command", "")
                if "session-register" in command:
                    found.add(event + ":register")
                elif "session-unregister" in command:
                    found.add(event + ":unregister")
    return found

tracked = summarize("hooks/hooks.json")
plugin = summarize(".claude-plugin/hooks.json")
if tracked is None or plugin is None:
    print("MISSING")
elif tracked != plugin:
    print("MISMATCH " + ",".join(sorted(tracked ^ plugin)))
else:
    print("OK " + ",".join(sorted(tracked)))
PY
)"

case "$HOOKS_SUMMARY" in
  OK*)
    ENTRIES="${HOOKS_SUMMARY#OK }"
    for required in "SessionStart:register" "Stop:register" "SessionEnd:unregister"; do
      if grep -q "$required" <<<"$ENTRIES"; then
        ok "$required"
      else
        fail "hooks.json に $required がない (名簿が 1 ターンで消える回帰)"
      fi
    done
    if grep -q "Stop:unregister" <<<"$ENTRIES"; then
      fail "Stop で unregister している (Stop はターン境界であってセッション終了ではない)"
    fi
    ;;
  MISMATCH*)
    fail "hooks/hooks.json と .claude-plugin/hooks.json が不一致: ${HOOKS_SUMMARY#MISMATCH }"
    ;;
  *)
    fail "hooks.json を読めない (hooks/hooks.json または .claude-plugin/hooks.json)"
    ;;
esac
echo ""

# ---- 2. 身分証の producer: export 形式 ----
echo "2. identity producer writes export form to CLAUDE_ENV_FILE"
IDENTITY_SRC="$ROOT_DIR/go/internal/hookhandler/session_register_identity.go"
if [ ! -f "$IDENTITY_SRC" ]; then
  fail "session_register_identity.go がない"
else
  if grep -q 'CLAUDE_ENV_FILE' "$IDENTITY_SRC"; then
    ok "CLAUDE_ENV_FILE を読んでいる"
  else
    fail "CLAUDE_ENV_FILE を読んでいない"
  fi
  if grep -q '"export %s=%s"' "$IDENTITY_SRC"; then
    ok "export 形式で書き出している"
  else
    fail "export 形式で書いていない (素の KEY=VALUE は子プロセス env に届かない)"
  fi
fi
echo ""

# ---- 3. 送る口 (skill) ----
echo "3. agent-initiated send skill"
SEND_SKILL="$ROOT_DIR/skills/session-send/SKILL.md"
if [ ! -f "$SEND_SKILL" ]; then
  fail "skills/session-send/SKILL.md がない"
else
  ok "skills/session-send/SKILL.md がある"
  if grep -q 'inbox send' "$SEND_SKILL"; then
    ok "harness inbox send を案内している"
  else
    fail "SKILL.md が inbox send を案内していない"
  fi
  if grep -q 'HARNESS_LIVEMSG_TEAM' "$SEND_SKILL"; then
    ok "自分の身分証 (HARNESS_LIVEMSG_TEAM) の取り方を書いている"
  else
    fail "SKILL.md が HARNESS_LIVEMSG_TEAM に触れていない (宛名を名乗れない)"
  fi
fi
echo ""

# ---- 4. 送る口の実体 (CLI dispatch) ----
echo "4. inbox send subcommand is dispatched"
INBOX_DISPATCH="$ROOT_DIR/go/cmd/harness/inbox.go"
if [ -f "$INBOX_DISPATCH" ] && grep -q 'runInboxSendCommand' "$INBOX_DISPATCH"; then
  ok "inbox.go が send を dispatch している"
else
  fail "inbox send が dispatch されていない (skill が案内するコマンドが実在しない)"
fi
echo ""

# ---- 5. broadcast の scope 統一 ----
echo "5. broadcast uses the shared (git-common-dir) scope"
BROADCAST_SRC="$ROOT_DIR/go/internal/hookhandler/session_auto_broadcast.go"
if [ ! -f "$BROADCAST_SRC" ]; then
  fail "session_auto_broadcast.go がない"
elif grep -qE 'sharedLiveSessionsDirFromRoot|sharedSessionsDirFromRoot|sharedBroadcastPath' "$BROADCAST_SRC"; then
  ok "共有 scope の解決関数を使っている"
else
  fail "broadcast が worktree ローカルのまま (presence は共有なので、姿は見えるのに通知が届かない)"
fi
echo ""

# ---- 6. mem 同居時の非破壊 ----
echo "6. foreign roster entries survive (harness-mem coexistence)"
REGISTER_SRC="$ROOT_DIR/go/internal/hookhandler/session_register.go"
if [ -f "$REGISTER_SRC" ] && grep -q 'map\[string\]json.RawMessage' "$REGISTER_SRC"; then
  ok "active.json を RawMessage で読み書きしている"
else
  fail "active.json が自スキーマ決め打ち (他ツールの記録を 24h prune で破壊する)"
fi
echo ""

# ---- 7. 検証の関所 (既定 off) と 5 ツール目 ----
echo "7. verification knob and hermes host"
if grep -rqE 'livemsg' "$ROOT_DIR/go/pkg/config/" 2>/dev/null; then
  ok "config に livemsg が配線されている"
else
  fail "go/pkg/config に livemsg 設定がない ([livemsg] verification が読まれない)"
fi
if grep -q '^\[hermes\]' "$ROOT_DIR/hosts.toml" 2>/dev/null; then
  ok "hosts.toml に hermes がある"
else
  fail "hosts.toml に [hermes] がない (5 ツール目が未配線)"
fi

# hosts.toml に宣言があることと、`harness gen` が実際に出力することは別。
# Phase 141 では hermes の delivery が宣言だけされ、enforcement hook の deferred
# エラーで早期 return するため一度も出力されていなかった。宣言の grep では
# 捕まらないので、ここは実バイナリを一時ディレクトリで走らせて実出力を見る。
HARNESS_BIN="$ROOT_DIR/bin/harness"
if [ ! -x "$HARNESS_BIN" ]; then
  echo "  SKIP: bin/harness が無いため gen 実出力チェックを省略 (not_observed)"
else
  probe_root="$(mktemp -d)"
  probe_home="$(mktemp -d)"
  mkdir -p "$probe_home/.hermes"
  sed -n '/^\[hermes\]/,/^$/p' "$ROOT_DIR/hosts.toml" > "$probe_root/hosts.toml"
  if HOME="$probe_home" "$HARNESS_BIN" gen "$probe_root" >/dev/null 2>&1 \
     && [ -s "$probe_root/.hermes/hooks.json" ] \
     && grep -q 'inbox check' "$probe_root/.hermes/hooks.json"; then
    ok "harness gen が hermes の delivery を実際に出力する"
  else
    fail "hermes の delivery が生成されない (hosts.toml の宣言だけで実出力が無い)"
  fi
  rm -rf "$probe_root" "$probe_home"
fi
echo ""

# ---- 結果 ----
if [ "$ERRORS" -eq 0 ]; then
  echo "=== PASS: session pipeline wiring is intact (7/7) ==="
  exit 0
fi

echo "=== FAIL: $ERRORS wiring check(s) failed ==="
exit 1
