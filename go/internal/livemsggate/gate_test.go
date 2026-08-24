package livemsggate_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/internal/livemsggate"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

type failingRunner struct{}

func (failingRunner) Run(context.Context, string, string, ...string) ([]byte, error) {
	return nil, errors.New("git unavailable")
}

type fakeReviewer struct {
	calls  int
	result livemsggate.ReviewResult
}

func (r *fakeReviewer) Review(context.Context, string, string, []livemsggate.Check) livemsggate.ReviewResult {
	r.calls++
	return r.result
}

func TestEvaluateHoldsMissingMentionedFile(t *testing.T) {
	repoRoot := t.TempDir()

	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: repoRoot,
		Body:     "`docs/missing-report.md` を作成しました。",
	})

	if result.Verdict != livemsggate.VerdictHold {
		t.Fatalf("verdict = %q, want HOLD; result = %#v", result.Verdict, result)
	}
	if len(result.Checked) != 1 {
		t.Fatalf("checked count = %d, want 1; result = %#v", len(result.Checked), result)
	}
	check := result.Checked[0]
	if check.Check != livemsggate.CheckFileExists || check.Result != livemsggate.ResultFail {
		t.Fatalf("check = %#v, want file_exists fail", check)
	}
}

func TestEvaluateHoldsMissingPlainMentionedFile(t *testing.T) {
	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: t.TempDir(),
		Body:     "docs/missing-report.md を作成しました。",
	})

	assertCheck(t, result, livemsggate.CheckFileExists, livemsggate.ResultFail)
	if result.Verdict != livemsggate.VerdictHold {
		t.Fatalf("verdict = %q, want HOLD", result.Verdict)
	}
}

func TestEvaluateDoesNotTreatUncertainBackticksAsMissingPath(t *testing.T) {
	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: t.TempDir(),
		Body:     "`go test ./...` を実行します。",
	})

	if result.Verdict != livemsggate.VerdictSend {
		t.Fatalf("verdict = %q, want SEND; result = %#v", result.Verdict, result)
	}
	assertCheck(t, result, livemsggate.CheckFileExists, livemsggate.ResultNotApplicable)
}

func TestEvaluateHoldsUnknownCommit(t *testing.T) {
	repoRoot := initRepo(t)

	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: repoRoot,
		Body:     "commit deadbee は存在します。",
	})

	assertCheck(t, result, livemsggate.CheckCommitExists, livemsggate.ResultFail)
	if result.Verdict != livemsggate.VerdictHold {
		t.Fatalf("verdict = %q, want HOLD", result.Verdict)
	}
}

func TestEvaluateHoldsCleanClaimInDirtyRepo(t *testing.T) {
	repoRoot := initRepo(t)
	if err := os.WriteFile(filepath.Join(repoRoot, "dirty.txt"), []byte("dirty"), 0o600); err != nil {
		t.Fatal(err)
	}

	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: repoRoot,
		Body:     "作業ツリーに変更なしです。",
	})

	assertCheck(t, result, livemsggate.CheckGitStatusMatches, livemsggate.ResultFail)
	if result.Verdict != livemsggate.VerdictHold {
		t.Fatalf("verdict = %q, want HOLD", result.Verdict)
	}
}

func TestNotObservedDoesNotBecomeFail(t *testing.T) {
	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: t.TempDir(),
		Body:     "commit deadbee は存在します。",
		Runner:   failingRunner{},
	})

	assertCheck(t, result, livemsggate.CheckCommitExists, livemsggate.ResultNotObserved)
	for _, check := range result.Checked {
		if check.Result == livemsggate.ResultFail {
			t.Fatalf("not_observed was converted to fail: %#v", result)
		}
	}
}

func TestMissingRepoRootMakesFileCheckNotObserved(t *testing.T) {
	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: filepath.Join(t.TempDir(), "missing-repo"),
		Body:     "`docs/report.md` を作成しました。",
	})

	assertCheck(t, result, livemsggate.CheckFileExists, livemsggate.ResultNotObserved)
	for _, check := range result.Checked {
		if check.Result == livemsggate.ResultFail {
			t.Fatalf("unavailable repo was reported as a failed claim: %#v", result)
		}
	}
}

func TestAgentReviewRunsOnceOnlyForUnresolvedClaim(t *testing.T) {
	reviewer := &fakeReviewer{result: livemsggate.ReviewResult{Result: livemsggate.ResultPass, Detail: "test evidence found"}}
	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: t.TempDir(),
		Body:     "テストはすべて成功しました。",
		Reviewer: reviewer,
	})

	if reviewer.calls != 1 {
		t.Fatalf("review calls = %d, want 1", reviewer.calls)
	}
	assertCheck(t, result, livemsggate.CheckAgentReview, livemsggate.ResultPass)
}

func TestAgentReviewDoesNotRunForMachineDecidableClaim(t *testing.T) {
	reviewer := &fakeReviewer{result: livemsggate.ReviewResult{Result: livemsggate.ResultPass}}
	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: t.TempDir(),
		Body:     "`docs/missing-report.md` を作成しました。",
		Reviewer: reviewer,
	})

	if reviewer.calls != 0 {
		t.Fatalf("review calls = %d, want 0", reviewer.calls)
	}
	if result.Verdict != livemsggate.VerdictHold {
		t.Fatalf("verdict = %q, want HOLD", result.Verdict)
	}
}

func TestResultMatchesLivemsgGateSchema(t *testing.T) {
	result := livemsggate.Evaluate(context.Background(), livemsggate.Options{
		RepoRoot: t.TempDir(),
		Body:     "`docs/missing-report.md` を作成しました。",
	})
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var instance any
	if err := json.Unmarshal(raw, &instance); err != nil {
		t.Fatal(err)
	}

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	schemaPath := filepath.Join(filepath.Dir(file), "..", "..", "..", "templates", "schemas", "livemsg-gate.v1.json")
	schemaData, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatal(err)
	}
	schemaDoc, err := jsonschema.UnmarshalJSON(bytes.NewReader(schemaData))
	if err != nil {
		t.Fatal(err)
	}
	compiler := jsonschema.NewCompiler()
	const schemaURL = "https://claude-code-harness.local/schemas/livemsg-gate.v1.json"
	if err := compiler.AddResource(schemaURL, schemaDoc); err != nil {
		t.Fatal(err)
	}
	schema, err := compiler.Compile(schemaURL)
	if err != nil {
		t.Fatal(err)
	}
	if err := schema.Validate(instance); err != nil {
		t.Fatalf("result does not match schema: %v\n%s", err, raw)
	}
}

func initRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	cmd := exec.Command("git", "init", "-q")
	cmd.Dir = dir
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, output)
	}
	return dir
}

func assertCheck(t *testing.T, result livemsggate.Result, name livemsggate.CheckName, want livemsggate.CheckResult) {
	t.Helper()
	for _, check := range result.Checked {
		if check.Check == name {
			if check.Result != want {
				t.Fatalf("%s result = %q, want %q; result = %#v", name, check.Result, want, result)
			}
			return
		}
	}
	t.Fatalf("check %s missing; result = %#v", name, result)
}
