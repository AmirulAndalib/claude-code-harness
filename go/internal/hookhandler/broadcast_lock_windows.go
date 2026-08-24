//go:build windows

package hookhandler

import "fmt"

// withBroadcastFileLock uses the repository's cross-platform plans lock on
// Windows. acquirePlansLock falls back from unsupported flock to an atomic
// mkdir lock, and a failed acquisition is returned rather than writing
// unsynchronized shared broadcast state.
func withBroadcastFileLock(lockPath string, fn func() error) error {
	lock, err := acquirePlansLock(lockPath)
	if err != nil {
		return fmt.Errorf("acquire broadcast lock: %w", err)
	}
	defer releasePlansLock(lock)
	return fn()
}
