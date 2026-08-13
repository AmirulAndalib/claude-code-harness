package shellscan

import (
	"path/filepath"
	"regexp"
	"strings"
)

// 実際のエージェントは削除対象をリテラルで書かず、直前の行で組み立てた変数を
// 使う:
//
//	SCRATCH=/private/tmp/claude-502/<project>/<session>/scratchpad
//	FAKE="$SCRATCH/fakerepo2"
//	rm -rf "$FAKE"
//
// 抽出される対象は `$FAKE` のままなので、封じ込め判定は「展開結果が分からない」
// として必ず確認へ落ちる。ここでは *同一コマンド文字列の中で一度だけ*
// リテラル代入された変数に限って解決し、削除対象が実際にどこを指すのかを
// 判定器に見せる。曖昧さが少しでも残る形は展開せず、従来どおり確認へ落とす。

var assignmentNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// 変数参照 `$NAME` / `${NAME}`。
var variableReferencePattern = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)`)

// 展開を諦めるべき文字。コマンド置換・glob・チルダ展開・単語分割が絡むと、
// 静的には対象が決まらない。
const unresolvableValueChars = "`*?[]{}~ \t"

const maxVariableResolutionPasses = 8

// ExpandLiteralAssignments resolves `$VAR` / `${VAR}` inside targets using
// assignments found in command, and returns the targets with every fully
// resolvable reference replaced. A target that cannot be resolved with full
// confidence is returned unchanged, so callers that reject `$` in targets keep
// rejecting it.
//
// A variable is usable only when ALL of the following hold:
//
//   - it is assigned exactly once in the whole command (a second assignment
//     makes the value at the point of use ambiguous),
//   - its value contains no command substitution, glob, tilde or whitespace,
//   - every reference inside its value resolves to a usable variable,
//   - the resulting target is an absolute path.
//
// The function never expands to a relative path and never guesses: it is a
// confidence filter, not a shell.
func ExpandLiteralAssignments(command string, targets []string) []string {
	if len(targets) == 0 {
		return targets
	}
	needsExpansion := false
	for _, target := range targets {
		if strings.Contains(target, "$") {
			needsExpansion = true
			break
		}
	}
	if !needsExpansion {
		return targets
	}

	values := resolveLiteralAssignments(StripNonExecutableText(command))
	if len(values) == 0 {
		return targets
	}

	expanded := make([]string, len(targets))
	for i, target := range targets {
		expanded[i] = target
		if !strings.Contains(target, "$") {
			continue
		}
		substituted, ok := substituteVariables(target, values)
		if !ok || !filepath.IsAbs(substituted) {
			continue
		}
		expanded[i] = substituted
	}
	return expanded
}

// ResolveCommandForAnalysis returns command with every `$VAR` / `${VAR}`
// reference replaced by its statically resolved literal, and reports whether
// the whole command could be resolved (no `$` left).
//
// The result is for ANALYSIS ONLY — it is never executed. Its purpose is to let
// the indeterminacy scanner see a command whose expansions are already known,
// instead of treating any `$` as "this could add removal targets". Resolution
// refuses values containing whitespace or glob characters, so substitution
// cannot introduce new word splitting or new matches.
//
// When ok is false the caller must keep using the original command: a single
// unresolved reference means the target set is genuinely unknown.
func ResolveCommandForAnalysis(command string) (string, bool) {
	if !strings.Contains(command, "$") {
		return command, true
	}
	values := resolveLiteralAssignments(StripNonExecutableText(command))
	if len(values) == 0 {
		return command, false
	}
	resolved, ok := substituteVariables(command, values)
	if !ok {
		return command, false
	}
	// 参照をすべて literal へ置き換えた後、純粋な代入だけの文は解析上もはや
	// 何も変えない。残しておくと「削除の前に対象解決を変えうる文がある」と
	// 判定され、せっかく解決した意味が消える。代入以外の語を 1 つでも含む文
	// (`A=1 rm -rf /x` のような前置き代入) は絶対に落とさない。
	return dropPureAssignmentStatements(resolved), true
}

func dropPureAssignmentStatements(command string) string {
	lines := strings.Split(command, "\n")
	kept := make([]string, 0, len(lines))
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			kept = append(kept, line)
			continue
		}
		pureAssignment := true
		for _, field := range fields {
			if !isAssignment(field) {
				pureAssignment = false
				break
			}
		}
		if pureAssignment {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

// resolveLiteralAssignments returns the variables that are assigned exactly
// once to a value that resolves to a literal string.
func resolveLiteralAssignments(command string) map[string]string {
	raw := map[string]string{}
	duplicated := map[string]bool{}

	for _, token := range assignmentTokens(command) {
		index := strings.IndexByte(token, '=')
		if index <= 0 {
			continue
		}
		name := token[:index]
		if !assignmentNamePattern.MatchString(name) {
			continue
		}
		if _, seen := raw[name]; seen {
			// 2 回以上代入された変数は、使用時点の値が静的に決まらない。
			duplicated[name] = true
			continue
		}
		raw[name] = unquoteValue(token[index+1:])
	}
	for name := range duplicated {
		delete(raw, name)
	}

	// 値そのものが他の変数を参照しうるので、収束するまで繰り返し解決する。
	resolved := map[string]string{}
	for pass := 0; pass < maxVariableResolutionPasses; pass++ {
		progressed := false
		for name, value := range raw {
			if _, done := resolved[name]; done {
				continue
			}
			if strings.ContainsAny(value, unresolvableValueChars) {
				continue
			}
			substituted, ok := substituteVariables(value, resolved)
			if !ok {
				continue
			}
			resolved[name] = substituted
			progressed = true
		}
		if !progressed {
			break
		}
	}
	return resolved
}

// assignmentTokens returns the `NAME=VALUE` words that start a statement.
// Splitting on shell separators keeps `FOO=bar` in `cmd --flag FOO=bar` out.
func assignmentTokens(command string) []string {
	segments := strings.FieldsFunc(command, func(char rune) bool {
		return char == '\n' || char == ';' || char == '&' || char == '|' || char == '(' || char == ')'
	})
	tokens := []string{}
	for _, segment := range segments {
		for _, field := range strings.Fields(segment) {
			if !isAssignment(field) {
				// 代入は文の先頭に連続して現れる。最初の非代入語で打ち切る。
				break
			}
			tokens = append(tokens, field)
		}
	}
	return tokens
}

// unquoteValue strips one layer of surrounding quotes. Single quotes suppress
// expansion in the shell, so a single-quoted value keeps any `$` literally and
// will simply fail to resolve later.
func unquoteValue(value string) string {
	if len(value) >= 2 {
		if (value[0] == '"' && value[len(value)-1] == '"') ||
			(value[0] == '\'' && value[len(value)-1] == '\'') {
			return value[1 : len(value)-1]
		}
	}
	return value
}

// substituteVariables replaces every `$NAME` / `${NAME}` in text using values.
// It reports false when any reference is missing, so the caller can decline to
// expand rather than produce a half-resolved path.
func substituteVariables(text string, values map[string]string) (string, bool) {
	if !strings.Contains(text, "$") {
		return text, true
	}
	complete := true
	result := variableReferencePattern.ReplaceAllStringFunc(text, func(match string) string {
		name := strings.Trim(match, "${}")
		value, ok := values[name]
		if !ok {
			complete = false
			return match
		}
		return value
	})
	if !complete || strings.Contains(result, "$") {
		return text, false
	}
	return result, true
}
