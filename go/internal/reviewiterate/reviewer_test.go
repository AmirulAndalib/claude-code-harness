package reviewiterate

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestHeadlessReviewPromptsSpecifyResponseContract(t *testing.T) {
	var prompt string
	runner := func(_ context.Context, _ string, args ...string) (string, error) {
		prompt = args[len(args)-1]
		return `{"findings":["Evidence: source.go:12; missing check"],"refined":"Add the boundary test"}`, nil
	}
	h := HeadlessCLIReviewer{Runner: runner, SessionIDGen: func(string) string { return "fresh-review" }}
	if _, err := h.Review(context.Background(), "security", "worker evidence"); err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"JSON", `"findings"`, `"refined"`, "security", "worker evidence", "evidence"} {
		if !strings.Contains(prompt, required) {
			t.Errorf("advisory prompt does not specify %q: %q", required, prompt)
		}
	}
	b := HeadlessCLIBrain{Runner: func(_ context.Context, _ string, args ...string) (string, error) {
		prompt = args[len(args)-1]
		return `{"verdict":"REQUEST_CHANGES"}`, nil
	}}
	if _, err := b.Verdict(context.Background(), "worker evidence", []Review{{Lens: "scope", Findings: []string{"unverified change"}}}); err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"JSON", `"verdict"`, "APPROVE", "REQUEST_CHANGES", "worker evidence", "unverified change"} {
		if !strings.Contains(prompt, required) {
			t.Errorf("brain prompt does not specify %q: %q", required, prompt)
		}
	}
}

func TestParseBrainVerdictRejectsAmbiguousApproval(t *testing.T) {
	for _, output := range []string{
		"do not APPROVE; REQUEST_CHANGES", "NOT APPROVED", "APPROVE", "REQUEST_CHANGES",
		`{"verdict":"do not APPROVE; REQUEST_CHANGES"}`, `{"verdict":"UNKNOWN","note":"APPROVE"}`,
		`{"note":"APPROVE"}`, `{"verdict":"REQUEST_CHANGES","verdict":"APPROVE"}`,
		`{"verdict":"APPROVE","verdict":"REQUEST_CHANGES"}`, `{"verdict":"APPROVE"} REQUEST_CHANGES`,
		`["APPROVE"]`, "", "null",
	} {
		t.Run(output, func(t *testing.T) {
			verdict, err := parseBrainVerdict(output)
			if err == nil || verdict == VerdictApprove {
				t.Fatalf("ambiguous or non-contract output returned verdict=%q, err=%v", verdict, err)
			}
		})
	}
	for _, verdict := range []Verdict{VerdictApprove, VerdictRequestChanges} {
		got, err := parseBrainVerdict(" \n{\"verdict\":\"" + string(verdict) + "\"}\n")
		if err != nil || got != verdict {
			t.Errorf("valid JSON verdict = %q, %v; want %q", got, err, verdict)
		}
	}
}

func TestParseAdvisoryRequiresFindingsContract(t *testing.T) {
	for _, output := range []string{"", "looks fine", "null", `{"verdict":"APPROVE"}`, `{"findings":null}`, `{"findings":"none"}`} {
		if _, err := parseAdvisoryResponse("scope", output); err == nil {
			t.Errorf("invalid advisory output accepted as a review: %q", output)
		}
	}
	if review, err := parseAdvisoryResponse("scope", `{"findings":[],"refined":""}`); err != nil || len(review.Findings) != 0 {
		t.Errorf("valid empty findings = %+v, %v", review, err)
	}
}

func TestHeadlessCLIRealCompanionReadOnlyDispatch(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("companion dispatch requires bash")
	}
	root := t.TempDir()
	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	capture := filepath.Join(root, "argv")
	for name, script := range map[string]string{
		"codex":   "#!/usr/bin/env bash\nprintf '%s\\0' \"$@\" > \"$HARNESS_TEST_REVIEW_ARGV\"\nprintf '%s\\n' \"$HARNESS_TEST_REVIEW_OUTPUT\"\n",
		"harness": "#!/usr/bin/env bash\nif [ \"$3\" = capture ]; then printf '{}' > \"$5\"; fi\n",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", root)
	t.Setenv("HARNESS_BIN", filepath.Join(bin, "harness"))
	t.Setenv("HARNESS_ORCHESTRATION_LEDGER", filepath.Join(root, "ledger.jsonl"))
	t.Setenv("HARNESS_CODEX_PRIMARY_ENV_STATE_FILE", filepath.Join(root, "primary.json"))
	t.Setenv("HARNESS_TEST_REVIEW_ARGV", capture)
	t.Setenv("HARNESS_DISABLE_MODEL_ROUTING", "1")
	t.Setenv("CODEX_EFFORT", "ultra")
	script, err := filepath.Abs(filepath.Join("..", "..", "..", "scripts", "codex-companion.sh"))
	if err != nil {
		t.Fatal(err)
	}
	for _, brain := range []bool{false, true} {
		t.Run(map[bool]string{false: "advisory", true: "brain"}[brain], func(t *testing.T) {
			if brain {
				t.Setenv("HARNESS_TEST_REVIEW_OUTPUT", `{"verdict":"REQUEST_CHANGES"}`)
				b := HeadlessCLIBrain{Runner: DefaultScriptRunner(), CompanionScript: script}
				_, err = b.Verdict(context.Background(), "worker evidence", nil)
			} else {
				t.Setenv("HARNESS_TEST_REVIEW_OUTPUT", `{"findings":[],"refined":""}`)
				h := HeadlessCLIReviewer{Runner: DefaultScriptRunner(), CompanionScript: script, SessionIDGen: func(string) string { return "fresh" }}
				_, err = h.Review(context.Background(), "scope", "worker evidence")
			}
			if err != nil {
				t.Fatalf("real companion rejected headless request: %v", err)
			}
			data, err := os.ReadFile(capture)
			if err != nil {
				t.Fatal(err)
			}
			args := strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
			readonly := false
			for i, arg := range args {
				if arg == "--sandbox" && i+1 < len(args) && args[i+1] == "read-only" {
					readonly = true
				}
				if arg == "--write" || arg == "--read" || arg == "--full-auto" || arg == "--dangerously-bypass-approvals-and-sandbox" {
					t.Errorf("unexpected permission/unsupported flag: %q", args)
				}
			}
			if !readonly || args[0] != "exec" {
				t.Fatalf("runtime argv does not enforce read-only: %q", args)
			}
		})
	}
}
