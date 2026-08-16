package writinglint

import "fmt"

// Match is one writing-lint hit against a scanned text.
type Match struct {
	RuleID   string
	Text     string // matched substring
	Good     string // suggested rewrite pattern
	Severity string
	Start    int
	End      int
}

// ScanOpts configures ScanText.
type ScanOpts struct {
	// Scene narrows which rules run via Rule.AppliesToScene. Empty means no
	// narrowing (every enabled rule runs).
	Scene string
}

// ScanText narrows rules to Enabled + AppliesToScene(opts.Scene), then runs
// each rule's compiled regexp against text and returns every match.
func ScanText(text string, rules []Rule, opts ScanOpts) ([]Match, error) {
	var matches []Match
	for _, rule := range rules {
		if !rule.Enabled || !rule.AppliesToScene(opts.Scene) {
			continue
		}
		compiled, err := rule.Compile()
		if err != nil {
			return nil, fmt.Errorf("rule %q: %w", rule.ID, err)
		}
		for _, loc := range compiled.Regexp.FindAllStringIndex(text, -1) {
			matches = append(matches, Match{
				RuleID:   rule.ID,
				Text:     text[loc[0]:loc[1]],
				Good:     rule.Good,
				Severity: rule.Severity,
				Start:    loc[0],
				End:      loc[1],
			})
		}
	}
	return matches, nil
}
