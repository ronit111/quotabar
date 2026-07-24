#!/bin/bash
# (r9 #3) The shipped archiver launchd template carries a literal __SCRIPTS_DIR__
# placeholder; install.sh must substitute it with the real install path. This test
# verifies BOTH that install.sh wires the substitution AND that the template + the
# substitution produce a valid, placeholder-free plist. Hermetic: no launchctl, no load.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$AB/.." && pwd)"
TEMPLATE="$AB/launchd/com.quotabar.archiver.plist"
INSTALL="$REPO/install.sh"
PASS=0; FAILS=0
ok() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $2"; else FAILS=$((FAILS+1)); echo "  FAIL $2"; fi; }

# the template SHIPS the placeholder (that is intended — it is a template)
grep -q "__SCRIPTS_DIR__/archiverd.py" "$TEMPLATE" && ok 0 "template carries the __SCRIPTS_DIR__ placeholder" || ok 1 "template carries the placeholder"

# install.sh WIRES the substitution (sed on __SCRIPTS_DIR__ -> a LaunchAgents plist).
# install.sh lives at the REPO ROOT, not inside the account-bank scripts dir — so in the
# byte-synced live tree it is absent; those checks SKIP there (verified in the repo tree).
if [ -f "$INSTALL" ]; then
  # (release-eve) the plist write, the shim staging and the REAL_CLAUDE_BIN merge now live
  # behind --with-pinning (default OFF). PINBLOCK is the text of that gated region; the
  # wiring assertions below therefore point at the FLAGGED path, not the default one.
  PINBLOCK="$(awk '/^if \[ "\$WITH_PINNING" -eq 1 \]; then$/{inb=1} /^# ===== end opt-in launch pinning/{inb=0} inb' "$INSTALL")"
  [ -n "$PINBLOCK" ] && ok 0 "install.sh has a --with-pinning gated block (release-eve)" || ok 1 "install.sh gates pinning behind --with-pinning (release-eve)"
  grep -q '\-\-with-pinning) WITH_PINNING=1' "$INSTALL" && ok 0 "install.sh parses --with-pinning (release-eve)" || ok 1 "install.sh parses --with-pinning (release-eve)"
  grep -q 'WITH_PINNING=0' "$INSTALL" && ok 0 "pinning defaults to OFF (release-eve)" || ok 1 "pinning defaults OFF (release-eve)"
  # the three side-effecting writes must be INSIDE the gated block, not on the default path
  printf '%s\n' "$PINBLOCK" | grep -q 'LaunchAgents' && ok 0 "archiver plist write is gated behind --with-pinning (release-eve)" || ok 1 "plist write gated (release-eve)"
  printf '%s\n' "$PINBLOCK" | grep -q 'REAL_CLAUDE_BIN' && ok 0 "REAL_CLAUDE_BIN merge is gated behind --with-pinning (release-eve)" || ok 1 "REAL_CLAUDE_BIN merge gated (release-eve)"
  printf '%s\n' "$PINBLOCK" | grep -q '_stage_shim' && ok 0 "shim staging is gated behind --with-pinning (release-eve)" || ok 1 "shim staging gated (release-eve)"
  # (release-eve) ACCOUNTS_DIR honors BANK_DIR then ACCOUNT_BANK_DIR then the default (lib.sh:22)
  grep -q 'ACCOUNTS_DIR="${BANK_DIR:-${ACCOUNT_BANK_DIR:-$HOME/.claude/accounts}}"' "$INSTALL" && ok 0 "ACCOUNTS_DIR mirrors lib.sh resolution order (release-eve)" || ok 1 "ACCOUNTS_DIR honors BANK_DIR/ACCOUNT_BANK_DIR (release-eve)"
  # (release-eve) --help works and advertises the flag; an unknown flag is refused, not ignored
  _HELP="$(/bin/bash "$INSTALL" --help 2>&1)"; _HRC=$?
  { [ "$_HRC" -eq 0 ] && printf '%s' "$_HELP" | grep -q -- '--with-pinning'; } && ok 0 "install.sh --help documents --with-pinning (release-eve)" || ok 1 "install.sh --help documents the flag (rc $_HRC: $_HELP)"
  /bin/bash "$INSTALL" --nonsense >/dev/null 2>&1 && ok 1 "install.sh must reject an unknown flag" || ok 0 "install.sh rejects an unknown flag (release-eve)"
  # (release-eve) the DEFAULT path must not talk about ceremonies it is not performing:
  # every cutover/SHADOW mention in executable output belongs to the gated block.
  _CUT_DEFAULT="$(awk '/^if \[ "\$WITH_PINNING" -eq 1 \]; then$/{inb=1} /^# ===== end opt-in launch pinning/{inb=0} !inb' "$INSTALL" \
      | grep -vE '^\s*#' | grep -nEi 'cutover|SHADOW' | grep -vE 'WITH_PINNING' || true)"
  [ -z "$_CUT_DEFAULT" ] && ok 0 "default install output never mentions cutover/SHADOW (release-eve)" || ok 1 "default path mentions cutover/SHADOW: $_CUT_DEFAULT"
  grep -q "__SCRIPTS_DIR__" "$INSTALL" && ok 0 "install.sh substitutes __SCRIPTS_DIR__ (r9 #3)" || ok 1 "install.sh substitutes __SCRIPTS_DIR__ (r9 #3)"
  grep -q "LaunchAgents" "$INSTALL" && ok 0 "install.sh writes the resolved plist to LaunchAgents (r9 #3)" || ok 1 "install.sh targets LaunchAgents"
  # it must NOT load the job (owner-driven at cutover)
  grep -qE "launchctl (load|bootstrap)" "$INSTALL" && ok 1 "install.sh must NOT load the launchd job" || ok 0 "install.sh does NOT load the launchd job (r9 #3)"
  # (r10 #3) install.sh records REAL_CLAUDE_BIN + stages the shim into accounts/bin
  grep -q "REAL_CLAUDE_BIN" "$INSTALL" && ok 0 "install.sh records REAL_CLAUDE_BIN in .config.json (r10 #3)" || ok 1 "install.sh records REAL_CLAUDE_BIN (r10 #3)"
  grep -q 'ACCOUNTS_DIR/bin' "$INSTALL" && ok 0 "install.sh stages the shim into accounts/bin (r10 #3)" || ok 1 "install.sh stages the shim into accounts/bin (r10 #3)"
  # (r10 #5) the substitution must be delimiter/metachar-safe (no bare `sed s|...|$VAR|`)
  grep -qE 'sed "s\|__SCRIPTS_DIR__\|\$SCRIPTS_DEST' "$INSTALL" && ok 1 "install.sh must not use the unescaped sed substitution (r10 #5)" || ok 0 "install.sh avoids the unescaped sed substitution (r10 #5)"
  # (r11 #1) install.sh must EXCLUDE the shim when resolving REAL_CLAUDE_BIN (self-reference)
  grep -q '_is_shim' "$INSTALL" && ok 0 "install.sh excludes the shim from REAL_CLAUDE_BIN resolution (r11 #1)" || ok 1 "install.sh excludes the shim (r11 #1)"
  grep -q 'Kept the existing REAL_CLAUDE_BIN' "$INSTALL" && ok 0 "install.sh keeps existing REAL_CLAUDE_BIN rather than overwrite with a shim (r11 #1)" || ok 1 "install.sh keeps existing on shim-only PATH (r11 #1)"
  # (r11 #3) install.sh emits a RESOLVED hooks fragment
  grep -q 'hooks-fragment.resolved.json' "$INSTALL" && ok 0 "install.sh emits a resolved hooks fragment (r11 #3)" || ok 1 "install.sh emits a resolved hooks fragment (r11 #3)"
  # (r11 #4) the plist substitution XML-escapes the path
  grep -q 'saxutils import escape' "$INSTALL" && ok 0 "plist substitution XML-escapes the path (r11 #4)" || ok 1 "plist substitution XML-escapes the path (r11 #4)"
  # (r12 #2) shim staging never follows a symlink at the dest (rm-first) + refuses the real binary
  grep -q 'rm -f "\$SHIM_PATH"' "$INSTALL" && ok 0 "install.sh rm's the shim dest before cp (no-follow) (r12 #2)" || ok 1 "install.sh rm-first shim dest (r12 #2)"
  grep -q 'refusing to overwrite it' "$INSTALL" && ok 0 "install.sh refuses to overwrite the real binary (r12 #2)" || ok 1 "install.sh refuses real-binary overwrite (r12 #2)"
  # (r12 #8) the .config.json merge takes the bank lock
  grep -q 'import banklock' "$INSTALL" && grep -q 'lk.acquire' "$INSTALL" && ok 0 "install.sh merges .config.json under the bank lock (r12 #8)" || ok 1 "install.sh takes the bank lock for .config.json (r12 #8)"
  # (r12 #3) the hooks substitution shell-quotes the path (shlex.quote)
  grep -q 'shlex.quote' "$INSTALL" && ok 0 "install.sh shell-quotes the hooks path (r12 #3)" || ok 1 "install.sh shell-quotes the hooks path (r12 #3)"
  # (r13 #10) a skipped REAL_CLAUDE_BIN recording (bank-lock timeout) must FAIL LOUDLY + not stage the shim
  grep -q 'sys.exit(3)' "$INSTALL" && ok 0 "install.sh signals a skipped merge as a failure (rc 3) (r13 #10)" || ok 1 "install.sh fails a skipped merge (r13 #10)"
  grep -q 'shim NOT staged' "$INSTALL" && ok 0 "install.sh warns loudly + does not stage the shim on a skipped merge (r13 #10)" || ok 1 "install.sh loud on skipped merge (r13 #10)"
else
  echo "  ---  install.sh not in this tree (repo-root installer); wiring checks run in the repo tree"
fi

# (r10 #5) the substitution must survive a path containing sed-hostile chars ('&' and '|').
# Verify the ACTUAL mechanism install.sh uses (Python literal str.replace), not sed.
TRICKY='/tmp/q&b|c'
OUT2="$(mktemp)"
SCRIPTS_DEST="$TRICKY" TEMPLATE="$TEMPLATE" ARCHIVER_PLIST="$OUT2" python3 - <<'PY'
import os
src = open(os.environ["TEMPLATE"]).read()
open(os.environ["ARCHIVER_PLIST"], "w").write(src.replace("__SCRIPTS_DIR__", os.environ["SCRIPTS_DEST"]))
PY
grep -qF "$TRICKY/archiverd.py" "$OUT2" && ok 0 "substitution survives a path with '&' and '|' (r10 #5)" || ok 1 "substitution survives '&'/'|' path (r10 #5)"
grep -q "__SCRIPTS_DIR__" "$OUT2" && ok 1 "tricky-path plist still has the placeholder" || ok 0 "tricky-path plist fully substituted (r10 #5)"
rm -f "$OUT2"

# (r11 #4) the plist substitution must XML-ESCAPE the path: '&' -> '&amp;', and the result
# must be valid XML. Exercise the ACTUAL mechanism (Python xml.sax escape) install.sh uses.
XPATH='/tmp/a&b<c'
OUTX="$(mktemp)"
SCRIPTS_DEST="$XPATH" TEMPLATE="$TEMPLATE" OUTX="$OUTX" python3 - <<'PY'
import os
from xml.sax.saxutils import escape
src = open(os.environ["TEMPLATE"]).read()
open(os.environ["OUTX"], "w").write(src.replace("__SCRIPTS_DIR__", escape(os.environ["SCRIPTS_DEST"])))
PY
grep -q '&amp;' "$OUTX" && ok 0 "plist path '&' is XML-escaped to '&amp;' (r11 #4)" || ok 1 "plist path '&' XML-escaped (r11 #4)"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$OUTX" >/dev/null 2>&1 && ok 0 "XML-escaped plist is valid (plutil -lint) (r11 #4)" || ok 1 "XML-escaped plist valid (r11 #4)"
else
  python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$OUTX" && ok 0 "XML-escaped plist is valid (plistlib) (r11 #4)" || ok 1 "XML-escaped plist valid (r11 #4)"
fi
rm -f "$OUTX"

# (r11 #3) the shipped hooks-fragment.json is a placeholder-driven TEMPLATE, and the
# substitution yields valid JSON pointing at the real scripts dir.
HOOKS_TMPL="$AB/hooks-fragment.json"
if [ -f "$HOOKS_TMPL" ]; then
  grep -q '__SCRIPTS_DIR__/session-hook.sh' "$HOOKS_TMPL" && ok 0 "hooks-fragment.json is placeholder-driven (r11 #3)" || ok 1 "hooks-fragment.json is placeholder-driven (r11 #3)"
  grep -q '~/.claude/scripts/account-bank/session-hook.sh' "$HOOKS_TMPL" && ok 1 "hooks template must not hard-code ~/.claude path" || ok 0 "hooks template has no hard-coded ~/.claude path (r11 #3)"
  # (r12 #3) exercise the ACTUAL mechanism with a SPACES path: it must SHELL-QUOTE (shlex)
  # so the hook command doesn't word-split, AND stay valid JSON, AND run correctly.
  HOUT="$(mktemp)"
  SCRIPTS_DEST='/tmp/Quota Bar/account-bank' HOOKS_TMPL="$HOOKS_TMPL" HOUT="$HOUT" python3 - <<'PY'
import json, os, shlex
src = open(os.environ["HOOKS_TMPL"]).read()
safe = json.dumps(shlex.quote(os.environ["SCRIPTS_DEST"]))[1:-1]
out = src.replace("__SCRIPTS_DIR__", safe)
json.loads(out)   # must remain valid JSON
open(os.environ["HOUT"], "w").write(out)
PY
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HOUT" && ok 0 "resolved hooks fragment (spaces path) is valid JSON (r12 #3)" || ok 1 "resolved hooks fragment valid JSON (r12 #3)"
  # the SessionStart command, extracted and word-split by the shell, must resolve to ONE
  # existing-shaped script path (the quoting held the spaces together).
  CMD="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['hooks']['SessionStart'][0]['hooks'][0]['command'])" "$HOUT")"
  # simulate the shell parsing: `bash <quoted-path> start` -> second word is the script path
  SCRIPT_ARG="$(eval "set -- $CMD; echo \"\$2\"")"
  [ "$SCRIPT_ARG" = "/tmp/Quota Bar/account-bank/session-hook.sh" ] && ok 0 "hooks path with spaces stays ONE arg after shell-splitting (r12 #3)" || ok 1 "hooks spaces path one arg (got: [$SCRIPT_ARG])"
  rm -f "$HOUT"
else
  ok 1 "hooks-fragment.json present"
fi

# the substitution itself yields a placeholder-free, valid plist pointing at a real path
DEST="/tmp/quotabar-test-scripts-$$"
OUT="$(mktemp)"
sed "s|__SCRIPTS_DIR__|$DEST|g" "$TEMPLATE" > "$OUT"
grep -q "__SCRIPTS_DIR__" "$OUT" && ok 1 "resolved plist still has the placeholder" || ok 0 "resolved plist has NO __SCRIPTS_DIR__ left (r9 #3)"
grep -q "$DEST/archiverd.py" "$OUT" && ok 0 "resolved plist points at <scripts>/archiverd.py (r9 #3)" || ok 1 "resolved plist points at the real archiverd.py"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$OUT" >/dev/null 2>&1 && ok 0 "resolved plist is valid (plutil -lint)" || ok 1 "resolved plist is valid (plutil -lint)"
else
  python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$OUT" && ok 0 "resolved plist is valid (plistlib)" || ok 1 "resolved plist is valid (plistlib)"
fi
rm -f "$OUT"

echo "-- install_plist: $PASS passed, $FAILS failed"
[ $FAILS -eq 0 ]
