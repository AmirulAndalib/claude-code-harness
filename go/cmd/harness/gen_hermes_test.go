package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunGenWrite_HermesMissingFailsOpenWithoutGeneratingConfig(t *testing.T) {
	root := t.TempDir()
	descriptor := `[hermes]
hook_event = "pre_tool_call"
delivery_strategy = "turn"
delivery_event_turn = "stop"
`
	if err := os.WriteFile(filepath.Join(root, hostsDescriptorName), []byte(descriptor), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", t.TempDir())

	if err := runGenWrite(root); err != nil {
		t.Fatalf("runGenWrite without Hermes installed must fail open: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".hermes")); !os.IsNotExist(err) {
		t.Fatalf("harness gen must not create a Hermes hook/config path, stat error = %v", err)
	}
}

// TestRunGenWrite_HermesInstalledGeneratesDelivery pins the delivery half.
// Deferring the enforcement hook must not defer delivery: hosts.toml declared
// hermes turn delivery while `gen` emitted it nowhere, because the deferral
// returned before delivery generation was ever reached.
func TestRunGenWrite_HermesInstalledGeneratesDelivery(t *testing.T) {
	root := t.TempDir()
	descriptor := `[hermes]
hook_event = "pre_tool_call"
hook_path  = ".hermes/hooks.json"
requires_home_path = ".hermes"
delivery_strategy = "turn"
delivery_event_turn = "stop"
`
	if err := os.WriteFile(filepath.Join(root, hostsDescriptorName), []byte(descriptor), 0o644); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".hermes"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	if err := runGenWrite(root); err != nil {
		t.Fatalf("runGenWrite: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(root, ".hermes", "hooks.json"))
	if err != nil {
		t.Fatalf("hermes delivery was not generated: %v", err)
	}
	if !strings.Contains(string(data), `"stop"`) {
		t.Fatalf("hermes delivery must use the snake_case stop event: %s", data)
	}
	if !strings.Contains(string(data), "inbox check") {
		t.Fatalf("hermes delivery must wire the inbox check: %s", data)
	}
}
