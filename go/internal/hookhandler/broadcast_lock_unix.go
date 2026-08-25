//go:build !windows

package hookhandler

// withBroadcastFileLock keeps the existing Unix flock behavior used by other
// append-only hook state. withFileLock blocks until the shared lock is held;
// its established best-effort fallback is retained for non-locking filesystems.
func withBroadcastFileLock(lockPath string, fn func() error) error {
	var fnErr error
	withFileLock(lockPath, func() {
		fnErr = fn()
	})
	return fnErr
}
