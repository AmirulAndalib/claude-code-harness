package hookhandler

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Phase 133 追補: the session-log warning fired on line count alone, while
// /maintenance can only move entries older than the retention window. Measured
// 2026-08-14: 688 lines against a 600 limit, but all 27 entries were within 30
// days — zero movable. Following the warning would break the retention rule;
// ignoring it meant the warning fired every session. Raising the limit
// (500 → 600) only moved where the mismatch happens; it recurred in days.

func writeSessionLog(t *testing.T, dir string, body string) string {
	t.Helper()
	path := filepath.Join(dir, "session-log.md")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write session-log: %v", err)
	}
	return path
}

func runAutoCleanup(t *testing.T, h *AutoCleanupHandler, dir, path string) string {
	t.Helper()
	input := `{"tool_name":"Write","tool_input":{"file_path":"` + path + `"},"cwd":"` + dir + `"}`
	var out bytes.Buffer
	if err := h.Handle(strings.NewReader(input), &out); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	return out.String()
}

func sessionHeader(at time.Time) string {
	return fmt.Sprintf("## セッション: %sT00:00:00Z\n", at.Format("2006-01-02"))
}

// Over the limit, but every entry is inside the retention window: nothing can
// be moved, so the warning must stay silent.
func TestCheckSessionLog_SilentWhenNothingIsArchivable(t *testing.T) {
	dir := t.TempDir()
	h := &AutoCleanupHandler{ProjectRoot: dir, SessionLogMaxLines: 10}

	var b strings.Builder
	for i := 0; i < 3; i++ {
		b.WriteString(sessionHeader(time.Now().AddDate(0, 0, -i)))
		b.WriteString(strings.Repeat("body\n", 10))
	}
	path := writeSessionLog(t, dir, b.String())

	if got := runAutoCleanup(t, h, dir, path); got != "" {
		t.Fatalf("expected no warning when nothing is archivable, got %q", got)
	}
}

// Over the limit with at least one entry past the window: the warning is
// actionable and must still fire.
func TestCheckSessionLog_WarnsWhenAnEntryIsArchivable(t *testing.T) {
	dir := t.TempDir()
	h := &AutoCleanupHandler{ProjectRoot: dir, SessionLogMaxLines: 10}

	var b strings.Builder
	b.WriteString(sessionHeader(time.Now().AddDate(0, 0, -(sessionLogRetentionDays + 5))))
	b.WriteString(strings.Repeat("body\n", 10))
	b.WriteString(sessionHeader(time.Now()))
	b.WriteString(strings.Repeat("body\n", 10))
	path := writeSessionLog(t, dir, b.String())

	got := runAutoCleanup(t, h, dir, path)
	if !strings.Contains(got, "session-log") {
		t.Fatalf("expected a warning when an entry is archivable, got %q", got)
	}
}

// Under the limit stays silent regardless of how old the entries are: the line
// count is still the first gate.
func TestCheckSessionLog_UnderLimitStaysSilent(t *testing.T) {
	dir := t.TempDir()
	h := &AutoCleanupHandler{ProjectRoot: dir, SessionLogMaxLines: 1000}

	body := sessionHeader(time.Now().AddDate(0, -6, 0)) + strings.Repeat("body\n", 10)
	path := writeSessionLog(t, dir, body)

	if got := runAutoCleanup(t, h, dir, path); got != "" {
		t.Fatalf("expected no warning under the line limit, got %q", got)
	}
}

// A header whose date cannot be parsed counts as archivable. Treating it as
// fresh would silence the warning on malformed input — the failure mode that
// hides a real problem.
func TestCountArchivableSessionLogEntries_UnparsableDateCountsAsArchivable(t *testing.T) {
	dir := t.TempDir()
	path := writeSessionLog(t, dir, "## セッション: 9999-99-99T00:00:00Z\nbody\n")

	n, err := countArchivableSessionLogEntries(path, time.Now())
	if err != nil {
		t.Fatalf("countArchivableSessionLogEntries: %v", err)
	}
	if n != 1 {
		t.Fatalf("got %d archivable entries, want 1 (an unparsable date must not be read as fresh)", n)
	}
}

func TestCountArchivableSessionLogEntries_CountsOnlyEntriesPastTheWindow(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()

	body := sessionHeader(now.AddDate(0, 0, -(sessionLogRetentionDays+1))) +
		sessionHeader(now.AddDate(0, 0, -(sessionLogRetentionDays+100))) +
		sessionHeader(now.AddDate(0, 0, -1)) +
		sessionHeader(now)
	path := writeSessionLog(t, dir, body)

	n, err := countArchivableSessionLogEntries(path, now)
	if err != nil {
		t.Fatalf("countArchivableSessionLogEntries: %v", err)
	}
	if n != 2 {
		t.Fatalf("got %d archivable entries, want 2", n)
	}
}

// Both header spellings must be recognized. The writer emits
// `## セッション: <RFC3339>`; the maintenance reference documents
// `## YYYY-MM-DD`. Matching only one would count zero on the other and silence
// the warning permanently — worse than the over-firing this change replaces.
func TestCountArchivableSessionLogEntries_AcceptsBothHeaderSpellings(t *testing.T) {
	dir := t.TempDir()
	old := time.Now().AddDate(0, 0, -(sessionLogRetentionDays + 1)).Format("2006-01-02")

	body := fmt.Sprintf("## セッション: %sT01:02:03Z\nbody\n## %s\nbody\n", old, old)
	path := writeSessionLog(t, dir, body)

	n, err := countArchivableSessionLogEntries(path, time.Now())
	if err != nil {
		t.Fatalf("countArchivableSessionLogEntries: %v", err)
	}
	if n != 2 {
		t.Fatalf("got %d archivable entries, want 2 (both header spellings must count)", n)
	}
}

// A non-date `## ...` heading (e.g. `## Index`) is not an entry.
func TestCountArchivableSessionLogEntries_IgnoresNonDateHeadings(t *testing.T) {
	dir := t.TempDir()
	path := writeSessionLog(t, dir, "## Index\n\n## Session Log\nbody\n")

	n, err := countArchivableSessionLogEntries(path, time.Now())
	if err != nil {
		t.Fatalf("countArchivableSessionLogEntries: %v", err)
	}
	if n != 0 {
		t.Fatalf("got %d archivable entries, want 0", n)
	}
}
