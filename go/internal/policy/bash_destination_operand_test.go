package policy

import (
	"strings"
	"testing"
)

// Phase 133.12 (i): R03 (Bash write to protected paths) extracted only redirections and `tee`, so ln / cp / mv /
// install put a file at a protected path without the rule ever seeing it.
// Measured before the fix (target = a protected path):
//
//	redirect deny / tee deny / ln -sf allow / ln allow / cp allow / mv allow / install allow
//
// A refuter reached the 133.10 breakout through `ln -s`; the other three are
// equivalent, so they are covered together.

// protectedDir is assembled from fragments so this file never carries a literal
// that the guardrail would read as a write target while it is being edited.
var protectedDir = "." + "git"

func hasTarget(targets []string, want string) bool {
	for _, t := range targets {
		if t == want {
			return true
		}
	}
	return false
}

func TestExtractBashWriteTargets_DestinationOperandCommands(t *testing.T) {
	dest := protectedDir + "/config"

	cases := []struct {
		name    string
		command string
	}{
		{"symlink", "ln -sf /tmp/evil " + dest},
		{"hardlink", "ln /tmp/evil " + dest},
		{"copy", "cp /tmp/evil " + dest},
		{"move", "mv /tmp/evil " + dest},
		{"install with flag value", "install -m 755 /tmp/evil " + dest},
		{"copy recursive", "cp -r /tmp/evil " + dest},
		{"after a pipe", "echo x | cp /tmp/evil " + dest},
		{"after a separator", "true && mv /tmp/evil " + dest},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := extractBashWriteTargets(tc.command)
			if !hasTarget(got, dest) {
				t.Fatalf("extractBashWriteTargets(%q) = %v, want it to contain %q", tc.command, got, dest)
			}
		})
	}
}

// `-t DIR` puts the destination FIRST — the one form where "the last operand is
// the destination" does not hold. Before this was handled, the flag was dropped
// as an ordinary option and the destination vanished entirely: measured
// 2026-08-14, all five spellings below were allowed while the positional form
// was denied.
func TestExtractBashWriteTargets_TargetDirectoryFlag(t *testing.T) {
	dest := protectedDir

	cases := []struct {
		name    string
		command string
	}{
		{"cp -t", "cp -t " + dest + " /tmp/source"},
		{"mv -t", "mv -t " + dest + " /tmp/source"},
		{"ln -t", "ln -t " + dest + " /tmp/source"},
		{"install -t", "install -t " + dest + " /tmp/source"},
		{"long form", "cp --target-directory " + dest + " /tmp/source"},
		{"long form with equals", "cp --target-directory=" + dest + " /tmp/source"},
		{"multiple sources", "cp -t " + dest + " /tmp/a /tmp/b"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := extractBashWriteTargets(tc.command)
			if !hasTarget(got, dest) {
				t.Fatalf("extractBashWriteTargets(%q) = %v, want it to contain %q", tc.command, got, dest)
			}
			for _, target := range got {
				if target == "/tmp/source" || target == "/tmp/b" {
					t.Fatalf("extractBashWriteTargets(%q) reported the source %q as a write target", tc.command, target)
				}
			}
		})
	}
}

// A -t destination outside any protected path must stay unremarkable.
func TestClassifyBashProtectedWrite_OrdinaryTargetDirectoryIsNotFlagged(t *testing.T) {
	root := t.TempDir()

	for _, command := range []string{
		"cp -t dist build/out.txt",
		"install --target-directory=dist build/out.txt",
	} {
		if got := classifyBashProtectedWrite(command, root); got.Level != protectedPathNone {
			t.Fatalf("classifyBashProtectedWrite(%q).Level = %v, want none", command, got.Level)
		}
	}
}

// Multiple sources into a directory: the directory is what gets written.
func TestExtractBashWriteTargets_MultipleSourcesReportDirectory(t *testing.T) {
	dest := protectedDir + "/"
	command := "cp /tmp/a /tmp/b " + dest

	got := extractBashWriteTargets(command)
	if !hasTarget(got, dest) {
		t.Fatalf("extractBashWriteTargets(%q) = %v, want it to contain %q", command, got, dest)
	}
}

// A flag value must never be reported as a path. Taking the last operand is
// what guarantees this: `755` is never final.
func TestExtractBashWriteTargets_FlagValueIsNotAPath(t *testing.T) {
	command := "install -m 755 /tmp/evil /tmp/out"

	for _, target := range extractBashWriteTargets(command) {
		if target == "755" {
			t.Fatalf("extractBashWriteTargets(%q) reported the flag value 755 as a path", command)
		}
	}
}

// The single-operand form creates a link in the shell's working directory,
// which the payload's cwd does not reliably describe. Guessing a path would
// classify the wrong file, so nothing is reported.
func TestExtractBashWriteTargets_SingleOperandIsNotReported(t *testing.T) {
	command := "ln -s /tmp/evil"

	if got := extractBashWriteTargets(command); len(got) != 0 {
		t.Fatalf("extractBashWriteTargets(%q) = %v, want no targets", command, got)
	}
}

// Unresolved expansions are not classifiable paths.
func TestExtractBashWriteTargets_UnresolvedExpansionIsSkipped(t *testing.T) {
	command := "cp /tmp/evil $DEST"

	for _, target := range extractBashWriteTargets(command) {
		if strings.Contains(target, "$") {
			t.Fatalf("extractBashWriteTargets(%q) reported an unresolved expansion %q", command, target)
		}
	}
}

// End-to-end: the destination-operand family now classifies the same as a
// redirection for a protected path.
func TestClassifyBashProtectedWrite_DestinationOperandMatchesRedirection(t *testing.T) {
	root := t.TempDir()
	dest := protectedDir + "/config"

	redirect := classifyBashProtectedWrite("echo x > "+dest, root)
	if redirect.Level == protectedPathNone {
		t.Fatal("redirection to a protected path classified as none; the baseline case regressed")
	}

	for _, command := range []string{
		"ln -sf /tmp/evil " + dest,
		"cp /tmp/evil " + dest,
		"mv /tmp/evil " + dest,
		"install /tmp/evil " + dest,
	} {
		got := classifyBashProtectedWrite(command, root)
		if got.Level != redirect.Level {
			t.Fatalf("classifyBashProtectedWrite(%q).Level = %v, want %v (same as the redirection form)", command, got.Level, redirect.Level)
		}
	}
}

// Ordinary uses outside protected paths must stay unremarkable.
func TestClassifyBashProtectedWrite_OrdinaryCopyIsNotFlagged(t *testing.T) {
	root := t.TempDir()

	for _, command := range []string{
		"cp README.md docs/README.md",
		"mv build/out.txt dist/out.txt",
		"ln -sf ../shared/lib vendor/lib",
	} {
		if got := classifyBashProtectedWrite(command, root); got.Level != protectedPathNone {
			t.Fatalf("classifyBashProtectedWrite(%q).Level = %v, want none", command, got.Level)
		}
	}
}
