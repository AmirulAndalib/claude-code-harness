package auditlog

import "os"

func withFileLock(lockPath string, fn func() error) error {
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()

	if err := fileLock(lock); err != nil {
		return err
	}
	defer func() {
		_ = fileUnlock(lock)
	}()

	return fn()
}
