package shellscan

import (
	"reflect"
	"strings"
	"testing"
)

func TestDangerousRemoval_UnifiedCorpus(t *testing.T) {
	cases := []struct {
		name      string
		command   string
		dangerous bool
		targets   []string
	}{
		{name: "short recursive", command: "rm -r /outside", dangerous: true, targets: []string{"/outside"}},
		{name: "short uppercase recursive", command: "rm -R /outside", dangerous: true, targets: []string{"/outside"}},
		{name: "combined rf", command: "rm -rf /outside", dangerous: true, targets: []string{"/outside"}},
		{name: "combined fr", command: "rm -fr /outside", dangerous: true, targets: []string{"/outside"}},
		{name: "separate short flags", command: "rm -r -f /outside", dangerous: true, targets: []string{"/outside"}},
		{name: "long recursive force", command: "rm --recursive --force /outside", dangerous: true, targets: []string{"/outside"}},
		{name: "long force recursive", command: "rm --force --recursive /outside", dangerous: true, targets: []string{"/outside"}},
		{name: "find delete", command: "find /outside -name '*.tmp' -delete", dangerous: true, targets: []string{"/outside"}},
		{name: "find option before path", command: "find -H /outside -delete", dangerous: true, targets: []string{"/outside"}},
		{name: "find exec rm", command: `find /outside -type f -exec rm -rf {} \;`, dangerous: true, targets: []string{"/outside"}},
		{name: "macOS system path without recursion", command: "rm -f /System/Library/test", dangerous: true, targets: []string{"/System/Library/test"}},
		{name: "macOS user library without recursion", command: "rm -f ~/Library/Messages", dangerous: true, targets: []string{"~/Library/Messages"}},
		{name: "shell command string", command: "bash -c 'rm -rf /outside'", dangerous: true, targets: []string{"/outside"}},
		{name: "command substitution", command: "echo $(rm -rf /outside)", dangerous: true, targets: []string{"/outside"}},
		{name: "force only", command: "rm -f /ordinary", dangerous: false},
		{name: "end of options recursive-looking target", command: "rm -- -r", dangerous: false},
		{name: "find print", command: "find /outside -name '*.tmp' -print", dangerous: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dangerous, targets := DangerousRemoval(tc.command)
			if dangerous != tc.dangerous {
				t.Fatalf("DangerousRemoval(%q).dangerous = %v, want %v",
					tc.command, dangerous, tc.dangerous)
			}
			if !reflect.DeepEqual(targets, tc.targets) {
				t.Fatalf("DangerousRemoval(%q).targets = %#v, want %#v",
					tc.command, targets, tc.targets)
			}
		})
	}
}

func TestDangerousRemoval_TargetsStayWithinCommandSegment(t *testing.T) {
	cases := []struct {
		name    string
		command string
		targets []string
	}{
		{
			name:    "leading command",
			command: "cd /tmp && rm -rf ./build",
			targets: []string{"./build"},
		},
		{
			name:    "trailing command",
			command: "rm -rf /worktree/build && printf /",
			targets: []string{"/worktree/build"},
		},
		{
			name:    "semicolon",
			command: "printf / ; rm -rf /worktree/build",
			targets: []string{"/worktree/build"},
		},
		{
			name:    "or operator",
			command: "rm -rf /worktree/build || printf /",
			targets: []string{"/worktree/build"},
		},
		{
			name:    "pipeline",
			command: "rm -rf /worktree/build | tee /outside/log",
			targets: []string{"/worktree/build"},
		},
		{
			name:    "newline",
			command: "rm -rf /worktree/build\nprintf /",
			targets: []string{"/worktree/build"},
		},
		{
			name:    "escaped newline continues command",
			command: "rm -rf \\\n/outside",
			targets: []string{"/outside"},
		},
		{
			name:    "end of options",
			command: "rm -r -- -target",
			targets: []string{"-target"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dangerous, targets := DangerousRemoval(tc.command)
			if !dangerous {
				t.Fatalf("DangerousRemoval(%q).dangerous = false, want true", tc.command)
			}
			if !reflect.DeepEqual(targets, tc.targets) {
				t.Fatalf("DangerousRemoval(%q).targets = %#v, want %#v",
					tc.command, targets, tc.targets)
			}
		})
	}
}

func TestStripNonExecutableText_RemovesDocumentHeredocAndComments(t *testing.T) {
	command := "cat >> notes.md <<'EOF'\n" +
		"rm -rf /\n" +
		"cat /project/.env\n" +
		"EOF\n" +
		"printf done # rm -rf /opt/data"

	scannable := StripNonExecutableText(command)
	for _, removed := range []string{"rm -rf /", "cat /project/.env", "rm -rf /opt/data"} {
		if strings.Contains(scannable, removed) {
			t.Fatalf("StripNonExecutableText retained non-executable text %q in %q", removed, scannable)
		}
	}
	if !strings.Contains(scannable, "cat >> notes.md") || !strings.Contains(scannable, "printf done") {
		t.Fatalf("StripNonExecutableText removed executable opener/command: %q", scannable)
	}
}

func TestStripNonExecutableText_KeepsInterpreterHeredocBodies(t *testing.T) {
	interpreters := []string{
		"bash",
		"sh",
		"zsh",
		"dash",
		"ksh",
		"python",
		"python3",
		"perl",
		"ruby",
		"node",
	}

	for _, interpreter := range interpreters {
		t.Run(interpreter, func(t *testing.T) {
			command := interpreter + " <<EOF\nEXECUTABLE_BODY_MARKER\nEOF"
			scannable := StripNonExecutableText(command)
			if !strings.Contains(scannable, "EXECUTABLE_BODY_MARKER") {
				t.Fatalf("%s heredoc body was removed: %q", interpreter, scannable)
			}
		})
	}
}

func TestStripNonExecutableText_KeepsBodyPipedToInterpreter(t *testing.T) {
	command := "cat <<EOF | bash\nrm -rf /outside\nEOF"
	scannable := StripNonExecutableText(command)
	if !strings.Contains(scannable, "rm -rf /outside") {
		t.Fatalf("body piped to bash was removed: %q", scannable)
	}
}

func TestStripNonExecutableText_QuotedHeredocMarkerDoesNotHideCommands(t *testing.T) {
	for _, command := range []string{
		"printf '<<EOF'\nrm -rf /outside",
		"printf \"<<EOF\"\nrm -rf /outside",
	} {
		t.Run(command, func(t *testing.T) {
			scannable := StripNonExecutableText(command)
			if !strings.Contains(scannable, "rm -rf /outside") {
				t.Fatalf("quoted heredoc marker hid executable command: %q", scannable)
			}
		})
	}
}
