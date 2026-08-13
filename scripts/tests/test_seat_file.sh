#!/usr/bin/env bash
# v107/v108 — the FILE seat: current Claude Code keeps the active credential in
# $CLAUDE_CONFIG_DIR/.credentials.json and no longer writes the bare keychain slot this
# bank was built against. Reads AND writes must follow the seat, or banking reports "not
# logged in" on a logged-in machine (13 Aug: bank frozen ~20h) and a swap writes a place
# the CLI never reads (switching nothing).
#
# These cases run with NO security stub on purpose — in file mode kc_write never invokes
# `security` at all, so nothing here can touch the real keychain. CLAUDE_CONFIG_DIR is a
# temp dir throughout; the owner's real ~/.claude/.credentials.json is never read.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB_DIR="$(dirname "$HERE")"
# shellcheck source=testlib.sh
. "$HERE/testlib.sh"

FAILS=0; COUNT=0
ok() { COUNT=$((COUNT+1)); if [ "$1" = "0" ]; then printf '  ok   %s\n' "$2"; else printf '  FAIL %s\n' "$2"; FAILS=$((FAILS+1)); fi; }
eq() { COUNT=$((COUNT+1)); if [ "$1" = "$2" ]; then printf '  ok   %s\n' "$3"; else printf '  FAIL %s (expected [%s] got [%s])\n' "$3" "$1" "$2"; FAILS=$((FAILS+1)); fi; }

new_env seatfile >/dev/null      # exports BANK_DIR/CLAUDE_JSON/stubs into THIS shell
BASE="$(dirname "$BANK_DIR")"
CFG="$BASE/cfgdir"; mkdir -p "$CFG"
BLOB='{"claudeAiOauth":{"accessToken":"AT-FILE","refreshToken":"RT-FILE","expiresAt":99999999999999,"subscriptionType":"max"}}'

# The stub indirection new_env sets is exactly what must DISABLE file mode; drop it for
# the file-seat cases and restore it for the isolation case below.
STUB_SEC="$ACCOUNT_BANK_SECURITY_BIN"; STUB_KC="$STUB_KC_FILE"
unset ACCOUNT_BANK_SECURITY_BIN STUB_KC_FILE

export CLAUDE_CONFIG_DIR="$CFG"
# shellcheck source=../lib.sh
. "$AB_DIR/lib.sh"

# --- seat detection
if _seat_is_file; then r=0; else r=1; fi
eq "1" "$r" "an ABSENT credentials file is not the file seat (falls through to the slot)"

printf '%s' "$BLOB" > "$CFG/.credentials.json"
if _seat_is_file; then r=0; else r=1; fi
eq "0" "$r" "a present, non-empty credentials file IS the seat"

: > "$CFG/.credentials.json"
if _seat_is_file; then r=0; else r=1; fi
eq "1" "$r" "an EMPTY credentials file is not a usable seat"
printf '%s' "$BLOB" > "$CFG/.credentials.json"

# --- cred_read follows the seat
eq "$BLOB" "$(cred_read)" "cred_read returns the file's credential"

printf '%s' 'not json at all' > "$CFG/.credentials.json"
out="$(cred_read 2>/dev/null)"; rc=$?
ok "$([ "$out" != "not json at all" ] && echo 0 || echo 1)" \
   "a file that does not parse is NOT served as a credential (falls through)"
printf '%s' "$BLOB" > "$CFG/.credentials.json"

# --- the seat path follows CLAUDE_CONFIG_DIR, never $HOME blindly.
# Crossing accounts here would hand a pinned context the DEFAULT account's credential.
eq "$CFG/.credentials.json" "$(_seat_file_path)" "the seat path follows CLAUDE_CONFIG_DIR"

# --- isolation: redirected credential reads must never reach the real file.
# This guard is why the hermetic suite stopped reading the owner's live token.
( export ACCOUNT_BANK_SECURITY_BIN="$STUB_SEC" STUB_KC_FILE="$STUB_KC"
  if _seat_is_file; then echo FILE; else echo SLOT; fi ) > "$BASE/iso.txt"
eq "SLOT" "$(cat "$BASE/iso.txt")" "a stubbed/redirected security bin forces the SLOT, never the file"

# --- (v108.1) the seat read must not depend on ANY external binary.
# QuotaBar runs as an LSUIElement with PATH=/usr/bin:/bin:/usr/sbin:/sbin — the same
# minimal-PATH class of environment that once made bare `claude` fail rc 127 and killed
# auto-ping. A credential read is not the place to need a subprocess, so the shape check
# is pure bash (case + $(<file)) rather than a python3 parse.
( PATH=/nonexistent; r="$(cred_read)"; [ ${#r} -gt 0 ] ) && rr=0 || rr=1
eq "0" "$rr" "cred_read works with an EMPTY PATH (no python3, no cat)"

# --- kc_write writes THE FILE, verifies against it, and leaves it 0600.
# No `security` process is involved in this branch at all.
NEW='{"claudeAiOauth":{"accessToken":"AT-NEW","refreshToken":"RT-NEW","expiresAt":99999999999999,"subscriptionType":"max"}}'
acquire_lock >/dev/null 2>&1
if printf '%s' "$NEW" | kc_write >/dev/null 2>&1; then wrc=0; else wrc=$?; fi
release_lock >/dev/null 2>&1
eq "0" "$wrc" "kc_write succeeds against the file seat"
eq "$NEW" "$(cat "$CFG/.credentials.json")" "the credential FILE now holds the new blob"
eq "600" "$(stat -f '%OLp' "$CFG/.credentials.json")" "the credential file stays 0600"

# --- the pre-overwrite credential must still be recoverable (never-destroy principle)
ok "$([ -n "$(ls -1 "$BANK_DIR"/archive/* 2>/dev/null || true)" ] && echo 0 || echo 1)" \
   "the pre-overwrite credential was archived before being replaced"

printf -- '-- seat_file: %d passed, %d failed\n' "$((COUNT-FAILS))" "$FAILS"
[ "$FAILS" -eq 0 ]
