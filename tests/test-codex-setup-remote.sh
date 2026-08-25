#!/usr/bin/env bash
# Regression test for remote setup's managed Codex agent synchronization.
# Uses a fake git clone and temporary HOME; no network or real Codex install.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

FAKE_SOURCE="${TMP_ROOT}/fake-harness"
FAKE_BIN="${TMP_ROOT}/bin"
HOME_DIR="${TMP_ROOT}/home"
CODEX_HOME_DIR="${HOME_DIR}/.codex"
mkdir -p \
  "${FAKE_SOURCE}/codex/.codex/skills/breezing" \
  "${FAKE_SOURCE}/codex/.codex/rules" \
  "${FAKE_SOURCE}/codex/.codex/agents" \
  "${FAKE_BIN}" \
  "${CODEX_HOME_DIR}/agents"

cat > "${FAKE_SOURCE}/codex/.codex/skills/breezing/SKILL.md" <<'EOF'
---
name: breezing
description: Fake Breezing skill for setup test
---
Fake skill body.
EOF
printf 'fake rule\n' > "${FAKE_SOURCE}/codex/.codex/rules/harness.rules"
cp "${ROOT_DIR}/codex/.codex/agents/worker.toml" \
  "${FAKE_SOURCE}/codex/.codex/agents/worker.toml"
cp "${ROOT_DIR}/codex/.codex/agents/reviewer.toml" \
  "${FAKE_SOURCE}/codex/.codex/agents/reviewer.toml"
printf '# fake AGENTS\n' > "${FAKE_SOURCE}/codex/AGENTS.md"

cat > "${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != "clone" ]; then
  echo "fake git only supports clone" >&2
  exit 2
fi
destination="${!#}"
mkdir -p "${destination}"
cp -R "${FAKE_HARNESS_SOURCE}/." "${destination}/"
EOF
chmod +x "${FAKE_BIN}/git"

run_remote_setup() {
  local home_dir="$1"
  local log_file="$2"
  local project_dir="${3:-}"

  if [ -n "${project_dir}" ]; then
    (
      cd "${project_dir}"
      HOME="${home_dir}" \
        CODEX_HOME="${home_dir}/.codex" \
        FAKE_HARNESS_SOURCE="${FAKE_SOURCE}" \
        PATH="${FAKE_BIN}:${PATH}" \
        bash "${ROOT_DIR}/scripts/setup-codex.sh" --project >"${log_file}" 2>&1
    )
    return
  fi

  HOME="${home_dir}" \
  CODEX_HOME="${home_dir}/.codex" \
  FAKE_HARNESS_SOURCE="${FAKE_SOURCE}" \
  PATH="${FAKE_BIN}:${PATH}" \
  bash "${ROOT_DIR}/scripts/setup-codex.sh" --user >"${log_file}" 2>&1
}

assert_remote_codex_accepts_config() {
  local file="$1"
  local validation_home
  validation_home="${TMP_ROOT}/codex-validation-$(basename "$file" .toml)"

  if ! command -v codex >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "${validation_home}"
  cp "${file}" "${validation_home}/config.toml"
  if ! HOME="${validation_home}" CODEX_HOME="${validation_home}" codex --strict-config features list \
    >"${validation_home}/features.out" 2>"${validation_home}/features.err"; then
    if grep -Fq '`--strict-config` is not supported for `codex features`' "${validation_home}/features.err"; then
      if ! HOME="${validation_home}" CODEX_HOME="${validation_home}" codex features list \
        >"${validation_home}/features.out" 2>"${validation_home}/features.err"; then
        sed 's/^/  /' "${validation_home}/features.err" >&2
        echo "Codex rejected remote setup-created config: ${file}" >&2
        exit 1
      fi
    else
      sed 's/^/  /' "${validation_home}/features.err" >&2
      echo "Codex rejected remote setup-created config: ${file}" >&2
      exit 1
    fi
  fi
}

# A broken managed symlink is still an existing user entry. Remote setup must
# back it up instead of treating it as absent and letting cp follow it.
ln -s "${TMP_ROOT}/missing-worker.toml" "${CODEX_HOME_DIR}/agents/worker.toml"
printf 'name = "personal"\nmodel = "personal-model"\n' > "${CODEX_HOME_DIR}/agents/personal.toml"

setup_log="${TMP_ROOT}/setup.log"
if ! HOME="${HOME_DIR}" \
  CODEX_HOME="${CODEX_HOME_DIR}" \
  FAKE_HARNESS_SOURCE="${FAKE_SOURCE}" \
  PATH="${FAKE_BIN}:${PATH}" \
  bash "${ROOT_DIR}/scripts/setup-codex.sh" --user >"${setup_log}" 2>&1; then
  sed 's/^/  /' "${setup_log}" >&2
  echo "remote setup fake-clone run failed" >&2
  exit 1
fi

[ -f "${CODEX_HOME_DIR}/agents/worker.toml" ] || {
  echo "remote setup did not install managed worker.toml" >&2
  exit 1
}
[ -f "${CODEX_HOME_DIR}/agents/reviewer.toml" ] || {
  echo "remote setup did not install managed reviewer.toml" >&2
  exit 1
}
grep -Fq 'model = "gpt-5.6-luna"' "${CODEX_HOME_DIR}/agents/worker.toml" || {
  echo "remote setup installed the wrong worker model" >&2
  exit 1
}
grep -Fq 'model = "gpt-5.6-sol"' "${CODEX_HOME_DIR}/agents/reviewer.toml" || {
  echo "remote setup installed the wrong reviewer model" >&2
  exit 1
}
grep -Fq 'personal-model' "${CODEX_HOME_DIR}/agents/personal.toml" || {
  echo "remote setup did not preserve unrelated agent profile" >&2
  exit 1
}

backup_count="$(find "${CODEX_HOME_DIR}/backups/setup-codex" -name 'worker.toml.*' | wc -l | tr -d ' ')"
[ "${backup_count}" -ge 1 ] || {
  echo "remote setup did not back up the existing managed worker profile" >&2
  exit 1
}

if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
  python3 - "${CODEX_HOME_DIR}/config.toml" "${CODEX_HOME_DIR}/agents/worker.toml" "${CODEX_HOME_DIR}/agents/reviewer.toml" <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as stream:
        document = tomllib.load(stream)
    if path.endswith("config.toml"):
        if document.get("features", {}).get("multi_agent") is not True:
            raise SystemExit("remote setup config must enable multi_agent")
    elif not document.get("name") or not document.get("model"):
        raise SystemExit(f"managed agent TOML missing name/model: {path}")
PY
fi
grep -Fqx 'multi_agent = true' "${CODEX_HOME_DIR}/config.toml" || {
  echo "remote fresh setup must enable features.multi_agent" >&2
  exit 1
}
grep -Fqx 'default_mode_request_user_input = true' "${CODEX_HOME_DIR}/config.toml" || {
  echo "remote fresh setup must enable features.default_mode_request_user_input" >&2
  exit 1
}
if command -v codex >/dev/null 2>&1; then
  validation_home="${TMP_ROOT}/codex-validation"
  mkdir -p "${validation_home}"
  cp "${CODEX_HOME_DIR}/config.toml" "${validation_home}/config.toml"
  HOME="${validation_home}" CODEX_HOME="${validation_home}" codex --strict-config features list \
    >"${validation_home}/features.out" 2>"${validation_home}/features.err" || {
      if grep -Fq '`--strict-config` is not supported for `codex features`' "${validation_home}/features.err"; then
        HOME="${validation_home}" CODEX_HOME="${validation_home}" codex features list \
          >"${validation_home}/features.out" 2>"${validation_home}/features.err" || {
            sed 's/^/  /' "${validation_home}/features.err" >&2
            echo "Codex rejected remote setup-created config" >&2
            exit 1
          }
      else
        sed 's/^/  /' "${validation_home}/features.err" >&2
        echo "Codex rejected remote setup-created config" >&2
        exit 1
      fi
    }
fi

# Case 1b: existing feature values are operator-owned. Remote setup fills only
# the missing feature default and keeps explicit true/false values unchanged.
HOME_ONE_B="${TMP_ROOT}/home-existing-features"
CODEX_ONE_B="${HOME_ONE_B}/.codex"
mkdir -p "${CODEX_ONE_B}"
cat > "${CODEX_ONE_B}/config.toml" <<'TOML'
[features]
multi_agent = false

[custom]
marker = "preserve-remote-existing-features"
TOML

if ! run_remote_setup "${HOME_ONE_B}" "${TMP_ROOT}/remote-existing-features-setup.log"; then
  sed 's/^/  /' "${TMP_ROOT}/remote-existing-features-setup.log" >&2
  echo "remote setup failed for an existing features table" >&2
  exit 1
fi
if [ "$(grep -Fxc '[features]' "${CODEX_ONE_B}/config.toml")" -ne 1 ] || \
  ! grep -Fqx 'multi_agent = false' "${CODEX_ONE_B}/config.toml" || \
  ! grep -Fqx 'default_mode_request_user_input = true' "${CODEX_ONE_B}/config.toml"; then
  echo "remote setup must preserve explicit multi_agent and add request_user_input" >&2
  exit 1
fi

HOME_ONE_C="${TMP_ROOT}/home-existing-request"
CODEX_ONE_C="${HOME_ONE_C}/.codex"
mkdir -p "${CODEX_ONE_C}"
cat > "${CODEX_ONE_C}/config.toml" <<'TOML'
[features]
default_mode_request_user_input = false
TOML

if ! run_remote_setup "${HOME_ONE_C}" "${TMP_ROOT}/remote-existing-request-setup.log"; then
  sed 's/^/  /' "${TMP_ROOT}/remote-existing-request-setup.log" >&2
  echo "remote setup failed for an existing request setting" >&2
  exit 1
fi
if [ "$(grep -Fxc '[features]' "${CODEX_ONE_C}/config.toml")" -ne 1 ] || \
  ! grep -Fqx 'multi_agent = true' "${CODEX_ONE_C}/config.toml" || \
  ! grep -Fqx 'default_mode_request_user_input = false' "${CODEX_ONE_C}/config.toml"; then
  echo "remote setup must preserve explicit request_user_input and add multi_agent" >&2
  exit 1
fi

# Case 1d: quoted canonical tables and keys are valid TOML equivalents.
HOME_ONE_D="${TMP_ROOT}/home-quoted-owned-tables"
CODEX_ONE_D="${HOME_ONE_D}/.codex"
mkdir -p "${CODEX_ONE_D}"
cat > "${CODEX_ONE_D}/config.toml" <<'TOML'
['features']
'multi_agent' = true
'default_mode_request_user_input' = false

['agents']
'max_threads' = 4

['memories']
'no_memories_if_mcp_or_web_search' = true
TOML

if ! run_remote_setup "${HOME_ONE_D}" "${TMP_ROOT}/remote-quoted-setup.log"; then
  sed 's/^/  /' "${TMP_ROOT}/remote-quoted-setup.log" >&2
  echo "remote setup failed for quoted canonical tables" >&2
  exit 1
fi
if grep -Fqx '[features]' "${CODEX_ONE_D}/config.toml" || \
  grep -Fqx '[agents]' "${CODEX_ONE_D}/config.toml" || \
  grep -Fqx '[memories]' "${CODEX_ONE_D}/config.toml" || \
  ! grep -Fqx "'default_mode_request_user_input' = false" "${CODEX_ONE_D}/config.toml" || \
  ! grep -Fqx "'max_threads' = 4" "${CODEX_ONE_D}/config.toml" || \
  ! grep -Fqx "'no_memories_if_mcp_or_web_search' = true" "${CODEX_ONE_D}/config.toml"; then
  echo "remote setup must preserve canonical quoted table values" >&2
  exit 1
fi
assert_remote_codex_accepts_config "${CODEX_ONE_D}/config.toml"

# Case 1e: valid TOML semantic shapes outside the merger's safe subset fail
# before managed targets are changed.
HOME_ONE_E="${TMP_ROOT}/home-invalid-owned-shapes"
CODEX_ONE_E="${HOME_ONE_E}/.codex"
mkdir -p "${CODEX_ONE_E}/skills/sentinel" "${CODEX_ONE_E}/rules" "${CODEX_ONE_E}/agents"
printf 'skills sentinel\n' > "${CODEX_ONE_E}/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "${CODEX_ONE_E}/rules/sentinel.rules"
printf 'agents sentinel\n' > "${CODEX_ONE_E}/agents/sentinel.toml"
cat > "${CODEX_ONE_E}/config.toml" <<'TOML'
features.multi_agent = false
TOML
cp "${CODEX_ONE_E}/config.toml" "${TMP_ROOT}/remote-dotted-features-before.toml"
find "${CODEX_ONE_E}/skills" "${CODEX_ONE_E}/rules" "${CODEX_ONE_E}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-dotted-features-targets-before.txt"

if run_remote_setup "${HOME_ONE_E}" "${TMP_ROOT}/remote-dotted-features-setup.log"; then
  echo "remote setup must fail closed for root dotted feature keys" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-dotted-features-before.toml" "${CODEX_ONE_E}/config.toml"; then
  echo "remote setup must not mutate root dotted feature keys" >&2
  exit 1
fi
find "${CODEX_ONE_E}/skills" "${CODEX_ONE_E}/rules" "${CODEX_ONE_E}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-dotted-features-targets-after.txt"
if ! cmp -s "${TMP_ROOT}/remote-dotted-features-targets-before.txt" \
  "${TMP_ROOT}/remote-dotted-features-targets-after.txt"; then
  echo "remote setup must not mutate targets before rejecting dotted feature keys" >&2
  exit 1
fi

HOME_ONE_F="${TMP_ROOT}/home-inline-memories"
CODEX_ONE_F="${HOME_ONE_F}/.codex"
mkdir -p "${CODEX_ONE_F}"
cat > "${CODEX_ONE_F}/config.toml" <<'TOML'
memories = { no_memories_if_mcp_or_web_search = true }
TOML
cp "${CODEX_ONE_F}/config.toml" "${TMP_ROOT}/remote-inline-memories-before.toml"
if run_remote_setup "${HOME_ONE_F}" "${TMP_ROOT}/remote-inline-memories-setup.log"; then
  echo "remote setup must fail closed for inline memories" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-inline-memories-before.toml" "${CODEX_ONE_F}/config.toml"; then
  echo "remote setup must not mutate inline memories" >&2
  exit 1
fi

HOME_ONE_G="${TMP_ROOT}/home-inline-agents"
CODEX_ONE_G="${HOME_ONE_G}/.codex"
mkdir -p "${CODEX_ONE_G}"
cat > "${CODEX_ONE_G}/config.toml" <<'TOML'
agents = { max_threads = 4 }
TOML
cp "${CODEX_ONE_G}/config.toml" "${TMP_ROOT}/remote-inline-agents-before.toml"
if run_remote_setup "${HOME_ONE_G}" "${TMP_ROOT}/remote-inline-agents-setup.log"; then
  echo "remote setup must fail closed for inline agents" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-inline-agents-before.toml" "${CODEX_ONE_G}/config.toml"; then
  echo "remote setup must not mutate inline agents" >&2
  exit 1
fi

# Case 2: the distributed template's exact comment + after_agent notify stanza
# is removed, while unrelated config survives and the original is backed up.
HOME_TWO="${TMP_ROOT}/home-legacy-notify-template"
CODEX_TWO="${HOME_TWO}/.codex"
mkdir -p "${CODEX_TWO}"
cat > "${CODEX_TWO}/config.toml" <<'TOML'
[custom]
marker = "preserve-remote-template-variant"

[notify]
# Session end notification: log to harness state + codex memories (0.110.0: ~/.codex/memories/ auto-writable)
after_agent = "mkdir -p .claude/state && echo \"[HARNESS-LEARNING] $(date -u +%Y-%m-%dT%H:%M:%SZ) Session completed\" >> .claude/state/session-log.txt"
TOML
cp "${CODEX_TWO}/config.toml" "${TMP_ROOT}/remote-legacy-notify-template-before.toml"

if ! run_remote_setup "${HOME_TWO}" "${TMP_ROOT}/remote-template-setup.log"; then
  sed 's/^/  /' "${TMP_ROOT}/remote-template-setup.log" >&2
  echo "remote setup failed for the exact distributed-template notify stanza" >&2
  exit 1
fi
if grep -Fqx '[notify]' "${CODEX_TWO}/config.toml" || \
  grep -Fq 'after_agent = "mkdir -p .claude/state' "${CODEX_TWO}/config.toml"; then
  echo "remote setup must remove the exact distributed-template notify stanza" >&2
  exit 1
fi
grep -Fqx 'marker = "preserve-remote-template-variant"' "${CODEX_TWO}/config.toml" || {
  echo "remote setup must preserve unrelated template config" >&2
  exit 1
}
remote_config_backup="$(find "${CODEX_TWO}/backups/setup-codex" -type f -name 'config.toml.*' -print -quit 2>/dev/null || true)"
[ -n "${remote_config_backup}" ] || {
  echo "remote setup must create a config backup" >&2
  exit 1
}
if ! cmp -s "${TMP_ROOT}/remote-legacy-notify-template-before.toml" "${remote_config_backup}"; then
  echo "remote setup config backup does not match pre-mutation content" >&2
  exit 1
fi
assert_remote_codex_accepts_config "${CODEX_TWO}/config.toml"

# Case 3: the historical two-line setup stanza is migrated without replacing
# a config symlink or changing its target identity.
HOME_THREE="${TMP_ROOT}/home-legacy-notify-setup"
CODEX_THREE="${HOME_THREE}/.codex"
CONFIG_TARGET_THREE="${TMP_ROOT}/remote-legacy-notify-setup-target.toml"
mkdir -p "${CODEX_THREE}"
cat > "${CONFIG_TARGET_THREE}" <<'TOML'
[features]
multi_agent = true

[notify]
after_agent = "echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt"

[custom]
marker = "preserve-remote-setup-variant"
TOML
cp "${CONFIG_TARGET_THREE}" "${TMP_ROOT}/remote-legacy-notify-setup-before.toml"
ln -s "${CONFIG_TARGET_THREE}" "${CODEX_THREE}/config.toml"

if ! run_remote_setup "${HOME_THREE}" "${TMP_ROOT}/remote-setup-setup.log"; then
  sed 's/^/  /' "${TMP_ROOT}/remote-setup-setup.log" >&2
  echo "remote setup failed for the exact setup notify stanza" >&2
  exit 1
fi
if [ ! -L "${CODEX_THREE}/config.toml" ]; then
  echo "remote setup must preserve the config symlink" >&2
  exit 1
fi
if grep -Fqx '[notify]' "${CONFIG_TARGET_THREE}" || \
  grep -Fq "after_agent = \"echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt\"" "${CONFIG_TARGET_THREE}"; then
  echo "remote setup must remove the exact setup notify stanza" >&2
  exit 1
fi
grep -Fqx 'marker = "preserve-remote-setup-variant"' "${CONFIG_TARGET_THREE}" || {
  echo "remote setup must preserve unrelated setup config" >&2
  exit 1
}
remote_symlink_backup="$(find "${CODEX_THREE}/backups/setup-codex" -type f -name 'config.toml.*' -print -quit 2>/dev/null || true)"
[ -n "${remote_symlink_backup}" ] || {
  echo "remote setup must back up a symlink target config" >&2
  exit 1
}
if ! cmp -s "${TMP_ROOT}/remote-legacy-notify-setup-before.toml" "${remote_symlink_backup}"; then
  echo "remote setup symlink config backup does not match pre-mutation content" >&2
  exit 1
fi
assert_remote_codex_accepts_config "${CONFIG_TARGET_THREE}"

# Case 4: custom notify tables fail closed and remain byte-identical.
HOME_FOUR="${TMP_ROOT}/home-custom-notify"
CODEX_FOUR="${HOME_FOUR}/.codex"
mkdir -p \
  "${CODEX_FOUR}/skills/sentinel" \
  "${CODEX_FOUR}/rules" \
  "${CODEX_FOUR}/agents"
printf 'skills sentinel\n' > "${CODEX_FOUR}/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "${CODEX_FOUR}/rules/sentinel.rules"
printf 'agents sentinel\n' > "${CODEX_FOUR}/agents/sentinel.toml"
cat > "${CODEX_FOUR}/config.toml" <<'TOML'
[features]
multi_agent = true

[notify]
after_agent = "custom operator command"
TOML
cp "${CODEX_FOUR}/config.toml" "${TMP_ROOT}/remote-custom-notify-before.toml"
find "${CODEX_FOUR}/skills" "${CODEX_FOUR}/rules" "${CODEX_FOUR}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-custom-targets-before.txt"

if run_remote_setup "${HOME_FOUR}" "${TMP_ROOT}/remote-custom-setup.log"; then
  echo "remote setup must fail closed for a custom notify table" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-custom-notify-before.toml" "${CODEX_FOUR}/config.toml"; then
  echo "remote setup must preserve custom notify byte-for-byte" >&2
  exit 1
fi
find "${CODEX_FOUR}/skills" "${CODEX_FOUR}/rules" "${CODEX_FOUR}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-custom-targets-after.txt"
if ! cmp -s "${TMP_ROOT}/remote-custom-targets-before.txt" "${TMP_ROOT}/remote-custom-targets-after.txt"; then
  echo "remote setup must not mutate skills/rules/agents before rejecting custom notify" >&2
  exit 1
fi
if [ -n "$(find "${CODEX_FOUR}/backups" -type f -name 'config.toml.*' -print -quit 2>/dev/null)" ]; then
  echo "remote setup must not back up a custom notify config before failing" >&2
  exit 1
fi

# Case 4b: descendant tables are ambiguous too and must fail unchanged.
HOME_FOUR_B="${TMP_ROOT}/home-custom-notify-descendant"
CODEX_FOUR_B="${HOME_FOUR_B}/.codex"
mkdir -p "${CODEX_FOUR_B}"
cat > "${CODEX_FOUR_B}/config.toml" <<'TOML'
[notify.custom]
command = "custom operator command"
TOML
cp "${CODEX_FOUR_B}/config.toml" "${TMP_ROOT}/remote-custom-notify-descendant-before.toml"

if run_remote_setup "${HOME_FOUR_B}" "${TMP_ROOT}/remote-custom-descendant-setup.log"; then
  echo "remote setup must fail closed for a custom notify descendant table" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-custom-notify-descendant-before.toml" "${CODEX_FOUR_B}/config.toml"; then
  echo "remote setup must preserve custom notify descendant byte-for-byte" >&2
  exit 1
fi
if [ -n "$(find "${CODEX_FOUR_B}/backups" -type f -name 'config.toml.*' -print -quit 2>/dev/null)" ]; then
  echo "remote setup must not back up a custom notify descendant before failing" >&2
  exit 1
fi

# Case 4c: project mode must preflight config before replacing project AGENTS.
HOME_FOUR_C="${TMP_ROOT}/home-custom-notify-project"
PROJECT_FOUR_C="${TMP_ROOT}/project-custom-notify"
CODEX_FOUR_C="${PROJECT_FOUR_C}/.codex"
mkdir -p \
  "${CODEX_FOUR_C}/skills/sentinel" \
  "${CODEX_FOUR_C}/rules" \
  "${CODEX_FOUR_C}/agents"
printf 'project skills sentinel\n' > "${CODEX_FOUR_C}/skills/sentinel/SKILL.md"
printf 'project rules sentinel\n' > "${CODEX_FOUR_C}/rules/sentinel.rules"
printf 'project agents sentinel\n' > "${CODEX_FOUR_C}/agents/sentinel.toml"
printf 'project AGENTS sentinel\n' > "${PROJECT_FOUR_C}/AGENTS.md"
cat > "${CODEX_FOUR_C}/config.toml" <<'TOML'
[notify.custom]
command = "custom project operator command"
TOML
cp "${CODEX_FOUR_C}/config.toml" "${TMP_ROOT}/remote-project-custom-notify-before.toml"
cp "${PROJECT_FOUR_C}/AGENTS.md" "${TMP_ROOT}/remote-project-agents-before.txt"
find "${CODEX_FOUR_C}/skills" "${CODEX_FOUR_C}/rules" "${CODEX_FOUR_C}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-project-custom-targets-before.txt"

if run_remote_setup "${HOME_FOUR_C}" "${TMP_ROOT}/remote-project-custom-setup.log" "${PROJECT_FOUR_C}"; then
  echo "remote project setup must fail closed for a custom notify table" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-project-custom-notify-before.toml" "${CODEX_FOUR_C}/config.toml" || \
  ! cmp -s "${TMP_ROOT}/remote-project-agents-before.txt" "${PROJECT_FOUR_C}/AGENTS.md"; then
  echo "remote project setup must preserve config and AGENTS on preflight failure" >&2
  exit 1
fi
find "${CODEX_FOUR_C}/skills" "${CODEX_FOUR_C}/rules" "${CODEX_FOUR_C}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-project-custom-targets-after.txt"
if ! cmp -s "${TMP_ROOT}/remote-project-custom-targets-before.txt" "${TMP_ROOT}/remote-project-custom-targets-after.txt"; then
  echo "remote project setup must not mutate managed targets before rejecting custom notify" >&2
  exit 1
fi

# Case 4d: an exact legacy stanza does not permit a later unsupported root
# shape to be partially migrated. Validation must fail before any rewrite.
HOME_FOUR_D="${TMP_ROOT}/home-legacy-plus-invalid-shape"
CODEX_FOUR_D="${HOME_FOUR_D}/.codex"
mkdir -p "${CODEX_FOUR_D}/skills/sentinel" "${CODEX_FOUR_D}/rules" "${CODEX_FOUR_D}/agents"
printf 'skills sentinel\n' > "${CODEX_FOUR_D}/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "${CODEX_FOUR_D}/rules/sentinel.rules"
printf 'agents sentinel\n' > "${CODEX_FOUR_D}/agents/sentinel.toml"
cat > "${CODEX_FOUR_D}/config.toml" <<'TOML'
agents = { max_threads = 4 }

[notify]
after_agent = "echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt"
TOML
cp "${CODEX_FOUR_D}/config.toml" "${TMP_ROOT}/remote-legacy-plus-invalid-before.toml"
find "${CODEX_FOUR_D}/skills" "${CODEX_FOUR_D}/rules" "${CODEX_FOUR_D}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-legacy-plus-invalid-targets-before.txt"

if run_remote_setup "${HOME_FOUR_D}" "${TMP_ROOT}/remote-legacy-plus-invalid-setup.log"; then
  echo "remote setup must fail closed for legacy notify plus an invalid root shape" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-legacy-plus-invalid-before.toml" "${CODEX_FOUR_D}/config.toml"; then
  echo "remote setup must not migrate legacy notify before rejecting an invalid root shape" >&2
  exit 1
fi
find "${CODEX_FOUR_D}/skills" "${CODEX_FOUR_D}/rules" "${CODEX_FOUR_D}/agents" \
  -mindepth 1 -maxdepth 2 -print | sort > "${TMP_ROOT}/remote-legacy-plus-invalid-targets-after.txt"
if ! cmp -s "${TMP_ROOT}/remote-legacy-plus-invalid-targets-before.txt" \
  "${TMP_ROOT}/remote-legacy-plus-invalid-targets-after.txt"; then
  echo "remote setup must not mutate targets for legacy notify plus an invalid root shape" >&2
  exit 1
fi

# Case 4e: an exact legacy stanza still requires a usable backup destination.
# A regular file at the backup root must fail before any managed target or
# project AGENTS.md mutation.
HOME_FOUR_E="${TMP_ROOT}/home-backup-root-file"
PROJECT_FOUR_E="${TMP_ROOT}/project-backup-root-file"
CODEX_FOUR_E="${PROJECT_FOUR_E}/.codex"
BACKUP_FOUR_E="${CODEX_FOUR_E}/backups/setup-codex"
mkdir -p \
  "${CODEX_FOUR_E}/skills/sentinel" \
  "${CODEX_FOUR_E}/rules" \
  "${CODEX_FOUR_E}/agents" \
  "$(dirname "${BACKUP_FOUR_E}")"
printf 'skills sentinel\n' > "${CODEX_FOUR_E}/skills/sentinel/SKILL.md"
printf 'rules sentinel\n' > "${CODEX_FOUR_E}/rules/sentinel.rules"
printf 'agents sentinel\n' > "${CODEX_FOUR_E}/agents/sentinel.toml"
printf 'backup root must remain a file\n' > "${BACKUP_FOUR_E}"
printf 'project AGENTS sentinel\n' > "${PROJECT_FOUR_E}/AGENTS.md"
cat > "${CODEX_FOUR_E}/config.toml" <<'TOML'
[notify]
after_agent = "echo '[HARNESS-LEARNING] Session completed' >> .claude/state/session-log.txt"
TOML
cp "${CODEX_FOUR_E}/config.toml" "${TMP_ROOT}/remote-backup-root-file-config-before.toml"
cp "${PROJECT_FOUR_E}/AGENTS.md" "${TMP_ROOT}/remote-backup-root-file-agents-before.txt"
cp -R "${CODEX_FOUR_E}/skills" "${TMP_ROOT}/remote-backup-root-file-skills-before"
cp -R "${CODEX_FOUR_E}/rules" "${TMP_ROOT}/remote-backup-root-file-rules-before"
cp -R "${CODEX_FOUR_E}/agents" "${TMP_ROOT}/remote-backup-root-file-agents-before"
cp "${BACKUP_FOUR_E}" "${TMP_ROOT}/remote-backup-root-file-backup-before.txt"

if run_remote_setup "${HOME_FOUR_E}" "${TMP_ROOT}/remote-backup-root-file-setup.log" "${PROJECT_FOUR_E}"; then
  echo "remote setup must fail when the backup destination is a regular file" >&2
  exit 1
fi
if ! cmp -s "${TMP_ROOT}/remote-backup-root-file-config-before.toml" "${CODEX_FOUR_E}/config.toml" || \
  ! cmp -s "${TMP_ROOT}/remote-backup-root-file-agents-before.txt" "${PROJECT_FOUR_E}/AGENTS.md" || \
  ! cmp -s "${TMP_ROOT}/remote-backup-root-file-backup-before.txt" "${BACKUP_FOUR_E}" || \
  ! diff -ru "${TMP_ROOT}/remote-backup-root-file-skills-before" "${CODEX_FOUR_E}/skills" >/dev/null || \
  ! diff -ru "${TMP_ROOT}/remote-backup-root-file-rules-before" "${CODEX_FOUR_E}/rules" >/dev/null || \
  ! diff -ru "${TMP_ROOT}/remote-backup-root-file-agents-before" "${CODEX_FOUR_E}/agents" >/dev/null; then
  echo "remote setup must preserve all targets when the backup destination is unusable" >&2
  exit 1
fi

# Case 5: modern top-level notify arrays remain untouched.
HOME_FIVE="${TMP_ROOT}/home-modern-notify"
CODEX_FIVE="${HOME_FIVE}/.codex"
mkdir -p "${CODEX_FIVE}"
cat > "${CODEX_FIVE}/config.toml" <<'TOML'
notify = ["echo", "done"]

[custom]
marker = "preserve-remote-modern-notify"
TOML

if ! run_remote_setup "${HOME_FIVE}" "${TMP_ROOT}/remote-modern-setup.log"; then
  sed 's/^/  /' "${TMP_ROOT}/remote-modern-setup.log" >&2
  echo "remote setup failed for a modern notify string array" >&2
  exit 1
fi
grep -Fqx 'notify = ["echo", "done"]' "${CODEX_FIVE}/config.toml" || {
  echo "remote setup must preserve a modern top-level notify string array" >&2
  exit 1
}
assert_remote_codex_accepts_config "${CODEX_FIVE}/config.toml"

echo "test-codex-setup-remote: config loads; managed agent TOMLs parse"
