// Package policy implements the Harness v4 declarative guardrail rules engine.
//
// It contains the pure rule-evaluation core: each rule is a
// (toolPattern, evaluate) pair evaluated in order; the first match wins
// (short-circuit). This package depends only on the Go standard library,
// pkg/hookproto, and the dependency-free pkg/shellscan leaf package so that the
// rule logic can be reused without pulling in the configuration and state
// layers (those live in internal/guardrail).
package policy

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/shellscan"
)

// tddEnforceLevelMax mirrors config.TDDEnforceLevelMax ("max") as a plain
// string so that the pure R14 evaluator can compare against the TDD enforce
// level without importing pkg/config. RuleContext.TddEnforceLevel is resolved
// to one of "off" / "central" / "max" by the configuration layer in
// internal/guardrail before the rules run.
const tddEnforceLevelMax = "max"

// GuardRule is a single declarative guard rule.
type GuardRule struct {
	ID          string
	ToolPattern *regexp.Regexp
	Evaluate    func(ctx hookproto.RuleContext) *hookproto.HookResult
}

// Pre-compiled patterns for R08 (breezing reviewer prohibited commands)
var r08ReviewerProhibitedPatterns = []*regexp.Regexp{
	regexp.MustCompile(`\bgit\s+(?:commit|push|reset|checkout|merge|rebase)\b`),
	regexp.MustCompile(`\brm\s+`),
	regexp.MustCompile(`\bmv\s+`),
	regexp.MustCompile(`\bcp\s+.*-r\b`),
	// ln も data-mutating。とくに `ln -s` は R08 の .claude/state 例外と
	// 組み合わせると write-block 全体を破る (2026-08-11 の敵対的再検証で
	// 実証: state 内に repo 内 src を指す symlink を作り、その経由で
	// 任意ファイルへ書けた)。書き込み側は EvalSymlinks で塞いだうえで、
	// 作成側もここで止める (二重防御)。
	regexp.MustCompile(`\bln\s+`),
	regexp.MustCompile(`\btee\b`),
}

// Pre-compiled patterns for R09 (secret file detection)
var r09SecretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`\.env$`),
	regexp.MustCompile(`id_rsa$`),
	regexp.MustCompile(`\.pem$`),
	regexp.MustCompile(`\.key$`),
	regexp.MustCompile(`secrets?/`),
}

var (
	r14SourcePathPattern = regexp.MustCompile(`(?:^|/)(?:app|cmd|go|internal|lib|pkg|src)/(?:.+)\.(?:cs|go|java|js|jsx|kt|php|py|rb|rs|swift|ts|tsx)$`)
	r14TestPathPattern   = regexp.MustCompile(`(?:^|/)(?:__tests__|test|tests)(?:/|$)|(?:_test\.go|_test\.py|\.spec\.[jt]sx?|\.test\.[jt]sx?)$`)
)

func protectedPathHookResult(match protectedPathMatch, filePath, operation string) *hookproto.HookResult {
	switch match.Level {
	case protectedPathDeny:
		return &hookproto.HookResult{
			Decision: hookproto.DecisionDeny,
			Reason:   fmt.Sprintf("%s is not allowed: %s (%s)", operation, filePath, match.Reason),
		}
	case protectedPathAsk:
		return &hookproto.HookResult{
			Decision: hookproto.DecisionAsk,
			Reason:   fmt.Sprintf("%s requires confirmation: %s (%s)", operation, filePath, match.Reason),
		}
	case protectedPathWarn:
		return &hookproto.HookResult{
			Decision:      hookproto.DecisionApprove,
			SystemMessage: fmt.Sprintf("Warning: detected %s: %s (%s)", operation, filePath, match.Reason),
		}
	default:
		return nil
	}
}

func isTddSourceWriteCandidate(filePath, projectRoot string) bool {
	if !isUnderProjectRoot(filePath, projectRoot) {
		return false
	}
	normalized := normalizePathForGuardrail(filePath)
	if r14TestPathPattern.MatchString(normalized) {
		return false
	}
	return r14SourcePathPattern.MatchString(normalized)
}

func tddBypassHookResult(ctx hookproto.RuleContext, filePath string) *hookproto.HookResult {
	reason := strings.TrimSpace(ctx.TddBypassReason)
	message := fmt.Sprintf("TDD enforcement bypass active for %s (HARNESS_TDD_BYPASS=1).", filePath)
	if reason != "" {
		message += fmt.Sprintf(" reason=%q", reason)
	} else if ctx.TddBypassReasonRequired {
		message += " HARNESS_TDD_BYPASS_REASON is required for audit but was empty."
	} else {
		message += " HARNESS_TDD_BYPASS_REASON was empty."
	}
	return &hookproto.HookResult{
		Decision:      hookproto.DecisionApprove,
		SystemMessage: message,
	}
}

func r14TddRequiredLocalTrialResult(ctx hookproto.RuleContext) *hookproto.HookResult {
	if ctx.TddEnforceLevel != tddEnforceLevelMax || !ctx.TddHookEnabled {
		return nil
	}
	filePath, ok := ctx.Input.ToolInput["file_path"].(string)
	if !ok {
		return nil
	}
	if !isTddSourceWriteCandidate(filePath, ctx.ProjectRoot) {
		return nil
	}
	if ctx.TddBypass {
		// TDD bypass only bypasses the future TDD-specific denial path. It must
		// not short-circuit later non-TDD guardrails such as Codex direct-write
		// denial.
		return nil
	}

	// Phase 68 B1-B3 local trial: R14 is registered but non-blocking until the
	// dedicated TDD evaluator is added by the follow-up helper implementation.
	return nil
}

// Rules is the ordered table of all guard rules.
var Rules = []GuardRule{
	// R01: sudo block (Bash)
	{
		ID:          "R01:no-sudo",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			if !hasSudo(command) {
				return nil
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionDeny,
				Reason:   "sudo is not allowed. If it is required, ask the user to run it manually.",
			}
		},
	},

	// R02: protected path write block (Write/Edit/MultiEdit)
	{
		ID:          "R02:no-write-protected-paths",
		ToolPattern: regexp.MustCompile(`^(?:Write|Edit|MultiEdit)$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			filePath, ok := ctx.Input.ToolInput["file_path"].(string)
			if !ok {
				return nil
			}
			match := classifyProtectedPathAtRoot(filePath, ctx.ProjectRoot)
			if match.Level == protectedPathNone {
				return nil
			}
			return protectedPathHookResult(match, filePath, "file write to a protected path")
		},
	},

	// R03: Bash write to protected paths block
	{
		ID:          "R03:no-bash-write-protected-paths",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			return bashProtectedWriteHookResult(ctx, command)
		},
	},

	// R14: TDD required for source writes (local-trial registration only)
	{
		ID:          "R14:test-required-for-src-write",
		ToolPattern: regexp.MustCompile(`^(?:Write|Edit|MultiEdit)$`),
		Evaluate:    r14TddRequiredLocalTrialResult,
	},

	// R15: block staging or committing secret files
	{
		ID:          "R15:no-stage-secret-file",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			path, ok := secretFileStaging(command, ctx.ProjectRoot)
			if !ok {
				return nil
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionDeny,
				Reason:   fmt.Sprintf("staging secret or credential file is not allowed: %s", path),
			}
		},
	},

	// R04: confirm write outside project root
	{
		ID:          "R04:confirm-write-outside-project",
		ToolPattern: regexp.MustCompile(`^(?:Write|Edit|MultiEdit)$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			filePath, ok := ctx.Input.ToolInput["file_path"].(string)
			if !ok {
				return nil
			}
			if isUnderProjectRoot(filePath, ctx.ProjectRoot) {
				return nil
			}
			physicalPath := filePath
			if !filepath.IsAbs(physicalPath) && ctx.ProjectRoot != "" {
				physicalPath = filepath.Join(ctx.ProjectRoot, physicalPath)
			}
			resolvedPath, err := evalSymlinksAllowMissing(physicalPath)
			if err == nil && shellscan.IsAllowlistedTempPath(resolvedPath) {
				return nil
			}
			if err == nil && shellscan.IsAgentStatePath(resolvedPath) {
				return nil
			}
			// Work mode skips confirmation
			if ctx.WorkMode {
				return nil
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionAsk,
				Reason:   fmt.Sprintf("Write outside the project root: %s\nAllow it?", filePath),
			}
		},
	},

	// R05: confirm dangerous deletion commands
	{
		ID:          "R05:confirm-rm-rf",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			dangerous, targets := shellscan.DangerousRemoval(command)
			if !dangerous {
				return nil
			}
			if ctx.WorkMode {
				return nil
			}
			// 対象で判断する。エージェント自身が所有する領域 (作業ツリー /
			// OS の一時領域) の中だけを消すなら確認しない。エージェントの
			// 種別や worktree にいるかどうかでは判断しない。
			if dangerousRemovalTargetsAreAgentOwned(command, targets, ctx.ProjectRoot, ctx.Input.SessionID) {
				return nil
			}
			// destructive_delete=warn (operator opt-in, HOTL). When the static
			// analysis cannot PROVE the target is agent-owned — a relative
			// target after `cd`, any preceding shell segment (133.10: a prior
			// segment can plant a symlink so the same spelling resolves outside
			// the worktree) — the default answer is "ask the human". Under warn
			// the human is replaced by the agent's own judgement: the command is
			// approved, a warning is injected, and the guardrail layer records
			// the deletion for after-the-fact review. The 133.10 symlink
			// residual is accepted knowingly under this mode; do not "simplify"
			// warn into the default path. Out-of-root spellings, `..`, unresolved
			// `$VAR`, globs and bare `.` still ask even under warn — that keeps
			// the blast-radius backstop of spec.md HOTL invariant 3.
			if NormalizeDestructiveDeletePolicy(ctx.DestructiveDeletePolicy) == DestructiveDeletePolicyWarn &&
				dangerousRemovalTargetsAreLexicallyLocal(command, targets, ctx.ProjectRoot, ctx.Input.SessionID) {
				return &hookproto.HookResult{
					Decision:      hookproto.DecisionApprove,
					SystemMessage: fmt.Sprintf("R05_WARN: destructive delete allowed without confirmation (destructive_delete=warn; target not statically verifiable, recorded in .claude/state/destructive-delete.jsonl):\n%s", command),
				}
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionAsk,
				Reason:   fmt.Sprintf("Detected a destructive delete command:\n%s\nRun it?", command),
			}
		},
	},

	// R06: git push --force block (no bypass even in work mode)
	{
		ID:          "R06:no-force-push",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			if !hasForcePush(command) {
				return nil
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionDeny,
				Reason:   "git push --force is not allowed. History-destroying operations are forbidden.",
			}
		},
	},

	// R07: Codex mode — no Write/Edit
	{
		ID:          "R07:codex-mode-no-write",
		ToolPattern: regexp.MustCompile(`^(?:Write|Edit|MultiEdit)$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			if !ctx.CodexMode {
				return nil
			}
			// R07 は「orchestrator の Claude が直接書かず codex に委譲する」
			// 規律。codex host 自身 (委譲先 worker) の書き込みは対象外 —
			// 除外しないと委譲された実装作業そのものが止まる。
			if ctx.Input.Host == "codex" {
				return nil
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionDeny,
				Reason:   "During Codex mode Claude cannot write files directly. Delegate implementation to the Codex Worker (codex exec).",
			}
		},
	},

	// R08: Breezing reviewer — no write operations
	{
		ID:          "R08:breezing-reviewer-no-write",
		ToolPattern: regexp.MustCompile(`^(?:Write|Edit|MultiEdit|Bash)$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			if ctx.BreezingRole != "reviewer" {
				return nil
			}
			toolName := ctx.Input.ToolName
			if toolName == "Bash" {
				command, ok := ctx.Input.ToolInput["command"].(string)
				if !ok {
					return nil
				}
				matched := false
				for _, p := range r08ReviewerProhibitedPatterns {
					if p.MatchString(command) {
						matched = true
						break
					}
				}
				if !matched {
					return nil
				}
			} else {
				// shell 版 parity: reviewer は .claude/state/ 配下 (レビュー
				// レポート等の成果物置き場) には書いてよい。これが無いと
				// reviewer が自身の verdict artifact を書けず run が壊れる。
				// 判定は必ず Clean 済みパスの封じ込めで行う — 素の substring
				// 判定は `/.claude/state/../../src/x.ts` の traversal で
				// バイパスされる (2026-08-11 レビューで実測)。
				if filePath, ok := ctx.Input.ToolInput["file_path"].(string); ok {
					if isWithinReviewerStateDir(ctx.ProjectRoot, filePath) {
						return nil
					}
				}
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionDeny,
				Reason:   "The Breezing reviewer role cannot write files or run data-mutating commands.",
			}
		},
	},

	// R09: warn on secret file read
	{
		ID:          "R09:warn-secret-file-read",
		ToolPattern: regexp.MustCompile(`^Read$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			filePath, ok := ctx.Input.ToolInput["file_path"].(string)
			if !ok {
				return nil
			}
			for _, p := range r09SecretPatterns {
				if p.MatchString(filePath) {
					return &hookproto.HookResult{
						Decision:      hookproto.DecisionApprove,
						SystemMessage: fmt.Sprintf("Warning: reading a file that may contain sensitive data: %s", filePath),
					}
				}
			}
			return nil
		},
	},

	// R10: --no-verify / --no-gpg-sign block
	{
		ID:          "R10:no-git-bypass-flags",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			if !hasDangerousGitBypassFlag(command) {
				return nil
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionDeny,
				Reason:   "--no-verify / --no-gpg-sign is not allowed. Do not bypass hooks or signature verification.",
			}
		},
	},

	// R11: protected branch git reset --hard block
	{
		ID:          "R11:no-reset-hard-protected-branch",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			if !hasProtectedBranchResetHard(command) {
				return nil
			}
			return &hookproto.HookResult{
				Decision: hookproto.DecisionDeny,
				Reason:   "git reset --hard on a protected branch is not allowed. Use a method that does not destroy history.",
			}
		},
	},

	// R12: configurable direct push policy for protected branches
	{
		ID:          "R12:confirm-direct-push-protected-branch",
		ToolPattern: regexp.MustCompile(`^Bash$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			command, ok := ctx.Input.ToolInput["command"].(string)
			if !ok {
				return nil
			}
			if !hasDirectPushToProtectedBranch(command) {
				return nil
			}

			switch NormalizeProtectedBranchPushPolicy(ctx.ProtectedBranchPushPolicy) {
			case ProtectedBranchPushPolicyDeny:
				return &hookproto.HookResult{
					Decision: hookproto.DecisionDeny,
					Reason:   "Direct push to main/master is disabled by configuration. Create a PR via a feature branch.",
				}
			case ProtectedBranchPushPolicyAllow:
				return nil
			default:
				// Plan preapproval can suppress this guardrail confirmation,
				// but never the explicit deny branch above or the runtime
				// action hard floor evaluated before policy rules.
				if ctx.ConsumePlanPreapproval != nil &&
					ctx.ConsumePlanPreapproval("external-send", command) {
					return nil
				}
				return &hookproto.HookResult{
					Decision: hookproto.DecisionAsk,
					Reason:   "Direct push to main/master. Run it after user confirmation? (setting: protected_branch_push=ask)",
				}
			}
		},
	},

	// R13: warn on protected review paths (Write/Edit/MultiEdit)
	{
		ID:          "R13:warn-protected-review-paths",
		ToolPattern: regexp.MustCompile(`^(?:Write|Edit|MultiEdit)$`),
		Evaluate: func(ctx hookproto.RuleContext) *hookproto.HookResult {
			filePath, ok := ctx.Input.ToolInput["file_path"].(string)
			if !ok {
				return nil
			}
			if !isProtectedReviewPath(filePath) {
				return nil
			}
			return &hookproto.HookResult{
				Decision:      hookproto.DecisionApprove,
				SystemMessage: fmt.Sprintf("Warning: detected a change to an important file: %s", filePath),
			}
		},
	},
}

// isWithinReviewerStateDir reports whether filePath resolves inside
// <projectRoot>/.claude/state/ — both lexically (after Clean, so
// "/.claude/state/../../src/x.ts" is rejected) and physically (after
// EvalSymlinks, so a symlink planted inside the state dir cannot redirect a
// write outside it). Both checks are required: the lexical one alone was
// bypassed in the 2026-08-11 adversarial re-verification by creating
// ".claude/state/escape -> <project>/src" and writing through it.
func isWithinReviewerStateDir(projectRoot, filePath string) bool {
	if projectRoot == "" || filePath == "" {
		return false
	}
	p := filePath
	if !filepath.IsAbs(p) {
		p = filepath.Join(projectRoot, p)
	}
	stateDir := filepath.Clean(filepath.Join(projectRoot, ".claude", "state"))

	// 1) lexical containment (".." collapse)
	if !pathContainedIn(stateDir, filepath.Clean(p)) {
		return false
	}

	// 2) physical containment (symlink resolution). 対象ファイルはまだ存在
	// しないことが普通なので、存在する最も深い祖先まで遡って解決する。
	// 解決できない場合は lexical 判定のみで通す (fail-open にしない範囲で、
	// 存在しないパスを理由に正当な state 書き込みを止めないため)。
	resolvedState, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		return true // state dir 自体が未作成: lexical 判定を採用
	}
	dir := filepath.Dir(filepath.Clean(p))
	for {
		resolvedDir, err := filepath.EvalSymlinks(dir)
		if err == nil {
			return pathContainedIn(resolvedState, resolvedDir)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return true // 祖先が一つも実在しない: lexical 判定を採用
		}
		dir = parent
	}
}

// pathContainedIn reports whether target is base itself or nested under it.
func pathContainedIn(base, target string) bool {
	rel, err := filepath.Rel(base, target)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

// EvaluateRules evaluates all guard rules in order and returns the first match.
// If no rule matches, it returns approve.
func EvaluateRules(ctx hookproto.RuleContext) hookproto.HookResult {
	toolName := ctx.Input.ToolName
	for _, rule := range Rules {
		if !rule.ToolPattern.MatchString(toolName) {
			continue
		}
		if result := rule.Evaluate(ctx); result != nil {
			result.RuleID = rule.ID
			return *result
		}
	}
	return hookproto.HookResult{Decision: hookproto.DecisionApprove}
}
