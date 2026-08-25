//go:build windows

package hookhandler

import (
	"os"
	"path/filepath"
	"testing"
)

// TestBroadcastFileLock_WindowsMkdirFallback pins the Windows contract that
// unsupported flock does not run the writer without serialization.
func TestBroadcastFileLock_WindowsMkdirFallback(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "broadcast.md.lock")
	run := false
	if err := withBroadcastFileLock(lockPath, func() error {
		run = true
		return nil
	}); err != nil {
		t.Fatalf("withBroadcastFileLock: %v", err)
	}
	if !run {
		t.Fatal("locked callback did not run")
	}
	if _, err := os.Stat(lockPath + plansLockDirSuffix); !os.IsNotExist(err) {
		t.Fatalf("Windows mkdir lock should be released, stat err=%v", err)
	}
}
