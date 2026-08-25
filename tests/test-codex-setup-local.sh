#!/usr/bin/env bash
#
# test-codex-setup-local.sh
# Regression tests for Codex local setup safety.
#
# The setup script must never follow a user-level skill symlink and move files
# out of the Harness source tree while trying to back up an existing install.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

run_setup() {
  local home_dir="$1"
  local codex_home="$home_dir/.codex"

  HOME="$home_dir" \
    CODEX_HOME="$codex_home" \
    CLAUDE_PLUGIN_ROOT="$ROOT_DIR" \
    bash "$ROOT_DIR/scripts/codex-setup-local.sh" --user >/tmp/codex-setup-local.$$ 2>&1
}

run_setup_project() {
  local home_dir="$1"
  local project_dir="$2"
  local log_file="$3"

  (
    cd "$project_dir"
    HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      CLAUDE_PLUGIN_ROOT="$ROOT_DIR" \
      bash "$ROOT_DIR/scripts/codex-setup-local.sh" --project >"$log_file" 2>&1
  )
}

assert_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "expected file to exist: $file" >&2
    exit 1
  fi
}

assert_symlink() {
  local path="$1"
  if [ ! -L "$path" ]; then
    echo "expected symlink: $path" >&2
    exit 1
  fi
}

assert_not_symlink() {
  local path="$1"
  if [ -L "$path" ]; then
    echo "expected non-symlink path: $path" >&2
    exit 1
  fi
}

assert_toml_valid() {
  local file="$1"

  if ! command -v python3 >/dev/null 2>&1 || \
    ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    return 0
  fi
  if ! python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$file"; then
    echo "expected valid TOML: $file" >&2
    exit 1
  fi
}

assert_codex_accepts_config() {
  local file="$1"
  local validation_home

  if ! command -v codex >/dev/null 2>&1; then
    return 0
  fi
  validation_home="$(mktemp -d "$TMP_ROOT/codex-validation.XXXXXX")"
  cp "$file" "$validation_home/config.toml"
  if ! HOME="$validation_home" CODEX_HOME="$validation_home" codex --strict-config features list \
    >"$validation_home/features.out" 2>"$validation_home/features.err"; then
    if grep -Fq '`--strict-config` is not supported for `codex features`' "$validation_home/features.err"; then
      if ! HOME="$validation_home" CODEX_HOME="$validation_home" codex features list \
        >"$validation_home/features.out" 2>"$validation_home/features.err"; then
        sed 's/^/  /' "$validation_home/features.err" >&2
        echo "Codex rejected setup-created config: $file" >&2
        exit 1
      fi
    else
      sed 's/^/  /' "$validation_home/features.err" >&2
      echo "Codex rejected setup-created config: $file" >&2
      exit 1
    fi
  fi
}

assert_managed_agent_toml() {
  local file="$1"
  assert_toml_valid "$file"
  if ! grep -Fq 'name = ' "$file" || ! grep -Fq 'model = ' "$file"; then
    echo "managed agent TOML is missing name/model: $file" >&2
    exit 1
  fi
}

assert_config_backup_matches() {
  local expected="$1"
  local backup_root="$2"
  local backup

  backup="$(find "$backup_root" -type f -name 'config.toml.*' -print -quit 2>/dev/null || true)"
  if [ -z "$backup" ]; then
    echo "expected a config backup under: $backup_root" >&2
    exit 1
  fi
  if ! cmp -s "$expected" "$backup"; then
    echo "config backup does not match the pre-mutation content: $backup" >&2
    exit 1
  fi
}

SOURCE_SKILL="$ROOT_DIR/codex/.codex/skills/breezing"
SOURCE_SKILL_FILE="$SOURCE_SKILL/SKILL.md"
SOURCE_AGENT_FILE="$ROOT_DIR/codex/.codex/agents/worker.toml"

assert_file "$SOURCE_SKILL_FILE"
assert_file "$SOURCE_AGENT_FILE"
assert_file "$ROOT_DIR/codex/.codex/agents/reviewer.toml"
assert_managed_agent_toml "$ROOT_DIR/codex/.codex/agents/worker.toml"
assert_managed_agent_toml "$ROOT_DIR/codex/.codex/agents/reviewer.toml"

# Case 1: the user skill is a symlink to the current source skill.
# This is already up to date, so setup should preserve the symlink and must not
# recurse into it as if it were a normal directory.
HOME_ONE="$TMP_ROOT/home-source-link"
CODEX_ONE="$HOME_ONE/.codex"
mkdir -p "$CODEX_ONE/skills"
ln -s "$SOURCE_SKILL" "$CODEX_ONE/skills/breezing"

run_setup "$HOME_ONE"

assert_symlink "$CODEX_ONE/skills/breezing"
assert_file "$SOURCE_SKILL_FILE"
assert_file "$CODEX_ONE/config.toml"
assert_file "$CODEX_ONE/agents/worker.toml"
assert_file "$CODEX_ONE/agents/reviewer.toml"
assert_toml_valid "$CODEX_ONE/config.toml"
grep -Fqx 'multi_agent = true' "$CODEX_ONE/config.toml" || {
  echo "fresh setup must enable features.multi_agent" >&2
  exit 1
}
grep -Fqx 'default_mode_request_user_input = true' "$CODEX_ONE/config.toml" || {
  echo "fresh setup must enable features.default_mode_request_user_input" >&2
  exit 1
}
assert_managed_agent_toml "$CODEX_ONE/agents/worker.toml"
assert_managed_agent_toml "$CODEX_ONE/agents/reviewer.toml"
assert_codex_accepts_config "$CODEX_ONE/config.toml"

# Case 2: the user skill is a symlink to some other local directory.
# Setup should back up the symlink itself, replace it with a real copied skill
# directory, and leave the external symlink target untouched.
HOME_TWO="$TMP_ROOT/home-stale-link"
CODEX_TWO="$HOME_TWO/.codex"
STALE_TARGET="$TMP_ROOT/stale-breezing"
mkdir -p "$CODEX_TWO/skills" "$STALE_TARGET"
printf 'stale skill target\n' > "$STALE_TARGET/SKILL.md"
ln -s "$STALE_TARGET" "$CODEX_TWO/skills/breezing"

run_setup "$HOME_TWO"

assert_not_symlink "$CODEX_TWO/skills/breezing"
assert_file "$CODEX_TWO/skills/breezing/SKILL.md"
assert_file "$STALE_TARGET/SKILL.md"
if ! grep -Fq 'stale skill target' "$STALE_TARGET/SKILL.md"; then
  echo "stale symlink target was modified" >&2
  exit 1
fi

# Case 3: multiple files with the same basename can be backed up in one run.
# Backups are stored in one flat directory, so the script must add a suffix
# instead of overwriting an earlier backup from the same second/process.
HOME_THREE="$TMP_ROOT/home-backup-collision"
CODEX_THREE="$HOME_THREE/.codex"
mkdir -p "$CODEX_THREE/skills/harness-loop" "$CODEX_THREE/skills/harness-plan"
printf 'old harness-loop\n' > "$CODEX_THREE/skills/harness-loop/SKILL.md"
printf 'old harness-plan\n' > "$CODEX_THREE/skills/harness-plan/SKILL.md"

run_setup "$HOME_THREE"

backup_count="$(
  find "$CODEX_THREE/backups/codex-setup-local" -type f -name 'SKILL.md.*' | wc -l | tr -d ' '
)"
if [ "$backup_count" -lt 2 ]; then
  echo "expected at least 2 SKILL.md backups, found $backup_count" >&2
  exit 1
fi

# Case 4: managed Codex agents are synchronized into agents/ while unrelated
# user-defined profiles remain untouched and an existing managed profile is
# backed up before replacement.
HOME_FOUR="$TMP_ROOT/home-managed-agents"
CODEX_FOUR="$HOME_FOUR/.codex"
mkdir -p "$CODEX_FOUR/agents"
printf 'name = "worker"\nmodel = "old-worker"\n' > "$CODEX_FOUR/agents/worker.toml"
printf 'name = "personal"\nmodel = "personal-model"\n' > "$CODEX_FOUR/agents/personal.toml"

run_setup "$HOME_FOUR"

assert_file "$CODEX_FOUR/agents/worker.toml"
if ! grep -Fq 'model = "gpt-5.6-luna"' "$CODEX_FOUR/agents/worker.toml"; then
  echo "managed worker agent was not synchronized" >&2
  exit 1
fi
if ! grep -Fq 'personal-model' "$CODEX_FOUR/agents/personal.toml"; then
  echo "unrelated user agent profile was not preserved" >&2
  exit 1
fi
agent_backup_count="$({ find "$CODEX_FOUR/backups/codex-setup-local" -type f -name 'worker.toml.*' || true; } | wc -l | tr -d ' ')"
if [ "$agent_backup_count" -lt 1 ]; then
  echo "expected existing managed worker profile to be backed up" >&2
  exit 1
fi

# Case 4b: existing feature values are operator-owned. Setup fills only the
# missing feature default and keeps explicit true/false values unchanged.
HOME_FOUR_B="$TMP_ROOT/home-existing-features"
CODEX_FOUR_B="$HOME_FOUR_B/.codex"
mkdir -p "$CODEX_FOUR_B"
cat > "$CODEX_FOUR_B/config.toml" <<'TOML'
[features]
multi_agent = false

[custom]
marker = "preserve-existing-features"
TOML

run_setup "$HOME_FOUR_B"

if [ "$(grep -Fxc '[features]' "$CODEX_FOUR_B/config.toml")" -ne 1 ] || \
  ! grep -Fqx 'multi_agent = false' "$CODEX_FOUR_B/config.toml" || \
  ! grep -Fqx 'default_mode_request_user_input = true' "$CODEX_FOUR_B/config.toml"; then
  echo "setup must preserve explicit multi_agent and add request_user_input" >&2
  exit 1
fi

HOME_FOUR_C="$TMP_ROOT/home-existing-request"
CODEX_FOUR_C="$HOME_FOUR_C/.codex"
mkdir -p "$CODEX_FOUR_C"
cat > "$CODEX_FOUR_C/config.toml" <<'TOML'
[features]
default_mode_request_user_input = false
TOML

run_setup "$HOME_FOUR_C"

if [ "$(grep -Fxc '[features]' "$CODEX_FOUR_C/config.toml")" -ne 1 ] || \
  ! grep -Fqx 'multi_agent = true' "$CODEX_FOUR_C/config.toml" || \
  ! grep -Fqx 'default_mode_request_user_input = false' "$CODEX_FOUR_C/config.toml"; then
  echo "setup must preserve explicit request_user_input and add multi_agent" >&2
  exit 1
fi

# Case 4d: quoted canonical tables and keys are valid TOML equivalents. Setup
# must extend them without appending a duplicate bare table.
HOME_FOUR_D="$TMP_ROOT/home-quoted-owned-tables"
CODEX_FOUR_D="$HOME_FOUR_D/.codex"
mkdir -p "$CODEX_FOUR_D"
cat > "$CODEX_FOUR_D/config.toml" <<'TOML'
['features']
'multi_agent' = true
'default_mode_request_user_input' = false

['agents']
'max_threads' = 4

['memories']
'no_memories_if_mcp_or_web_search' = true
TOML

run_setup "$HOME_FOUR_D"

if grep -Fqx '[features]' "$CODEX_FOUR_D/config.toml" || \
  grep -Fqx '[agents]' "$CODEX_FOUR_D/config.toml" || \
  grep -Fqx '[memories]' "$CODEX_FOUR_D/config.toml" || \
  ! grep -Fqx "'default_mode_request_user_input' = false" "$CODEX_FOUR_D/config.toml" || \
  ! grep -Fqx "'max_threads' = 4" "$CODEX_FOUR_D/config.toml" || \
  ! grep -Fqx "'no_memories_if_mcp_or_web_search' = true" "$CODEX_FOUR_D/config.toml"; then
  echo "setup must preserve canonical quoted table values" >&2
  exit 1
fi
assert_toml_valid "$CODEX_FOUR_D/config.toml"
assert_codex_accepts_config "$CODEX_FOUR_D/config.toml"

# Case 4e: valid TOML semantic shapes outside the merger's safe subset fail
# before any managed target is changed.
HOME_FOUR_E="$TMP_ROOT/home-invalid-owned-shapes"
CODEX_FOUR_E="$HOME_FOUR_E/.codex"
mkdir -p "$CODEX_FOUR_E/skills/sentinel" "$CODEX_FOUR_E/rules" "$CODEX_FOUR_E/agents"
printf 'skills sentinel\n' > "$CODEX_FOUR_E/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "$CODEX_FOUR_E/rules/sentinel.rules"
printf 'agents sentinel\n' > "$CODEX_FOUR_E/agents/sentinel.toml"
cat > "$CODEX_FOUR_E/config.toml" <<'TOML'
features.multi_agent = false
TOML
cp "$CODEX_FOUR_E/config.toml" "$TMP_ROOT/local-dotted-features-before.toml"
find "$CODEX_FOUR_E/skills" "$CODEX_FOUR_E/rules" "$CODEX_FOUR_E/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-dotted-features-targets-before.txt"

if run_setup "$HOME_FOUR_E"; then
  echo "setup must fail closed for root dotted feature keys" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-dotted-features-before.toml" "$CODEX_FOUR_E/config.toml"; then
  echo "setup must not mutate root dotted feature keys" >&2
  exit 1
fi
find "$CODEX_FOUR_E/skills" "$CODEX_FOUR_E/rules" "$CODEX_FOUR_E/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-dotted-features-targets-after.txt"
if ! cmp -s "$TMP_ROOT/local-dotted-features-targets-before.txt" \
  "$TMP_ROOT/local-dotted-features-targets-after.txt"; then
  echo "setup must not mutate targets before rejecting dotted feature keys" >&2
  exit 1
fi

HOME_FOUR_F="$TMP_ROOT/home-inline-agents"
CODEX_FOUR_F="$HOME_FOUR_F/.codex"
mkdir -p "$CODEX_FOUR_F"
cat > "$CODEX_FOUR_F/config.toml" <<'TOML'
agents = { max_threads = 4 }
TOML
cp "$CODEX_FOUR_F/config.toml" "$TMP_ROOT/local-inline-agents-before.toml"
if run_setup "$HOME_FOUR_F"; then
  echo "setup must fail closed for inline agents" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-inline-agents-before.toml" "$CODEX_FOUR_F/config.toml"; then
  echo "setup must not mutate inline agents" >&2
  exit 1
fi

HOME_FOUR_G="$TMP_ROOT/home-inline-memories"
CODEX_FOUR_G="$HOME_FOUR_G/.codex"
mkdir -p "$CODEX_FOUR_G"
cat > "$CODEX_FOUR_G/config.toml" <<'TOML'
memories = { no_memories_if_mcp_or_web_search = true }
TOML
cp "$CODEX_FOUR_G/config.toml" "$TMP_ROOT/local-inline-memories-before.toml"
if run_setup "$HOME_FOUR_G"; then
  echo "setup must fail closed for inline memories" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-inline-memories-before.toml" "$CODEX_FOUR_G/config.toml"; then
  echo "setup must not mutate inline memories" >&2
  exit 1
fi

# Case 5: the historical two-line setup notify stanza is removed exactly. A
# config symlink and its target remain in place, the original target is backed
# up before mutation, and normal Harness defaults/profiles still arrive.
HOME_FIVE="$TMP_ROOT/home-legacy-notify-setup"
CODEX_FIVE="$HOME_FIVE/.codex"
CONFIG_TARGET_FIVE="$TMP_ROOT/legacy-notify-setup-target.toml"
mkdir -p "$CODEX_FIVE"
cat > "$CONFIG_TARGET_FIVE" <<'TOML'
[features]
multi_agent = true

[notify]
after_agent = "echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt"

[custom]
marker = "preserve-setup-variant"
TOML
cp "$CONFIG_TARGET_FIVE" "$TMP_ROOT/local-legacy-notify-setup-before.toml"
ln -s "$CONFIG_TARGET_FIVE" "$CODEX_FIVE/config.toml"

run_setup "$HOME_FIVE"

assert_symlink "$CODEX_FIVE/config.toml"
if grep -Fqx '[notify]' "$CONFIG_TARGET_FIVE" || \
  grep -Fq "after_agent = \"echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt\"" "$CONFIG_TARGET_FIVE"; then
  echo "setup must remove the exact historical notify stanza" >&2
  exit 1
fi
grep -Fqx 'marker = "preserve-setup-variant"' "$CONFIG_TARGET_FIVE" || {
  echo "setup must preserve unrelated config around the legacy notify stanza" >&2
  exit 1
}
assert_file "$CODEX_FIVE/agents/worker.toml"
assert_toml_valid "$CONFIG_TARGET_FIVE"
assert_codex_accepts_config "$CONFIG_TARGET_FIVE"
assert_config_backup_matches \
  "$TMP_ROOT/local-legacy-notify-setup-before.toml" \
  "$CODEX_FIVE/backups/codex-setup-local"

# Case 6: the distributed template's exact comment + after_agent variant is
# also migrated, while unrelated config remains untouched and a backup exists.
HOME_SIX="$TMP_ROOT/home-legacy-notify-template"
CODEX_SIX="$HOME_SIX/.codex"
mkdir -p "$CODEX_SIX"
cat > "$CODEX_SIX/config.toml" <<'TOML'
[custom]
marker = "preserve-template-variant"

[notify]
# Session end notification: log to harness state + codex memories (0.110.0: ~/.codex/memories/ auto-writable)
after_agent = "mkdir -p .claude/state && echo \"[HARNESS-LEARNING] $(date -u +%Y-%m-%dT%H:%M:%SZ) Session completed\" >> .claude/state/session-log.txt"
TOML
cp "$CODEX_SIX/config.toml" "$TMP_ROOT/local-legacy-notify-template-before.toml"

run_setup "$HOME_SIX"

if grep -Fqx '[notify]' "$CODEX_SIX/config.toml" || \
  grep -Fq 'after_agent = "mkdir -p .claude/state' "$CODEX_SIX/config.toml"; then
  echo "setup must remove the exact distributed-template notify stanza" >&2
  exit 1
fi
grep -Fqx 'marker = "preserve-template-variant"' "$CODEX_SIX/config.toml" || {
  echo "setup must preserve unrelated config around the template notify stanza" >&2
  exit 1
}
assert_toml_valid "$CODEX_SIX/config.toml"
assert_codex_accepts_config "$CODEX_SIX/config.toml"
assert_config_backup_matches \
  "$TMP_ROOT/local-legacy-notify-template-before.toml" \
  "$CODEX_SIX/backups/codex-setup-local"

# Case 7: a custom [notify] table is operator-owned. Setup must fail visibly
# and leave the config byte-identical, without creating a config backup.
HOME_SEVEN="$TMP_ROOT/home-custom-notify"
CODEX_SEVEN="$HOME_SEVEN/.codex"
mkdir -p \
  "$CODEX_SEVEN/skills/sentinel" \
  "$CODEX_SEVEN/rules" \
  "$CODEX_SEVEN/agents"
printf 'skills sentinel\n' > "$CODEX_SEVEN/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "$CODEX_SEVEN/rules/sentinel.rules"
printf 'agents sentinel\n' > "$CODEX_SEVEN/agents/sentinel.toml"
cat > "$CODEX_SEVEN/config.toml" <<'TOML'
[features]
multi_agent = true

[notify]
after_agent = "custom operator command"
TOML
cp "$CODEX_SEVEN/config.toml" "$TMP_ROOT/local-custom-notify-before.toml"
find "$CODEX_SEVEN/skills" "$CODEX_SEVEN/rules" "$CODEX_SEVEN/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-custom-targets-before.txt"

if run_setup "$HOME_SEVEN"; then
  echo "setup must fail closed for a custom notify table" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-custom-notify-before.toml" "$CODEX_SEVEN/config.toml"; then
  echo "setup must preserve a custom notify table byte-for-byte" >&2
  exit 1
fi
find "$CODEX_SEVEN/skills" "$CODEX_SEVEN/rules" "$CODEX_SEVEN/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-custom-targets-after.txt"
if ! cmp -s "$TMP_ROOT/local-custom-targets-before.txt" "$TMP_ROOT/local-custom-targets-after.txt"; then
  echo "setup must not mutate skills/rules/agents before rejecting custom notify" >&2
  exit 1
fi
if [ -n "$(find "$CODEX_SEVEN/backups" -type f -name 'config.toml.*' -print -quit 2>/dev/null)" ]; then
  echo "setup must not back up a custom notify config before failing" >&2
  exit 1
fi

# Case 7b: descendant tables are ambiguous too and must fail without touching
# the config.
HOME_SEVEN_B="$TMP_ROOT/home-custom-notify-descendant"
CODEX_SEVEN_B="$HOME_SEVEN_B/.codex"
mkdir -p "$CODEX_SEVEN_B"
cat > "$CODEX_SEVEN_B/config.toml" <<'TOML'
[notify.custom]
command = "custom operator command"
TOML
cp "$CODEX_SEVEN_B/config.toml" "$TMP_ROOT/local-custom-notify-descendant-before.toml"

if run_setup "$HOME_SEVEN_B"; then
  echo "setup must fail closed for a custom notify descendant table" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-custom-notify-descendant-before.toml" "$CODEX_SEVEN_B/config.toml"; then
  echo "setup must preserve a custom notify descendant byte-for-byte" >&2
  exit 1
fi
if [ -n "$(find "$CODEX_SEVEN_B/backups" -type f -name 'config.toml.*' -print -quit 2>/dev/null)" ]; then
  echo "setup must not back up a custom notify descendant before failing" >&2
  exit 1
fi

# Case 7c: project mode must preflight config before replacing project AGENTS.
HOME_SEVEN_C="$TMP_ROOT/home-custom-notify-project"
PROJECT_SEVEN_C="$TMP_ROOT/project-custom-notify"
CODEX_SEVEN_C="$PROJECT_SEVEN_C/.codex"
mkdir -p \
  "$CODEX_SEVEN_C/skills/sentinel" \
  "$CODEX_SEVEN_C/rules" \
  "$CODEX_SEVEN_C/agents"
printf 'project skills sentinel\n' > "$CODEX_SEVEN_C/skills/sentinel/SKILL.md"
printf 'project rules sentinel\n' > "$CODEX_SEVEN_C/rules/sentinel.rules"
printf 'project agents sentinel\n' > "$CODEX_SEVEN_C/agents/sentinel.toml"
printf 'project AGENTS sentinel\n' > "$PROJECT_SEVEN_C/AGENTS.md"
cat > "$CODEX_SEVEN_C/config.toml" <<'TOML'
[notify.custom]
command = "custom project operator command"
TOML
cp "$CODEX_SEVEN_C/config.toml" "$TMP_ROOT/local-project-custom-notify-before.toml"
cp "$PROJECT_SEVEN_C/AGENTS.md" "$TMP_ROOT/local-project-agents-before.txt"
find "$CODEX_SEVEN_C/skills" "$CODEX_SEVEN_C/rules" "$CODEX_SEVEN_C/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-project-custom-targets-before.txt"

if run_setup_project "$HOME_SEVEN_C" "$PROJECT_SEVEN_C" "$TMP_ROOT/local-project-custom-setup.log"; then
  echo "project setup must fail closed for a custom notify table" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-project-custom-notify-before.toml" "$CODEX_SEVEN_C/config.toml" || \
  ! cmp -s "$TMP_ROOT/local-project-agents-before.txt" "$PROJECT_SEVEN_C/AGENTS.md"; then
  echo "project setup must preserve config and AGENTS on preflight failure" >&2
  exit 1
fi
find "$CODEX_SEVEN_C/skills" "$CODEX_SEVEN_C/rules" "$CODEX_SEVEN_C/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-project-custom-targets-after.txt"
if ! cmp -s "$TMP_ROOT/local-project-custom-targets-before.txt" "$TMP_ROOT/local-project-custom-targets-after.txt"; then
  echo "project setup must not mutate managed targets before rejecting custom notify" >&2
  exit 1
fi

# Case 7d: an exact legacy stanza does not permit a later unsupported root
# shape to be partially migrated. Validation must fail before any rewrite.
HOME_SEVEN_D="$TMP_ROOT/home-legacy-plus-invalid-shape"
CODEX_SEVEN_D="$HOME_SEVEN_D/.codex"
mkdir -p "$CODEX_SEVEN_D/skills/sentinel" "$CODEX_SEVEN_D/rules" "$CODEX_SEVEN_D/agents"
printf 'skills sentinel\n' > "$CODEX_SEVEN_D/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "$CODEX_SEVEN_D/rules/sentinel.rules"
printf 'agents sentinel\n' > "$CODEX_SEVEN_D/agents/sentinel.toml"
cat > "$CODEX_SEVEN_D/config.toml" <<'TOML'
agents = { max_threads = 4 }

[notify]
after_agent = "echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt"
TOML
cp "$CODEX_SEVEN_D/config.toml" "$TMP_ROOT/local-legacy-plus-invalid-before.toml"
find "$CODEX_SEVEN_D/skills" "$CODEX_SEVEN_D/rules" "$CODEX_SEVEN_D/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-legacy-plus-invalid-targets-before.txt"

if run_setup "$HOME_SEVEN_D"; then
  echo "setup must fail closed for legacy notify plus an invalid root shape" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-legacy-plus-invalid-before.toml" "$CODEX_SEVEN_D/config.toml"; then
  echo "setup must not migrate legacy notify before rejecting an invalid root shape" >&2
  exit 1
fi
find "$CODEX_SEVEN_D/skills" "$CODEX_SEVEN_D/rules" "$CODEX_SEVEN_D/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "$TMP_ROOT/local-legacy-plus-invalid-targets-after.txt"
if ! cmp -s "$TMP_ROOT/local-legacy-plus-invalid-targets-before.txt" \
  "$TMP_ROOT/local-legacy-plus-invalid-targets-after.txt"; then
  echo "setup must not mutate targets for legacy notify plus an invalid root shape" >&2
  exit 1
fi

# Case 7e: an exact legacy stanza still requires a usable backup destination.
# A regular file at the backup root must fail before any managed target or
# project AGENTS.md mutation.
HOME_SEVEN_E="$TMP_ROOT/home-backup-root-file"
PROJECT_SEVEN_E="$TMP_ROOT/project-backup-root-file"
CODEX_SEVEN_E="$PROJECT_SEVEN_E/.codex"
BACKUP_SEVEN_E="$CODEX_SEVEN_E/backups/codex-setup-local"
mkdir -p \
  "$CODEX_SEVEN_E/skills/sentinel" \
  "$CODEX_SEVEN_E/rules" \
  "$CODEX_SEVEN_E/agents" \
  "$(dirname "$BACKUP_SEVEN_E")"
printf 'skills sentinel\n' > "$CODEX_SEVEN_E/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "$CODEX_SEVEN_E/rules/sentinel.rules"
printf 'agents sentinel\n' > "$CODEX_SEVEN_E/agents/sentinel.toml"
printf 'backup root must remain a file\n' > "$BACKUP_SEVEN_E"
printf 'project AGENTS sentinel\n' > "$PROJECT_SEVEN_E/AGENTS.md"
cat > "$CODEX_SEVEN_E/config.toml" <<'TOML'
[notify]
after_agent = "echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt"
TOML
cp "$CODEX_SEVEN_E/config.toml" "$TMP_ROOT/local-backup-root-file-config-before.toml"
cp "$PROJECT_SEVEN_E/AGENTS.md" "$TMP_ROOT/local-backup-root-file-agents-before.txt"
cp -R "$CODEX_SEVEN_E/skills" "$TMP_ROOT/local-backup-root-file-skills-before"
cp -R "$CODEX_SEVEN_E/rules" "$TMP_ROOT/local-backup-root-file-rules-before"
cp -R "$CODEX_SEVEN_E/agents" "$TMP_ROOT/local-backup-root-file-agents-before"
cp "$BACKUP_SEVEN_E" "$TMP_ROOT/local-backup-root-file-backup-before.txt"

if run_setup_project "$HOME_SEVEN_E" "$PROJECT_SEVEN_E" "$TMP_ROOT/local-backup-root-file-setup.log"; then
  echo "setup must fail when the backup destination is a regular file" >&2
  exit 1
fi
if ! cmp -s "$TMP_ROOT/local-backup-root-file-config-before.toml" "$CODEX_SEVEN_E/config.toml" || \
  ! cmp -s "$TMP_ROOT/local-backup-root-file-agents-before.txt" "$PROJECT_SEVEN_E/AGENTS.md" || \
  ! cmp -s "$TMP_ROOT/local-backup-root-file-backup-before.txt" "$BACKUP_SEVEN_E" || \
  ! diff -ru "$TMP_ROOT/local-backup-root-file-skills-before" "$CODEX_SEVEN_E/skills" >/dev/null || \
  ! diff -ru "$TMP_ROOT/local-backup-root-file-rules-before" "$CODEX_SEVEN_E/rules" >/dev/null || \
  ! diff -ru "$TMP_ROOT/local-backup-root-file-agents-before" "$CODEX_SEVEN_E/agents" >/dev/null; then
  echo "setup must preserve all targets when the backup destination is unusable" >&2
  exit 1
fi

# Case 8: modern top-level notify string arrays are not legacy tables and must
# survive setup unchanged while defaults/profiles are added.
HOME_EIGHT="$TMP_ROOT/home-modern-notify"
CODEX_EIGHT="$HOME_EIGHT/.codex"
mkdir -p "$CODEX_EIGHT"
cat > "$CODEX_EIGHT/config.toml" <<'TOML'
notify = ["echo", "done"]

[custom]
marker = "preserve-modern-notify"
TOML

run_setup "$HOME_EIGHT"

grep -Fqx 'notify = ["echo", "done"]' "$CODEX_EIGHT/config.toml" || {
  echo "setup must preserve a modern top-level notify string array" >&2
  exit 1
}
grep -Fqx 'marker = "preserve-modern-notify"' "$CODEX_EIGHT/config.toml" || {
  echo "setup must preserve unrelated modern-notify config" >&2
  exit 1
}
assert_toml_valid "$CODEX_EIGHT/config.toml"
assert_codex_accepts_config "$CODEX_EIGHT/config.toml"

echo "OK"
