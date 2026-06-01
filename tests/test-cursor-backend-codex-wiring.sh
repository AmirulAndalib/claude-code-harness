#!/usr/bin/env bash
# Static CONTRACT test for TASK 83.9.
# Asserts that the Codex-native execution skills wire in the execution-backend
# switch (HARNESS_IMPL_BACKEND) so that driving the harness FROM the Codex host
# also honors the resolved backend. Pure grep — no network, no cursor-agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_SKILL="${ROOT}/skills-codex/harness-work/SKILL.md"
SHARED_WORK_SKILL="${ROOT}/skills/harness-work/SKILL.md"
BREEZING_SKILL="${ROOT}/skills-codex/breezing/SKILL.md"
SHARED_BREEZING_SKILL="${ROOT}/skills/breezing/SKILL.md"
REVIEW_SKILL="${ROOT}/codex/.codex/skills/harness-review/SKILL.md"
REVIEW_CURSOR_REF="${ROOT}/codex/.codex/skills/harness-review/references/cursor-review.md"
CURSOR_DO_SKILL="${ROOT}/codex/.codex/skills/cursor-do/SKILL.md"
CURSOR_ASK_SKILL="${ROOT}/codex/.codex/skills/cursor-ask/SKILL.md"
CURSOR_SETUP_SKILL="${ROOT}/codex/.codex/skills/cursor-setup/SKILL.md"
CURSOR_REVIEW_SKILL="${ROOT}/codex/.codex/skills/cursor-review/SKILL.md"
CURSOR_RESCUE_SKILL="${ROOT}/codex/.codex/skills/cursor-rescue/SKILL.md"
CODEX_MANIFEST="${ROOT}/.codex-plugin/plugin.json"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$WORK_SKILL" ] || fail "missing ${WORK_SKILL}"
[ -f "$SHARED_WORK_SKILL" ] || fail "missing ${SHARED_WORK_SKILL}"
[ -f "$BREEZING_SKILL" ] || fail "missing ${BREEZING_SKILL}"
[ -f "$SHARED_BREEZING_SKILL" ] || fail "missing ${SHARED_BREEZING_SKILL}"
[ -f "$REVIEW_SKILL" ] || fail "missing ${REVIEW_SKILL}"
[ -f "$REVIEW_CURSOR_REF" ] || fail "missing ${REVIEW_CURSOR_REF}"
[ -f "$CURSOR_DO_SKILL" ] || fail "missing ${CURSOR_DO_SKILL}"
[ -f "$CURSOR_ASK_SKILL" ] || fail "missing ${CURSOR_ASK_SKILL}"
[ -f "$CURSOR_SETUP_SKILL" ] || fail "missing ${CURSOR_SETUP_SKILL}"
[ -f "$CURSOR_REVIEW_SKILL" ] || fail "missing ${CURSOR_REVIEW_SKILL}"
[ -f "$CURSOR_RESCUE_SKILL" ] || fail "missing ${CURSOR_RESCUE_SKILL}"
[ -f "$CODEX_MANIFEST" ] || fail "missing ${CODEX_MANIFEST}"

# 1. harness-work (codex) must declare the backend section + resolver.
grep -q "Execution Backend Selection" "$WORK_SKILL" \
  || fail "harness-work: missing 'Execution Backend Selection' section"
grep -q "resolve-impl-backend.sh" "$WORK_SKILL" \
  || fail "harness-work: missing resolve-impl-backend.sh resolver"
grep -q "Backend-resolved executor path (Solo / Parallel / Breezing)" "$WORK_SKILL" \
  || fail "harness-work: missing shared Solo/Parallel/Breezing executor resolver section"
grep -q "Backend-resolved executor path (Solo / Parallel / Breezing)" "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: missing shared Solo/Parallel/Breezing executor resolver section"
grep -q 'harness-work 3 --cursor' "$WORK_SKILL" \
  || fail "harness-work: Solo cursor invocation must be called out explicitly"
grep -q 'local Read/Write/Edit/Bash に fall through してはいけない' "$WORK_SKILL" \
  || fail "harness-work: Solo cursor default must not fall through to local implementation"
grep -Fq 'if topology in ["solo", "parallel"] and backend in ["cursor", "codex"]:' "$WORK_SKILL" \
  || fail "harness-work: Solo/Parallel cursor/codex backend must branch to companion worktree path"
grep -q "enter_non_claude_companion_review_loop(worker_result)" "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: Solo/Parallel companion result must enter non-Claude companion review loop"
grep -q "Do not use the Worker-only SendMessage/self_review loop for cursor/codex" "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: companion-result.v1 must avoid Worker-only SendMessage/self_review loop"
grep -q 'git("-C", worker_result.worktreePath, "diff", "{worker_result.baseCommit}..HEAD")' "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: companion review loop must review the full baseCommit..HEAD range"
grep -q 'git cherry-pick --no-commit {worker_result.baseCommit}..{worker_result.commit}' "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: companion approve path must cherry-pick the full reviewed range"
grep -q "各 task の実装 executor は Backend-resolved executor path に従う" "$WORK_SKILL" \
  || fail "harness-work: Parallel mode must use the same backend resolver per task"

# 2. cursor delegation command via the companion wrapper.
grep -q "cursor-companion.sh" "$WORK_SKILL" \
  || fail "harness-work: missing cursor-companion.sh delegation"

# 3. role-scoped: reviewer/advisor stay on the brain (claude/Opus).
grep -Eq "Reviewer.*(claude|Opus|brain)" "$WORK_SKILL" \
  || fail "harness-work: missing role-scoped reviewer-stays-on-claude line"

# 4. breezing (codex) references the backend selection SSOT.
grep -q "Execution Backend" "$BREEZING_SKILL" \
  || fail "breezing: missing reference to Execution Backend selection"
grep -q "HARNESS_IMPL_BACKEND" "$BREEZING_SKILL" \
  || fail "breezing: missing HARNESS_IMPL_BACKEND reference"
grep -q "resolve-impl-backend.sh\"" "$BREEZING_SKILL" \
  || fail "breezing: missing resolver call"
grep -q "explicit_backend_value" "$BREEZING_SKILL" \
  || fail "breezing: explicit --backend <value> must be forwarded to resolver"
grep -q -- "--backend cursor" "$BREEZING_SKILL" \
  || fail "breezing: missing explicit cursor backend invocation"
grep -q "cursor-companion.sh" "$BREEZING_SKILL" \
  || fail "breezing: missing cursor companion delegation"
grep -q 'bash "${HARNESS_PLUGIN_ROOT}/scripts/cursor-companion.sh" task --write' "$SHARED_BREEZING_SKILL" \
  || fail "shared breezing: cursor fast path must call the bundled cursor companion"
grep -q 'bash "${HARNESS_PLUGIN_ROOT}/scripts/resolve-impl-backend.sh"' "$SHARED_BREEZING_SKILL" \
  || fail "shared breezing: cursor fast path must resolve backend through the bundled helper"
if grep -q 'bash scripts/cursor-companion.sh' "$SHARED_BREEZING_SKILL" \
  || grep -q '`scripts/resolve-impl-backend.sh`' "$SHARED_BREEZING_SKILL"; then
  fail "shared breezing: default cursor path must not call target-repo relative helper scripts"
fi
grep -q "companion-result.v1" "$BREEZING_SKILL" \
  || fail "breezing: companion stdout must be normalized to worker_result shape"
grep -q 'files_changed: git("-C", worktree_path, "diff", "--name-only", "{TASK_BASE_REF}..HEAD")' "$BREEZING_SKILL" \
  || fail "breezing: companion-result.v1 must preserve files_changed"
grep -q 'status", "--porcelain") != ""' "$BREEZING_SKILL" \
  || fail "breezing: cursor backend must commit dirty Cursor output before no-commit rejection"
grep -q 'cursor-composer@local' "$BREEZING_SKILL" \
  || fail "breezing: cursor dirty output auto-commit must use a deterministic local identity"
grep -q 'cursor: breezing review fix' "$BREEZING_SKILL" \
  || fail "breezing: cursor retry dirty output must be folded into a review-fix commit"
if grep -q 'latest_commit == TASK_BASE_REF and git("-C", worktree_path, "status", "--porcelain") != ""' "$BREEZING_SKILL"; then
  fail "breezing: cursor dirty output must be folded in even when Cursor also created a commit"
fi
if grep -q 'latest_commit == previous_commit and git("-C", worktree_path, "status", "--porcelain") != ""' "$BREEZING_SKILL"; then
  fail "breezing: cursor dirty retry output must be folded in even when Cursor also created a commit"
fi
grep -q "retry produced no new commit" "$BREEZING_SKILL" \
  || fail "breezing: non-claude retry loop must rerun companion and detect no-progress"
grep -q 'cherry-pick --no-commit {TASK_BASE_REF}..{commit_hash}' "$BREEZING_SKILL" \
  || fail "breezing: approve path must cherry-pick the full companion commit range"
if grep -q -- "--default cursor" "$BREEZING_SKILL" "$WORK_SKILL"; then
  fail "Codex shipped skills must not hard-code cursor as call-site default"
fi
grep -q "未設定時は claude" "$WORK_SKILL" \
  || fail "harness-work: shipped fallback must remain claude"
grep -q "explicit_backend_value" "$WORK_SKILL" \
  || fail "harness-work: explicit --backend <value> must be forwarded to resolver"
grep -q "git worktree add" "$WORK_SKILL" \
  || fail "harness-work: non-claude backend must create an isolated worktree"
grep -q "companion-result.v1" "$WORK_SKILL" \
  || fail "harness-work: companion stdout must be normalized to worker_result shape"
grep -q "baseCommit: BASE_REF" "$WORK_SKILL" \
  || fail "harness-work: companion result must preserve the base commit for retry ranges"
grep -q 'status", "--porcelain") != ""' "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: cursor backend must commit dirty Cursor output before no-commit rejection"
grep -q 'cursor-composer@local' "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: cursor dirty output auto-commit must use a deterministic local identity"
if grep -q 'latest_commit == BASE_REF and git("-C", worktree_path, "status", "--porcelain") != ""' "$SHARED_WORK_SKILL"; then
  fail "shared harness-work: cursor dirty output must be folded in even when Cursor also created a commit"
fi
if grep -q 'latest_commit == previous_commit and git("-C", worker_result.worktreePath, "status", "--porcelain") != ""' "$SHARED_WORK_SKILL"; then
  fail "shared harness-work: cursor dirty retry output must be folded in even when Cursor also created a commit"
fi
grep -q 'status", "--porcelain") != ""' "$WORK_SKILL" \
  || fail "harness-work: Codex-host cursor backend must commit dirty Cursor output before no-commit rejection"
grep -q 'cursor-composer@local' "$WORK_SKILL" \
  || fail "harness-work: Codex-host cursor dirty output auto-commit must use a deterministic local identity"
if grep -q 'latest_commit == BASE_REF and git("-C", worktree_path, "status", "--porcelain") != ""' "$WORK_SKILL"; then
  fail "harness-work: Codex-host cursor dirty output must be folded in even when Cursor also created a commit"
fi
grep -qi "create exactly one git commit" "$WORK_SKILL" \
  || fail "harness-work: companion prompt must require a commit before return"
grep -q "retry produced no new commit" "$WORK_SKILL" \
  || fail "harness-work: non-claude retry loop must detect no-progress commits"
range_review_count="$(grep -F -c 'git("-C", worker_result.worktreePath, "diff", "{worker_result.baseCommit}..HEAD")' "$WORK_SKILL")"
[ "$range_review_count" -ge 2 ] \
  || fail "harness-work: initial and retry reviews must cover the full companion commit range"
grep -q 'cherry-pick --no-commit {worker_result.baseCommit}..{latest_commit}' "$WORK_SKILL" \
  || fail "harness-work: approve path must cherry-pick the full companion commit range"

# 5. Default ON must affect review as an advisory cursor second-opinion, while
# primary verdict remains on the brain.
grep -q "resolver result.*cursor" "$REVIEW_SKILL" \
  || fail "harness-review: missing resolver-result cursor trigger"
grep -q 'code+cursor-second-opinion' "$REVIEW_SKILL" \
  || fail "harness-review: cursor default must be additive to the core code review mode"
grep -q 'references/code-review.md`, `references/governance.md`, `references/cursor-review.md`, `references/dual-review.md' "$REVIEW_SKILL" \
  || fail "harness-review: cursor second-opinion must keep core code/governance references"
grep -q 'core review gates (`references/code-review.md`, `references/governance.md`) は必ず先に読み' "$REVIEW_SKILL" \
  || fail "harness-review: cursor default must not replace core review gates"
grep -q "resolve-impl-backend.sh\" --role reviewer" "$REVIEW_SKILL" \
  || fail "harness-review: missing resolver call for default-ON review"
grep -q 'HARNESS_PLUGIN_ROOT="${HARNESS_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"' "$REVIEW_SKILL" \
  || fail "harness-review: resolver must derive HARNESS_PLUGIN_ROOT before use"
grep -q 'resolved_backend="claude"' "$REVIEW_SKILL" \
  || fail "harness-review: missing fail-open claude fallback when resolver is unavailable"
grep -q '明示 mode words.*先に確定' "$REVIEW_SKILL" \
  || fail "harness-review: explicit plan/scope/full modes must be honored before cursor defaulting"
grep -q 'plan.*scope.*resolver result より優先' "$REVIEW_SKILL" \
  || fail "harness-review: cursor default must not replace plan/scope references"
grep -q "primary verdict.*Opus" "$REVIEW_CURSOR_REF" \
  || fail "cursor-review: primary verdict must remain Opus/brain"
grep -q 'resolve-impl-backend.sh" --role reviewer' "$REVIEW_CURSOR_REF" \
  || fail "cursor-review: default ON must use resolver, not env-only"
grep -q 'HARNESS_PLUGIN_ROOT="${HARNESS_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"' "$REVIEW_CURSOR_REF" \
  || fail "cursor-review: must derive HARNESS_PLUGIN_ROOT before helper use"
grep -q 'bash "${HARNESS_PLUGIN_ROOT}/scripts/cursor-companion.sh" task' "$REVIEW_CURSOR_REF" \
  || fail "cursor-review: read-only delegation must call bundled cursor companion"
if grep -q 'bash scripts/cursor-companion.sh' "$REVIEW_CURSOR_REF"; then
  fail "cursor-review: must not call target-repo relative cursor companion"
fi

# 6. Codex distribution must expose the Cursor namespace commands in user-facing
# prompts/descriptions, while shipped skill frontmatter stays validator-safe
# lowercase hyphen. The hyphenated ids are packaging ids, not advertised aliases.
grep -q "^name: cursor-do$" "$CURSOR_DO_SKILL" \
  || fail "cursor:do: shipped skill frontmatter must use validator-safe cursor-do id"
grep -q "^name: cursor-ask$" "$CURSOR_ASK_SKILL" \
  || fail "cursor:ask: shipped skill frontmatter must use validator-safe cursor-ask id"
grep -q "^name: cursor-setup$" "$CURSOR_SETUP_SKILL" \
  || fail "cursor:setup: shipped skill frontmatter must use validator-safe cursor-setup id"
grep -q "^name: cursor-review$" "$CURSOR_REVIEW_SKILL" \
  || fail "cursor:review: shipped skill frontmatter must use validator-safe cursor-review id"
grep -q "^name: cursor-rescue$" "$CURSOR_RESCUE_SKILL" \
  || fail "cursor:rescue: shipped skill frontmatter must use validator-safe cursor-rescue id"
grep -q "cursor:do" "$CURSOR_DO_SKILL" \
  || fail "cursor:do: user-facing namespace must remain documented in the shipped skill"
grep -q "cursor:ask" "$CURSOR_ASK_SKILL" \
  || fail "cursor:ask: user-facing namespace must remain documented in the shipped skill"
grep -q "cursor:setup" "$CURSOR_SETUP_SKILL" \
  || fail "cursor:setup: user-facing namespace must remain documented in the shipped skill"
grep -q "cursor:review" "$CURSOR_REVIEW_SKILL" \
  || fail "cursor:review: user-facing namespace must remain documented in the shipped skill"
grep -q "cursor:rescue" "$CURSOR_RESCUE_SKILL" \
  || fail "cursor:rescue: user-facing namespace must remain documented in the shipped skill"
grep -q 'HARNESS_PLUGIN_ROOT="${HARNESS_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: must derive HARNESS_PLUGIN_ROOT before helper use"
grep -q '.codex-plugin/plugin.json' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: plugin root validation must accept the generated Codex package manifest"
grep -q '.cursor-plugin/plugin.json' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: plugin root validation must accept the generated Cursor package manifest"
cursor_do_root_count="$(grep -c 'HARNESS_PLUGIN_ROOT="${HARNESS_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"' "$CURSOR_DO_SKILL")"
[ "$cursor_do_root_count" -ge 2 ] \
  || fail "cursor:do: delegate step must re-derive HARNESS_PLUGIN_ROOT in its own shell"
grep -q 'HARNESS_PLUGIN_ROOT="${HARNESS_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"' "$CURSOR_ASK_SKILL" \
  || fail "cursor:ask: must derive HARNESS_PLUGIN_ROOT before helper use"
grep -q '.codex-plugin/plugin.json' "$CURSOR_ASK_SKILL" \
  || fail "cursor:ask: plugin root validation must accept the generated Codex package manifest"
grep -q '.cursor-plugin/plugin.json' "$CURSOR_ASK_SKILL" \
  || fail "cursor:ask: plugin root validation must accept the generated Cursor package manifest"
grep -q 'bash "${HARNESS_PLUGIN_ROOT}/scripts/cursor-companion.sh" task' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: cursor companion must be called through HARNESS_PLUGIN_ROOT"
grep -q 'bash "${HARNESS_PLUGIN_ROOT}/scripts/cursor-companion.sh" task' "$CURSOR_ASK_SKILL" \
  || fail "cursor:ask: cursor companion must be called through HARNESS_PLUGIN_ROOT"
grep -q 'git rev-list --count "${BASE_REF}..HEAD"' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: must count the reviewed range before cherry-pick"
grep -q "expected exactly one" "$CURSOR_DO_SKILL" \
  || fail "cursor:do: must reject multi-commit Cursor results before target mutation"
grep -q 'commit --amend --no-edit --no-verify' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: must amend dirty Cursor output into an existing Cursor commit before counting commits"
grep -q '==AUTO_AMENDED==' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: dirty commit-plus-worktree output must be visibly folded before cherry-pick"
grep -q 'HOME/.local/bin/cursor-agent' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: precheck must honor cursor-companion fallback cursor-agent path"
grep -q '\[ ! -f "${WT_DIR}/tests/test-support-claim-wording.sh" \] || (cd "${WT_DIR}" && bash tests/test-support-claim-wording.sh)' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: support wording gate must run inside the candidate worktree"
grep -q '\[ ! -f "${WT_DIR}/scripts/ci/check-consistency.sh" \] || (cd "${WT_DIR}" && bash scripts/ci/check-consistency.sh)' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: consistency gate must run inside the candidate worktree"
grep -q '\[ ! -f "${WT_DIR}/tests/validate-plugin.sh" \] || (cd "${WT_DIR}" && bash tests/validate-plugin.sh)' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: plugin validation gate must run inside the candidate worktree"
grep -q 'git commit --amend --no-edit' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: Plans.md marker update must be committed into the cherry-pick commit"
grep -q "Plans.md has pre-existing local edits" "$CURSOR_DO_SKILL" \
  || fail "cursor:do: must refuse to amend pre-existing Plans.md edits into the cursor commit"
grep -q 'git diff --cached --quiet -- Plans.md' "$CURSOR_DO_SKILL" \
  || fail "cursor:do: must check staged Plans.md edits before marker amend"
plans_guard_line="$(grep -n 'Plans.md has pre-existing local edits' "$CURSOR_DO_SKILL" | head -1 | cut -d: -f1)"
cherry_pick_line="$(grep -n 'git cherry-pick "${SHA}"' "$CURSOR_DO_SKILL" | head -1 | cut -d: -f1)"
[ "$plans_guard_line" -lt "$cherry_pick_line" ] \
  || fail "cursor:do: Plans.md pre-existing edit guard must run before cherry-pick mutates the target branch"
grep -q "marker-only diff" "$CURSOR_DO_SKILL" \
  || fail "cursor:do: amend block must be scoped to the marker-only diff"
if grep -q 'test-support-claim-wording.sh 2>/dev/null || true\|check-consistency.sh 2>/dev/null || true\|validate-plugin.sh 2>/dev/null || true' "$CURSOR_DO_SKILL"; then
  fail "cursor:do: contract-grep gates must not discard failures"
fi
if grep -q 'for SHA in ${COMMITS}' "$CURSOR_DO_SKILL"; then
  fail "cursor:do: must not cherry-pick Cursor commits one SHA at a time"
fi
if grep -q 'HARNESS_PLUGIN_ROOT:-\.' "$CURSOR_DO_SKILL" "$CURSOR_ASK_SKILL"; then
  fail "cursor:do/ask: helper calls must not fall back to target-repo relative scripts"
fi
grep -q 'bash "${HARNESS_PLUGIN_ROOT}/scripts/setup-cursor.sh" --check' "$CURSOR_SETUP_SKILL" \
  || fail "cursor:setup: setup script must be called through HARNESS_PLUGIN_ROOT"
grep -q 'HOME/.local/bin/cursor-agent' "$CURSOR_SETUP_SKILL" \
  || fail "cursor:setup: check must honor cursor-companion fallback cursor-agent path"
if grep -q '^   cursor-agent --version$' "$CURSOR_SETUP_SKILL"; then
  fail "cursor:setup: check must not call cursor-agent directly without fallback resolution"
fi
grep -q "run exactly one matching unset command" "$CURSOR_SETUP_SKILL" \
  || fail "cursor:setup: unset must choose exactly one user/project scope"
grep -q 'probe/scripts' "$CURSOR_SETUP_SKILL" \
  || fail "cursor:setup: CLAUDE_SKILL_DIR fallback must walk up to the real plugin root"
grep -q 'HARNESS_PLUGIN_ROOT="${HARNESS_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"' "$CURSOR_REVIEW_SKILL" \
  || fail "cursor:review: must derive HARNESS_PLUGIN_ROOT before helper use"
grep -q 'HARNESS_PLUGIN_ROOT="${HARNESS_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"' "$CURSOR_RESCUE_SKILL" \
  || fail "cursor:rescue: must derive HARNESS_PLUGIN_ROOT before helper use"
grep -q 'bash "${HARNESS_PLUGIN_ROOT}/scripts/setup-cursor.sh" --check' "$CURSOR_RESCUE_SKILL" \
  || fail "cursor:rescue: setup script must be called through HARNESS_PLUGIN_ROOT"
grep -q 'HOME/.local/bin/cursor-agent' "$CURSOR_RESCUE_SKILL" \
  || fail "cursor:rescue: diagnostics must honor cursor-companion fallback cursor-agent path"
if grep -q '^cursor-agent --version$' "$CURSOR_RESCUE_SKILL"; then
  fail "cursor:rescue: diagnostics must not call cursor-agent directly without fallback resolution"
fi
if grep -q 'CLAUDE_SKILL_DIR}/../..' "$CURSOR_DO_SKILL" "$CURSOR_ASK_SKILL" "$CURSOR_SETUP_SKILL" "$CURSOR_REVIEW_SKILL" "$CURSOR_RESCUE_SKILL" "$REVIEW_SKILL" "$WORK_SKILL" "$SHARED_WORK_SKILL"; then
  fail "CLAUDE_SKILL_DIR fallback must not assume a fixed two-level skill mirror depth"
fi
grep -q 'DIFF_TEXT="$(git diff "${BASE_REF}..HEAD")"' "$CURSOR_REVIEW_SKILL" \
  || fail "cursor:review: must capture the selected diff text"
grep -q -- "--base=*" "$CURSOR_REVIEW_SKILL" \
  || fail "cursor:review: must parse --base=<ref> from arguments"
grep -q 'Diff:' "$CURSOR_REVIEW_SKILL" \
  || fail "cursor:review: must pass diff text into the Cursor prompt"
grep -Fq '"Use $cursor-do / $cursor-ask / $cursor-review / $cursor-setup / $cursor-rescue for Cursor delegation."' "$CODEX_MANIFEST" \
  || fail "Codex manifest: missing combined Cursor default prompt"
prompt_count="$(grep -F -c '"Use $' "$CODEX_MANIFEST")"
[ "$prompt_count" -le 3 ] \
  || fail "Codex manifest: defaultPrompt must stay within the surfaced 3-entry limit"
if grep -Fq '$cursor:do' "$CODEX_MANIFEST" || grep -Fq '$cursor:ask' "$CODEX_MANIFEST"; then
  fail "Codex manifest must use registered cursor-* skill names for name-based invocation"
fi

grep -q "HARNESS_CODEX_PRIMARY_ENV_STATE_FILE" "$WORK_SKILL" \
  || fail "harness-work: codex delegated worktrees need isolated primary-env guard state"
grep -q "HARNESS_CODEX_PRIMARY_ENV_STATE_FILE" "$BREEZING_SKILL" \
  || fail "breezing: codex delegated worktrees need isolated primary-env guard state"
grep -q -- '-C "$WORKTREE_PATH"' "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: Codex mode must run companion inside the isolated worktree"
grep -q -- 'task --write -C {worktree_path}' "$WORK_SKILL" \
  || fail "harness-work: Codex delegated worktree must use a companion-supported cwd flag"
grep -q -- 'task --write -C {worktree_path}' "$BREEZING_SKILL" \
  || fail "breezing: Codex delegated worktree must use a companion-supported cwd flag"
grep -q -- '--cwd)' "${ROOT}/scripts/codex-companion.sh" \
  || fail "codex-companion: structured exec must handle --cwd alias explicitly"
grep -q 'passthrough+=(--cd "${2:-}")' "${ROOT}/scripts/codex-companion.sh" \
  || fail "codex-companion: structured exec must normalize --cwd to codex exec --cd"
grep -Fq -- '--cwd=*|--cd=*' "${ROOT}/scripts/codex-companion.sh" \
  || fail "codex-companion: effort parser must handle inline --cwd/--cd values without consuming the prompt"
grep -q 'WORKTREE_HEAD="$(git -C "$WORKTREE_PATH" rev-parse HEAD)"' "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: Codex mode must capture the delegated worktree tip"
grep -q 'git cherry-pick --no-commit "$BASE_REF..$WORKTREE_HEAD"' "$SHARED_WORK_SKILL" \
  || fail "shared harness-work: Codex mode must cherry-pick the reviewed worktree range"

echo "ok"
