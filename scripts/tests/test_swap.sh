#!/bin/bash
# Fail-closed swap transaction (findings 7,8,9,10,12) + happy path + rollback.
# All against a stub keychain; the real login is never touched.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
SWAP="$AB_DIR/swap-account.sh"

# ---- happy path a->b ----
new_env swap_happy >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" pro claude_pro
/bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "happy swap exits 0"
# (v110) the liveness pre-flight ROTATES the parked target's token and commits it to
# the bank before the keychain write; the keychain must hold that POST-ROTATION
# credential, byte-consistent with the bank record. Asserting the literal pre-swap
# token "B" would assert that a SPENT token was committed.
b_at="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"])' "$BANK_DIR/b@x.com.json")"
assert_contains "\"accessToken\":\"$b_at\"" "$(kc_now)" "keychain holds b's post-verify credential (bank-consistent)"
assert_eq "b@x.com" "$(claude_json_email)" "claude.json now names b@x.com"
assert_file_present "$BANK_DIR/a@x.com.json" "outgoing a@x.com re-banked"
assert_file_absent "$BANK_DIR/.swap-journal.json" "journal cleared on clean commit"

# ---- (v112) a 2.1.235-shape live item: swap must pass the capture gate AND keep
#      this device's mcpOAuth instead of overwriting the item wholesale ----
new_env swap_235 >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
# graft mcpOAuth (with a space-delimited OAuth scope) onto the live stub item, exactly
# as CLI 2.1.235 does once an MCP server has been authorised
python3 - "$STUB_KC_FILE" <<'GRAFT'
import json, sys
p = sys.argv[1]
b = json.load(open(p))
b["claudeAiOauth"]["rateLimitTier"] = "default_claude_max_20x"
b["mcpOAuth"] = {"example-server|0123456789abcdef": {"scope": "read write offline_access",
                                               "accessToken": "MCP-AT"}}
json.dump(b, open(p, "w"), separators=(",", ":"))
GRAFT
assert_contains "mcpOAuth" "$(kc_now)" "the live item carries mcpOAuth before the swap"
bank_record b@x.com B "" "$FUT" pro claude_pro
/bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "(v112) swap succeeds against a 2.1.235-shape live item"
b_at="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"])' "$BANK_DIR/b@x.com.json")"
assert_contains "\"accessToken\":\"$b_at\"" "$(kc_now)" "(v112) the target's credential was installed"
assert_eq "read write offline_access" "$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("mcpOAuth") or {}).get("example-server|0123456789abcdef",{}).get("scope",""))' "$STUB_KC_FILE")" \
  "(v112) mcpOAuth SURVIVED the swap — MCP connector logins intact"
assert_eq "" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["claudeAiOauth"].get("rateLimitTier",""))' "$STUB_KC_FILE")" \
  "(v112) the outgoing account's claudeAiOauth was replaced, not blended"
assert_eq "b@x.com" "$(claude_json_email)" "(v112) claude.json now names b@x.com"
assert_file_absent "$BANK_DIR/.swap-journal.json" "(v112) journal cleared on clean commit"
# the bank must NEVER acquire mcpOAuth — that is what stops a stale copy being restored
assert_eq "" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("mcpOAuth",""))' "$BANK_DIR/a@x.com.json")" \
  "(v112) the re-banked outgoing record carries NO mcpOAuth"

# ---- finding 8: no valid preimage (keychain unreadable) -> abort, no change ----
new_env swap_nopre >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B
before="$(kc_now)"
STUB_KC_MODE=readfail /bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "swap aborts when the outgoing keychain read is empty (transient)"
assert_eq "$before" "$(kc_now)" "keychain unchanged when preimage capture failed"
assert_file_absent "$BANK_DIR/.swap-journal.json" "no journal left after preimage abort"

# ---- finding 7: outgoing re-bank fails -> abort before any keychain mutation ----
new_env swap_rebankfail >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B
mkdir -p "$BANK_DIR/a@x.com.json"        # make the outgoing re-bank target un-writable (a dir)
before="$(kc_now)"
/bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "swap aborts when outgoing re-bank fails (finding 7)"
assert_eq "$before" "$(kc_now)" "keychain unchanged when re-bank failed"

# ---- finding 9: swap journal cannot be created -> abort before kc_write ----
new_env swap_journalfail >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B
mkdir -p "$BANK_DIR/.swap-journal.json"  # journal path is a dir -> write fails
before="$(kc_now)"
/bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "swap aborts when the journal cannot be written (finding 9)"
assert_contains '"accessToken":"A"' "$(kc_now)" "keychain still A after journal-fail abort"

# ---- finding 10: indeterminate kc_write -> journal RETAINED, fail loud ----
new_env swap_indeterminate >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B
STUB_KC_MODE=writeignore /bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "indeterminate keychain write -> nonzero (finding 10)"
assert_contains '"accessToken":"A"' "$(kc_now)" "keychain unchanged (write didn't land)"
assert_file_present "$BANK_DIR/.swap-journal.json" "journal RETAINED after indeterminate write (never assume unchanged)"

# ---- metadata write fails -> keychain rolled back to pre-swap ----
new_env swap_rollback >/dev/null
rod="$BANK_DIR/../rod"; rm -rf "$rod" || _fixture_die "rm rod"; mkdir -p "$rod" || _fixture_die "mkdir rod"
# (r5 #5) checked fixture write: if this metadata write silently failed, the swap
# would abort early on missing identity and the rollback assertions below (68-70)
# would all pass VACUOUSLY without ever exercising rollback. W fails hard instead.
printf '{"oauthAccount":{"emailAddress":"a@x.com","organizationType":"claude_max"}}' | W "$rod/claude.json"
export CLAUDE_JSON="$rod/claude.json"
printf '{"claudeAiOauth":{"accessToken":"A","refreshToken":"rA","expiresAt":%s,"subscriptionType":"max"}}' "$FUT" | W "$STUB_KC_FILE"
bank_record b@x.com B
chmod 500 "$rod"                          # claude.json dir read-only -> metadata write fails
/bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
chmod 700 "$rod"
assert_ne 0 "$rc" "metadata-write failure -> swap nonzero"
assert_contains '"accessToken":"A"' "$(kc_now)" "keychain ROLLED BACK to A after metadata failure"
assert_file_absent "$BANK_DIR/.swap-journal.json" "journal cleared after successful rollback"

# ---- (v110) pre-flight: target confirmed DEAD -> abort, active untouched ----
# The zzazipyro class: a shared account's banked grant revoked by a co-user's
# /login while every offline field still reads fresh. The swap must discover this
# BEFORE the keychain write, mark needs-relogin, and leave the active login alone.
new_env swap_preflight_dead >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" pro claude_pro
before="$(kc_now)"
STUB_CLAUDE_MODE=authfail /bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "swap aborts when the target credential is confirmed dead (v110)"
assert_eq "$before" "$(kc_now)" "keychain untouched after dead-target abort"
assert_eq "a@x.com" "$(claude_json_email)" "active identity unchanged after dead-target abort"
assert_contains 'needs-relogin' "$(cat "$BANK_DIR/b@x.com.json")" "dead target marked needs-relogin"

# ---- (v110) pre-flight: TRANSIENT failure -> abort retriable, nothing marked dead ----
new_env swap_preflight_transient >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" pro claude_pro
before="$(kc_now)"
STUB_CLAUDE_MODE=forbidden /bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "swap aborts on transient verification failure (403 stays ambiguous)"
assert_eq "$before" "$(kc_now)" "keychain untouched after transient abort"
case "$(cat "$BANK_DIR/b@x.com.json")" in
  *needs-relogin*) fail "transient failure must NOT mark the target needs-relogin" ;;
  *) pass "transient failure leaves the target retriable (not marked dead)" ;;
esac

# ---- (v110) escape hatch: SKIP_TARGET_VERIFY commits the banked blob directly ----
new_env swap_preflight_skip >/dev/null
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" pro claude_pro
ACCOUNT_BANK_SKIP_TARGET_VERIFY=1 STUB_CLAUDE_MODE=authfail /bin/bash "$SWAP" b@x.com >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "skip-verify swap proceeds without the pre-flight"
assert_contains '"accessToken":"B"' "$(kc_now)" "skip-verify commits the banked blob verbatim"

finish "swap"
