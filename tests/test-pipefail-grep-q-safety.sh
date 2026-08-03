#!/bin/bash
# tests/test-pipefail-grep-q-safety.sh
# Phase 129.1 / 130.1 - pipefail 下で結果が反転する `producer | grep -q` 構文の検出
#
# 何を検出するか:
#   `printf '%s' "$x" | grep -q P` のように、producer の出力をパイプで
#   `grep -q` に渡す書き方。`grep -q` は最初の一致で終了してパイプを閉じるため、
#   分割書き込み中の producer が EPIPE で失敗する。`set -o pipefail` はその失敗を
#   パイプライン全体の結果へ昇格させるので、探す文字列が実在するのに「無い」と
#   判定される。一致が入力の前方にあるほど再現する。
#
#   実測 (PR #285, skills/harness-accept/SKILL.md frontmatter 2019 バイト, 200 回):
#     2 行目の項目 200/200 誤判定 / 3 行目の項目 200/200 誤判定 / 8 行目の項目 0/200
#
#   実測2 (Phase 130, tests/test-i18n-locale-resolver.sh:196、内容長 1257 バイト、
#     一致位置は先頭 4 バイト目。同一データで 20 回ずつ):
#     `jq ... | grep -q` は 20/20 誤判定 / `grep -q ... <<<"$C"` は 20/20 正判定
#
# producer の対象範囲 (Phase 130 で拡大):
#   Phase 129.1 は producer を printf / echo / cat の 3 つに限定していた。そのため
#   jq / find / git / grep / head / awk / シェル関数呼び出しなど他の producer を持つ
#   同型の構文が検出網から漏れていた。Phase 130 でパイプ左側の producer 種別を問わず、
#   右側が grep -q 系であれば検出する判定へ広げた。
#
# 正しい書き方:
#   `grep -q P <<<"$x"`                    (変数が producer の場合。パイプが無いので EPIPE が起きない)
#   `grep -q P file`                       (ファイルが producer の場合。cat が不要)
#   `X="$(producer)"; grep -q P <<<"$X"`   (producer がコマンド/関数呼び出しの場合。
#                                            まず変数へ捕捉してから herestring で判定する)
#
# 検出の限界 (静的走査であること):
#   - 変数経由で組み立てたコマンド文字列 (eval 等) は対象外
#   - 複数行にまたがる二重引用符文字列 (例: `python3 -c "\n...\n" | grep -q X` のように
#     `"` の開始と終了が別の物理行にある場合) は対象外。引用符状態は論理行
#     (行末 `\` で畳んだ範囲) ごとにリセットされるため、複数行文字列の終端行がたまたま
#     `"..." | grep -q ...` の形になると「引用符の中」と誤認して見逃す。Phase 130 で
#     この形の実例を 3 件、目視レビューで発見・修正した (この検出器では検出できない
#     既知の限界として残す)
#
# Usage: bash tests/test-pipefail-grep-q-safety.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SELF_REL="tests/$(basename "${BASH_SOURCE[0]}")"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "✗ $1" >&2; }

# ---- 走査対象 ----
# pipefail が有効なシェルスクリプトだけを対象にする。pipefail が無ければ
# grep が一致している限りパイプライン全体は成功するため実害がない。
# macOS の /bin/bash は 3.2 のため `mapfile` (bash 4+) は使えない。
TARGET_FILES=()
while IFS= read -r _f; do
  TARGET_FILES+=("$_f")
done < <(
  find tests scripts hooks -type f -name '*.sh' 2>/dev/null \
    | grep -v '/node_modules/' \
    | grep -v "^${SELF_REL}$" \
    | sort
)

scan_file() {
  # $1: file
  # pipefail 無効なら対象外
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*o[[:space:]]+pipefail|^[[:space:]]*set[[:space:]]+-o[[:space:]]+pipefail' "$1" || return 0

  # producer (種類を問わない) の出力を grep -q 系へパイプしている行。
  # パイプ記号が引用符の外にあるものだけを対象にする。引用符の中の `| grep -q` は
  # 説明文やメッセージの一部であって実行されないため。
  # 除外するもの:
  #   - コメント行 (行頭が #)。説明文中に構文を書けるようにするため
  #   - `|| true` / `|| :` で終わる行。pipefail が結果を昇格させないため実害がない
  #   - `||` (論理 OR) の右側にある `grep -q`。パイプではないため対象外
  perl -e '
    # 物理行を論理行へ畳む。行末の継続文字 `\` を跨ぐパイプラインを見落とさないため。
    # あわせて here-document の本文を読み飛ばす。here-doc の中の `|` は実行される
    # パイプではなく、説明文やテンプレートの一部なので走査対象にしてはいけない。
    my @logical;
    my ($buf, $start) = ("", 0);
    my ($hd, @hd_queue);   # $hd = 読み飛ばし中の終端子 [delim, allow_indent]
    while (my $l = <>) {
      chomp $l;

      if (defined $hd) {
        my ($delim, $allow_indent) = @$hd;
        my $t = $l;
        $t =~ s/^\t+// if $allow_indent;   # `<<-` はタブ字下げされた終端子を許す
        if ($t =~ /^\s*\Q$delim\E\s*$/) {
          $hd = @hd_queue ? shift @hd_queue : undef;
        }
        next;
      }

      # この物理行が開始する here-doc の終端子を集める。
      # `<<<` (herestring) は here-doc ではないので、次の文字がクォートか
      # 識別子先頭でなければ一致しない正規表現にしてある。
      my @started;
      my $probe = $l;
      while ($probe =~ /<<(-?)\s*(?:([\x27"])([A-Za-z_][A-Za-z0-9_]*)\2|([A-Za-z_][A-Za-z0-9_]*))/g) {
        push @started, [ (defined $3 ? $3 : $4), ($1 eq q{-} ? 1 : 0) ];
      }

      $start = $. unless length $buf;
      if ($l =~ s/\\$//) { $buf .= $l; push @hd_queue, @started; next; }
      push @logical, [$start, $buf . $l];
      $buf = "";

      unshift @started, @hd_queue; @hd_queue = ();
      if (@started) { $hd = shift @started; @hd_queue = @started; }
    }
    push @logical, [$start, $buf] if length $buf;

    for my $rec (@logical) {
      my ($lineno, $line) = @$rec;
      next if $line =~ /^\s*#/;
      next if $line =~ /\|\|\s*(?:true|:)\s*$/;

      # 引用符の外にあるパイプ位置を集める
      my ($q, $i, @pipes) = ("", 0);
      while ($i < length $line) {
        my $c = substr($line, $i, 1);
        if ($q) {
          # 二重引用符の中では `\` がエスケープとして働く。単一引用符の中では働かない。
          if ($q eq q{"} && $c eq "\\") { $i += 2; next; }
          $q = "" if $c eq $q;
          $i++; next;
        }
        if ($c eq q{"} || $c eq q{'"'"'}) { $q = $c; $i++; next; }
        if ($c eq "\\") { $i += 2; next; }
        # `||` は or 演算子なのでパイプとして数えない
        if ($c eq "|") {
          if (substr($line, $i, 2) eq "||") { $i += 2; next; }
          push @pipes, $i;
        }
        $i++;
      }
      for my $p (@pipes) {
        my $before = substr($line, 0, $p);
        my $after  = substr($line, $p + 1);
        # producer 種別は問わない。パイプの左側に何らかのコマンドがあれば対象とする
        # (Phase 130: printf/echo/cat 限定を撤廃)。
        next unless $before =~ /\S/;
        next unless $after  =~ /^\s*grep\s+(?:-[a-zA-Z]+\s+)*-[a-zA-Z]*q/;
        print "$lineno:$line\n";
        last;
      }
    }
  ' "$1" 2>/dev/null | sed "s|^|$1:|"
}

FINDINGS=""
for f in "${TARGET_FILES[@]}"; do
  hits="$(scan_file "$f" || true)"
  [[ -n "$hits" ]] && FINDINGS+="$hits"$'\n'
done
FINDINGS="${FINDINGS%$'\n'}"

# ---- 1. 検出結果 ----

if [[ -z "$FINDINGS" ]]; then
  pass "pipefail 下の 'producer | grep -q' は検出されませんでした"
else
  count="$(printf '%s\n' "$FINDINGS" | grep -c . || true)"
  fail "pipefail 下の 'producer | grep -q' を ${count} 箇所検出しました (herestring '<<<' か grep のファイル引数へ書き換えてください)"
  printf '%s\n' "$FINDINGS" | sed 's/^/    /'
fi

# ---- 2. 除外条件が効いているか (fixture で固定) ----

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pipefail-grep-q.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# (a) pipefail 無し → 検出しない
cat > "$FIXTURE_DIR/no-pipefail.sh" <<'FIXEOF'
#!/bin/bash
set -eu
printf '%s' "$x" | grep -q "needle"
FIXEOF

# (b) pipefail 有り + 該当構文 → 検出する
cat > "$FIXTURE_DIR/hit.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
printf '%s' "$x" | grep -q "needle"
FIXEOF

# (c) pipefail 有り + `|| true` で終わる → 検出しない
cat > "$FIXTURE_DIR/or-true.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
printf '%s' "$x" | grep -q "needle" || true
FIXEOF

# (d) pipefail 有り + herestring (正しい書き方) → 検出しない
cat > "$FIXTURE_DIR/herestring.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
grep -q "needle" <<<"$x"
FIXEOF

# (e) pipefail 有り + grep -q 以外 (-c など) → 検出しない (早期終了しない)
cat > "$FIXTURE_DIR/grep-c.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
printf '%s' "$x" | grep -c "needle"
FIXEOF

# (f) pipefail 有り + コメント行に書かれた構文 → 検出しない
cat > "$FIXTURE_DIR/comment.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
# printf '%s' "$x" | grep -q "needle" は使わないこと
grep -q "needle" <<<"$x"
FIXEOF

# (g) pipefail 有り + 引用符の中に書かれた構文 → 検出しない (実行されない文字列)
cat > "$FIXTURE_DIR/quoted.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
echo "producer | grep -q は使わないこと"
grep -q "needle" <<<"$x"
FIXEOF

# (h) pipefail 有り + 行末の継続文字を跨ぐパイプライン → 検出する
cat > "$FIXTURE_DIR/continuation.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
printf '%s' "$x" \
  | grep -q "needle"
FIXEOF

# (i) pipefail 有り + 二重引用符の中のエスケープされた引用符 → 検出しない
# `\"` を閉じ引用符と誤解すると、後続の `| grep -q` が引用符の外に見えてしまう
cat > "$FIXTURE_DIR/escaped-quote.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
echo "he said \"use x | grep -q y\" today"
grep -q "needle" <<<"$x"
FIXEOF

# (j) pipefail 有り + jq producer (printf/echo/cat 以外) → 検出する (Phase 130)
cat > "$FIXTURE_DIR/jq-producer.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
jq -r '.field' <<<"$x" | grep -q "needle"
FIXEOF

# (k) pipefail 有り + find producer (printf/echo/cat 以外) → 検出する (Phase 130)
cat > "$FIXTURE_DIR/find-producer.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
find . -name "*.txt" | grep -q .
FIXEOF

# (l) pipefail 有り + printf/echo/cat 以外の producer + `|| true` → 検出しない
# (広げた producer 判定でも既存の `|| true` 除外が効くことを固定する)
cat > "$FIXTURE_DIR/other-producer-or-true.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
some_cmd | grep -q "needle" || true
FIXEOF

# (m) pipefail 無し + jq producer → 検出しない
cat > "$FIXTURE_DIR/jq-no-pipefail.sh" <<'FIXEOF'
#!/bin/bash
set -eu
jq -r '.field' <<<"$x" | grep -q "needle"
FIXEOF

# (l) here-document の本文に書かれた構文 → 検出しない
#     here-doc の中の `|` は実行されるパイプではなく、説明文やテンプレートの一部。
cat > "$FIXTURE_DIR/heredoc-body.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
cat <<'DOC'
説明: producer | grep -q needle と書くと結果が反転します
DOC
FIXEOF

# (m) here-document の直後にある実際のパイプライン → 検出する
#     本文の読み飛ばしが行き過ぎて後続の実コードまで隠さないことの非退行。
cat > "$FIXTURE_DIR/heredoc-then-hit.sh" <<'FIXEOF'
#!/bin/bash
set -euo pipefail
cat <<'DOC'
producer | grep -q needle
DOC
jq -r '.field' <<<"$x" | grep -q "needle"
FIXEOF

# (n) `<<-` (タブ字下げ終端子) の here-document 本文 → 検出しない
#     終端子がタブで字下げされていても本文の終わりを認識できること。
printf '%s\n' '#!/bin/bash' 'set -euo pipefail' 'cat <<-DOC' \
  '	説明: producer | grep -q needle' '	DOC' > "$FIXTURE_DIR/heredoc-dash.sh"

expect_scan() {
  local file="$1" expected="$2" label="$3"
  local got
  got="$(scan_file "$file" || true)"
  if [[ "$expected" == "hit" && -n "$got" ]]; then
    pass "fixture: $label は検出される"
  elif [[ "$expected" == "miss" && -z "$got" ]]; then
    pass "fixture: $label は検出されない"
  else
    fail "fixture: $label の判定が期待と異なる (expected=$expected, got='${got}')"
  fi
}

expect_scan "$FIXTURE_DIR/no-pipefail.sh" miss "pipefail 無し"
expect_scan "$FIXTURE_DIR/hit.sh"         hit  "pipefail + printf | grep -q"
expect_scan "$FIXTURE_DIR/or-true.sh"     miss "|| true で終わる行"
expect_scan "$FIXTURE_DIR/herestring.sh"  miss "herestring (正しい書き方)"
expect_scan "$FIXTURE_DIR/grep-c.sh"      miss "grep -c (早期終了しない)"
expect_scan "$FIXTURE_DIR/comment.sh"     miss "コメント行に書かれた構文"
expect_scan "$FIXTURE_DIR/quoted.sh"      miss "引用符の中に書かれた構文"
expect_scan "$FIXTURE_DIR/continuation.sh"   hit  "行末の継続文字を跨ぐパイプライン"
expect_scan "$FIXTURE_DIR/escaped-quote.sh"  miss "二重引用符内のエスケープされた引用符"
expect_scan "$FIXTURE_DIR/jq-producer.sh"    hit  "pipefail + jq | grep -q (printf/echo/cat 以外の producer)"
expect_scan "$FIXTURE_DIR/find-producer.sh"  hit  "pipefail + find | grep -q (printf/echo/cat 以外の producer)"
expect_scan "$FIXTURE_DIR/other-producer-or-true.sh" miss "任意 producer + || true で終わる行"
expect_scan "$FIXTURE_DIR/jq-no-pipefail.sh" miss "pipefail 無し + jq | grep -q"
expect_scan "$FIXTURE_DIR/heredoc-body.sh"   miss "here-document の本文に書かれた構文"
expect_scan "$FIXTURE_DIR/heredoc-then-hit.sh" hit "here-document の直後にある実際のパイプライン"
expect_scan "$FIXTURE_DIR/heredoc-dash.sh"   miss "タブ字下げ終端子 (<<-) の here-document 本文"

# ---- 3. サマリ ----

echo
echo "============================================"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "All assertions passed."
  exit 0
fi
exit 1
