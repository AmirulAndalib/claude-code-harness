package harnessmem

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setInvocationTestHooks はテスト中だけ goosForInvocation / lookPathForInvocation を
// 差し替え、終了時に復元する。
func setInvocationTestHooks(t *testing.T, goos string, lookPath func(string) (string, error)) {
	t.Helper()
	origGOOS := goosForInvocation
	origLookPath := lookPathForInvocation
	if goos != "" {
		goosForInvocation = goos
	}
	if lookPath != nil {
		lookPathForInvocation = lookPath
	}
	t.Cleanup(func() {
		goosForInvocation = origGOOS
		lookPathForInvocation = origLookPath
	})
}

// fakeLookPath は node / bun だけを固定パスで解決する LookPath。
func fakeLookPath(t *testing.T) func(string) (string, error) {
	t.Helper()
	return func(bin string) (string, error) {
		switch bin {
		case "node":
			return "/fake/bin/node", nil
		case "bun":
			return "/fake/bin/bun", nil
		}
		return "", errors.New("not found: " + bin)
	}
}

func TestResolveInvocation_WrapsJSExtensionWithNode(t *testing.T) {
	setInvocationTestHooks(t, "", fakeLookPath(t))

	script := filepath.Join(t.TempDir(), "harness-mem.js")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env node\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_MEM_CLI", script)

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve")
	}
	if inv.Name != "/fake/bin/node" {
		t.Errorf("Name = %q, want node runtime", inv.Name)
	}
	if len(inv.ArgPrefix) != 1 || inv.ArgPrefix[0] != script {
		t.Errorf("ArgPrefix = %v, want [%s]", inv.ArgPrefix, script)
	}
	if !inv.Installed {
		t.Error("Installed should remain true")
	}
}

func TestResolveInvocation_FallsBackToBunWhenNodeMissing(t *testing.T) {
	setInvocationTestHooks(t, "", func(bin string) (string, error) {
		if bin == "bun" {
			return "/fake/bin/bun", nil
		}
		return "", errors.New("not found: " + bin)
	})

	script := filepath.Join(t.TempDir(), "harness-mem.js")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env node\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_MEM_CLI", script)

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve")
	}
	if inv.Name != "/fake/bin/bun" {
		t.Errorf("Name = %q, want bun runtime", inv.Name)
	}
}

func TestResolveInvocation_NoJSRuntimeKeepsOriginal(t *testing.T) {
	setInvocationTestHooks(t, "", func(bin string) (string, error) {
		return "", errors.New("not found: " + bin)
	})

	script := filepath.Join(t.TempDir(), "harness-mem.js")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env node\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARNESS_MEM_CLI", script)

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve")
	}
	// runtime が無い場合は元の Invocation のまま（従来の exec エラーに任せる）
	if inv.Name != script {
		t.Errorf("Name = %q, want original script %q", inv.Name, script)
	}
	if len(inv.ArgPrefix) != 0 {
		t.Errorf("ArgPrefix = %v, want empty", inv.ArgPrefix)
	}
}

func TestResolveInvocation_UnixExtensionlessNotWrapped(t *testing.T) {
	setInvocationTestHooks(t, "linux", fakeLookPath(t))

	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("HARNESS_MEM_CLI", "")
	os.Unsetenv("HARNESS_MEM_CLI")

	scriptsDir := filepath.Join(home, ".harness-mem", "runtime", "harness-mem", "scripts")
	if err := os.MkdirAll(scriptsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	candidate := filepath.Join(scriptsDir, "harness-mem")
	if err := os.WriteFile(candidate, []byte("#!/usr/bin/env node\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve")
	}
	// Unix では shebang が効くため拡張子なしスクリプトは wrap しない（従来挙動）
	if inv.Name != candidate {
		t.Errorf("Name = %q, want unwrapped candidate %q", inv.Name, candidate)
	}
	if len(inv.ArgPrefix) != 0 {
		t.Errorf("ArgPrefix = %v, want empty", inv.ArgPrefix)
	}
}

func TestResolveInvocation_WindowsExtensionlessCandidateWrapped(t *testing.T) {
	setInvocationTestHooks(t, "windows", fakeLookPath(t))

	home := t.TempDir()
	t.Setenv("HOME", home)
	// Windows では os.UserHomeDir が USERPROFILE を参照する
	t.Setenv("USERPROFILE", home)
	os.Unsetenv("HARNESS_MEM_CLI")

	scriptsDir := filepath.Join(home, ".harness-mem", "runtime", "harness-mem", "scripts")
	if err := os.MkdirAll(scriptsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	candidate := filepath.Join(scriptsDir, "harness-mem")
	if err := os.WriteFile(candidate, []byte("#!/usr/bin/env node\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve")
	}
	if inv.Name != "/fake/bin/node" {
		t.Errorf("Name = %q, want node runtime (shebang not honored on Windows)", inv.Name)
	}
	if len(inv.ArgPrefix) != 1 || inv.ArgPrefix[0] != candidate {
		t.Errorf("ArgPrefix = %v, want [%s]", inv.ArgPrefix, candidate)
	}
}

func TestResolveInvocation_WindowsJSCandidateFoundAndWrapped(t *testing.T) {
	setInvocationTestHooks(t, "windows", fakeLookPath(t))

	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	os.Unsetenv("HARNESS_MEM_CLI")

	// 拡張子なしのラッパーは置かず、.js 実体だけを置く (Windows npm レイアウト)
	scriptsDir := filepath.Join(home, ".harness-mem", "runtime", "harness-mem", "scripts")
	if err := os.MkdirAll(scriptsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	jsCandidate := filepath.Join(scriptsDir, "harness-mem.js")
	if err := os.WriteFile(jsCandidate, []byte("#!/usr/bin/env node\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve via .js candidate")
	}
	if inv.Name != "/fake/bin/node" {
		t.Errorf("Name = %q, want node runtime", inv.Name)
	}
	if len(inv.ArgPrefix) != 1 || inv.ArgPrefix[0] != jsCandidate {
		t.Errorf("ArgPrefix = %v, want [%s]", inv.ArgPrefix, jsCandidate)
	}
}

func TestResolveInvocation_WindowsCmdShimNotWrapped(t *testing.T) {
	calls := 0
	setInvocationTestHooks(t, "windows", func(bin string) (string, error) {
		calls++
		if bin == "harness-mem" {
			return `C:\Users\test\AppData\Roaming\npm\harness-mem.cmd`, nil
		}
		return "", errors.New("not found: " + bin)
	})

	home := t.TempDir() // candidate は存在しない
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	os.Unsetenv("HARNESS_MEM_CLI")
	t.Setenv("HARNESS_MEM_DISABLE_PATH_LOOKUP", "")
	os.Unsetenv("HARNESS_MEM_DISABLE_PATH_LOOKUP")

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve via PATH shim")
	}
	// .cmd shim は CreateProcess で直接実行できるため wrap しない
	if !strings.HasSuffix(inv.Name, "harness-mem.cmd") {
		t.Errorf("Name = %q, want .cmd shim unwrapped", inv.Name)
	}
	if len(inv.ArgPrefix) != 0 {
		t.Errorf("ArgPrefix = %v, want empty", inv.ArgPrefix)
	}
	if calls == 0 {
		t.Error("lookPath should have been consulted")
	}
}

func TestResolveInvocation_WindowsPathLookupJSWrapped(t *testing.T) {
	// Windows の LookPath は PATHEXT (.JS を含み得る) で harness-mem.js を
	// 返すことがある。その場合も node 経由に wrap する (#207 の実エラー経路)。
	jsOnPath := `C:\Users\test\.harness-mem\runtime\harness-mem\scripts\harness-mem.js`
	setInvocationTestHooks(t, "windows", func(bin string) (string, error) {
		switch bin {
		case "harness-mem":
			return jsOnPath, nil
		case "node":
			return `C:\Program Files\nodejs\node.exe`, nil
		}
		return "", errors.New("not found: " + bin)
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	os.Unsetenv("HARNESS_MEM_CLI")
	os.Unsetenv("HARNESS_MEM_DISABLE_PATH_LOOKUP")

	inv, ok := ResolveInvocation(false)
	if !ok {
		t.Fatal("expected invocation to resolve")
	}
	if inv.Name != `C:\Program Files\nodejs\node.exe` {
		t.Errorf("Name = %q, want node runtime", inv.Name)
	}
	if len(inv.ArgPrefix) != 1 || inv.ArgPrefix[0] != jsOnPath {
		t.Errorf("ArgPrefix = %v, want [%s]", inv.ArgPrefix, jsOnPath)
	}
}

func TestResolveInvocation_NpxFallbackNotWrapped(t *testing.T) {
	setInvocationTestHooks(t, "windows", fakeLookPath(t))

	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	os.Unsetenv("HARNESS_MEM_CLI")
	t.Setenv("HARNESS_MEM_DISABLE_PATH_LOOKUP", "1")

	inv, ok := ResolveInvocation(true)
	if !ok {
		t.Fatal("expected npx fallback")
	}
	if inv.Name != "npx" {
		t.Errorf("Name = %q, want npx", inv.Name)
	}
	if inv.Installed {
		t.Error("npx fallback should report Installed=false")
	}
}

func TestNeedsJSRuntime(t *testing.T) {
	tests := []struct {
		name string
		goos string
		path string
		want bool
	}{
		{"js on linux", "linux", "x.js", true},
		{"mjs on darwin", "darwin", "x.mjs", true},
		{"cjs on windows", "windows", `C:\x.cjs`, true},
		{"exe on windows", "windows", `C:\harness-mem.exe`, false},
		{"cmd on windows", "windows", `C:\harness-mem.cmd`, false},
		{"missing extensionless on windows", "windows", `C:\does\not\exist\harness-mem`, false},
		{"extensionless on linux", "linux", "/usr/local/bin/harness-mem", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setInvocationTestHooks(t, tt.goos, nil)
			if got := needsJSRuntime(tt.path); got != tt.want {
				t.Errorf("needsJSRuntime(%q) on %s = %v, want %v", tt.path, tt.goos, got, tt.want)
			}
		})
	}
}

func TestNeedsJSRuntime_WindowsExtensionlessExistingFile(t *testing.T) {
	setInvocationTestHooks(t, "windows", nil)
	script := filepath.Join(t.TempDir(), "harness-mem")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env node\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !needsJSRuntime(script) {
		t.Errorf("needsJSRuntime(%q) on windows = false, want true (existing shebang script)", script)
	}
}
