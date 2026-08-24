package livemsggate

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

type Verdict string

const (
	VerdictSend Verdict = "SEND"
	VerdictHold Verdict = "HOLD"
)

type CheckName string

const (
	CheckFileExists       CheckName = "file_exists"
	CheckCommitExists     CheckName = "commit_exists"
	CheckGitStatusMatches CheckName = "git_status_matches"
	CheckAgentReview      CheckName = "agent_review"
)

type CheckResult string

const (
	ResultPass          CheckResult = "pass"
	ResultFail          CheckResult = "fail"
	ResultNotApplicable CheckResult = "not_applicable"
	ResultNotObserved   CheckResult = "not_observed"
)

type Check struct {
	Check   CheckName   `json:"check"`
	Result  CheckResult `json:"result"`
	Subject string      `json:"subject,omitempty"`
	Detail  string      `json:"detail,omitempty"`
}

type Result struct {
	SchemaVersion string  `json:"schema_version"`
	Verdict       Verdict `json:"verdict"`
	Reason        string  `json:"reason"`
	Checked       []Check `json:"checked"`
}

type Options struct {
	RepoRoot string
	Body     string
	Runner   CommandRunner
	Reviewer Reviewer
}

var pathPattern = regexp.MustCompile("`([^`]+)`")
var plainPathPattern = regexp.MustCompile("(?:^|[[:space:]\\\"'`(（「])([A-Za-z0-9._@+-]+(?:/[A-Za-z0-9._@+-]+)+|[A-Za-z0-9_@+-]+\\.[A-Za-z0-9._@+-]+)(?:$|[[:space:]\\\"'`)）」。、,:;])")
var commitPattern = regexp.MustCompile(`(?i)(?:^|[^0-9a-f])([0-9a-f]{7,40})(?:$|[^0-9a-f])`)
var cleanClaimPattern = regexp.MustCompile(`(?i)(変更なし|変更はありません|作業ツリー.{0,12}(clean|クリーン)|working tree.{0,12}clean|no (uncommitted )?changes|(すべて.{0,8})?(commit|コミット).{0,4}(した|済み))`)
var unresolvedClaimPattern = regexp.MustCompile(`(?i)(テスト.{0,16}(成功|失敗|pass|green)|tests?.{0,16}(passed|failed|green)|レビュー.{0,16}(承認|approve)|動作確認.{0,8}(済み|完了)|実装.{0,16}(完了|済み|しました))`)
var safePathPattern = regexp.MustCompile(`^[A-Za-z0-9._@+-]+(?:/[A-Za-z0-9._@+-]+)*$`)

type CommandRunner interface {
	Run(ctx context.Context, dir, name string, args ...string) ([]byte, error)
}

type Reviewer interface {
	Review(ctx context.Context, repoRoot, body string, machineChecks []Check) ReviewResult
}

type ReviewResult struct {
	Result CheckResult
	Detail string
}

type execRunner struct{}

func (execRunner) Run(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	return cmd.CombinedOutput()
}

func Evaluate(ctx context.Context, opts Options) Result {
	result := Result{SchemaVersion: "livemsg-gate.v1", Verdict: VerdictSend, Reason: "machine checks passed", Checked: []Check{}}
	runner := opts.Runner
	if runner == nil {
		runner = execRunner{}
	}
	unresolved := false
	paths, uncertainPaths := extractPaths(opts.Body)
	for _, subject := range uncertainPaths {
		result.Checked = append(result.Checked, Check{Check: CheckFileExists, Result: ResultNotApplicable, Subject: truncate(subject, 512), Detail: "text is not confidently a repo-relative path"})
	}
	for _, path := range paths {
		check := Check{Check: CheckFileExists, Subject: truncate(path, 512)}
		rootInfo, rootErr := os.Stat(opts.RepoRoot)
		if rootErr != nil || !rootInfo.IsDir() {
			check.Result = ResultNotObserved
			check.Detail = "repository root could not be inspected"
			unresolved = true
		} else if _, err := os.Stat(filepath.Join(opts.RepoRoot, filepath.FromSlash(path))); err == nil {
			check.Result = ResultPass
			check.Detail = "path exists"
		} else if os.IsNotExist(err) {
			check.Result = ResultFail
			check.Detail = "path does not exist"
			result.Verdict = VerdictHold
			result.Reason = truncate(fmt.Sprintf("mentioned path %q does not exist", path), 2048)
		} else {
			check.Result = ResultNotObserved
			check.Detail = "path could not be inspected"
			unresolved = true
		}
		result.Checked = append(result.Checked, check)
	}
	for _, match := range commitPattern.FindAllStringSubmatch(opts.Body, -1) {
		commit := match[1]
		check := Check{Check: CheckCommitExists, Subject: commit}
		if _, err := runner.Run(ctx, opts.RepoRoot, "git", "rev-parse", "--verify", "--quiet", commit+"^{commit}"); err == nil {
			check.Result = ResultPass
			check.Detail = "commit resolves"
		} else if _, probeErr := runner.Run(ctx, opts.RepoRoot, "git", "rev-parse", "--is-inside-work-tree"); probeErr == nil {
			check.Result = ResultFail
			check.Detail = "commit does not resolve"
			result.Verdict = VerdictHold
			result.Reason = fmt.Sprintf("mentioned commit %q does not exist", commit)
		} else {
			check.Result = ResultNotObserved
			check.Detail = "git repository could not be inspected"
			unresolved = true
		}
		result.Checked = append(result.Checked, check)
	}
	if claim := cleanClaimPattern.FindString(opts.Body); claim != "" {
		check := Check{Check: CheckGitStatusMatches, Subject: claim}
		output, err := runner.Run(ctx, opts.RepoRoot, "git", "status", "--porcelain")
		if err != nil {
			check.Result = ResultNotObserved
			check.Detail = "git status could not be inspected"
			unresolved = true
		} else if len(strings.TrimSpace(string(output))) == 0 {
			check.Result = ResultPass
			check.Detail = "git status is clean"
		} else {
			check.Result = ResultFail
			check.Detail = "git status has changes"
			result.Verdict = VerdictHold
			result.Reason = "message claims a clean worktree, but git status has changes"
		}
		result.Checked = append(result.Checked, check)
	}

	if unresolvedClaimPattern.MatchString(opts.Body) {
		unresolved = true
	}
	if unresolved && result.Verdict != VerdictHold {
		review := ReviewResult{Result: ResultNotObserved, Detail: "agent reviewer is unavailable"}
		if opts.Reviewer != nil {
			review = opts.Reviewer.Review(ctx, opts.RepoRoot, opts.Body, append([]Check(nil), result.Checked...))
		}
		if !validCheckResult(review.Result) {
			review = ReviewResult{Result: ResultNotObserved, Detail: "agent reviewer returned an invalid result"}
		}
		review.Detail = truncate(review.Detail, 1024)
		result.Checked = append(result.Checked, Check{Check: CheckAgentReview, Result: review.Result, Subject: truncate(strings.TrimSpace(opts.Body), 512), Detail: review.Detail})
		switch review.Result {
		case ResultPass, ResultNotApplicable:
			result.Reason = "verification checks passed"
		case ResultFail:
			result.Verdict = VerdictHold
			result.Reason = truncate(nonEmpty(review.Detail, "agent review rejected an unresolved claim"), 2048)
		default:
			result.Verdict = VerdictHold
			result.Reason = truncate(nonEmpty(review.Detail, "an asserted claim could not be verified"), 2048)
		}
	}
	return result
}

func extractPaths(body string) ([]string, []string) {
	seen := make(map[string]bool)
	var paths []string
	var uncertain []string
	for _, match := range pathPattern.FindAllStringSubmatch(body, -1) {
		value := match[1]
		if isRepoRelativePath(value) {
			if !seen[value] {
				seen[value] = true
				paths = append(paths, value)
			}
		} else {
			uncertain = append(uncertain, value)
		}
	}
	for _, match := range plainPathPattern.FindAllStringSubmatch(body, -1) {
		value := match[1]
		if isRepoRelativePath(value) && !seen[value] {
			seen[value] = true
			paths = append(paths, value)
		}
	}
	return paths, uncertain
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) > limit {
		return string(runes[:limit])
	}
	return value
}

func nonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func validCheckResult(result CheckResult) bool {
	return result == ResultPass || result == ResultFail || result == ResultNotApplicable || result == ResultNotObserved
}

func isRepoRelativePath(value string) bool {
	if value == "" || filepath.IsAbs(value) || strings.HasPrefix(value, "./") || strings.Contains(value, "\\") || !safePathPattern.MatchString(value) {
		return false
	}
	cleaned := filepath.Clean(filepath.FromSlash(value))
	return cleaned != "." && cleaned != ".." && !strings.HasPrefix(cleaned, ".."+string(filepath.Separator)) &&
		(strings.Contains(value, "/") || strings.Contains(filepath.Base(value), "."))
}
