package policy

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/Chachamaru127/claude-code-harness/go/pkg/hookproto"
)

// R05 は「一律に削除を確認する」のではなく「何を消そうとしているか」で判断する。
// 通すのは、エージェント自身が所有する領域 — 作業ツリー (task worktree を含む)
// と、このセッション自身の scratch — の中だけを消す場合に限る。
//
// このテストは両方向を固定する。allow 側だけを見ると「緩めたら通った」で満足
// してしまい、ask 側だけを見ると「元から通らない」だけかもしれない。
//
// 重要: WorkMode が立っていると R05 は丸ごと skip されるため、環境が漏れている
// と allow の主張がすべて空振りになる (Phase 132 で実際に踏んだ罠)。各ケースで
// 明示的に knob env を落とし、control ケースで ask が出ることを確かめている。

const testSessionID = "99999999-aaaa-bbbb-cccc-dddddddddddd"

func clearWorkModeEnv(t *testing.T) {
	t.Helper()
	for _, key := range []string{"HARNESS_WORK_MODE", "ULTRAWORK_MODE"} {
		t.Setenv(key, "")
		if err := os.Unsetenv(key); err != nil {
			t.Fatalf("unset %s: %v", key, err)
		}
	}
}

// makeSessionScratch builds <tmp>/<sessionID>/scratchpad, mirroring the shape
// Claude Code hands the agent: the session id appears as a path component under
// an OS temp root.
func makeSessionScratch(t *testing.T, sessionID string) string {
	t.Helper()
	tempRoot := os.TempDir()
	scratch := filepath.Join(tempRoot, "cch-r05-test", sessionID, "scratchpad")
	if err := os.MkdirAll(scratch, 0o755); err != nil {
		t.Fatalf("mkdir scratch: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(filepath.Join(tempRoot, "cch-r05-test")) })
	return scratch
}

func evalRemoval(t *testing.T, command, projectRoot, sessionID string) hookproto.HookDecision {
	t.Helper()
	ctx := makeCtx("Bash", map[string]interface{}{"command": command})
	ctx.ProjectRoot = projectRoot
	ctx.Input.SessionID = sessionID
	ctx.WorkMode = false
	return EvaluateRules(ctx).Decision
}

func TestR05_JudgesByTargetNotByActor(t *testing.T) {
	clearWorkModeEnv(t)

	projectRoot := t.TempDir()
	scratch := makeSessionScratch(t, testSessionID)
	mine := filepath.Join(scratch, "mine")
	if err := os.MkdirAll(mine, 0o755); err != nil {
		t.Fatalf("mkdir mine: %v", err)
	}

	// scratchpad の中に $HOME を指す symlink を仕込む。実パス解決が効いていれば
	// これは「自分の scratch」とは見なされない。
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("home dir: %v", err)
	}
	escape := filepath.Join(scratch, "escape")
	if err := os.Symlink(home, escape); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	otherSessionScratch := filepath.Join(os.TempDir(), "cch-r05-test",
		"11111111-2222-3333-4444-555555555555", "scratchpad")

	cases := []struct {
		name    string
		command string
		want    hookproto.HookDecision
		why     string
	}{
		// --- 通すべきもの: 自分が所有する領域だけを消す -----------------------
		{
			name:    "own session scratch, literal path",
			command: fmt.Sprintf("rm -rf %s", mine),
			want:    hookproto.DecisionApprove,
			why:     "エージェント自身の作業用ディレクトリ。確認は無意味な割り込みになる",
		},
		{
			name: "own session scratch, built from a variable",
			command: fmt.Sprintf("S=%s\nF=\"$S/mine\"\nrm -rf \"$F\"",
				scratch),
			want: hookproto.DecisionApprove,
			why:  "実際のエージェントは対象をリテラルで書かない。一度だけリテラル代入された変数は解決する",
		},
		{
			name: "own session scratch, variable and a pipe in the same command",
			command: fmt.Sprintf("S=%s\nF=\"$S/mine\"\nrm -rf \"$F\"\nmkdir -p \"$F\"\necho done | tail -1",
				scratch),
			want: hookproto.DecisionApprove,
			why:  "対象がすべて絶対パスなら、パイプは対象集合を変えない",
		},
		{
			name:    "inside the project root",
			command: fmt.Sprintf("rm -rf %s/build", projectRoot),
			want:    hookproto.DecisionApprove,
			why:     "従来からの挙動。作業ツリーの中は確認しない",
		},

		// --- 確認すべきもの: 所有していない、または対象が確定しない -------------
		{
			name:    "the shared temp root itself",
			command: "rm -rf " + os.TempDir(),
			want:    hookproto.DecisionAsk,
			why:     "他セッション・他ツールの一時状態を巻き添えにする",
		},
		{
			name:    "another session's scratch",
			command: "rm -rf " + otherSessionScratch,
			want:    hookproto.DecisionAsk,
			why:     "/tmp は共有。一時領域であることは所有していることを意味しない",
		},
		{
			name:    "symlink inside our scratch that resolves to $HOME",
			command: "rm -rf " + escape,
			want:    hookproto.DecisionAsk,
			why:     "実パス解決前の見た目で判断すると脱出できてしまう",
		},
		{
			name:    "glob inside our scratch",
			command: fmt.Sprintf("rm -rf %s/*", scratch),
			want:    hookproto.DecisionAsk,
			why:     "展開結果が静的に決まらない",
		},
		{
			name:    "variable assigned twice",
			command: fmt.Sprintf("A=%s\nA=$HOME\nrm -rf \"$A\"", mine),
			want:    hookproto.DecisionAsk,
			why:     "使用時点の値が一意に決まらない。最初の代入だけ見ると騙される",
		},
		{
			name:    "variable from command substitution",
			command: fmt.Sprintf("A=$(echo %s)\nrm -rf \"$A\"", mine),
			want:    hookproto.DecisionAsk,
			why:     "実行しないと値が分からない",
		},
		{
			name:    "value containing whitespace",
			command: fmt.Sprintf("A=\"%s/a b\"\nrm -rf \"$A\"", scratch),
			want:    hookproto.DecisionAsk,
			why:     "単語分割で対象が増えうる",
		},
		{
			name:    "undefined variable",
			command: "rm -rf \"$UNDEFINED_TARGET_VAR\"",
			want:    hookproto.DecisionAsk,
			why:     "解決できない参照は推測しない",
		},
		{
			name:    "xargs adds targets from stdin",
			command: "printf /outside | xargs rm -rf ./build",
			want:    hookproto.DecisionAsk,
			why:     "argv に現れない対象が増える。パイプ緩和で絶対に壊してはいけない一線",
		},
		// --- Phase D refuter が実証した突破口の再発防止 -----------------------
		// bash はシングルクォートの中を展開しない。解析器がここを展開すると、
		// 実際には「$S/x」という名前の相対パスを消すコマンドを「自分の scratch
		// を消している」と誤認する。プロジェクト内に `$S` という名前の symlink
		// を置くだけで (作成自体はどのルールにも触れない)、実際の削除先は
		// プロジェクト外の任意のファイルになり、無言で通っていた。
		{
			name: "single-quoted value must not be expanded",
			command: fmt.Sprintf("S=%s\nF='$S/fake_secret_data.txt'\nrm -rf \"$F\"",
				scratch),
			want: hookproto.DecisionAsk,
			why:  "bash はここを展開しない。解析器が展開すると実際の削除先と食い違う (refuter 実証の突破口)",
		},
		{
			name:    "single-quoted removal target itself",
			command: fmt.Sprintf("S=%s\nrm -rf '$S/mine'", scratch),
			want:    hookproto.DecisionAsk,
			why:     "対象トークン側がシングルクォートされている形。代入の右辺だけ見ていると取りこぼす",
		},
		{
			name: "backslash-escaped dollar inside a double-quoted value",
			command: fmt.Sprintf("S=%s\nF=\"%s/leaf\\$S\"\nrm -rf \"$F\"",
				scratch, scratch),
			want: hookproto.DecisionAsk,
			why:  "退避された $ も shell は展開しない。同じ乖離の別表現",
		},
		{
			name:    "assignment prefix on the removal statement itself",
			command: fmt.Sprintf("FOO=bar rm -rf %s", filepath.Join(os.TempDir(), "cch-r05-test", "not-ours")),
			want:    hookproto.DecisionAsk,
			why:     "前置き代入の文は解析から落とさない (落とすと rm ごと消える)",
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got := evalRemoval(t, testCase.command, projectRoot, testSessionID)
			if got != testCase.want {
				t.Fatalf("decision = %s, want %s\ncommand: %s\nwhy: %s",
					got, testCase.want, testCase.command, testCase.why)
			}
		})
	}
}

// セッション id が短い・空・記号だけ、といった値で「自分の scratch」判定が
// 成立してはならない。成立すると、任意の一時ディレクトリが所有物になる。
func TestR05_WeakSessionIDDoesNotGrantOwnership(t *testing.T) {
	clearWorkModeEnv(t)

	projectRoot := t.TempDir()
	for _, sessionID := range []string{"", ".", "..", "a", "tmp", "short-id"} {
		t.Run(fmt.Sprintf("session_id=%q", sessionID), func(t *testing.T) {
			scratch := filepath.Join(os.TempDir(), "cch-r05-weak", sessionID, "scratchpad")
			// 存在しなくても判定はできる (未作成パスも symlink 解決を通る)。
			// "." や ".." のように作成できない名前でも skip せず必ず評価する。
			_ = os.MkdirAll(scratch, 0o755)
			t.Cleanup(func() { _ = os.RemoveAll(filepath.Join(os.TempDir(), "cch-r05-weak")) })

			got := evalRemoval(t, "rm -rf "+scratch, projectRoot, sessionID)
			if got != hookproto.DecisionAsk {
				t.Fatalf("decision = %s, want ask — a weak session id must not make a temp dir agent-owned", got)
			}
		})
	}
}

// R04 は ~/.claude/projects/<slug>/memory への書き込みを確認なしで通すが、
// R05 は同じ場所の再帰削除を通してはならない。書き込みは scratch の churn、
// 再帰削除は蓄積した知識の喪失で、blast radius が違う。
func TestR05_AgentMemoryIsNotChurnableScratch(t *testing.T) {
	clearWorkModeEnv(t)

	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("home dir: %v", err)
	}
	memoryDir := filepath.Join(home, ".claude", "projects", "some-slug", "memory")

	got := evalRemoval(t, "rm -rf "+memoryDir, t.TempDir(), testSessionID)
	if got == hookproto.DecisionApprove {
		t.Fatalf("decision = approve, want ask or deny — recursive delete of agent memory must not be silent")
	}
}
