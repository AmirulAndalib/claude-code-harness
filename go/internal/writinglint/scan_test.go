package writinglint

import "testing"

func loadFixtureRules(t *testing.T) []Rule {
	t.Helper()
	rules, err := LoadDict("testdata/rules.jsonl")
	if err != nil {
		t.Fatalf("LoadDict: %v", err)
	}
	return rules
}

func TestScanText_HitsEnabledPatternRegardlessOfScene(t *testing.T) {
	rules := loadFixtureRules(t)
	matches, err := ScanText("結論から書かず、以下に示します。", rules, ScanOpts{})
	if err != nil {
		t.Fatalf("ScanText: %v", err)
	}
	if len(matches) != 1 {
		t.Fatalf("len(matches) = %d, want 1: %+v", len(matches), matches)
	}
	if matches[0].RuleID != "meta-narration" || matches[0].Good == "" {
		t.Fatalf("matches[0] = %+v, want rule meta-narration with a Good suggestion", matches[0])
	}
}

func TestScanText_NegativeNoHitOnCleanText(t *testing.T) {
	rules := loadFixtureRules(t)
	matches, err := ScanText("結論。やったこと。なぜ。", rules, ScanOpts{})
	if err != nil {
		t.Fatalf("ScanText: %v", err)
	}
	if len(matches) != 0 {
		t.Fatalf("len(matches) = %d, want 0: %+v", len(matches), matches)
	}
}

func TestScanText_DisabledRuleNeverMatches(t *testing.T) {
	rules := loadFixtureRules(t)
	matches, err := ScanText("この行はヒットしない、はずが有効なら失敗する。", rules, ScanOpts{})
	if err != nil {
		t.Fatalf("ScanText: %v", err)
	}
	if len(matches) != 0 {
		t.Fatalf("disabled rule matched: %+v", matches)
	}
}

func TestScanText_SceneNarrowing(t *testing.T) {
	rules := loadFixtureRules(t)
	text := "重要なのはこの一点である。"

	// scene=external: rule is scoped to external+chat, must hit.
	hits, err := ScanText(text, rules, ScanOpts{Scene: "external"})
	if err != nil {
		t.Fatalf("ScanText: %v", err)
	}
	if len(hits) != 1 {
		t.Fatalf("scene=external: len(matches) = %d, want 1", len(hits))
	}

	// scene=report: rule is not scoped to report, must not hit.
	miss, err := ScanText(text, rules, ScanOpts{Scene: "report"})
	if err != nil {
		t.Fatalf("ScanText: %v", err)
	}
	if len(miss) != 0 {
		t.Fatalf("scene=report: len(matches) = %d, want 0: %+v", len(miss), miss)
	}
}

func TestScanText_NoSceneRuleAppliesToEveryScene(t *testing.T) {
	rules := loadFixtureRules(t)
	for _, scene := range []string{"", "external", "chat", "report"} {
		matches, err := ScanText("とても良い結果だった。", rules, ScanOpts{Scene: scene})
		if err != nil {
			t.Fatalf("ScanText(scene=%q): %v", scene, err)
		}
		found := false
		for _, m := range matches {
			if m.RuleID == "no-scene-rule" {
				found = true
			}
		}
		if !found {
			t.Fatalf("scene=%q: no-scene-rule did not match, matches=%+v", scene, matches)
		}
	}
}

func TestScanText_InvalidRE2PatternErrors(t *testing.T) {
	bad := []Rule{{ID: "bad", Pattern: "(?<=foo)bar", Enabled: true}} // lookbehind: unsupported in RE2
	if _, err := ScanText("foobar", bad, ScanOpts{}); err == nil {
		t.Fatal("expected error compiling a non-RE2 pattern (lookbehind)")
	}
}
