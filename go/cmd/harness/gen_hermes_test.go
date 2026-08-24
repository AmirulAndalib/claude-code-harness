package main

import (
	"os"
	"path/filepath"
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
