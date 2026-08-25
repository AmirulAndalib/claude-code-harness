#!/bin/bash
#
# setup-codex.sh
#
# Setup Harness for Codex CLI.
#
# Usage:
#   ./scripts/setup-codex.sh [--user|--project]
#
# Codex CLI install (official, 0.134.0+):
#   curl -fsSL https://github.com/openai/codex/releases/latest/download/install.sh | sh
#   PowerShell: see install.ps1 on the same GitHub release assets page.
# Harness setup assumes Codex is already installed; this script copies skills/config only.
# Permission profiles: Codex 0.134.0 makes --profile the primary selector (see
# docs/codex-permission-profiles-policy.md).

set -euo pipefail
IFS=$'\n\t'

HARNESS_REPO="https://github.com/Chachamaru127/claude-code-harness.git"
HARNESS_BRANCH="main"
TEMP_DIR=$(mktemp -d)
PROJECT_DIR=$(pwd)
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
TARGET_MODE="user"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_ok() { echo "[OK]   $1"; }
log_err() { echo "[ERR]  $1" >&2; }

usage() {
    cat <<USAGE
Usage: $0 [--user|--project]

Modes:
  --user      Install to CODEX_HOME (default: $CODEX_HOME_DIR)
  --project   Install to current project (.codex/ + AGENTS.md)
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --user)
                TARGET_MODE="user"
                ;;
            --project)
                TARGET_MODE="project"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_err "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

check_requirements() {
    log_info "Checking requirements..."
    if ! command -v git >/dev/null 2>&1; then
        log_err "git is required but not installed"
        exit 1
    fi
    log_ok "All requirements met"
}

clone_harness() {
    log_info "Downloading Harness..."
    git clone --depth 1 --branch "$HARNESS_BRANCH" "$HARNESS_REPO" "$TEMP_DIR/harness" 2>/dev/null || {
        log_err "Failed to clone Harness repository"
        exit 1
    }
    log_ok "Harness downloaded"
}

backup_path() {
    local target="$1"
    local backup_root="$2"
    if [ -e "$target" ] || [ -L "$target" ]; then
        local ts
        local base
        local dst
        ts=$(date +%Y%m%d%H%M%S)
        base="$(basename "$target")"
        mkdir -p "$backup_root"
        dst="$backup_root/${base}.${ts}.$$"
        mv "$target" "$dst"
        log_warn "Backed up $target to $dst"
    fi
}

should_skip_sync_entry() {
    local name="$1"
    case "$name" in
        _archived|*.backup.*)
            return 0
            ;;
    esac
    return 1
}

is_legacy_harness_skill_name() {
    local name="$1"
    case "$name" in
        plan-with-agent|planning|plans-management|sync-status|work|execute|impl|parallel-workflows|verify|setup|harness-init|release-har|codex-review|codex-worker|remember)
            return 0
            ;;
    esac
    return 1
}

is_harness_managed_skill_entry() {
    local skill_file="$1"
    [ -f "$skill_file" ] || return 1

    if grep -Eq 'Claude Code Harness|Harness v3|claude-code-harness|/harness-|Plans\.md' "$skill_file"; then
        return 0
    fi
    return 1
}

cleanup_legacy_skill_entries() {
    local dst_dir="$1"
    local backup_root="$2"
    [ -d "$dst_dir" ] || return 0

    local legacy_path
    for legacy_path in "$dst_dir"/_archived "$dst_dir"/*.backup.*; do
        [ -e "$legacy_path" ] || continue
        backup_path "$legacy_path" "$backup_root"
    done
}

extract_skill_frontmatter_name() {
    local skill_file="$1"
    [ -f "$skill_file" ] || return 1

    awk '
        BEGIN { in_frontmatter = 0 }
        /^---[[:space:]]*$/ {
            if (in_frontmatter == 0) {
                in_frontmatter = 1
                next
            }
            exit
        }
        in_frontmatter == 1 && /^[[:space:]]*name:[[:space:]]*/ {
            sub(/^[[:space:]]*name:[[:space:]]*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            gsub(/^"|"$/, "", $0)
            print $0
            exit
        }
    ' "$skill_file"
}

cleanup_legacy_skill_name_duplicates() {
    local src_dir="$1"
    local dst_dir="$2"
    local backup_root="$3"
    [ -d "$src_dir" ] || return 0
    [ -d "$dst_dir" ] || return 0

    local src_skill_names=""
    local src_entry
    for src_entry in "$src_dir"/*; do
        [ -d "$src_entry" ] || continue
        local src_name
        src_name="$(basename "$src_entry")"
        if should_skip_sync_entry "$src_name"; then
            continue
        fi
        local src_skill_name
        src_skill_name="$(extract_skill_frontmatter_name "$src_entry/SKILL.md" || true)"
        [ -n "$src_skill_name" ] || continue
        src_skill_names+=$'\n'"$src_skill_name"
    done

    [ -n "$src_skill_names" ] || return 0

    local deduped=0
    local dst_entry
    for dst_entry in "$dst_dir"/*; do
        [ -d "$dst_entry" ] || continue
        local dst_name
        dst_name="$(basename "$dst_entry")"
        if should_skip_sync_entry "$dst_name"; then
            continue
        fi
        [ -e "$src_dir/$dst_name" ] && continue

        local dst_skill_name
        dst_skill_name="$(extract_skill_frontmatter_name "$dst_entry/SKILL.md" || true)"
        [ -n "$dst_skill_name" ] || continue

        if grep -Fxq "$dst_skill_name" <<<"$src_skill_names"; then
            backup_path "$dst_entry" "$backup_root"
            deduped=$((deduped + 1))
        fi
    done

    if [ "$deduped" -gt 0 ]; then
        log_warn "Moved $deduped legacy skill alias(es) with duplicate frontmatter name"
    fi
}

cleanup_removed_harness_skill_entries() {
    local src_dir="$1"
    local dst_dir="$2"
    local backup_root="$3"
    [ -d "$src_dir" ] || return 0
    [ -d "$dst_dir" ] || return 0

    local removed=0
    local dst_entry
    for dst_entry in "$dst_dir"/*; do
        [ -d "$dst_entry" ] || continue
        local dst_name
        dst_name="$(basename "$dst_entry")"
        if should_skip_sync_entry "$dst_name"; then
            continue
        fi
        [ -e "$src_dir/$dst_name" ] && continue

        local dst_skill_file="$dst_entry/SKILL.md"
        local dst_skill_name
        dst_skill_name="$(extract_skill_frontmatter_name "$dst_skill_file" || true)"

        if ! is_harness_managed_skill_entry "$dst_skill_file"; then
            continue
        fi

        if is_legacy_harness_skill_name "$dst_name" || { [ -n "$dst_skill_name" ] && is_legacy_harness_skill_name "$dst_skill_name"; }; then
            backup_path "$dst_entry" "$backup_root"
            removed=$((removed + 1))
        fi
    done

    if [ "$removed" -gt 0 ]; then
        log_warn "Moved $removed removed legacy Harness skill(s) that are no longer shipped"
    fi
}

merge_dir_recursive() {
    local src_dir="$1"
    local dst_dir="$2"
    local backup_root="$3"
    local _copied_ref="$4"
    local _updated_ref="$5"

    mkdir -p "$dst_dir"

    local entry
    for entry in "$src_dir"/*; do
        [ -e "$entry" ] || continue
        local name
        name="$(basename "$entry")"
        local dst_path="$dst_dir/$name"

        if [ ! -e "$dst_path" ]; then
            cp -R -L "$entry" "$dst_dir/"
            eval "$_copied_ref=\$((\$$_copied_ref + 1))"
        elif [ -d "$entry" ] && [ -d "$dst_path" ]; then
            merge_dir_recursive "$entry" "$dst_path" "$backup_root" "$_copied_ref" "$_updated_ref"
        else
            backup_path "$dst_path" "$backup_root"
            cp -R -L "$entry" "$dst_dir/"
            eval "$_updated_ref=\$((\$$_updated_ref + 1))"
        fi
    done
}

sync_named_children() {
    local src_dir="$1"
    local dst_dir="$2"
    local label="$3"
    local backup_root="$4"

    [ -d "$src_dir" ] || {
        log_err "$label source not found: $src_dir"
        exit 1
    }

    mkdir -p "$dst_dir"

    local copied=0
    local updated=0
    local skipped=0
    local preserved=0
    local entry
    for entry in "$src_dir"/*; do
        [ -e "$entry" ] || continue

        local name
        name="$(basename "$entry")"
        if should_skip_sync_entry "$name"; then
            skipped=$((skipped + 1))
            continue
        fi
        local dst_path="$dst_dir/$name"

        if [ ! -e "$dst_path" ] && [ ! -L "$dst_path" ]; then
            cp -R -L "$entry" "$dst_dir/"
            copied=$((copied + 1))
        elif [ -L "$dst_path" ]; then
            backup_path "$dst_path" "$backup_root"
            cp -R -L "$entry" "$dst_dir/"
            updated=$((updated + 1))
        elif [ -d "$entry" ] && [ -d "$dst_path" ]; then
            merge_dir_recursive "$entry" "$dst_path" "$backup_root" "copied" "updated"
        else
            backup_path "$dst_path" "$backup_root"
            cp -R -L "$entry" "$dst_dir/"
            updated=$((updated + 1))
        fi
    done

    for entry in "$dst_dir"/*; do
        [ -e "$entry" ] || continue
        local name
        name="$(basename "$entry")"
        if should_skip_sync_entry "$name"; then
            continue
        fi
        [ -e "$src_dir/$name" ] || preserved=$((preserved + 1))
    done

    log_ok "$label merged to $dst_dir ($copied new, $updated updated, $preserved preserved, $skipped skipped)"
}

copy_project_agents() {
    local backup_root="$1"
    local src="$TEMP_DIR/harness/codex/AGENTS.md"
    local dst="$PROJECT_DIR/AGENTS.md"

    if [ ! -f "$src" ]; then
        log_err "codex/AGENTS.md not found in Harness"
        exit 1
    fi

    if [ -f "$dst" ]; then
        backup_path "$dst" "$backup_root"
    fi

    cp "$src" "$dst"
    log_ok "AGENTS.md copied to project root"
}

resolve_config_write_path() {
    local path="$1"
    local hops=0

    while [ -L "$path" ]; do
        hops=$((hops + 1))
        if [ "$hops" -gt 40 ]; then
            log_err "Config symlink chain is too deep: $1"
            return 1
        fi

        local link_target
        link_target="$(readlink "$path")"
        case "$link_target" in
            /*)
                path="$link_target"
                ;;
            *)
                path="$(dirname "$path")/$link_target"
                ;;
        esac
    done

    local target_dir
    target_dir="$(cd "$(dirname "$path")" && pwd -P)"
    printf '%s/%s\n' "$target_dir" "$(basename "$path")"
}

snapshot_config_once() {
    local cfg="$1"
    local backup_root="$2"
    local write_path="$cfg"
    local ts
    local dst
    local suffix=1

    if [ "${CONFIG_BACKUP_CREATED:-0}" -eq 1 ]; then
        return 0
    fi
    if [ -L "$cfg" ]; then
        if ! write_path="$(resolve_config_write_path "$cfg")"; then
            return 1
        fi
    fi

    if ! mkdir -p "$backup_root"; then
        return 1
    fi
    if ! ts="$(date +%Y%m%d%H%M%S)"; then
        return 1
    fi
    dst="$backup_root/${cfg##*/}.${ts}.$$"
    while [ -e "$dst" ] || [ -L "$dst" ]; do
        dst="$backup_root/${cfg##*/}.${ts}.$$.$suffix"
        suffix=$((suffix + 1))
    done
    if ! cp -p "$write_path" "$dst"; then
        rm -f "$dst"
        return 1
    fi
    CONFIG_BACKUP_CREATED=1
    log_warn "Backed up config content from $write_path to $dst"
}

validate_config_merge_shape() {
    local cfg="$1"
    local legacy_notify_setup
    local legacy_notify_template
    local legacy_notify_comment
    legacy_notify_setup='after_agent = "echo '\''[HARNESS-LEARNING] Session completed'\'' >> .claude/state/session-log.txt"'
    # Exact historical literal; never execute its command substitution.
    # shellcheck disable=SC2016
    legacy_notify_template='after_agent = "mkdir -p .claude/state && echo \"[HARNESS-LEARNING] $(date -u +%Y-%m-%dT%H:%M:%SZ) Session completed\" >> .claude/state/session-log.txt"'
    legacy_notify_comment='# Session end notification: log to harness state + codex memories (0.110.0: ~/.codex/memories/ auto-writable)'

    # Safe-subset invariant: reject ambiguous semantic forms before creating a
    # temp file or backup; the line merger then sees only canonical owned paths.
    LEGACY_NOTIFY_SETUP="$legacy_notify_setup" \
        LEGACY_NOTIFY_TEMPLATE="$legacy_notify_template" \
        LEGACY_NOTIFY_COMMENT="$legacy_notify_comment" \
        awk -v cfg="$cfg" '
        BEGIN {
            at_root = 1
            single_quote = sprintf("%c", 39)
            triple_double_quote = "\"\"\""
            triple_single_quote = single_quote single_quote single_quote
            feature_key = "(features|\"features\"|" single_quote "features" single_quote ")"
            agents_key = "(agents|\"agents\"|" single_quote "agents" single_quote ")"
            memories_key = "(memories|\"memories\"|" single_quote "memories" single_quote ")"
            notify_key = "(notify|\"notify\"|" single_quote "notify" single_quote ")"
            managed_agent_names = "(implementer|reviewer|task_worker|code_reviewer|" \
                "codex_implementer|claude_implementer|claude_reviewer|plan_analyst|plan_critic)"
            managed_agent_key = "(" managed_agent_names "|\"" managed_agent_names "\"|" \
                single_quote managed_agent_names single_quote ")"
            managed_feature_names = "(multi_agent|default_mode_request_user_input)"
            managed_feature_key = "(" managed_feature_names "|\"" managed_feature_names "\"|" \
                single_quote managed_feature_names single_quote ")"
            agent_scalar_names = "(max_threads)"
            agent_scalar_key = "(" agent_scalar_names "|\"" agent_scalar_names "\"|" \
                single_quote agent_scalar_names single_quote ")"
            memory_scalar_names = "(no_memories_if_mcp_or_web_search)"
            memory_scalar_key = "(" memory_scalar_names "|\"" memory_scalar_names "\"|" \
                single_quote memory_scalar_names single_quote ")"
            basic_string = "\"([^\"\\\\]|\\\\.)*\""
            literal_string = single_quote "[^" single_quote "]*" single_quote
            notify_string = "(" basic_string "|" literal_string ")"
            notify_inline_array = "^\\[[[:space:]]*(" notify_string \
                "([[:space:]]*,[[:space:]]*" notify_string ")*[[:space:]]*,?)?" \
                "[[:space:]]*\\][[:space:]]*(#.*)?$"
            notify_multiline_open = "^\\[[[:space:]]*(#.*)?$"
            notify_multiline_element = "^[[:space:]]*" notify_string \
                "[[:space:]]*,[[:space:]]*(#.*)?$"
            bare_key = "[A-Za-z0-9_-]+"
            basic_key = "\"[^\"\\\\]*\""
            literal_key = single_quote "[^" single_quote "]*" single_quote
            table_key = "(" bare_key "|" basic_key "|" literal_key ")"
            ordinary_table = "^[[:space:]]*\\[[[:space:]]*" table_key \
                "([[:space:]]*\\.[[:space:]]*" table_key ")*[[:space:]]*\\]" \
                "[[:space:]]*(#.*)?$"
            array_table = "^[[:space:]]*\\[\\[[[:space:]]*" table_key \
                "([[:space:]]*\\.[[:space:]]*" table_key ")*[[:space:]]*\\]\\]" \
                "[[:space:]]*(#.*)?$"
        }

        function is_supported_table(line) {
            return line ~ ordinary_table
        }

        function table_body(line, body) {
            body = line
            sub(/^[[:space:]]*\[[[:space:]]*/, "", body)
            sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", body)
            return body
        }

        function is_supported_array_table(line) {
            return line ~ array_table
        }

        function array_table_body(line, body) {
            body = line
            sub(/^[[:space:]]*\[\[[[:space:]]*/, "", body)
            sub(/[[:space:]]*\]\][[:space:]]*(#.*)?$/, "", body)
            return body
        }

        function is_owned_array_table(line, body, owned_root) {
            if (!is_supported_array_table(line)) {
                return 0
            }
            body = array_table_body(line)
            owned_root = "(features|\"features\"|" single_quote "features" single_quote \
                "|agents|\"agents\"|" single_quote "agents" single_quote \
                "|memories|\"memories\"|" single_quote "memories" single_quote \
                "|notify|\"notify\"|" single_quote "notify" single_quote ")"
            return body ~ ("^" owned_root "([[:space:]]*\\.|$)")
        }

        function is_notify_descendant_table(line, body) {
            if (!is_supported_table(line)) {
                return 0
            }
            body = table_body(line)
            return body ~ ("^" notify_key "[[:space:]]*\\.")
        }

        function is_scalar_descendant_table(line, root_key, scalar_key, body) {
            if (!is_supported_table(line)) {
                return 0
            }
            body = table_body(line)
            return body ~ ("^" root_key "[[:space:]]*\\.[[:space:]]*" \
                scalar_key "([[:space:]]*\\.|$)")
        }

        function is_agent_role_descendant_table(line, body) {
            if (!is_supported_table(line)) {
                return 0
            }
            body = table_body(line)
            return body ~ ("^" agents_key "[[:space:]]*\\.[[:space:]]*" \
                managed_agent_key "[[:space:]]*\\.")
        }

        function is_named_table(line, name, body) {
            if (!is_supported_table(line)) {
                return 0
            }
            body = table_body(line)
            return body == name || body == "\"" name "\"" || \
                body == single_quote name single_quote
        }

        function is_agents_subtable(line, body, prefix) {
            if (!is_supported_table(line)) {
                return 0
            }
            body = table_body(line)
            prefix = "(agents|\"agents\"|" single_quote "agents" single_quote ")"
            return body ~ ("^" prefix "[[:space:]]*\\.")
        }

        function is_canonical_agents_subtable(line) {
            return line ~ /^\[agents\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\][[:space:]]*(#.*)?$/
        }

        function starts_multiline_array(line, rhs) {
            if (line !~ /=/) {
                return 0
            }
            rhs = line
            sub(/^[^=]*=[[:space:]]*/, "", rhs)
            sub(/[[:space:]]*#.*/, "", rhs)
            return rhs ~ /^\[/ && rhs !~ /\]/
        }

        function lhs_has_escape(line, lhs) {
            if (line !~ /=/) {
                return 0
            }
            lhs = line
            sub(/=.*/, "", lhs)
            return index(lhs, "\\") > 0
        }

        function is_named_assignment(line, name, pattern) {
            pattern = "^[[:space:]]*(" name "|\"" name "\"|" \
                single_quote name single_quote ")[[:space:]]*="
            return line ~ pattern
        }

        function is_boolean_assignment(line, name, pattern) {
            pattern = "^[[:space:]]*(" name "|\"" name "\"|" \
                single_quote name single_quote ")[[:space:]]*=" \
                "[[:space:]]*(true|false)[[:space:]]*(#.*)?$"
            return line ~ pattern
        }

        function is_positive_integer_assignment(line, name, pattern) {
            pattern = "^[[:space:]]*(" name "|\"" name "\"|" \
                single_quote name single_quote ")[[:space:]]*=" \
                "[[:space:]]*[1-9][0-9]*[[:space:]]*(#.*)?$"
            return line ~ pattern
        }

        function is_string_array_assignment(line, name, rhs, pattern) {
            pattern = "^[[:space:]]*(" name "|\"" name "\"|" \
                single_quote name single_quote ")[[:space:]]*=[[:space:]]*"
            if (line !~ pattern) {
                return 0
            }
            rhs = line
            sub(pattern, "", rhs)
            return rhs ~ notify_inline_array || rhs ~ notify_multiline_open
        }

        function finish_notify(signature) {
            signature = notify_signature
            in_notify = 0
            notify_signature = ""
            if (signature == ENVIRON["LEGACY_NOTIFY_SETUP"] || \
                signature == ENVIRON["LEGACY_NOTIFY_COMMENT"] "\n" ENVIRON["LEGACY_NOTIFY_TEMPLATE"]) {
                return 1
            }
            print "Unsupported custom [notify] table in " cfg \
                "; migrate it manually before running setup" > "/dev/stderr"
            fatal = 1
            return 0
        }

        index($0, triple_double_quote) || index($0, triple_single_quote) {
            print "Unsupported multiline TOML string in " cfg \
                "; preserve it manually before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        in_multiline_array {
            if ($0 ~ /^[[:space:]]*\]/) {
                if ($0 !~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*(#.*)?$/) {
                    print "Unsupported multiline TOML array closing line in " cfg \
                        "; preserve it manually before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                in_multiline_array = 0
                multiline_array_requires_strings = 0
                next
            }
            if (multiline_array_requires_strings) {
                if ($0 ~ /^[[:space:]]*(#|$)/) {
                    next
                }
                if ($0 !~ notify_multiline_element) {
                    print "notify multiline array elements must be strings in " cfg \
                        "; preserve the config manually before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                next
            }
            if ($0 ~ /^[[:space:]]*\[/) {
                print "Unsupported nested multiline TOML array in " cfg \
                    "; preserve it manually before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }
            next
        }

        /^[[:space:]]*\[/ {
            if (in_notify && !finish_notify()) {
                exit 64
            }
            if (is_supported_array_table($0)) {
                if (is_owned_array_table($0)) {
                    print "Unsupported array-of-tables for setup-owned config in " cfg \
                        "; use canonical tables before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                at_root = 0
                in_agents = 0
                in_features = 0
                in_memories = 0
                next
            }
            if (!is_supported_table($0)) {
                print "Unsupported TOML table shape in " cfg \
                    "; preserve it manually before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }
            in_agents = 0
            in_features = 0
            in_memories = 0
            if (is_scalar_descendant_table($0, feature_key, managed_feature_key)) {
                print "Unsupported managed feature descendant table in " cfg \
                    "; use scalar feature values before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }
            if (is_scalar_descendant_table($0, agents_key, agent_scalar_key) || \
                is_agent_role_descendant_table($0)) {
                print "Unsupported managed agents descendant table in " cfg \
                    "; use canonical agent values/tables before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }
            if (is_scalar_descendant_table($0, memories_key, memory_scalar_key)) {
                print "Unsupported managed memories descendant table in " cfg \
                    "; use scalar memory values before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }
            if (is_notify_descendant_table($0)) {
                print "Unsupported custom notify descendant table in " cfg \
                    "; use a root notify array before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }
            if (is_named_table($0, "features")) {
                features_tables += 1
                if (features_tables > 1) {
                    print "Duplicate [features] tables in " cfg \
                        "; merge them before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                in_features = 1
            }
            if (is_named_table($0, "agents")) {
                if (agents_table_seen) {
                    print "Unsupported or duplicate [agents] table in " cfg \
                        "; use one canonical [agents] table before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                agents_table_seen = 1
                in_agents = 1
            } else if (is_agents_subtable($0)) {
                agent_table_name = table_body($0)
                if (!is_canonical_agents_subtable($0) || agent_tables[agent_table_name]) {
                    print "Unsupported or duplicate agents subtable in " cfg \
                        "; use canonical [agents.name] tables before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                agent_tables[agent_table_name] = 1
            }
            if (is_named_table($0, "memories")) {
                if (memories_table_seen) {
                    print "Unsupported or duplicate [memories] table in " cfg \
                        "; use one canonical [memories] table before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                memories_table_seen = 1
                in_memories = 1
            }
            if (is_named_table($0, "notify")) {
                if ($0 !~ /^[[:space:]]*\[notify\][[:space:]]*$/ || notify_seen) {
                    print "Unsupported custom [notify] table in " cfg \
                        "; migrate it manually before running setup" > "/dev/stderr"
                    fatal = 1
                    exit 64
                }
                notify_seen = 1
                in_notify = 1
                at_root = 0
                next
            }
            at_root = 0
            next
        }

        in_notify {
            if ($0 ~ /^[[:space:]]*$/) {
                next
            }
            if (notify_signature == "") {
                notify_signature = $0
            } else {
                notify_signature = notify_signature "\n" $0
            }
            next
        }

        /^[[:space:]]*(#|$)/ {
            next
        }

        (at_root || in_features || in_agents || in_memories) && lhs_has_escape($0) {
            print "Unsupported escaped TOML key in setup-owned scope in " cfg \
                "; use unescaped keys before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        in_agents && $0 ~ ("^[[:space:]]*" managed_agent_key "[[:space:]]*(\\.|=)") {
            print "Unsupported managed agent role shape in " cfg \
                "; use canonical [agents.name] tables before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        in_features && $0 ~ ("^[[:space:]]*" managed_feature_key "[[:space:]]*\\.") {
            print "Unsupported managed feature descendant key in " cfg \
                "; use scalar feature values before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        in_agents && $0 ~ ("^[[:space:]]*" agent_scalar_key "[[:space:]]*\\.") {
            print "Unsupported max_threads descendant key in " cfg \
                "; use a scalar max_threads value before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        in_memories && $0 ~ ("^[[:space:]]*" memory_scalar_key "[[:space:]]*\\.") {
            print "Unsupported managed memories descendant key in " cfg \
                "; use scalar memory values before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        in_features && is_named_assignment($0, "multi_agent") {
            feature_multi_agent_count += 1
            if (feature_multi_agent_count > 1 || !is_boolean_assignment($0, "multi_agent")) {
                print "multi_agent must be one explicit boolean value in " cfg > "/dev/stderr"
                fatal = 1
                exit 64
            }
        }

        in_features && is_named_assignment($0, "default_mode_request_user_input") {
            feature_request_count += 1
            if (feature_request_count > 1 || \
                !is_boolean_assignment($0, "default_mode_request_user_input")) {
                print "default_mode_request_user_input must be one explicit boolean value in " \
                    cfg > "/dev/stderr"
                fatal = 1
                exit 64
            }
        }

        in_agents && is_named_assignment($0, "max_threads") {
            max_threads_count += 1
            if (max_threads_count > 1 || !is_positive_integer_assignment($0, "max_threads")) {
                print "max_threads must be one positive integer value in " cfg > "/dev/stderr"
                fatal = 1
                exit 64
            }
        }

        in_memories && is_named_assignment($0, "no_memories_if_mcp_or_web_search") {
            memory_flag_count += 1
            if (memory_flag_count > 1 || \
                !is_boolean_assignment($0, "no_memories_if_mcp_or_web_search")) {
                print "no_memories_if_mcp_or_web_search must be one boolean value in " \
                    cfg > "/dev/stderr"
                fatal = 1
                exit 64
            }
        }

        at_root && $0 ~ ("^[[:space:]]*" notify_key "[[:space:]]*\\.") {
            print "Unsupported dotted notify shape in " cfg \
                "; use a root notify array before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        at_root && is_named_assignment($0, "notify") {
            notify_assignment_count += 1
            if (notify_assignment_count > 1 || !is_string_array_assignment($0, "notify")) {
                print "notify must be one root string-array value in " cfg > "/dev/stderr"
                fatal = 1
                exit 64
            }
        }

        at_root && $0 ~ ("^[[:space:]]*" feature_key "[[:space:]]*(\\.|=)") {
            print "Unsupported top-level features shape in " cfg \
                "; use a [features] table before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        at_root && $0 ~ ("^[[:space:]]*" agents_key "[[:space:]]*(\\.|=)") {
            print "Unsupported top-level agents shape in " cfg \
                "; use canonical [agents] tables before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        at_root && $0 ~ ("^[[:space:]]*" memories_key "[[:space:]]*(\\.|=)") {
            print "Unsupported top-level memories shape in " cfg \
                "; use a canonical [memories] table before running setup" > "/dev/stderr"
            fatal = 1
            exit 64
        }

        starts_multiline_array($0) {
            multiline_array_requires_strings = at_root && is_named_assignment($0, "notify")
            in_multiline_array = 1
            next
        }

        END {
            if (!fatal && in_multiline_array) {
                print "Unterminated multiline TOML array in " cfg \
                    "; preserve it manually before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }
            if (!fatal && in_notify && !finish_notify()) {
                exit 64
            }
        }
    ' "$cfg"
}

migrate_legacy_notify_config() {
    local cfg="$1"
    local backup_root="$2"
    local preflight_only="${3:-0}"
    local write_path
    local tmp
    local marker
    local legacy_notify_setup
    local legacy_notify_template
    local legacy_notify_comment

    write_path="$(resolve_config_write_path "$cfg")"
    # These are historical literals. Never evaluate the command substitution in
    # the template value while constructing the matcher.
    legacy_notify_setup='after_agent = "echo '\''[HARNESS-LEARNING] Session completed'\'' >> .claude/state/session-log.txt"'
    # shellcheck disable=SC2016
    legacy_notify_template='after_agent = "mkdir -p .claude/state && echo \"[HARNESS-LEARNING] $(date -u +%Y-%m-%dT%H:%M:%SZ) Session completed\" >> .claude/state/session-log.txt"'
    legacy_notify_comment='# Session end notification: log to harness state + codex memories (0.110.0: ~/.codex/memories/ auto-writable)'

    tmp="$(mktemp "${write_path}.tmp.XXXXXX")"
    marker="${tmp}.removed"
    if ! LEGACY_NOTIFY_SETUP="$legacy_notify_setup" \
        LEGACY_NOTIFY_TEMPLATE="$legacy_notify_template" \
        LEGACY_NOTIFY_COMMENT="$legacy_notify_comment" \
        awk -v cfg="$write_path" -v marker="$marker" '
            BEGIN {
                at_root = 1
                single_quote = sprintf("%c", 39)
                notify_key = "(notify|\"notify\"|" single_quote "notify" single_quote ")"
                basic_string = "\"([^\"\\\\]|\\\\.)*\""
                literal_string = single_quote "[^" single_quote "]*" single_quote
                notify_string = "(" basic_string "|" literal_string ")"
                notify_inline_array = "^\\[[[:space:]]*(" notify_string \
                    "([[:space:]]*,[[:space:]]*" notify_string ")*[[:space:]]*,?)?" \
                    "[[:space:]]*\\][[:space:]]*(#.*)?$"
                notify_multiline_element = "^[[:space:]]*" notify_string \
                    "[[:space:]]*,[[:space:]]*(#.*)?$"
            }

            function fail(message) {
                print message " in " cfg \
                    "; preserve the config manually before running setup" > "/dev/stderr"
                fatal = 1
                exit 64
            }

            function finish_notify(signature) {
                signature = notify_signature
                in_notify = 0
                notify_signature = ""
                if (signature == ENVIRON["LEGACY_NOTIFY_SETUP"] || \
                    signature == ENVIRON["LEGACY_NOTIFY_COMMENT"] "\n" \
                        ENVIRON["LEGACY_NOTIFY_TEMPLATE"]) {
                    removed = 1
                    return 1
                }
                fail("Unsupported custom [notify] table")
                return 0
            }

            function is_root_notify_table(line) {
                return line ~ /^[[:space:]]*\[notify\][[:space:]]*$/
            }

            function is_notify_descendant_table(line) {
                return line ~ ("^[[:space:]]*\\[\\[?[[:space:]]*" notify_key \
                    "([[:space:]]*\\.|[[:space:]]*\\])")
            }

            function is_root_notify_assignment(line, rhs) {
                if (line !~ ("^[[:space:]]*" notify_key "[[:space:]]*=")) {
                    return 0
                }
                rhs = line
                sub(/^[^=]*=[[:space:]]*/, "", rhs)
                if (rhs ~ notify_inline_array) {
                    return 1
                }
                if (rhs ~ /^\[[[:space:]]*$/) {
                    in_notify_array = 1
                    return 1
                }
                fail("Unsupported custom or ambiguous notify value")
                return 0
            }

            function append_notify_line(line) {
                if (notify_signature == "") {
                    notify_signature = line
                } else {
                    notify_signature = notify_signature "\n" line
                }
            }

            in_notify_array {
                if ($0 ~ /^[[:space:]]*\][[:space:]]*(#.*)?$/) {
                    print
                    in_notify_array = 0
                    next
                }
                if ($0 ~ /^[[:space:]]*(#|$)/) {
                    print
                    next
                }
                if ($0 !~ notify_multiline_element) {
                    fail("notify multiline array elements must be strings")
                }
                print
                next
            }

            in_notify {
                if ($0 ~ /^[[:space:]]*\[/) {
                    if (!finish_notify()) {
                        exit 64
                    }
                    if (is_root_notify_table($0)) {
                        if (notify_seen) {
                            fail("Duplicate [notify] table")
                        }
                        notify_seen = 1
                        in_notify = 1
                        next
                    }
                    if (is_notify_descendant_table($0)) {
                        fail("Unsupported custom or ambiguous [notify] table")
                    }
                    at_root = 0
                    print
                    next
                }
                if ($0 ~ /^[[:space:]]*$/) {
                    next
                }
                append_notify_line($0)
                next
            }

            is_root_notify_table($0) {
                if (notify_seen) {
                    fail("Duplicate [notify] table")
                }
                notify_seen = 1
                in_notify = 1
                next
            }

            is_notify_descendant_table($0) {
                fail("Unsupported custom or ambiguous [notify] table")
            }

            at_root && $0 ~ ("^[[:space:]]*" notify_key "[[:space:]]*\\.") {
                fail("Unsupported dotted notify shape")
            }

            at_root && is_root_notify_assignment($0) {
                print
                next
            }

            $0 ~ /^[[:space:]]*\[/ {
                at_root = 0
                print
                next
            }

            { print }

            END {
                if (fatal) {
                    exit 64
                }
                if (in_notify && !finish_notify()) {
                    exit 64
                }
                if (in_notify_array) {
                    print "Unterminated multiline notify array in " cfg \
                        "; preserve the config manually before running setup" > "/dev/stderr"
                    exit 64
                }
                if (removed) {
                    print "removed" > marker
                }
            }
        ' "$write_path" > "$tmp"; then
        rm -f "$tmp"
        rm -f "$marker"
        return 1
    fi

    if [ ! -s "$marker" ]; then
        rm -f "$tmp"
        rm -f "$marker"
        return 0
    fi
    rm -f "$marker"

    if [ "$preflight_only" -eq 1 ]; then
        rm -f "$tmp"
        return 0
    fi

    if ! snapshot_config_once "$cfg" "$backup_root"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$write_path"; then
        rm -f "$tmp"
        return 1
    fi
}

merge_codex_config_defaults() {
    local cfg="$1"
    local backup_root="$2"
    local write_path="$cfg"
    local tmp

    if [ -L "$cfg" ]; then
        write_path="$(resolve_config_write_path "$cfg")"
    fi

    validate_config_merge_shape "$write_path"

    tmp="$(mktemp "${write_path}.tmp.XXXXXX")"
    if ! cp -p "$write_path" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    # Read the file twice: first collect feature keys, then insert only missing
    # defaults immediately after the existing table header.
    if ! awk '
        BEGIN {
            single_quote = sprintf("%c", 39)
        }

        function is_table(line) {
            return line ~ /^[[:space:]]*\[/
        }

        function is_named_table(line, name, body) {
            if (line !~ /^[[:space:]]*\[[^][]+\][[:space:]]*(#.*)?$/) {
                return 0
            }
            body = line
            sub(/^[[:space:]]*\[[[:space:]]*/, "", body)
            sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", body)
            return body == name || body == "\"" name "\"" || \
                body == single_quote name single_quote
        }

        function is_features_table(line) {
            return is_named_table(line, "features")
        }

        function is_named_assignment(line, name, pattern) {
            pattern = "^[[:space:]]*(" name "|\"" name "\"|" \
                single_quote name single_quote ")[[:space:]]*="
            return line ~ pattern
        }

        FNR == NR {
            if (is_table($0)) {
                in_features = is_features_table($0)
                if (in_features) {
                    features_seen = 1
                }
            } else if (in_features) {
                if (is_named_assignment($0, "multi_agent")) {
                    multi_agent_seen = 1
                }
                if (is_named_assignment($0, "default_mode_request_user_input")) {
                    request_user_input_seen = 1
                }
            }
            next
        }

        {
            if (is_named_table($0, "notify")) {
                skip_notify = 1
                next
            }
            if (skip_notify) {
                if (!is_table($0)) {
                    next
                }
                skip_notify = 0
            }
            print
            printed += 1
            if (!defaults_inserted && is_features_table($0)) {
                if (!multi_agent_seen) {
                    print "multi_agent = true"
                }
                if (!request_user_input_seen) {
                    print "default_mode_request_user_input = true"
                }
                defaults_inserted = 1
            }
        }

        END {
            if (!features_seen) {
                if (printed > 0) {
                    print ""
                }
                print "[features]"
                print "multi_agent = true"
                print "default_mode_request_user_input = true"
            }
        }
    ' "$write_path" "$write_path" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    if cmp -s "$write_path" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    if ! snapshot_config_once "$cfg" "$backup_root"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$write_path"; then
        rm -f "$tmp"
        return 1
    fi
}

merge_codex_agent_defaults() {
    local cfg="$1"
    local backup_root="$2"
    local write_path="$cfg"
    local tmp

    if [ -L "$cfg" ]; then
        if ! write_path="$(resolve_config_write_path "$cfg")"; then
            return 1
        fi
    fi

    validate_config_merge_shape "$write_path"

    tmp="$(mktemp "${write_path}.tmp.XXXXXX")"
    if ! awk '
        BEGIN {
            single_quote = sprintf("%c", 39)
        }

        function is_table(line) {
            return line ~ /^[[:space:]]*\[[^][]+\][[:space:]]*(#.*)?$/
        }

        function table_body(line, body) {
            body = line
            sub(/^[[:space:]]*\[[[:space:]]*/, "", body)
            sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", body)
            return body
        }

        function is_named_table(line, name, body) {
            if (!is_table(line)) {
                return 0
            }
            body = table_body(line)
            return body == name || body == "\"" name "\"" || \
                body == single_quote name single_quote
        }

        function is_role_table(line, role, body) {
            if (!is_table(line)) {
                return 0
            }
            body = table_body(line)
            return body == "agents." role
        }

        function is_any_agents_subtable(line) {
            return line ~ /^[[:space:]]*\[agents\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\][[:space:]]*(#.*)?$/
        }

        FNR == NR {
            if (is_named_table($0, "agents")) {
                agents_seen = 1
                in_agents = 1
                in_memories = 0
            } else if (is_named_table($0, "memories")) {
                memories_seen = 1
                in_agents = 0
                in_memories = 1
            } else if (is_table($0)) {
                in_agents = 0
                in_memories = 0
            }
            if (is_role_table($0, "implementer")) {
                implementer_seen = 1
            }
            if (is_role_table($0, "reviewer")) {
                reviewer_seen = 1
            }
            if (is_role_table($0, "task_worker")) {
                task_worker_seen = 1
            }
            if (is_role_table($0, "code_reviewer")) {
                code_reviewer_seen = 1
            }
            if (is_role_table($0, "codex_implementer")) {
                codex_implementer_seen = 1
            }
            if (is_role_table($0, "claude_implementer")) {
                claude_implementer_seen = 1
            }
            if (is_role_table($0, "claude_reviewer")) {
                claude_reviewer_seen = 1
            }
            if (is_role_table($0, "plan_analyst")) {
                plan_analyst_seen = 1
            }
            if (is_role_table($0, "plan_critic")) {
                plan_critic_seen = 1
            }
            if (in_agents && $0 ~ /^[[:space:]]*(max_threads|"max_threads"|'"'"'max_threads'"'"')[[:space:]]*=/) {
                max_threads_seen = 1
            }
            if (in_memories && $0 ~ /^[[:space:]]*(no_memories_if_mcp_or_web_search|"no_memories_if_mcp_or_web_search"|'"'"'no_memories_if_mcp_or_web_search'"'"')[[:space:]]*=/) {
                memory_flag_seen = 1
            }
            next
        }

        {
            if (!agents_seen && !agents_header_inserted && is_any_agents_subtable($0)) {
                print "[agents]"
                print "max_threads = 8"
                print ""
                agents_header_inserted = 1
                printed += 3
            }

            if (is_named_table($0, "agents")) {
                print
                printed += 1
                if (!agents_defaults_inserted && !max_threads_seen) {
                    print "max_threads = 8"
                    printed += 1
                }
                agents_defaults_inserted = 1
                in_agents = 1
                in_memories = 0
                next
            }
            if (is_named_table($0, "memories")) {
                print
                printed += 1
                if (!memories_defaults_inserted && !memory_flag_seen) {
                    print "no_memories_if_mcp_or_web_search = false"
                    printed += 1
                }
                memories_defaults_inserted = 1
                in_agents = 0
                in_memories = 1
                next
            }
            if (is_table($0)) {
                print
                printed += 1
                in_agents = 0
                in_memories = 0
                next
            }
            print
            printed += 1
        }

        END {
            if (!agents_seen && !agents_header_inserted) {
                if (printed > 0) {
                    print ""
                }
                print "[agents]"
                print "max_threads = 8"
                agents_header_inserted = 1
            }
            if (!implementer_seen) {
                print ""
                print "[agents.implementer]"
                print "description = \"Codex implementation worker for harness task execution\""
            }
            if (!reviewer_seen) {
                print ""
                print "[agents.reviewer]"
                print "description = \"Codex reviewer worker for harness review and retake loops\""
                print "sandbox = \"workspace-read-only\""
            }
            if (!task_worker_seen) {
                print ""
                print "[agents.task_worker]"
                print "description = \"Standard Breezing implementer (impl_mode: standard). Implements tasks, runs self-review, build, and tests.\""
            }
            if (!code_reviewer_seen) {
                print ""
                print "[agents.code_reviewer]"
                print "description = \"Breezing reviewer. Performs independent code review with harness-review 5-point assessment including AI Residuals. Issues APPROVE / REQUEST_CHANGES / REJECT / STOP. Read-only.\""
                print "sandbox = \"workspace-read-only\""
            }
            if (!codex_implementer_seen) {
                print ""
                print "[agents.codex_implementer]"
                print "description = \"Codex Breezing implementer (impl_mode: codex, used with --codex flag). Invokes Codex CLI, verifies AGENTS_SUMMARY, enforces Quality Gates.\""
            }
            if (!claude_implementer_seen) {
                print ""
                print "[agents.claude_implementer]"
                print "description = \"Claude CLI delegated implementation worker (used when --claude)\""
            }
            if (!claude_reviewer_seen) {
                print ""
                print "[agents.claude_reviewer]"
                print "description = \"Claude CLI delegated reviewer worker (used when --claude)\""
                print "sandbox = \"workspace-read-only\""
            }
            if (!plan_analyst_seen) {
                print ""
                print "[agents.plan_analyst]"
                print "description = \"Phase 0 planning analyst: analyzes task granularity, estimates owns files, proposes dependencies, and evaluates risk. Read-only access to codebase.\""
                print "sandbox = \"workspace-read-only\""
            }
            if (!plan_critic_seen) {
                print ""
                print "[agents.plan_critic]"
                print "description = \"Phase 0 plan critic: red-teaming review of task decomposition. Checks goal coverage, granularity, dependency accuracy, parallelism, and risk. Read-only access.\""
                print "sandbox = \"workspace-read-only\""
            }
            if (!memories_seen) {
                print ""
                print "[memories]"
                print "no_memories_if_mcp_or_web_search = false"
            }
        }
    ' "$write_path" "$write_path" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    if cmp -s "$write_path" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    if ! snapshot_config_once "$cfg" "$backup_root"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$write_path"; then
        rm -f "$tmp"
        return 1
    fi
}

preflight_backup_destination() {
    local backup_root="$1"
    local parent="$backup_root"
    local next
    local probe

    if [ -L "$backup_root" ] && [ ! -e "$backup_root" ]; then
        log_err "Backup destination is a broken symlink: $backup_root"
        return 1
    fi
    if [ -e "$backup_root" ] || [ -L "$backup_root" ]; then
        if [ ! -d "$backup_root" ]; then
            log_err "Backup destination is not a directory: $backup_root"
            return 1
        fi
        if ! probe="$(mktemp "$backup_root/.codex-setup-backup.XXXXXX")"; then
            log_err "Backup destination is not writable: $backup_root"
            return 1
        fi
        if ! rm -f "$probe"; then
            log_err "Backup destination could not remove its preflight probe: $backup_root"
            return 1
        fi
        return 0
    fi

    while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do
        next="$(dirname "$parent")"
        if [ "$next" = "$parent" ]; then
            break
        fi
        parent="$next"
    done
    if [ ! -d "$parent" ]; then
        log_err "Backup destination parent is not a directory: $parent"
        return 1
    fi
    if ! probe="$(mktemp "$parent/.codex-setup-backup.XXXXXX")"; then
        log_err "Backup destination parent is not writable: $parent"
        return 1
    fi
    if ! rm -f "$probe"; then
        log_err "Backup destination parent could not remove its preflight probe: $parent"
        return 1
    fi
}

preflight_existing_config() {
    local target_root="$1"
    local backup_root="$2"
    local cfg="$target_root/config.toml"
    local write_path

    if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
        return 0
    fi
    migrate_legacy_notify_config "$cfg" "$backup_root" 1 || return 1
    write_path="$(resolve_config_write_path "$cfg")"
    validate_config_merge_shape "$write_path"
}

resolve_target_root() {
    if [ "$TARGET_MODE" = "user" ]; then
        echo "$CODEX_HOME_DIR"
    else
        echo "$PROJECT_DIR/.codex"
    fi
}

resolve_backup_root() {
    local target_root="$1"
    if [ "$TARGET_MODE" = "user" ]; then
        echo "$CODEX_HOME_DIR/backups/setup-codex"
    else
        echo "$target_root/backups/setup-codex"
    fi
}

ensure_multi_agent_defaults() {
    local target_root="$1"
    local backup_root="$2"
    local cfg="$target_root/config.toml"

    CONFIG_BACKUP_CREATED=0

    mkdir -p "$target_root"

    if [ ! -f "$cfg" ]; then
        cat > "$cfg" <<'CFG'
# Codex Team Config (Codex CLI 0.110.0+)

[features]
multi_agent = true
default_mode_request_user_input = true

[agents]
max_threads = 8

[agents.implementer]
description = "Codex implementation worker for harness task execution"

[agents.reviewer]
description = "Codex reviewer worker for harness review and retake loops"
sandbox = "workspace-read-only"

[agents.task_worker]
description = "Standard Breezing implementer (impl_mode: standard). Implements tasks, runs self-review, build, and tests."

[agents.code_reviewer]
description = "Breezing reviewer. Performs independent code review with harness-review 5-point assessment including AI Residuals. Issues APPROVE / REQUEST_CHANGES / REJECT / STOP. Read-only."
sandbox = "workspace-read-only"

[agents.codex_implementer]
description = "Codex Breezing implementer (impl_mode: codex, used with --codex flag). Invokes Codex CLI, verifies AGENTS_SUMMARY, enforces Quality Gates."

[agents.claude_implementer]
description = "Claude CLI delegated implementation worker (used when --claude)"

[agents.claude_reviewer]
description = "Claude CLI delegated reviewer worker (used when --claude)"
sandbox = "workspace-read-only"

[agents.plan_analyst]
description = "Phase 0 planning analyst: analyzes task granularity, estimates owns files, proposes dependencies, and evaluates risk. Read-only access to codebase."
sandbox = "workspace-read-only"

[agents.plan_critic]
description = "Phase 0 plan critic: red-teaming review of task decomposition. Checks goal coverage, granularity, dependency accuracy, parallelism, and risk. Read-only access."
sandbox = "workspace-read-only"

[memories]
no_memories_if_mcp_or_web_search = false
CFG
        log_ok "Created $cfg with multi_agent + harness role defaults"
        return
    fi

    migrate_legacy_notify_config "$cfg" "$backup_root"
    merge_codex_config_defaults "$cfg" "$backup_root"
    merge_codex_agent_defaults "$cfg" "$backup_root"
    log_ok "Ensured feature and agent defaults and migrated exact legacy config in $cfg"
}

print_success() {
    local target_root="$1"
    local backup_root="$2"

    echo ""
    echo "============================================"
    echo "Harness for Codex CLI setup complete."
    echo "============================================"
    echo ""
    echo "Mode: $TARGET_MODE"
    echo "Target: $target_root"
    echo ""
    echo "Created/updated:"
    echo "  $target_root/skills/  - Harness skills"
    echo "  $target_root/rules/   - Guardrails"
    echo "  $backup_root/ - Setup backups (outside skill scan path)"
    if [ "$TARGET_MODE" = "project" ]; then
        echo "  $PROJECT_DIR/AGENTS.md - Project instructions"
    else
        echo "  (project AGENTS.md unchanged in user mode)"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Restart Codex"
    echo "  2. Use \$harness-plan / \$harness-work / \$breezing / \$harness-loop to invoke Harness workflows"
    echo ""
}

main() {
    parse_args "$@"

    echo ""
    log_info "Setting up Harness for Codex CLI"
    log_info "Mode: $TARGET_MODE"
    if [ "$TARGET_MODE" = "user" ]; then
        log_info "Target: $CODEX_HOME_DIR"
    else
        log_info "Target: $PROJECT_DIR/.codex"
    fi
    echo ""

    check_requirements
    clone_harness

    local target_root
    target_root="$(resolve_target_root)"
    local backup_root
    backup_root="$(resolve_backup_root "$target_root")"

    preflight_backup_destination "$backup_root"
    preflight_existing_config "$target_root" "$backup_root"

    cleanup_legacy_skill_entries "$target_root/skills" "$backup_root"
    cleanup_legacy_skill_name_duplicates "$TEMP_DIR/harness/codex/.codex/skills" "$target_root/skills" "$backup_root"
    cleanup_removed_harness_skill_entries "$TEMP_DIR/harness/codex/.codex/skills" "$target_root/skills" "$backup_root"
    sync_named_children "$TEMP_DIR/harness/codex/.codex/skills" "$target_root/skills" "Skills" "$backup_root"
    sync_named_children "$TEMP_DIR/harness/codex/.codex/rules" "$target_root/rules" "Rules" "$backup_root"
    sync_named_children "$TEMP_DIR/harness/codex/.codex/agents" "$target_root/agents" "Agents" "$backup_root"

    if [ "$TARGET_MODE" = "project" ]; then
        copy_project_agents "$backup_root"
    else
        log_info "User mode: project AGENTS.md is unchanged"
    fi

    ensure_multi_agent_defaults "$target_root" "$backup_root"
    print_success "$target_root" "$backup_root"
}

main "$@"
