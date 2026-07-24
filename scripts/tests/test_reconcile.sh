#!/bin/bash
# reconcile: torn-swap rollback (12), external-login supersede (14), and an
# UNRESOLVED journal that BLOCKS later mutation (13).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
REC="$AB_DIR/reconcile.py"
SWAP="$AB_DIR/swap-account.sh"

blobA='{"claudeAiOauth":{"accessToken":"A","refreshToken":"rA","expiresAt":111}}'
blobB='{"claudeAiOauth":{"accessToken":"B","refreshToken":"rB","expiresAt":222}}'
blobC='{"claudeAiOauth":{"accessToken":"C","refreshToken":"rC","expiresAt":333}}'

write_journal() { # <preblob> <target> <target_fp> <current>
  python3 - "$BANK_DIR/.swap-journal.json" "$1" "$2" "$3" "$4" "$AB_DIR" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[6]); import bank_common
path, pre, target, tfp, cur = sys.argv[1:6]
json.dump({"type":"swap","pre_swap_blob":pre,"pre_fp":bank_common.cred_fingerprint(pre),
           "target":target,"target_fp":tfp,"current":cur,"ts":1}, open(path,"w"))
PY
}

# ---- finding 12: torn swap (keychain=target, metadata=source) -> roll back ----
new_env rec_torn >/dev/null
printf '%s' "$blobB" | W "$STUB_KC_FILE"                       # keychain holds target B
printf '{"oauthAccount":{"emailAddress":"a@x.com"}}' | W "$CLAUDE_JSON"   # metadata still source
write_journal "$blobA" b@x.com "$(fp_of "$blobB")" a@x.com
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "torn-swap reconcile exits 0 (resolved)"
assert_contains '"accessToken":"A"' "$(kc_now)" "keychain rolled back to pre-swap A (finding 12)"
assert_file_absent "$BANK_DIR/.swap-journal.json" "journal cleared after rollback"

# ---- finding 14 + r3 #11: external login to a THIRD account. Only dropped as
#      "superseded" when the live keychain POSITIVELY matches that account's BANKED
#      credential; otherwise the pairing is unverified and stays blocked. ----
new_env rec_supersede >/dev/null
printf '%s' "$blobC" | W "$STUB_KC_FILE"                       # keychain now holds C (external login)
printf '{"oauthAccount":{"emailAddress":"c@x.com"}}' | W "$CLAUDE_JSON"   # metadata also C (login wrote both)
bank_record c@x.com C rC 333 max claude_max                 # c@x.com IS banked, creds == live C
write_journal "$blobA" b@x.com "$(fp_of "$blobB")" a@x.com
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "superseded-swap reconcile exits 0 (live keychain == c's banked cred)"
assert_contains '"accessToken":"C"' "$(kc_now)" "external login C NOT clobbered (finding 14)"
assert_file_absent "$BANK_DIR/.swap-journal.json" "obsolete journal dropped (verified supersede)"

# r3 #11: SAME external-login shape but the active account is NOT banked with a
# matching credential -> cannot verify the two stores agree -> UNRESOLVED, kept.
new_env rec_supersede_unverif >/dev/null
printf '%s' "$blobC" | W "$STUB_KC_FILE"                       # keychain holds C
printf '{"oauthAccount":{"emailAddress":"c@x.com"}}' | W "$CLAUDE_JSON"   # metadata C, but c@x.com NOT banked
write_journal "$blobA" b@x.com "$(fp_of "$blobB")" a@x.com
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; rc=$?
assert_eq 10 "$rc" "unverified external login -> exit 10 (r3 #11 fail-closed)"
assert_file_present "$BANK_DIR/.swap-journal.json" "journal KEPT when supersede can't be verified"
assert_contains '"accessToken":"C"' "$(kc_now)" "keychain C still untouched (never clobbered)"

# ---- finding 13a: unparseable journal -> quarantined + exit 10 (unresolved) ----
new_env rec_corrupt >/dev/null
printf '%s' "$blobA" | W "$STUB_KC_FILE"
printf '{"oauthAccount":{"emailAddress":"a@x.com"}}' | W "$CLAUDE_JSON"
printf 'not json at all' | W "$BANK_DIR/.swap-journal.json"
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; rc=$?
assert_eq 10 "$rc" "unparseable swap journal -> exit 10 (unresolved)"
assert_file_absent "$BANK_DIR/.swap-journal.json" "corrupt journal moved to quarantine"
ls "$BANK_DIR"/.swap-journal.json.corrupt.* >/dev/null 2>&1
assert_eq 0 "$?" "quarantine copy exists (not silently deleted, finding 18)"

# ---- finding 13b: ambiguous KEPT journal BLOCKS a later swap ----
new_env rec_blocks >/dev/null
printf '%s' "$blobA" | W "$STUB_KC_FILE"                       # keychain unknown-ish vs journal
printf '{"oauthAccount":{"emailAddress":"a@x.com"}}' | W "$CLAUDE_JSON"   # active == source
# journal claims target=b with a target_fp that matches NOTHING live, current=a (== active):
# ambiguous "diverged while active still == source" -> kept + unresolved.
write_journal "$blobB" b@x.com "deadbeef-nomatch" a@x.com
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; rc=$?
assert_eq 10 "$rc" "ambiguous journal -> exit 10 (kept, unresolved)"
assert_file_present "$BANK_DIR/.swap-journal.json" "ambiguous journal is KEPT for inspection"
# now a swap must REFUSE while the journal is unresolved
bank_record b@x.com B
before="$(kc_now)"
/bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "swap BLOCKED while an unresolved torn-swap journal exists (finding 13)"
assert_eq "$before" "$(kc_now)" "keychain untouched while blocked"

# ---- r4 #7: Case C (torn rollback) requires the FULL evidence set: metadata must
#      STILL name the SOURCE (active == current), not merely "active != target". A
#      journal A->B with live keychain B but metadata naming a THIRD account C is NOT
#      our clean torn state — rolling back to A would leave keychain A vs metadata C.
#      Must stay UNRESOLVED (journal kept, keychain untouched). Pre-fix (active !=
#      target) restored A, cleared the journal, and reported resolved. ----
new_env rec_r47_thirdmeta >/dev/null
printf '%s' "$blobB" | W "$STUB_KC_FILE"                        # keychain holds target B
printf '{"oauthAccount":{"emailAddress":"c@x.com"}}' | W "$CLAUDE_JSON"   # metadata names THIRD account C
write_journal "$blobA" b@x.com "$(fp_of "$blobB")" a@x.com      # journal: source a -> target b
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; rc=$?
assert_eq 10 "$rc" "torn journal with metadata==THIRD account -> unresolved, not rolled back (r4 #7)"
assert_contains '"accessToken":"B"' "$(kc_now)" "keychain NOT rolled back to A (metadata != source) (r4 #7)"
assert_file_present "$BANK_DIR/.swap-journal.json" "journal KEPT when metadata isn't the source (r4 #7)"

# ---- r4 #7 (unreadable-metadata variant): keychain==target B, journal a->b, but
#      metadata is unreadable/empty. active is unknown, not the source -> unresolved. ----
new_env rec_r47_nometa >/dev/null
printf '%s' "$blobB" | W "$STUB_KC_FILE"                        # keychain holds target B
printf '{}' | W "$CLAUDE_JSON"                                  # metadata unreadable (no oauthAccount)
write_journal "$blobA" b@x.com "$(fp_of "$blobB")" a@x.com
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; rc=$?
assert_eq 10 "$rc" "torn journal with UNREADABLE metadata -> unresolved, not rolled back (r4 #7)"
assert_contains '"accessToken":"B"' "$(kc_now)" "keychain NOT rolled back on unreadable metadata (r4 #7)"
assert_file_present "$BANK_DIR/.swap-journal.json" "journal KEPT on unreadable metadata (r4 #7)"

finish "reconcile"
