#!/bin/bash
# Tests for attest-cutover.sh's PURE predicates (r8 #13 per-PID ack, r8 #14 versioned/
# JS-entrypoint detection). Sources ONLY the definitions above the first live probe, so
# nothing here touches the running system, launchd, or the network.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAILS=0
ok() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $2"; else FAILS=$((FAILS+1)); echo "  FAIL $2"; fi; }

# extract everything before the first live probe ("# 1. shim installed ...") — regexes,
# _has_unshimmed_claude, _all_acked, and the harmless helpers/vars they sit beside.
DEFS="$(mktemp)"
sed '/^# 1\. shim installed/,$d' "$HERE/attest-cutover.sh" > "$DEFS"
# shellcheck disable=SC1090
source "$DEFS"
SHIM="/test/accounts/bin/claude"     # override the sourced default AFTER sourcing

flag() { printf '%s\n' "$1" | _has_unshimmed_claude; }   # 0 == flagged as unshimmed

# (r8 #14) direct invocations of the real versioned binary / local install / JS entrypoint
# bypass the shim and MUST be flagged, even though "claude" is followed by "/" (which the
# bare command-token regex deliberately excludes).
flag "/Users/x/.claude/local/claude --dangerously-skip" && ok 0 ".claude/local/claude flagged (r8 #14)" || ok 1 ".claude/local/claude flagged (r8 #14)"
flag "/opt/homebrew/Caskroom/claude/versions/2.1.7/claude -p hi" && ok 0 "claude/versions/<v> flagged (r8 #14)" || ok 1 "claude/versions/<v> flagged (r8 #14)"
flag "node /Users/x/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js" && ok 0 "cli.js JS entrypoint flagged (r8 #14)" || ok 1 "cli.js JS entrypoint flagged (r8 #14)"
# safe lines: routed through the shim or claude-acct, or unrelated
flag "$SHIM --resume abc" && ok 1 "shim line wrongly flagged" || ok 0 "shim line NOT flagged (safe)"
flag "claude-acct a@x.com" && ok 1 "claude-acct line wrongly flagged" || ok 0 "claude-acct line NOT flagged (safe)"
flag "echo claudexyz is not a match" && ok 1 "claudexyz wrongly flagged" || ok 0 "claudexyz NOT flagged (word-boundary)"

# (r10 #7) a line that BOTH invokes the real binary AND mentions the shim/claude-acct (after
# a `;` or in a comment) must STILL flag — the old whole-line `grep -vF "$SHIM"` dropped it.
flag "/opt/homebrew/bin/claude -p x; # $SHIM" && ok 0 "real claude + shim mention on same line -> flagged (r10 #7)" || ok 1 "real+shim same line flagged (r10 #7)"
flag "/opt/homebrew/bin/claude -p x ; claude-acct whatever" && ok 0 "real claude + claude-acct on same line -> flagged (r10 #7)" || ok 1 "real+claude-acct same line flagged (r10 #7)"
flag "$SHIM -p x ; echo done" && ok 1 "pure shim line wrongly flagged" || ok 0 "pure shim line (with trailing cmd) NOT flagged (r10 #7)"
flag "# $SHIM is our launcher" && ok 1 "shim-only comment wrongly flagged" || ok 0 "shim-only comment NOT flagged (r10 #7)"

# (flip-sitting #2) a com.claude.* reverse-DNS label is NOT an invocation — every one of
# our launchd jobs is named com.claude.<x>, and the bare token between the dots flagged
# them all by name on the first live run.
flag "<string>com.claude.git-sync</string>" && ok 1 "com.claude.* label wrongly flagged" || ok 0 "com.claude.* label NOT flagged (flip-sitting #2)"
flag "	label = com.claude.local-daily-brief" && ok 1 "loaded-job label line wrongly flagged" || ok 0 "loaded com.claude.* label line NOT flagged (flip-sitting #2)"
flag "/opt/homebrew/bin/claude -p x # com.claude.git-sync" && ok 0 "real claude + com.claude. label same line -> still flagged" || ok 1 "real claude + label same line flagged (flip-sitting #2)"

# (flip-sitting #2) XML comment spans are inert and must be stripped before the scan —
# prose like "~/.claude commits" inside a comment matched the token regex.
_cmt_out="$(printf '<!-- ~/.claude commits are synced here -->\n<string>/bin/bash</string>\n' | _strip_xml_comments)"
printf '%s\n' "$_cmt_out" | _has_unshimmed_claude && ok 1 "comment prose wrongly flagged after strip" || ok 0 "XML comment prose stripped before scan (flip-sitting #2)"
_ml_out="$(printf '<!-- line one\n claude sync prose\n-->\n<string>claude</string>\n' | _strip_xml_comments)"
printf '%s\n' "$_ml_out" | _has_unshimmed_claude && ok 0 "real claude outside multi-line comment still flagged" || ok 1 "claude outside comment must still flag"

# (release-eve) an UNTERMINATED `<!--` must FAIL CLOSED: the old stripper swallowed the
# whole remainder of the plist, so one unbalanced comment hid every Program line below it.
_unterm="$(printf '<key>ProgramArguments</key>\n<!-- oops, never closed\n<string>/opt/homebrew/bin/claude</string>\n<string>-p</string>\n' | _strip_xml_comments)"
printf '%s\n' "$_unterm" | _has_unshimmed_claude && ok 0 "unterminated <!-- does NOT hide a real-binary line (fail closed) (release-eve)" || ok 1 "unterminated comment fails closed (release-eve)"
case "$_unterm" in *"/opt/homebrew/bin/claude"*) ok 0 "suppressed remainder of an unterminated comment is emitted (release-eve)";; *) ok 1 "suppressed remainder emitted (got: $_unterm)";; esac
# a properly CLOSED comment still emits nothing from inside it (no regression)
_closed="$(printf '<!-- /opt/homebrew/bin/claude in prose -->\n<string>/bin/bash</string>\n' | _strip_xml_comments)"
printf '%s\n' "$_closed" | _has_unshimmed_claude && ok 1 "closed comment content wrongly emitted" || ok 0 "closed comment still fully stripped (no regression) (release-eve)"

# (release-eve) _nondescendant_shell_pids — the self-exclusion walk, as a PURE function over a
# `pid ppid comm` table. Rows are deliberately UNORDERED (ps output is not topological).
_walk() { printf '%s\n' "$1" | _nondescendant_shell_pids "$2"; }
# the operator's invoking shell is the root's PARENT, never a descendant -> it MUST survive.
_tbl_parent='500 1 zsh
600 500 bash'
[ "$(_walk "$_tbl_parent" 600)" = "500" ] && ok 0 "parent-of-root survives the self-exclusion walk (release-eve)" || ok 1 "parent-of-root survives (got: $(_walk "$_tbl_parent" 600))"
# a DEEP transitive descendant chain, rows shuffled: every link must be excluded.
_tbl_deep='904 903 bash
901 900 bash
903 902 zsh
900 1 zsh
902 901 zsh'
[ -z "$(_walk "$_tbl_deep" 900)" ] && ok 0 "deep UNORDERED descendant chain fully excluded (release-eve)" || ok 1 "deep unordered chain excluded (got: $(_walk "$_tbl_deep" 900))"
# an unrelated shell is kept even when a descendant chain is present.
_tbl_mixed='903 902 zsh
777 1 zsh
902 900 zsh
900 1 zsh'
[ "$(_walk "$_tbl_mixed" 900)" = "777" ] && ok 0 "unrelated shell PID is kept (release-eve)" || ok 1 "unrelated PID kept (got: $(_walk "$_tbl_mixed" 900))"
# non-shell descendants/rows never appear, and the walk TERMINATES on arbitrary row order
# (including a self-parenting row that would loop a naive walk).
_tbl_term='2 2 zsh
5 4 bash
4 3 zsh
3 1 launchd
1 1 launchd'
_walk_out="$(_walk "$_tbl_term" 4)"
[ "$_walk_out" = "2" ] && ok 0 "walk terminates on arbitrary/self-parenting rows, keeps only unrelated shells (release-eve)" || ok 1 "walk terminates on arbitrary rows (got: $_walk_out)"

# (release-eve) note() must escape CONTROL characters too — a detail carrying a raw
# newline/tab (a ps comm, a crontab line) corrupts the hand-assembled report JSON.
checks=(); fails=0
note "ctl" false "$(printf 'line1\nline2\ttabbed\rcr')"
printf '{"checks":[%s]}' "${checks[0]}" | python3 -m json.tool >/dev/null 2>&1 && ok 0 "note() detail with newline/tab/CR yields valid JSON (release-eve)" || ok 1 "note() control-char escaping (release-eve)"
_rt="$(printf '{"checks":[%s]}' "${checks[0]}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["checks"][0]["detail"])')"
[ "$_rt" = "$(printf 'line1\nline2\ttabbed\rcr')" ] && ok 0 "escaped control chars round-trip to the original detail (release-eve)" || ok 1 "control chars round-trip (got: $(printf '%s' "$_rt" | od -c | head -2))"
checks=(); fails=0

# (release-eve) the live gate must REFUSE to run when SOURCED: sourced, $$ is the operator's
# own shell and the walk above would exclude their whole shell tree from the enumeration.
_SRC_OUT="$(cd "$HERE" && . ./attest-cutover.sh 2>&1)"; _SRC_RC=$?
[ "$_SRC_RC" -eq 2 ] && ok 0 "sourcing attest-cutover.sh refuses with rc 2 (release-eve)" || ok 1 "sourced attest refuses rc 2 (got $_SRC_RC)"
case "$_SRC_OUT" in *"refusing to run the live gate when sourced"*) ok 0 "sourced refusal names the gate-bypass reason (release-eve)";; *) ok 1 "sourced refusal message (got: $_SRC_OUT)";; esac
case "$_SRC_OUT" in *"ATTESTATION"*) ok 1 "sourced run must not reach the live probes";; *) ok 0 "sourced run never reaches the live probes (release-eve)";; esac

# (flip-sitting #3) note() must JSON-escape the detail — the live-shells ack example
# embeds double quotes, which corrupted the report on the first live run.
checks=(); fails=0
note "t" false 'run with ATTEST_SHELLS_ACK="1 2" and a back\slash'
printf '{"checks":[%s]}' "${checks[0]}" | python3 -m json.tool >/dev/null 2>&1 && ok 0 "note() detail with quotes+backslash yields valid JSON (flip-sitting #3)" || ok 1 "note() detail escaping (flip-sitting #3)"
checks=(); fails=0

# (r8 #13) per-PID ack: EVERY live pid must be listed; a blanket ack cannot pass a set.
_all_acked "111 222" 111 222 && ok 0 "every live pid acked -> pass (r8 #13)" || ok 1 "every live pid acked -> pass (r8 #13)"
_all_acked "111" 111 222 && ok 1 "partial ack wrongly passes" || ok 0 "partial ack -> fail closed (r8 #13)"
_all_acked "1" 111 && ok 1 "blanket ATTEST=1 wrongly passes" || ok 0 "blanket ATTEST_*_ACK=1 -> fail closed (r8 #13)"
_all_acked "" 111 && ok 1 "empty ack wrongly passes" || ok 0 "empty ack -> fail closed (r8 #13)"

rm -f "$DEFS"
echo "-- attest: $PASS passed, $FAILS failed"
[ $FAILS -eq 0 ]
