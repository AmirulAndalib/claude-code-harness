package guardrail

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

// This file restores the file-based breezing state resolution that the shell
// guard (scripts/pretooluse-guard.sh: check_breezing_role /
// check_breezing_codex_mode / try_register_breezing_role) had and the Go
// migration dropped. Without it, R07 (codex-mode-no-write) and R08
// (breezing-reviewer-no-write) never fire: their context fields had no
// producer at all (measured 2026-08-11, Plans.md 132.6).

// breezingRoleEntry is one entry in breezing-session-roles.json.
type breezingRoleEntry struct {
	Role string   `json:"role"`
	Owns []string `json:"owns,omitempty"`
}

// breezingActiveState is the subset of breezing-active.json we need.
type breezingActiveState struct {
	ImplMode string `json:"impl_mode"`
}

// validBreezingRole restricts registered roles to known lowercase words so a
// crafted content payload cannot smuggle arbitrary strings into the context.
var validBreezingRole = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)

// breezingRoleFilenameRe matches the self-registration Write target.
var breezingRoleFilenameRe = regexp.MustCompile(`^breezing-role-[A-Za-z0-9._-]+\.json$`)

// resolveBreezingRoleFromFile resolves this call's breezing role.
//
// Sources, in order (shell parity first, then the CC-native signal):
//  1. .claude/state/breezing-session-roles.json — looked up by the hook
//     payload's agent_id, then session_id (same order as the shell guard).
//  2. input.AgentType — Claude Code sets agent_type on every tool call made
//     inside a subagent. When a breezing run is active (breezing-active.json
//     exists) and the subagent type is CCH's "reviewer" agent, the call is a
//     breezing reviewer without any registration step.
//
// Returns "" when no role applies. Never errors: fail-open like the rest of
// the hook fast path.
func resolveBreezingRoleFromFile(projectRoot string, input hookproto.HookInput) string {
	if projectRoot == "" {
		return ""
	}
	stateDir := filepath.Join(projectRoot, ".claude", "state")

	rolesPath := filepath.Join(stateDir, "breezing-session-roles.json")
	if data, err := os.ReadFile(rolesPath); err == nil {
		var roles map[string]breezingRoleEntry
		if json.Unmarshal(data, &roles) == nil {
			for _, key := range []string{input.AgentID, input.SessionID} {
				if key == "" {
					continue
				}
				if entry, ok := roles[key]; ok && entry.Role != "" {
					return entry.Role
				}
			}
		}
	}

	// CC-native: reviewer subagent during an active breezing run.
	// agent_type は素の名前 ("reviewer") と plugin 修飾名
	// ("claude-code-harness:reviewer") の両形で届きうるため両対応する。
	agentType := input.AgentType
	if idx := strings.LastIndex(agentType, ":"); idx >= 0 {
		agentType = agentType[idx+1:]
	}
	if agentType == "reviewer" {
		if _, err := os.Stat(filepath.Join(stateDir, "breezing-active.json")); err == nil {
			return "reviewer"
		}
	}
	return ""
}

// resolveCodexModeFromBreezingActive reports whether the active breezing run
// delegates implementation to Codex (breezing-active.json impl_mode=codex).
// Shell parity: check_breezing_codex_mode.
func resolveCodexModeFromBreezingActive(projectRoot string) bool {
	if projectRoot == "" {
		return false
	}
	data, err := os.ReadFile(filepath.Join(projectRoot, ".claude", "state", "breezing-active.json"))
	if err != nil {
		return false
	}
	var active breezingActiveState
	if err := json.Unmarshal(data, &active); err != nil {
		return false
	}
	return active.ImplMode == "codex"
}

// tryRegisterBreezingRole ports the shell guard's try_register_breezing_role:
// a Write to .claude/state/breezing-role-*.json self-registers the calling
// session/subagent's role into breezing-session-roles.json.
//
// Security invariants (kept from the shell version, tightened):
//   - The registration key comes ONLY from the hook payload (agent_id first,
//     then session_id) — never from the written content. A writer can only
//     assign a role to itself.
//   - The role value must match validBreezingRole; self-registration as
//     "reviewer" only restricts the caller, so there is no escalation path.
//   - The target must resolve inside <projectRoot>/.claude/state/ with the
//     exact breezing-role-*.json basename.
//
// Returns a non-nil approve result when the Write was consumed as a
// registration, nil to fall through to normal rule evaluation.
func tryRegisterBreezingRole(input hookproto.HookInput) *hookproto.HookResult {
	if input.ToolName != "Write" {
		return nil
	}
	filePath, ok := input.ToolInput["file_path"].(string)
	if !ok || filePath == "" {
		return nil
	}
	if !breezingRoleFilenameRe.MatchString(filepath.Base(filePath)) {
		return nil
	}

	projectRoot := resolveProjectRoot(input)
	stateDir := filepath.Join(projectRoot, ".claude", "state")

	// Path containment: the write must land in this project's state dir.
	absTarget := filePath
	if !filepath.IsAbs(absTarget) {
		absTarget = filepath.Join(projectRoot, absTarget)
	}
	if filepath.Clean(filepath.Dir(absTarget)) != filepath.Clean(stateDir) {
		return nil
	}

	// 登録キーは agent_id のみ。session_id への fallback は行わない。
	//
	// Why (2026-08-11 の敵対的再検証で実証): session_id で登録すると、その
	// session_id を共有する Lead 自身の呼び出しまで reviewer と解決され、
	// Lead の全 Write が R08 で拒否される (run が壊れる)。CC は subagent の
	// tool call に必ず agent_id を付けるため、正当な subagent 登録は agent_id
	// を持つ。agent_id を持たない呼び出し = main thread であり、自分自身を
	// reviewer にする必要はない。
	//
	// worktree で spawn された teammate は独立セッションなので、Lead 側が
	// spawn 時に env HARNESS_BREEZING_ROLE を渡す経路を使う (SKILL.md 参照)。
	// shell 版は SESSION_ID へも fallback していたが、同じ汚染欠陥を持つ。
	key := strings.TrimSpace(input.AgentID)
	if key == "" {
		return nil
	}

	content, _ := input.ToolInput["content"].(string)
	var payload breezingRoleEntry
	if err := json.Unmarshal([]byte(content), &payload); err != nil {
		return nil
	}
	payload.Role = strings.TrimSpace(payload.Role)
	if !validBreezingRole.MatchString(payload.Role) {
		return nil
	}

	if err := upsertBreezingRole(stateDir, key, payload); err != nil {
		// 登録失敗は通常評価へフォールバック (fail-open)。
		return nil
	}
	return &hookproto.HookResult{
		Decision:      hookproto.DecisionApprove,
		SystemMessage: "Breezing role registered: " + payload.Role + " (key=" + key + ")",
		RuleID:        "BREEZING:role-register",
	}
}

// upsertBreezingRole merges one role entry into breezing-session-roles.json.
func upsertBreezingRole(stateDir, key string, entry breezingRoleEntry) error {
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return err
	}
	rolesPath := filepath.Join(stateDir, "breezing-session-roles.json")

	roles := map[string]breezingRoleEntry{}
	if data, err := os.ReadFile(rolesPath); err == nil {
		_ = json.Unmarshal(data, &roles)
	}
	roles[key] = entry

	data, err := json.MarshalIndent(roles, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(stateDir, ".breezing-roles-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	tmp.Close()
	return os.Rename(tmpName, rolesPath)
}
