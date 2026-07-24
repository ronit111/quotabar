#!/bin/bash
# "A malformed record never destroys credentials / never hides accounts" class:
# ping marker (39), toggle config (54), list rendering (53), bank writer id-match (6).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"

# ---- finding 39: ping marker REFUSES a malformed record (does not clobber it) ----
new_env mal_ping >/dev/null
printf '{ broken json with a token "accessToken":"SECRET"' | W "$BANK_DIR/p@x.com.json"
before="$(cat "$BANK_DIR/p@x.com.json")"
# (r6 b10) _ping_marker now runs the epoch gate first; the lock-holding caller passes the
# lock-acquire snapshot via ACCOUNT_BANK_EPOCH_SNAP. Sandbox has no EPOCH file (=> "v1 0").
ACCOUNT_BANK_EPOCH_SNAP="v1 0" python3 "$AB_DIR/_ping_marker.py" "$BANK_DIR/p@x.com.json" 123 success >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "ping marker refuses to stamp a malformed record (finding 39)"
assert_eq "$before" "$(cat "$BANK_DIR/p@x.com.json")" "malformed record left UNCHANGED (creds not destroyed)"
# valid record: marker succeeds and preserves credentials
bank_record v@x.com V "" "$FUT" pro claude_pro
ACCOUNT_BANK_EPOCH_SNAP="v1 0" python3 "$AB_DIR/_ping_marker.py" "$BANK_DIR/v@x.com.json" 456 success >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "ping marker stamps a valid record"
assert_contains '"accessToken": "V"' "$(cat "$BANK_DIR/v@x.com.json")" "credentials preserved after marker"
assert_contains '"last_ping": 456' "$(cat "$BANK_DIR/v@x.com.json")" "last_ping written"

# ---- finding 54: toggle-autoping QUARANTINES a malformed config, preserves settings ----
new_env mal_toggle >/dev/null
printf 'NOT VALID JSON { auto_pick maybe' | W "$BANK_DIR/.config.json"
/bin/bash "$AB_DIR/toggle-autoping.sh" x@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "toggle refuses a malformed config (finding 54)"
ls "$BANK_DIR"/.config.json.corrupt.* >/dev/null 2>&1
assert_eq 0 "$?" "malformed config quarantined (not overwritten with a partial file)"

# ---- finding 53: list-accounts renders an invalid record as INVALID, not a crash ----
new_env mal_list >/dev/null
bank_record good@x.com G "" "$FUT" max claude_max
printf '{"email":"bad@x.com","claudeAiOauth":{"expiresAt":"not-a-number"}}' | W "$BANK_DIR/bad@x.com.json"
out="$(/bin/bash "$AB_DIR/list-accounts.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "list-accounts does not crash on a malformed record"
assert_contains "good@x.com" "$out" "valid account still listed (finding 53)"
assert_contains "INVALID" "$out" "malformed account shown as INVALID, not hidden"

# ---- finding 6: bank writer refuses metadata/identity mismatch ----
new_env mal_writer >/dev/null
printf '{"oauthAccount":{"emailAddress":"someone-else@x.com"}}' | W "$CLAUDE_JSON"
blob='{"claudeAiOauth":{"accessToken":"A","refreshToken":"rA","expiresAt":111}}'
printf '%s' "$blob" | python3 "$AB_DIR/write_bank_record.py" "$CLAUDE_JSON" target@x.com "$BANK_DIR/target@x.com.json" iso 1 >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "bank writer refuses when metadata email != banked email (finding 6)"
assert_file_absent "$BANK_DIR/target@x.com.json" "no record written on identity mismatch"
# incomplete blob (missing refreshToken) refused
printf '{"oauthAccount":{"emailAddress":"target@x.com"}}' | W "$CLAUDE_JSON"
printf '{"claudeAiOauth":{"accessToken":"A","expiresAt":111}}' | python3 "$AB_DIR/write_bank_record.py" "$CLAUDE_JSON" target@x.com "$BANK_DIR/target@x.com.json" iso 1 >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "bank writer refuses an incomplete credential (finding 6)"

finish "malformed"
