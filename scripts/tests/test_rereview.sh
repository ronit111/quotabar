#!/bin/bash
# Regression tests for the Codex re-review fixes (14 items). Temp sandbox + stubs
# only; the real keychain/account are never touched.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
REC="$AB_DIR/reconcile.py"
SWAP="$AB_DIR/swap-account.sh"
PING="$AB_DIR/ping-account.sh"
RM="$AB_DIR/remove-account.sh"
UNRESOLVED=".swap-unresolved"

# ---- r3 #1 / #20: ABA-safe reclaim — REAL reclamation semantics (positive-death
#      only). The old test only checked a fresh lock (age short-circuit) + a
#      dead-pid lock; it never exercised an OLD LIVE lock, an unreadable owner on a
#      live lock, or concurrent contenders. ----
new_env aba >/dev/null
source "$AB_DIR/lib.sh"
mkdir -p "$LOCK_DIR"
printf '%s %s %s\n' "$$" "tok" "$(_proc_starttime "$$")" > "$LOCK_DIR/owner"   # live (our pid), fresh mtime
if _lock_stale_and_dead; then fail "fresh live lock wrongly judged stale/dead"; else pass "fresh live lock is NOT reclaimable"; fi
# (a) OLD but LIVE lock (our pid, aged mtime) must NOT be reclaimed
touch -t 200001010000 "$LOCK_DIR"
if _lock_stale_and_dead; then fail "OLD LIVE lock wrongly reclaimable (r3 #1)"; else pass "OLD LIVE lock is NOT reclaimable (r3 #1)"; fi
# (b) OLD live lock whose OWNER RECORD is present but UNREADABLE = UNKNOWN, NOT dead
printf 'garbage-not-a-pid\n' > "$LOCK_DIR/owner"; touch -t 200001010000 "$LOCK_DIR"
if _lock_stale_and_dead; then fail "old live lock w/ unreadable owner wrongly reclaimable (r3 #1)"; else pass "unreadable owner on an old lock is UNKNOWN, NOT reclaimable (r3 #1)"; fi
# (b2) (v101-confirm) an ABSENT owner record is a DIFFERENT state from an unreadable one: it
# is an acquisition killed between its mkdir and its owner publication, and refusing it
# forever wedged the lock permanently (no owner can ever be proven dead). Past the bounded
# grace it IS reclaimable; inside the grace it is not, because it may still be in flight.
rm -f "$LOCK_DIR/owner"; touch "$LOCK_DIR"
if _lock_stale_and_dead; then fail "a FRESH ownerless lock must not be reclaimable (v101-confirm)"; else pass "a FRESH ownerless lock is NOT reclaimable — acquisition may be in flight (v101-confirm)"; fi
touch -t 200001010000 "$LOCK_DIR"
if _lock_stale_and_dead; then pass "an ownerless lock PAST the grace IS reclaimable (v101-confirm)"; else fail "ownerless lock past the grace still wedged (v101-confirm)"; fi
rm -rf "$LOCK_DIR"
# (c) a genuinely OLD + DEAD lock (dead pid, aged) IS reclaimable
mkdir -p "$LOCK_DIR"
printf '%s %s %s\n' 999999 "tok" "Sat Jan  1 00:00:00 2000" > "$LOCK_DIR/owner"
touch -t 200001010000 "$LOCK_DIR"
if _lock_stale_and_dead; then pass "old+dead lock IS reclaimable"; else fail "old+dead lock not recognized"; fi
rm -rf "$LOCK_DIR"
# (d) dead-holder reclaim under TWO concurrent contenders: EXACTLY one wins the lock
new_env aba_race >/dev/null
mkdir -p "$LOCK_DIR"
printf '%s %s %s\n' 999999 "tok" "Sat Jan  1 00:00:00 2000" > "$LOCK_DIR/owner"
touch -t 200001010000 "$LOCK_DIR"
res="$BANK_DIR/.race.$$"; : > "$res"
_contender() { ( source "$AB_DIR/lib.sh"
  if acquire_lock 3; then echo win >> "$res"; sleep 4; release_lock; else echo lose >> "$res"; fi ) ; }
_contender & p1=$!
_contender & p2=$!
# give them a moment to both be inside acquire; then sample who holds the lock
sleep 1
wins_at_peak="$(grep -c '^win$' "$res" 2>/dev/null | tr -d ' ')"
wait "$p1" "$p2" 2>/dev/null
assert_eq 1 "${wins_at_peak:-0}" "exactly ONE contender reclaims the old+dead lock at a time (r3 #20)"

# ---- issue 3: durable unresolved marker blocks even after the journal is gone ----
new_env durable >/dev/null
printf 'A' | W "$STUB_KC_FILE"; printf '{"oauthAccount":{"emailAddress":"a@x.com"}}' | W "$CLAUDE_JSON"
printf 'not json' | W "$BANK_DIR/.swap-journal.json"
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; assert_eq 10 "$?" "unparseable journal -> exit 10"
assert_file_present "$BANK_DIR/$UNRESOLVED" "durable unresolved marker written (issue 3)"
assert_file_absent "$BANK_DIR/.swap-journal.json" "original journal removed (quarantined copy kept)"
# next run: no journal, but the marker still blocks
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; assert_eq 10 "$?" "marker still blocks on the NEXT run (no journal present)"
# a swap must refuse while the marker exists
bank_record b@x.com B
before="$(kc_now)"; /bin/bash "$SWAP" b@x.com >/dev/null 2>&1; assert_ne 0 "$?" "swap blocked by durable marker"
assert_eq "$before" "$(kc_now)" "keychain untouched while marker blocks"
# clearing the marker unblocks
rm -f "$BANK_DIR/$UNRESOLVED"
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1; assert_eq 0 "$?" "cleared marker -> reconcile clean again"

# ---- issue 2: ping passes HOLDS_LOCK to reconcile (no self-contention) ----
# with a durable marker present, ping must REFUSE (reconcile exit 10 seen), proving
# ping actually gets the reconcile result rather than success-on-contention.
new_env pingblock >/dev/null
set_active a@x.com A
bank_record a@x.com A "" "$FUT" max claude_max
printf 'x' | W "$BANK_DIR/$UNRESOLVED"
/bin/bash "$PING" a@x.com >/dev/null 2>&1; assert_ne 0 "$?" "ping refuses while unresolved marker present (issue 2/3)"

# ---- issue 4: forged refresh journal with traversal email is rejected ----
new_env traversal >/dev/null
printf 'A' | W "$STUB_KC_FILE"; printf '{"oauthAccount":{"emailAddress":"a@x.com"}}' | W "$CLAUDE_JSON"
canary="$BANK_DIR/../CANARY_SHOULD_NOT_APPEAR"; rm -f "$canary"
python3 - "$BANK_DIR" <<'PY'
import json, os, sys
bank = sys.argv[1]
# a safe-looking journal filename, but the email INSIDE points outside BANK_DIR
p = os.path.join(bank, ".refresh-journal-evil.json")
json.dump({"email": "../CANARY_SHOULD_NOT_APPEAR", "claudeAiOauth":
           {"accessToken":"a","refreshToken":"r","expiresAt": 9999999999999}, "ts": 1}, open(p,"w"))
PY
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$REC" >/dev/null 2>&1
assert_file_absent "$canary" "forged traversal journal did NOT write outside BANK_DIR (issue 4)"
ls "$BANK_DIR"/.refresh-journal-evil.json.corrupt.* >/dev/null 2>&1
assert_eq 0 "$?" "forged journal quarantined, not acted on"

# ---- issue 9: a rotation that lands but the turn exits nonzero is COMMITTED ----
new_env rotcommit >/dev/null
set_active a@x.com A "" "$FUT" max claude_max          # active is someone else
bank_record parked@x.com OLDTOKEN OLDREFRESH "$PAST" pro claude_pro   # expired parked token
export ACCOUNT_BANK_HOLDS_LOCK=1
STUB_CLAUDE_MODE=rotate_fail python3 "$AB_DIR/isolated_refresh.py" "$BANK_DIR/parked@x.com.json" >/dev/null 2>&1; rc=$?
unset ACCOUNT_BANK_HOLDS_LOCK
assert_eq 5 "$rc" "rotation+nonzero turn -> exit 5 (window not confirmed)"
newtok="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"])' "$BANK_DIR/parked@x.com.json")"
case "$newtok" in ROT-*) pass "rotated credential was COMMITTED despite nonzero turn (issue 9)";; *) fail "rotated token discarded (got $newtok)";; esac

# ---- issue 13: swap refuses to run with ACCOUNT_BANK_BOOTSTRAP=1 ----
new_env bootstrap >/dev/null
set_active a@x.com A; bank_record b@x.com B
ACCOUNT_BANK_BOOTSTRAP=1 /bin/bash "$SWAP" b@x.com >/dev/null 2>&1; assert_eq 2 "$?" "swap refuses BOOTSTRAP=1 (issue 13)"

# ---- issue 11: remove refuses when the live keychain already holds target's creds ----
new_env removefp >/dev/null
# active metadata says a@x.com, but the keychain already holds b's banked creds
# (a /login installed b's keychain item before ~/.claude.json updated).
bank_record b@x.com BTOKEN BREFRESH "$FUT" pro claude_pro
printf '{"claudeAiOauth":{"accessToken":"BTOKEN","refreshToken":"BREFRESH","expiresAt":%s,"subscriptionType":"pro"}}' "$FUT" | W "$STUB_KC_FILE"
printf '{"oauthAccount":{"emailAddress":"a@x.com"}}' | W "$CLAUDE_JSON"
/bin/bash "$RM" b@x.com >/dev/null 2>&1; assert_ne 0 "$?" "remove refuses: keychain holds target's creds (becoming active, issue 11)"
assert_file_present "$BANK_DIR/b@x.com.json" "target record preserved"

# ---- issue 10: write_bank_record refuses an INVALID existing record (no reset-to-{}) ----
new_env writerec >/dev/null
printf '{"oauthAccount":{"emailAddress":"w@x.com"}}' | W "$CLAUDE_JSON"
blob='{"claudeAiOauth":{"accessToken":"A","refreshToken":"rA","expiresAt":9999999999999}}'
printf '{ corrupt existing record with a "accessToken":"OLDSECRET"' | W "$BANK_DIR/w@x.com.json"
printf '%s' "$blob" | python3 "$AB_DIR/write_bank_record.py" "$CLAUDE_JSON" w@x.com "$BANK_DIR/w@x.com.json" iso 1 >/dev/null 2>&1
assert_eq 3 "$?" "write_bank_record REFUSES an invalid existing record (issue 10)"
assert_contains "corrupt existing record" "$(cat "$BANK_DIR/w@x.com.json")" "corrupt record left intact (not reset to {})"
# FORCE_REBANK recovers over it (verified-live creds)
printf '%s' "$blob" | ACCOUNT_BANK_FORCE_REBANK=1 python3 "$AB_DIR/write_bank_record.py" "$CLAUDE_JSON" w@x.com "$BANK_DIR/w@x.com.json" iso 1 >/dev/null 2>&1
assert_eq 0 "$?" "FORCE_REBANK overwrites a corrupt record with verified creds"
assert_contains '"accessToken": "A"' "$(cat "$BANK_DIR/w@x.com.json")" "record recovered to the fresh credential"

# ---- issue 11: write_bank_record refuses on an expected-fingerprint mismatch ----
new_env wrec_fp >/dev/null
printf '{"oauthAccount":{"emailAddress":"w@x.com"}}' | W "$CLAUDE_JSON"
printf '%s' "$blob" | python3 "$AB_DIR/write_bank_record.py" "$CLAUDE_JSON" w@x.com "$BANK_DIR/w@x.com.json" iso 1 "deadbeef-wrong-fp" >/dev/null 2>&1
assert_eq 2 "$?" "write_bank_record refuses when blob != caller's captured fingerprint (issue 11)"

# ---- r3 #13: non-finite expiresAt (NaN/Infinity) is rejected everywhere ----
new_env nonfinite >/dev/null
printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":Infinity}}' \
  | python3 "$AB_DIR/validate_blob.py" >/dev/null 2>&1; assert_ne 0 "$?" "validate_blob rejects Infinity expiresAt (r3 #13)"
printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":NaN}}' \
  | python3 "$AB_DIR/validate_blob.py" >/dev/null 2>&1; assert_ne 0 "$?" "validate_blob rejects NaN expiresAt (r3 #13)"

# ---- r3 #2: write_bank_record refuses a PLAN-inconsistent (crossed-identity) write ----
new_env plan_mismatch >/dev/null
printf '{"oauthAccount":{"emailAddress":"p@x.com","organizationType":"claude_max"}}' | W "$CLAUDE_JSON"
printf '{"claudeAiOauth":{"accessToken":"A","refreshToken":"rA","expiresAt":9999999999999,"subscriptionType":"pro"}}' \
  | python3 "$AB_DIR/write_bank_record.py" "$CLAUDE_JSON" p@x.com "$BANK_DIR/p@x.com.json" iso 1 >/dev/null 2>&1
assert_eq 2 "$?" "write_bank_record refuses a plan-inconsistent write (crossed identity, r3 #2)"
assert_file_absent "$BANK_DIR/p@x.com.json" "no record written on plan mismatch (r3 #2)"

# ---- r3 #3: swap aborts when the live keychain has creds but NO active email ----
new_env swap_noemail >/dev/null
printf '{"claudeAiOauth":{"accessToken":"L","refreshToken":"rL","expiresAt":%s,"subscriptionType":"max"}}' "$FUT" | W "$STUB_KC_FILE"
printf '{}' | W "$CLAUDE_JSON"                    # no oauthAccount.emailAddress
bank_record t@x.com T
before="$(kc_now)"; /bin/bash "$SWAP" t@x.com >/dev/null 2>&1; assert_ne 0 "$?" "swap aborts: live creds but no active identity (r3 #3)"
assert_eq "$before" "$(kc_now)" "keychain untouched on unidentifiable-current abort (r3 #3)"

# ---- r3 #17: already-active no-op reports FAILURE honestly if the re-bank fails ----
# keychain plan (pro) disagrees with metadata org (claude_max) -> the no-op re-bank
# hits the r3 #2 refusal, so the no-op must report failure, not "refreshed".
new_env noop_rebankfail >/dev/null
printf '{"claudeAiOauth":{"accessToken":"S","refreshToken":"rS","expiresAt":%s,"subscriptionType":"pro"}}' "$FUT" | W "$STUB_KC_FILE"
printf '{"oauthAccount":{"emailAddress":"s@x.com","organizationType":"claude_max"}}' | W "$CLAUDE_JSON"
bank_record s@x.com S "" "$FUT" max claude_max
/bin/bash "$SWAP" s@x.com >/dev/null 2>&1; assert_ne 0 "$?" "already-active no-op reports failure when bank refresh fails (r3 #17)"

# ---- r3 #18: active ping does NOT stamp when the live credential changes mid-turn ----
new_env ping_fpchange >/dev/null
set_active f@x.com F "" "$FUT" max claude_max
bank_record f@x.com F "" "$FUT" max claude_max
STUB_CLAUDE_MODE=mutate_kc /bin/bash "$PING" f@x.com >/dev/null 2>&1; assert_ne 0 "$?" "active ping aborts when the billed credential changes mid-turn (r3 #18)"
lp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("last_ping",0))' "$BANK_DIR/f@x.com.json" 2>/dev/null)"
assert_eq 0 "$lp" "no success cooldown stamped when the billed credential changed (r3 #18)"

# ---- r4 #8: keychain-first /login STATE (not mutation): the keychain already holds
#      account B's credential while metadata still names A, STABLE across reads. The
#      turn would bill B, but the pre-fix code (fingerprint stability only) stamped
#      A's cooldown. The live fingerprint must be BOUND to identity: it matches the
#      BANKED credential of b@x.com (a different account) -> abort, no stamp. ----
new_env ping_kcfirst >/dev/null
# keychain holds B's credential; metadata still names a@x.com (the lagging store)
printf '{"claudeAiOauth":{"accessToken":"BB","refreshToken":"rBB","expiresAt":%s,"subscriptionType":"max"}}' "$FUT" | W "$STUB_KC_FILE"
printf '{"oauthAccount":{"emailAddress":"a@x.com","organizationType":"claude_max"}}' | W "$CLAUDE_JSON"
bank_record a@x.com AA rAA "$FUT" max claude_max        # target A: banked cred != live keychain
bank_record b@x.com BB rBB "$FUT" max claude_max        # B: banked cred == the LIVE keychain cred
/bin/bash "$PING" --active >/dev/null 2>&1; assert_ne 0 "$?" "active ping aborts when the live keychain belongs to a DIFFERENT banked account (r4 #8)"
lp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("last_ping",0))' "$BANK_DIR/a@x.com.json" 2>/dev/null)"
assert_eq 0 "$lp" "no cooldown stamped on a@x.com during a keychain-first /login state (r4 #8)"

# ---- r5 #4 (SUPERSEDES the r4 #8 "benign drift pings OK" behavior): the active
#      account's OWN token rotated ahead of its bank record, so the live fingerprint
#      matches NO current bank record. r4 allowed this ping (fail-OPEN on drift);
#      finding #4 proved that gap is offline-indistinguishable from a keychain-first
#      /login installing an UNBANKED account, so the single resolver now FAILS CLOSED:
#      an UNRESOLVED identity aborts with no bill/stamp. The operator re-banks to
#      re-sync. (This assertion is the INVERSE of the retired r4 behavior; on r4 code
#      the ping returned 0 and stamped.) ----
new_env ping_drift >/dev/null
printf '{"claudeAiOauth":{"accessToken":"DRIFTED","refreshToken":"rDRIFT","expiresAt":%s,"subscriptionType":"max"}}' "$FUT" | W "$STUB_KC_FILE"
printf '{"oauthAccount":{"emailAddress":"d@x.com","organizationType":"claude_max"}}' | W "$CLAUDE_JSON"
bank_record d@x.com OLDER rOLDER "$FUT" max claude_max  # banked cred is the pre-rotation one (drift)
STUB_CLAUDE_MODE=norotate /bin/bash "$PING" --active >/dev/null 2>&1; assert_ne 0 "$?" "active ping aborts on UNRESOLVED self-drift (own token ahead of bank) — fail-closed (r5 #4)"
lp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("last_ping",0))' "$BANK_DIR/d@x.com.json" 2>/dev/null)"
assert_eq 0 "$lp" "no cooldown stamped on an unresolved self-drift (r5 #4)"

# ---- r5 #4 (positive bind still pings): keychain == the account's CURRENT bank
#      record AND metadata names it -> RESOLVED -> ping proceeds and stamps. Proves
#      the resolver is not blanket-refusing; it permits the fully-consistent state. ----
new_env ping_resolved >/dev/null
printf '{"claudeAiOauth":{"accessToken":"SS","refreshToken":"rSS","expiresAt":%s,"subscriptionType":"max"}}' "$FUT" | W "$STUB_KC_FILE"
printf '{"oauthAccount":{"emailAddress":"s@x.com","organizationType":"claude_max"}}' | W "$CLAUDE_JSON"
bank_record s@x.com SS rSS "$FUT" max claude_max        # banked cred == the LIVE keychain cred
STUB_CLAUDE_MODE=norotate /bin/bash "$PING" --active >/dev/null 2>&1; assert_eq 0 "$?" "active ping proceeds when identity RESOLVES to the target (r5 #4)"
lp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("last_ping",0))' "$BANK_DIR/s@x.com.json" 2>/dev/null)"
assert_ne 0 "$lp" "cooldown stamped on a cleanly-resolved active ping (r5 #4)"

finish "rereview"
