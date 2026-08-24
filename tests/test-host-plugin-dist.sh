#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build-host-plugin-dist.sh"

fail() {
  echo "test-host-plugin-dist: FAIL: $1" >&2
  exit 1
}

[ -x "$BUILD_SCRIPT" ] || chmod +x "$BUILD_SCRIPT"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

build_host() {
  local host="$1"
  local out="${TMP_ROOT}/${host}"
  bash "$BUILD_SCRIPT" --host "$host" --out "$out"
  printf '%s\n' "$out"
}

assert_absent() {
  local base="$1"
  local rel="$2"
  if [ -e "${base}/${rel}" ]; then
    fail "${base} must not contain ${rel}"
  fi
}

assert_present() {
  local base="$1"
  local rel="$2"
  if [ ! -e "${base}/${rel}" ]; then
    fail "${base} missing ${rel}"
  fi
}

assert_manifest_no_parent_paths() {
  local manifest="$1"
  if grep -Fq '../' "$manifest"; then
    fail "${manifest} contains .. paths"
  fi
}

CLAUDE_OUT="$(build_host claude)"
CODEX_OUT="$(build_host codex)"
CURSOR_OUT="$(build_host cursor)"
GROK_OUT="$(build_host grok)"

assert_present "$CLAUDE_OUT" ".claude-plugin/plugin.json"
assert_present "$CLAUDE_OUT" "skills/harness-work/SKILL.md"
assert_absent "$CLAUDE_OUT" ".codex-plugin"
assert_absent "$CLAUDE_OUT" ".cursor-plugin"
assert_absent "$CLAUDE_OUT" ".grok-plugin"
assert_absent "$CLAUDE_OUT" "codex"
assert_absent "$CLAUDE_OUT" ".cursor"
assert_present "$CLAUDE_OUT" "scripts/codex-companion.sh"
assert_present "$CLAUDE_OUT" "scripts/codex-review-app-server-proxy.mjs"
assert_present "$CLAUDE_OUT" "scripts/lib/orchestration-ledger.sh"
assert_present "$CLAUDE_OUT" "scripts/model-routing.sh"

assert_present "$CODEX_OUT" ".codex-plugin/plugin.json"
assert_present "$CODEX_OUT" "skills/harness-plan/SKILL.md"
assert_present "$CODEX_OUT" "scripts/codex-companion.sh"
assert_present "$CODEX_OUT" "scripts/codex-review-app-server-proxy.mjs"
assert_present "$CODEX_OUT" "scripts/lib/orchestration-ledger.sh"
assert_present "$CODEX_OUT" "scripts/cursor-companion.sh"
assert_present "$CODEX_OUT" "scripts/resolve-impl-backend.sh"
assert_present "$CODEX_OUT" "scripts/model-routing.sh"
assert_present "$CODEX_OUT" "VERSION"
for bin in harness harness-darwin-amd64 harness-darwin-arm64 harness-linux-amd64 harness-windows-amd64.exe; do
  assert_present "$CODEX_OUT" "bin/$bin"
  if ! cmp -s "$ROOT_DIR/bin/$bin" "$CODEX_OUT/bin/$bin"; then
    fail "Codex dist runtime binary must match the canonical artifact: $bin"
  fi
done
for profile in worker.toml reviewer.toml; do
  assert_present "$CODEX_OUT" "agents/$profile"
  if ! cmp -s "$ROOT_DIR/codex/.codex/agents/$profile" "$CODEX_OUT/agents/$profile"; then
    fail "Codex dist agent profile must be the generated canonical artifact: $profile"
  fi
done
assert_absent "$CODEX_OUT" ".claude-plugin"
assert_absent "$CODEX_OUT" ".cursor-plugin"
assert_absent "$CODEX_OUT" ".grok-plugin"
assert_absent "$CODEX_OUT" ".cursor"

# A Codex dist is a runtime package, not a presence-only bundle. Exercise the
# routed Luna/max task path with a fake provider binary and an isolated HOME;
# the real bundled harness binary performs both fingerprint captures.
mkdir -p "${TMP_ROOT}/codex-fake-bin" "${TMP_ROOT}/codex-home" "${TMP_ROOT}/codex-consumer"
cat >"${TMP_ROOT}/codex-fake-bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${FAKE_CODEX_ARGS:?}"
cat >/dev/null
EOF
chmod +x "${TMP_ROOT}/codex-fake-bin/codex"
if ! (cd "${TMP_ROOT}/codex-consumer" && \
  HOME="${TMP_ROOT}/codex-home" \
    CODEX_HOME="${TMP_ROOT}/codex-home" \
    PATH="${TMP_ROOT}/codex-fake-bin:${PATH}" \
    FAKE_CODEX_ARGS="${TMP_ROOT}/codex-args.txt" \
    HARNESS_PLUGIN_ROOT="$CODEX_OUT" \
    CODEX_MODEL_TIER=worker \
    bash "$CODEX_OUT/scripts/codex-companion.sh" task --write "dist closure smoke"); then
  fail "Codex dist routed task must start with its bundled runtime closure"
fi
if ! grep -Fq 'model_reasoning_effort="max"' "${TMP_ROOT}/codex-args.txt"; then
  fail "Codex dist routed task did not preserve worker max effort"
fi

assert_present "$CURSOR_OUT" ".cursor-plugin/plugin.json"
assert_present "$CURSOR_OUT" "skills/harness-work/SKILL.md"
assert_present "$CURSOR_OUT" "agents/worker.md"
assert_present "$CURSOR_OUT" "scripts/cursor-companion.sh"
assert_present "$CURSOR_OUT" "scripts/resolve-impl-backend.sh"
assert_present "$CURSOR_OUT" "scripts/model-routing.sh"
assert_absent "$CURSOR_OUT" ".claude-plugin"
assert_absent "$CURSOR_OUT" ".codex-plugin"
assert_absent "$CURSOR_OUT" ".grok-plugin"

assert_present "$GROK_OUT" ".grok-plugin/plugin.json"
assert_present "$GROK_OUT" "skills/harness-plan/SKILL.md"
assert_present "$GROK_OUT" "skills/harness-work/SKILL.md"
assert_present "$GROK_OUT" "skills/harness-review/SKILL.md"
assert_present "$GROK_OUT" "skills/breezing/SKILL.md"
assert_present "$GROK_OUT" "scripts/model-routing.sh"
assert_present "$GROK_OUT" "scripts/setup-grok.sh"
assert_present "$GROK_OUT" ".grok/AGENTS.md"
# 133.8/9a192025: grok dist intentionally carries the same guardrail closure
# as claude dist (.claude-plugin/plugin.json + hooks/hooks.json + bin/harness),
# because the valid_root bootstrap only recognizes a directory holding both
# bin/harness and a .claude-plugin/plugin.json naming this plugin. Without
# that closure, guardrail hooks silently no-op (exit 0) for grok-only
# installs. See scripts/build-host-plugin-dist.sh build_grok() comment.
assert_present "$GROK_OUT" ".claude-plugin/plugin.json"
assert_present "$GROK_OUT" "hooks/hooks.json"
assert_present "$GROK_OUT" "bin/harness"
assert_absent "$GROK_OUT" ".codex-plugin"
assert_absent "$GROK_OUT" ".cursor-plugin"

assert_manifest_no_parent_paths "${CLAUDE_OUT}/.claude-plugin/plugin.json"
assert_manifest_no_parent_paths "${CODEX_OUT}/.codex-plugin/plugin.json"
assert_manifest_no_parent_paths "${CURSOR_OUT}/.cursor-plugin/plugin.json"
assert_manifest_no_parent_paths "${GROK_OUT}/.grok-plugin/plugin.json"

# Cursor does not surface `user-invocable: true` skills. The cursor dist must
# normalize workflow skills so they register as Agent-Decides skills.
if grep -rEl '^user-invocable:[[:space:]]*true[[:space:]]*$' "${CURSOR_OUT}/skills" >/dev/null 2>&1; then
  fail "cursor dist still contains user-invocable: true skills (Cursor would drop them)"
fi
if [ ! -f "${CURSOR_OUT}/skills/breezing/SKILL.md" ]; then
  fail "cursor dist missing breezing skill"
fi
if ! grep -Eq '^user-invocable:[[:space:]]*false[[:space:]]*$' "${CURSOR_OUT}/skills/breezing/SKILL.md"; then
  fail "cursor dist breezing skill must be normalized to user-invocable: false"
fi
# Claude dist must preserve the original slash-command contract.
if ! grep -Eq '^user-invocable:[[:space:]]*true[[:space:]]*$' "${CLAUDE_OUT}/skills/breezing/SKILL.md"; then
  fail "claude dist breezing skill must keep user-invocable: true"
fi

node - "$CODEX_OUT/.codex-plugin/plugin.json" "$CURSOR_OUT/.cursor-plugin/plugin.json" "$GROK_OUT/.grok-plugin/plugin.json" <<'NODE'
const fs = require("fs");
const [codexPath, cursorPath, grokPath] = process.argv.slice(2);
const codex = JSON.parse(fs.readFileSync(codexPath, "utf8"));
const cursor = JSON.parse(fs.readFileSync(cursorPath, "utf8"));
const grok = JSON.parse(fs.readFileSync(grokPath, "utf8"));
function assert(cond, msg) {
  if (!cond) {
    console.error(msg);
    process.exit(1);
  }
}
assert(codex.skills === "./skills/", "codex dist skills path must be ./skills/");
assert(cursor.skills === "./skills/", "cursor dist skills path must be ./skills/");
assert(cursor.agents === "./agents/", "cursor dist agents path must be ./agents/");
assert(grok.skills === "./skills/", "grok dist skills path must be ./skills/");
assert(codex.interface.displayName === "Claude Code Harness for Codex", "codex displayName mismatch");
assert(cursor.interface.displayName === "Claude Code Harness for Cursor", "cursor displayName mismatch");
assert(grok.interface.displayName === "Claude Code Harness for Grok", "grok displayName mismatch");
assert(codex.interface.displayName !== cursor.interface.displayName, "displayName must differ by host");
assert(grok.interface.displayName !== cursor.interface.displayName, "grok displayName must differ from cursor");
assert(JSON.stringify(grok).includes("../") === false, "grok dist manifest must not contain ..");
NODE

echo "test-host-plugin-dist: ok"
