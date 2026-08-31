package policy

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
	"github.com/Chachamaru127/claude-code-harness/go/pkg/shellscan"
)

// ---------------------------------------------------------------------------
// Protected path taxonomy
// ---------------------------------------------------------------------------

type protectedPathLevel int

const (
	protectedPathNone protectedPathLevel = iota
	protectedPathWarn
	protectedPathAsk
	protectedPathDeny
)

type protectedPathMatch struct {
	Level  protectedPathLevel
	Reason string
	Path   string
}

type protectedPathRule struct {
	level   protectedPathLevel
	reason  string
	pattern *regexp.Regexp
}

var (
	publicEnvTemplateBasenames = []string{".env.example", ".env.template", ".env.sample", ".env.dist"}
	envFileDenyPattern         = regexp.MustCompile(`(?:^|/)\.env(?:$|\.)`)
	publicEnvTemplatePattern   = regexp.MustCompile(`(?:^|/)(?:` + strings.Join(quotedPublicEnvTemplateBasenames(), "|") + `)$`)
)

func quotedPublicEnvTemplateBasenames() []string {
	quoted := make([]string, 0, len(publicEnvTemplateBasenames))
	for _, name := range publicEnvTemplateBasenames {
		quoted = append(quoted, regexp.QuoteMeta(name))
	}
	return quoted
}

// Claude Code 2.1.121/2.1.126 protected path taxonomy:
//   - deny: .git/, secrets, shell rc/profile files, destructive hook entrypoints.
//   - ask: .claude/skills/, .claude/agents/, .claude/commands/, .vscode/.
//   - warn: .claude/rules/, .claude/memory/, setup metadata.
//
// This intentionally does not deny every .claude/ path. Runtime state and other
// project-local Claude data remain governed by the normal write rules.
var protectedPathRules = []protectedPathRule{
	// deny: repository internals, secrets, hook entrypoints, and shell startup files
	{protectedPathDeny, "Git internal metadata", regexp.MustCompile(`(?:^|/)\.git(?:/|$)`)},
	{protectedPathDeny, "secret or credential file", envFileDenyPattern},
	{protectedPathDeny, "secret or credential file", regexp.MustCompile(`(?:^|/)\.envrc$`)},
	{protectedPathDeny, "secret or credential file", regexp.MustCompile(`(?:^|/)secrets?(?:/|$)`)},
	{protectedPathDeny, "secret or credential file", regexp.MustCompile(`(?:^|/)(?:id_rsa|id_ed25519|id_ecdsa|id_dsa)$`)},
	{protectedPathDeny, "secret or credential file", regexp.MustCompile(`\.(?:pem|key|p12|pfx)$`)},
	{protectedPathDeny, "SSH trust file", regexp.MustCompile(`(?:^|/)(?:authorized_keys|known_hosts)$`)},
	{protectedPathDeny, "destructive hook entrypoint", regexp.MustCompile(`(?:^|/)\.husky(?:/|$)`)},
	{protectedPathDeny, "destructive hook entrypoint", regexp.MustCompile(`(?:^|/)\.claude/hooks(?:/|$)`)},
	{protectedPathDeny, "shell rc/profile file", regexp.MustCompile(`(?:^|/)\.(?:bashrc|bash_profile|bash_login|profile|zshrc|zprofile|zshenv|zlogin|zlogout|kshrc|cshrc|tcshrc)$`)},
	{protectedPathDeny, "shell rc/profile file", regexp.MustCompile(`(?:^|/)\.config/fish/config\.fish$`)},
	{protectedPathDeny, "shell rc/profile file", regexp.MustCompile(`(?:^|/)(?:Microsoft\.)?(?:PowerShell_)?profile\.ps1$`)},
	// Phase 128.3: .claude-code-harness.config.{json,yaml,yml} governs
	// runtimefloor.secretAllow / runtimefloor.releaseAuto and other control-plane
	// settings, the same governance tier as .claude/settings* and
	// .claude-plugin/settings*. Denied so the AI cannot loosen its own hard
	// floor by editing the declaration that scopes it. Does not match the
	// checked-in template "claude-code-harness.config.example.json" (no leading
	// dot, distinct ".example." infix).
	{protectedPathDeny, "harness control-plane config", regexp.MustCompile(`(?:^|/)\.claude-code-harness\.config\.(?:json|ya?ml)$`)},

	// Phase 140.2 review follow-up: the deferred-ops queue is the operator's
	// approval surface and destructive-delete.jsonl is its audit record. An
	// agent writing either file could forge "status":"approved" lines or erase
	// the review trail, so direct Write/Edit (R02) and shell writes (R03) are
	// denied. The guardrail process itself writes them from Go, not through a
	// tool call, so enforcement is unaffected. Residual: an interpreter
	// (python -c etc.) or a plain `rm <file>` (no -rf, so R05 does not match)
	// can still write or erase the file — either destroys the review trail but
	// neither can GRANT an approval; same accepted class as the R05 symlink
	// residual. R16 closes the approve-CLI channel.
	{protectedPathDeny, "guardrail approval queue / audit record", regexp.MustCompile(`(?:^|/)\.claude/state/(?:deferred-ops|destructive-delete)\.jsonl$`)},

	// ask: agent capability surfaces and editor automation settings
	{protectedPathAsk, "Claude capability path", regexp.MustCompile(`(?:^|/)\.claude/(?:skills|agents|commands)(?:/|$)`)},
	{protectedPathAsk, "editor automation settings", regexp.MustCompile(`(?:^|/)\.vscode(?:/|$)`)},

	// warn: policy/memory/setup metadata that is important but not hard-denied
	{protectedPathWarn, "Claude rule or memory path", regexp.MustCompile(`(?:^|/)\.claude/(?:rules|memory)(?:/|$)`)},
	{protectedPathWarn, "setup metadata", regexp.MustCompile(`(?:^|/)\.claude/(?:settings(?:\.local)?\.json|config(?:/|$)|Plans\.md$)`)},
	{protectedPathWarn, "setup metadata", regexp.MustCompile(`(?:^|/)\.claude-plugin/(?:plugin|settings(?:\.local)?)\.json$`)},
	{protectedPathWarn, "setup metadata", regexp.MustCompile(`(?:^|/)(?:CLAUDE|AGENTS)\.md$`)},
	{protectedPathWarn, "setup metadata", regexp.MustCompile(`(?:^|/)\.mcp\.json$`)},
	{protectedPathWarn, "setup metadata", regexp.MustCompile(`(?:^|/)harness\.toml$`)},
}

func normalizePathForGuardrail(filePath string) string {
	cleaned := filepath.Clean(filePath)
	if cleaned == "." {
		return filePath
	}
	return filepath.ToSlash(cleaned)
}

func classifyProtectedPathPattern(filePath string) protectedPathMatch {
	normalized := normalizePathForGuardrail(filePath)
	best := protectedPathMatch{Level: protectedPathNone, Path: normalized}
	for _, rule := range protectedPathRules {
		// Exact public templates are exempt only from the generic .env rule.
		// Independent protections (for example secrets/.env.example) still apply.
		if rule.pattern == envFileDenyPattern && isPublicEnvTemplatePath(normalized) {
			continue
		}
		if rule.pattern.MatchString(normalized) && rule.level > best.Level {
			best = protectedPathMatch{
				Level:  rule.level,
				Reason: rule.reason,
				Path:   normalized,
			}
		}
	}
	return best
}

func isPublicEnvTemplatePath(filePath string) bool {
	return publicEnvTemplatePattern.MatchString(normalizePathForGuardrail(filePath))
}

func strongerProtectedPathMatch(a, b protectedPathMatch) protectedPathMatch {
	if b.Level > a.Level {
		return b
	}
	return a
}

func classifyProtectedPath(filePath string) protectedPathMatch {
	match := classifyProtectedPathPattern(filePath)

	// Resolve symlinks and check the real path (CC 2.1.89: symlink target resolution)
	realPath, err := filepath.EvalSymlinks(filePath)
	if err != nil {
		// Fail-safe: symlink loop, broken link, or other error → deny.
		// Exception: if the path simply doesn't exist, it's classified from
		// the path text only, so new non-sensitive files are not over-blocked.
		if _, statErr := os.Lstat(filePath); os.IsNotExist(statErr) {
			return match
		}
		return protectedPathMatch{
			Level:  protectedPathDeny,
			Reason: "unresolvable protected path",
			Path:   normalizePathForGuardrail(filePath),
		}
	}

	return strongerProtectedPathMatch(match, classifyProtectedPathPattern(realPath))
}

// classifyProtectedPathAtRoot resolves relative paths from the hook project
// root, including symlinked parents whose final child does not exist yet.
func classifyProtectedPathAtRoot(filePath, projectRoot string) protectedPathMatch {
	match := classifyProtectedPathPattern(filePath)
	physicalPath := filePath
	if !filepath.IsAbs(physicalPath) && projectRoot != "" {
		physicalPath = filepath.Join(projectRoot, physicalPath)
	}

	resolved, err := evalSymlinksAllowMissing(physicalPath)
	if err != nil {
		return protectedPathMatch{
			Level:  protectedPathDeny,
			Reason: "unresolvable protected path",
			Path:   normalizePathForGuardrail(filePath),
		}
	}
	return strongerProtectedPathMatch(match, classifyProtectedPathPattern(resolved))
}

func evalSymlinksAllowMissing(filePath string) (string, error) {
	current := filepath.Clean(filePath)
	var suffix []string
	for {
		resolved, err := filepath.EvalSymlinks(current)
		if err == nil {
			for i := len(suffix) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, suffix[i])
			}
			return resolved, nil
		}
		if !os.IsNotExist(err) {
			return "", err
		}
		parent := filepath.Dir(current)
		if parent == current {
			return current, nil
		}
		suffix = append(suffix, filepath.Base(current))
		current = parent
	}
}

// isProtectedPath checks whether filePath matches any protected taxonomy level.
// If EvalSymlinks returns an error (symlink loop, broken link, etc.),
// the function returns true via the fail-safe deny classification.
func isProtectedPath(filePath string) bool {
	return classifyProtectedPath(filePath).Level != protectedPathNone
}

// ---------------------------------------------------------------------------
// Bash write target extraction
// ---------------------------------------------------------------------------

var (
	bashRedirectionTargetPattern = regexp.MustCompile(`(?:^|[\s;&|])(?:\d*&>>?|\d*>>?|&>>?|>\|)\s*['"]?([^'"` + "`" + `\s;&|]+)['"]?`)
	bashTeeCommandPattern        = regexp.MustCompile(`(?:^|[|;&]\s*)tee\b([^;&|]*)`)

	// Commands whose LAST operand is the path they create or replace. Until
	// 133.12 only redirections and `tee` were extracted, so R03 measured as:
	// redirect deny / tee deny / ln, cp, mv, install all silently allowed —
	// four equivalent ways to put a file at a protected path.
	//
	// A refuter reached the 133.10 breakout through `ln -s` specifically, but
	// patching only `ln` would leave the other three open. This is the same
	// lesson 133.10 recorded when it chose one general rule over case-by-case
	// patching of `$` expansion.
	bashDestinationOperandPattern = regexp.MustCompile(`(?:^|[|;&]\s*)(?:ln|cp|mv|install)\b([^;&|<>]*)`)
)

func stripShellTokenQuotes(token string) string {
	token = strings.TrimSpace(token)
	token = strings.Trim(token, "'\"")
	return token
}

func extractBashWriteTargets(command string) []string {
	var targets []string
	for _, m := range bashRedirectionTargetPattern.FindAllStringSubmatch(command, -1) {
		if len(m) >= 2 {
			targets = append(targets, stripShellTokenQuotes(m[1]))
		}
	}

	for _, m := range bashTeeCommandPattern.FindAllStringSubmatch(command, -1) {
		if len(m) < 2 {
			continue
		}
		for _, token := range strings.Fields(m[1]) {
			token = stripShellTokenQuotes(token)
			if token == "" || token == "--" {
				continue
			}
			if strings.HasPrefix(token, "-") {
				continue
			}
			if strings.ContainsAny(token, "<>|`$") {
				continue
			}
			targets = append(targets, token)
		}
	}

	targets = append(targets, bashDestinationOperands(command)...)

	return targets
}

// bashDestinationOperands returns the destination path of each ln/cp/mv/install
// invocation in command.
//
// Only the LAST operand is taken. For every form these commands accept
// (`cp SRC DST`, `mv SRC... DIR`, `ln -s TARGET LINK`, `install -m 755 SRC DST`)
// the final operand is what gets created or replaced; earlier operands are
// sources, which are reads and not R03's concern. Flags and their values are
// skipped, and taking the last operand keeps a flag value like the `755` of
// `install -m 755` from ever being read as a path.
//
// The single-operand form is deliberately NOT reported. `ln -s /some/target`
// creates a link in the *shell's* working directory, which the hook payload's
// cwd does not reliably describe for a command that may have chained a `cd`.
// Reporting a guessed path would classify the wrong file. The dangerous case
// this rule exists for always names its destination explicitly.
func bashDestinationOperands(command string) []string {
	var targets []string
	for _, m := range bashDestinationOperandPattern.FindAllStringSubmatch(command, -1) {
		if len(m) < 2 {
			continue
		}
		var operands []string
		explicitDestination := ""
		fields := strings.Fields(m[1])
		for i := 0; i < len(fields); i++ {
			token := stripShellTokenQuotes(fields[i])
			if token == "" || token == "--" {
				continue
			}
			// `-t DIR` / `--target-directory DIR` / `--target-directory=DIR`
			// put the destination FIRST, which is the one form where "the last
			// operand is the destination" does not hold. Dropping the flag as
			// an ordinary option hid the destination completely: measured
			// 2026-08-14, `cp -t <protected> /tmp/src` and the mv/ln/install
			// equivalents were all allowed while `cp /tmp/src <protected>` was
			// denied.
			if dest, consumed, ok := destinationFlag(fields, i); ok {
				explicitDestination = dest
				i += consumed
				continue
			}
			if strings.HasPrefix(token, "-") {
				continue
			}
			// Unresolved expansions are not paths we can classify; the caller
			// already treats an unresolvable protected path conservatively.
			if strings.ContainsAny(token, "`$") {
				continue
			}
			operands = append(operands, token)
		}
		if explicitDestination != "" {
			targets = append(targets, explicitDestination)
			continue
		}
		if len(operands) < 2 {
			continue
		}
		targets = append(targets, operands[len(operands)-1])
	}
	return targets
}

// destinationFlag reports the directory named by a -t/--target-directory option
// starting at fields[i], plus how many extra fields it consumed.
func destinationFlag(fields []string, i int) (dest string, consumed int, ok bool) {
	token := stripShellTokenQuotes(fields[i])

	for _, prefix := range []string{"--target-directory=", "-t="} {
		if strings.HasPrefix(token, prefix) {
			return stripShellTokenQuotes(strings.TrimPrefix(token, prefix)), 0, true
		}
	}
	if token == "-t" || token == "--target-directory" {
		if i+1 >= len(fields) {
			return "", 0, false
		}
		return stripShellTokenQuotes(fields[i+1]), 1, true
	}
	return "", 0, false
}

func classifyBashProtectedWrite(command, projectRoot string) protectedPathMatch {
	best := protectedPathMatch{Level: protectedPathNone}
	for _, target := range extractBashWriteTargets(command) {
		best = strongerProtectedPathMatch(best, classifyProtectedPathAtRoot(target, projectRoot))
	}
	return best
}

func bashProtectedWriteHookResult(ctx hookproto.RuleContext, command string) *hookproto.HookResult {
	var askResult *hookproto.HookResult
	var warnResult *hookproto.HookResult

	for _, target := range extractBashWriteTargets(command) {
		match := classifyProtectedPathAtRoot(target, ctx.ProjectRoot)
		switch match.Level {
		case protectedPathDeny:
			if result := r03ProtectedPathAskResult(ctx, match.Path); result != nil {
				if askResult == nil {
					askResult = result
				}
				continue
			}
			return protectedPathHookResult(match, match.Path, "shell write to a protected path")
		case protectedPathAsk:
			if askResult == nil {
				askResult = protectedPathHookResult(match, match.Path, "shell write to a protected path")
			}
		case protectedPathWarn:
			if warnResult == nil {
				warnResult = protectedPathHookResult(match, match.Path, "shell write to a protected path")
			}
		}
	}

	if askResult != nil {
		return askResult
	}
	if warnResult != nil {
		return warnResult
	}
	return nil
}

// ---------------------------------------------------------------------------
// Project root check
// ---------------------------------------------------------------------------

func isUnderProjectRoot(filePath, projectRoot string) bool {
	// 相対パスは projectRoot を基準に解決
	resolved := filePath
	if !filepath.IsAbs(filePath) {
		resolved = filepath.Join(projectRoot, filePath)
	}
	cleaned := filepath.Clean(resolved)
	root := filepath.Clean(projectRoot)
	if !strings.HasSuffix(root, string(filepath.Separator)) {
		root += string(filepath.Separator)
	}
	return strings.HasPrefix(cleaned, root) || cleaned == root
}

// dangerousRemovalTargetsAreAgentOwned reports whether EVERY removal target of
// command lies in space this agent owns and is expected to churn:
//
//   - inside the project root (the working tree, incl. a task worktree), or
//   - inside THIS session's own scratch tree — a temp path carrying the session
//     id as a component. Not the shared temp root, and not another session's
//     scratch: /tmp holds other agents' and other tools' state too.
//
// Judgement is by TARGET, never by actor: a subagent gets no more latitude than
// the Lead, and being "in a worktree" is not itself a licence to delete.
//
// Deliberately NOT included: shellscan.IsAgentStatePath. R04 lets the agent
// WRITE into ~/.claude/projects/<slug>/memory and ~/.claude/plans without
// confirmation, but a recursive delete there destroys accumulated knowledge
// rather than churning scratch. Do not "simplify" this to R04 parity.
//
// Every pre-existing refusal is kept: unknown targets, glob/expansion/traversal
// metacharacters, an indeterminate shell context, and targets whose resolved
// path escapes the root all still fall through to confirmation.
func dangerousRemovalTargetsAreAgentOwned(command string, targets []string, projectRoot, sessionID string) bool {
	if len(targets) == 0 {
		return false
	}

	// The project root is optional: a target may still qualify as ephemeral
	// scratch when the root is unknown or unusable.
	resolvedRoot := ""
	if projectRoot != "" && filepath.IsAbs(projectRoot) {
		if candidate, err := filepath.EvalSymlinks(projectRoot); err == nil {
			if info, statErr := os.Stat(candidate); statErr == nil && info.IsDir() {
				resolvedRoot = candidate
			}
		}
	}

	// 削除対象が変数経由で組み立てられている場合、同一コマンド内で一度だけ
	// リテラル代入された変数に限って解決する。解決できないものはそのまま
	// 残るので、下の `$` チェックが従来どおり確認へ落とす。
	targets = shellscan.ExpandLiteralAssignments(command, targets)

	// 判定不能スキャナは `$` を「対象が増えうる」印として扱う。展開を静的に
	// 解決できた場合に限り、解析用に解決済みのコマンド文字列を渡す (実行は
	// しない)。1 つでも解決できない参照が残れば元のまま = 従来どおり確認。
	scanCommand := command
	if resolvedCommand, resolved := shellscan.ResolveCommandForAnalysis(command); resolved {
		scanCommand = resolvedCommand
	}
	if shellscan.RemovalContextIndeterminate(scanCommand, targets) {
		return false
	}
	for _, target := range targets {
		if target == "" || strings.ContainsAny(target, "$`*?[]{}~") || hasParentTraversalComponent(target) {
			return false
		}

		targetPath := target
		if !filepath.IsAbs(targetPath) {
			if resolvedRoot == "" {
				return false
			}
			targetPath = filepath.Join(projectRoot, targetPath)
		}
		resolvedTarget, err := evalSymlinksAllowMissing(targetPath)
		if err != nil {
			return false
		}
		if resolvedRoot != "" && pathWithinRoot(resolvedTarget, resolvedRoot) {
			continue
		}
		// Symlinks are already resolved above, so a link planted inside the
		// scratchpad that points at $HOME cannot pass as session scratch.
		if shellscan.IsWithinSessionScratch(resolvedTarget, sessionID) {
			continue
		}
		return false
	}

	return true
}

func hasParentTraversalComponent(filePath string) bool {
	for _, component := range strings.FieldsFunc(filePath, func(char rune) bool {
		return char == '/' || char == '\\'
	}) {
		if component == ".." {
			return true
		}
	}
	return false
}

func pathWithinRoot(filePath, root string) bool {
	relative, err := filepath.Rel(root, filePath)
	if err != nil || filepath.IsAbs(relative) {
		return false
	}
	return relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// ---------------------------------------------------------------------------
// Whitespace normalization (CC 2.1.98: wildcard pattern defense-in-depth)
// ---------------------------------------------------------------------------

// wsNormPattern matches one or more whitespace characters (spaces, tabs, etc.)
var wsNormPattern = regexp.MustCompile(`\s+`)

// normalizeCommand collapses consecutive whitespace characters (spaces, tabs,
// and other whitespace) into a single space and trims leading/trailing whitespace.
// This is used as a defense-in-depth measure before wildcard pattern matching,
// so that "git  push  --force" and "git\tpush\t--force" are treated identically
// to "git push --force".
func normalizeCommand(cmd string) string {
	return strings.TrimSpace(wsNormPattern.ReplaceAllString(cmd, " "))
}

// ---------------------------------------------------------------------------
// Dangerous deletion detection
// ---------------------------------------------------------------------------

func hasDangerousRmRf(command string) bool {
	dangerous, _ := shellscan.DangerousRemoval(command)
	return dangerous
}

// ---------------------------------------------------------------------------
// git push --force detection
// ---------------------------------------------------------------------------

var (
	forcePushPattern = regexp.MustCompile(`\bgit\s+push\b.*--force(?:-with-lease)?\b`)
	forcePushShort   = regexp.MustCompile(`\bgit\s+push\b.*-f\b`)
)

func hasForcePush(command string) bool {
	// Normalize whitespace before matching (CC 2.1.98: defense-in-depth)
	command = normalizeCommand(command)
	return forcePushPattern.MatchString(command) || forcePushShort.MatchString(command)
}

// ---------------------------------------------------------------------------
// sudo detection
// ---------------------------------------------------------------------------

// sudoPattern matches "sudo" preceded by start-of-string, whitespace,
// or shell metacharacters that introduce a subshell context: (, |, &, `, ;.
// This prevents bypass via "echo $(sudo ...)" or "echo `sudo ...`".
// CC 2.1.110: extended to cover subshell and backtick contexts.
var sudoPattern = regexp.MustCompile(`(?:^|[\s(|&` + "`" + `;])sudo\s`)

func hasSudo(command string) bool {
	command = normalizeCommand(command)
	return sudoPattern.MatchString(command)
}

// ---------------------------------------------------------------------------
// --no-verify / --no-gpg-sign detection
// ---------------------------------------------------------------------------

// shellTokenBoundary matches the characters that terminate a flag token on a
// shell command line. Besides whitespace, bash treats the metacharacters
// `;`, `&`, `|`, `(`, `)`, `<` and `>` as token separators, so a flag such as
// `--no-verify` is still effective when written as `--no-verify&&echo` or
// `--no-verify;cmd`. Anchoring on this class (instead of `\s` alone) prevents
// the detection from being bypassed by appending a metacharacter without a
// surrounding space.
const shellTokenBoundary = `[\s;&|()<>]`

var (
	noVerifyPattern  = regexp.MustCompile(`(?:^|` + shellTokenBoundary + `)--no-verify(?:` + shellTokenBoundary + `|$)`)
	noGpgSignPattern = regexp.MustCompile(`(?:^|` + shellTokenBoundary + `)--no-gpg-sign(?:` + shellTokenBoundary + `|$)`)
)

func hasDangerousGitBypassFlag(command string) bool {
	command = normalizeCommand(command)
	return noVerifyPattern.MatchString(command) || noGpgSignPattern.MatchString(command)
}

// ---------------------------------------------------------------------------
// Protected branch reset --hard detection
// ---------------------------------------------------------------------------

var protectedBranchRefPattern = regexp.MustCompile(
	`^(?:origin/|upstream/)?(?:refs/heads/)?(?:main|master)(?:[~^]\d+)?$`,
)

func normalizeGitToken(token string) string {
	token = strings.Trim(token, "'\"")
	// Strip the git force-refspec prefix ("+main", "+refs/heads/main") before
	// matching against protectedBranchRefPattern. The pattern is anchored
	// with "^" and does not account for the leading "+", so without this the
	// force-refspec shorthand slips past both R11 (reset --hard) and R12
	// (direct push) protected-branch detection (Phase 128.2).
	token = strings.TrimPrefix(token, "+")
	return token
}

func hasProtectedBranchResetHard(command string) bool {
	command = normalizeCommand(command)
	tokens := strings.Fields(command)
	resetIndex := -1
	hasHard := false
	for i, t := range tokens {
		normalized := normalizeGitToken(t)
		if normalized == "reset" {
			resetIndex = i
		}
		if normalized == "--hard" {
			hasHard = true
		}
	}
	if resetIndex == -1 || !hasHard {
		return false
	}
	for _, t := range tokens[resetIndex+1:] {
		normalized := normalizeGitToken(t)
		if strings.HasPrefix(normalized, "-") {
			continue
		}
		if protectedBranchRefPattern.MatchString(normalized) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Direct push to protected branch detection
// ---------------------------------------------------------------------------

var gitPushPattern = regexp.MustCompile(`\bgit\s+push\b`)

func hasDirectPushToProtectedBranch(command string) bool {
	command = normalizeCommand(command)
	if !gitPushPattern.MatchString(command) {
		return false
	}
	tokens := strings.Fields(command)
	pushIndex := -1
	for i, t := range tokens {
		if t == "push" {
			pushIndex = i
			break
		}
	}
	if pushIndex == -1 {
		return false
	}

	// Collect non-flag args after "push"
	var args []string
	for _, t := range tokens[pushIndex+1:] {
		if !strings.HasPrefix(t, "-") {
			args = append(args, t)
		}
	}
	if len(args) == 0 {
		return false
	}

	for _, arg := range args {
		normalized := normalizeGitToken(arg)
		if protectedBranchRefPattern.MatchString(normalized) {
			return true
		}
		// Check refspec (src:dst)
		parts := strings.SplitN(arg, ":", 2)
		if len(parts) == 2 {
			if protectedBranchRefPattern.MatchString(normalizeGitToken(parts[1])) {
				return true
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Protected review path detection (warn-only)
// ---------------------------------------------------------------------------

var protectedReviewPathPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?:^|/)package\.json$`),
	regexp.MustCompile(`(?:^|/)Dockerfile$`),
	regexp.MustCompile(`(?:^|/)docker-compose\.yml$`),
	regexp.MustCompile(`(?:^|/)\.github/workflows/[^/]+$`),
	regexp.MustCompile(`(?:^|/)schema\.prisma$`),
	regexp.MustCompile(`(?:^|/)wrangler\.toml$`),
	regexp.MustCompile(`(?:^|/)index\.html$`),
}

func isProtectedReviewPath(filePath string) bool {
	for _, p := range protectedReviewPathPatterns {
		if p.MatchString(filePath) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Secret file staging detection (R15)
// ---------------------------------------------------------------------------

var gitGlobalValueOpts = map[string]bool{
	"-C":             true,
	"-c":             true,
	"--git-dir":      true,
	"--work-tree":    true,
	"--namespace":    true,
	"--exec-path":    true,
	"--super-prefix": true,
}

// r15SecretStagingPatterns targets credential-bearing pathspecs that must not
// be staged by name. Bulk adds remain governed by .gitignore plus R02/R03.
var r15EnvFileStagingPattern = regexp.MustCompile(`(?:^|/)\.env(?:\.[^/]+)?$`)

var r15SecretStagingPatterns = []*regexp.Regexp{
	r15EnvFileStagingPattern,
	regexp.MustCompile(`(?:^|/)id_rsa(?:\.[^/]+)?$`),
	regexp.MustCompile(`(?:^|/)id_ed25519(?:\.[^/]+)?$`),
	regexp.MustCompile(`\.pem$`),
	regexp.MustCompile(`\.key$`),
	regexp.MustCompile(`\.p12$`),
	regexp.MustCompile(`\.pfx$`),
	regexp.MustCompile(`(?:^|/)\.npmrc$`),
	regexp.MustCompile(`(?:^|/)\.pypirc$`),
	regexp.MustCompile(`(?:^|/)credentials$`),
	regexp.MustCompile(`(?:^|/)secrets?/`),
	regexp.MustCompile(`(?:^|/)\.aws/`),
	regexp.MustCompile(`(?:^|/)\.ssh/`),
}

type shellToken struct {
	value  string
	quoted bool
	op     bool
}

func shellLex(command string) []shellToken {
	var tokens []shellToken
	var cur strings.Builder
	curQuoted := false
	curHas := false
	var quote byte

	emit := func() {
		if curHas {
			tokens = append(tokens, shellToken{value: cur.String(), quoted: curQuoted})
		}
		cur.Reset()
		curQuoted = false
		curHas = false
	}
	emitOp := func() {
		emit()
		tokens = append(tokens, shellToken{op: true})
	}

	for i := 0; i < len(command); i++ {
		c := command[i]

		if quote == '\'' {
			if c == '\'' {
				quote = 0
			} else {
				cur.WriteByte(c)
				curHas = true
			}
			continue
		}

		if quote == '"' {
			if c == '\\' && i+1 < len(command) {
				if n := command[i+1]; n == '"' || n == '\\' || n == '$' || n == '`' {
					cur.WriteByte(n)
					curHas = true
					i++
					continue
				}
			}
			if c == '"' {
				quote = 0
			} else {
				cur.WriteByte(c)
				curHas = true
			}
			continue
		}

		if c == '\\' && i+1 < len(command) {
			cur.WriteByte(command[i+1])
			curHas = true
			i++
			continue
		}

		switch c {
		case '\'', '"':
			quote = c
			curQuoted = true
			curHas = true
		case ' ', '\t', '\n', '\r':
			emit()
		case ';', '(', ')', '`':
			emitOp()
		case '|', '&':
			if i+1 < len(command) && command[i+1] == c {
				i++
			}
			emitOp()
		case '$':
			if i+1 < len(command) && command[i+1] == '(' {
				i++
				emitOp()
			} else {
				cur.WriteByte(c)
				curHas = true
			}
		default:
			cur.WriteByte(c)
			curHas = true
		}
	}
	emit()
	return tokens
}

func indexOfGitSubcommand(tokens []shellToken) int {
	for i := 0; i < len(tokens); i++ {
		if filepath.Base(tokens[i].value) != "git" {
			continue
		}
		for j := i + 1; j < len(tokens); j++ {
			t := tokens[j]
			// A token that starts with "-" is a git global flag regardless of
			// shell quoting: `git "-C" /repo add .env` is byte-identical to
			// `git -C /repo add .env` from git's perspective. Treating a quoted
			// flag as the subcommand let R15 be bypassed by quoting -C / -c /
			// --git-dir, so quoting must not short-circuit the flag-skip loop.
			if !strings.HasPrefix(t.value, "-") {
				return j
			}
			if !strings.Contains(t.value, "=") && gitGlobalValueOpts[t.value] {
				j++
			}
		}
		return -1
	}
	return -1
}

func gitAddPathspecs(args []shellToken) []string {
	var out []string
	for _, t := range args {
		if !t.quoted && (t.value == "--" || strings.HasPrefix(t.value, "-")) {
			continue
		}
		if t.value != "" {
			out = append(out, t.value)
		}
	}
	return out
}

func gitCommitPathspecs(args []shellToken) []string {
	var out []string
	sawSep := false
	for _, t := range args {
		if !sawSep {
			if !t.quoted && t.value == "--" {
				sawSep = true
			}
			continue
		}
		if t.value != "" {
			out = append(out, t.value)
		}
	}
	return out
}

type gitStagedPath struct {
	displayPath   string
	effectivePath string
}

func gitInvocationRoot(tokens []shellToken, subcommandIndex int, projectRoot string) string {
	gitCWD := projectRoot
	if gitCWD == "" {
		gitCWD = "."
	}
	workTree := ""

	gitIndex := -1
	for i := 0; i < subcommandIndex; i++ {
		if filepath.Base(tokens[i].value) == "git" {
			gitIndex = i
			break
		}
	}
	if gitIndex < 0 {
		return filepath.Clean(gitCWD)
	}

	for i := gitIndex + 1; i < subcommandIndex; i++ {
		option := tokens[i].value
		switch {
		case option == "-C" && i+1 < subcommandIndex:
			dir := tokens[i+1].value
			if filepath.IsAbs(dir) {
				gitCWD = filepath.Clean(dir)
			} else {
				gitCWD = filepath.Join(gitCWD, dir)
			}
			i++
		case option == "--work-tree" && i+1 < subcommandIndex:
			workTree = effectiveGitPath(tokens[i+1].value, gitCWD)
			i++
		case strings.HasPrefix(option, "--work-tree="):
			workTree = effectiveGitPath(strings.TrimPrefix(option, "--work-tree="), gitCWD)
		}
	}
	if workTree != "" {
		return filepath.Clean(workTree)
	}
	return filepath.Clean(gitCWD)
}

func effectiveGitPath(path, gitRoot string) string {
	if filepath.IsAbs(path) {
		return filepath.Clean(path)
	}
	return filepath.Clean(filepath.Join(gitRoot, path))
}

func hasUnresolvedGitWorkingDirectoryOverride(command string) bool {
	envPrefix := false
	tokens := shellLex(command)
	for i, token := range tokens {
		if token.op {
			envPrefix = false
			continue
		}

		value := token.value
		switch value {
		case "cd", "pushd", "popd":
			return true
		}
		if strings.HasPrefix(value, "GIT_WORK_TREE=") {
			return true
		}
		if (value == "-C" || value == "--work-tree") && i+1 < len(tokens) {
			if !isStaticGitDirectoryArgument(tokens[i+1].value) {
				return true
			}
		}
		if strings.HasPrefix(value, "--work-tree=") && !isStaticGitDirectoryArgument(strings.TrimPrefix(value, "--work-tree=")) {
			return true
		}

		if filepath.Base(value) == "env" {
			envPrefix = true
			continue
		}
		if envPrefix {
			if value == "-C" || value == "--chdir" || strings.HasPrefix(value, "--chdir=") {
				return true
			}
			if filepath.Base(value) == "git" {
				envPrefix = false
			}
		}
	}
	return false
}

func isStaticGitDirectoryArgument(value string) bool {
	if value == "" || strings.HasPrefix(value, "~") {
		return false
	}
	return !strings.ContainsAny(value, "$`*?[]{}%")
}

func extractGitStagedPaths(command, projectRoot string) []gitStagedPath {
	var paths []gitStagedPath
	var segment []shellToken

	flush := func() {
		if len(segment) == 0 {
			return
		}
		if idx := indexOfGitSubcommand(segment); idx >= 0 {
			gitRoot := gitInvocationRoot(segment, idx, projectRoot)
			var pathspecs []string
			switch segment[idx].value {
			case "add", "stage":
				pathspecs = gitAddPathspecs(segment[idx+1:])
			case "commit":
				pathspecs = gitCommitPathspecs(segment[idx+1:])
			}
			for _, path := range pathspecs {
				paths = append(paths, gitStagedPath{
					displayPath:   path,
					effectivePath: effectiveGitPath(path, gitRoot),
				})
			}
		}
		segment = nil
	}

	for _, tok := range shellLex(command) {
		if tok.op {
			flush()
			continue
		}
		segment = append(segment, tok)
	}
	flush()
	return paths
}

func secretFileStaging(command, projectRoot string) (string, bool) {
	unresolvedWorkingDirectory := hasUnresolvedGitWorkingDirectoryOverride(command)
	for _, stagedPath := range extractGitStagedPaths(command, projectRoot) {
		path := stagedPath.effectivePath
		isPublicTemplate := isPublicEnvTemplatePath(path)
		if isPublicTemplate && unresolvedWorkingDirectory {
			return stagedPath.displayPath, true
		}
		if isPublicTemplate && classifyProtectedPathAtRoot(path, projectRoot).Level == protectedPathDeny {
			return stagedPath.displayPath, true
		}
		for _, p := range r15SecretStagingPatterns {
			if p == r15EnvFileStagingPattern && isPublicTemplate {
				continue
			}
			if p.MatchString(path) {
				return stagedPath.displayPath, true
			}
		}
	}
	return "", false
}

// dangerousRemovalTargetsAreLexicallyLocal is the destructive_delete=warn
// counterpart of dangerousRemovalTargetsAreAgentOwned. It judges by the
// SPELLING of each target only: no symlink resolution, and no refusal because a
// preceding shell segment or directory change makes the real location
// unprovable. Relative targets are accepted as-is (the agent issued the
// command from the worktree); absolute targets must sit lexically under the
// project root or inside this session's scratch. Anything that could widen the
// target set at runtime — shell expansion, globs, `..`, the bare `.` / `/` —
// still returns false so the rule keeps asking.
func dangerousRemovalTargetsAreLexicallyLocal(command string, targets []string, projectRoot, sessionID string) bool {
	if len(targets) == 0 {
		return false
	}
	targets = shellscan.ExpandLiteralAssignments(command, targets)

	cleanRoot := ""
	if projectRoot != "" && filepath.IsAbs(projectRoot) {
		cleanRoot = filepath.Clean(projectRoot)
	}
	// Without a usable project root there is no worktree to anchor a relative
	// spelling to (and the guardrail layer could not write the review record
	// either) — approving here would be a silent allow, so keep asking.
	if cleanRoot == "" {
		return false
	}

	for _, target := range targets {
		if target == "" || strings.ContainsAny(target, "$`*?[]{}~") || hasParentTraversalComponent(target) {
			return false
		}
		cleaned := filepath.Clean(target)
		if cleaned == "." || cleaned == string(filepath.Separator) {
			return false
		}
		if !filepath.IsAbs(cleaned) {
			continue
		}
		if pathWithinRoot(cleaned, cleanRoot) {
			continue
		}
		if shellscan.IsWithinSessionScratch(cleaned, sessionID) {
			continue
		}
		return false
	}
	return true
}
