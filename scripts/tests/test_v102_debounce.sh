#!/bin/bash
# (v102) ITEM 2 — the SessionStart deferral line is announced ONCE per distinct drift.
#
# v101 made the hook defer every ambiguous drift to the oracle-gated poll heal and ANNOUNCE
# each deferral. That is right the first time and wrong every time after: until the poll heals
# it (or the owner re-banks) the state is unchanged, so the same paragraph printed at every
# single SessionStart — all day, on exactly the machines where QuotaBar is not running to do
# the healing.
#
# The debounce keys on the DRIFT, not on time, so nothing is ever silently swallowed:
#   * first sight of a drift announces;
#   * the identical drift is silent on every later session;
#   * a CHANGED drift (further rotation / different account / different refusal) announces;
#   * a healed or in-sync state clears the record, so the next real drift is news again.
# diag() still logs every deferral — the debounce hides the owner-facing line, not the log.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"

hook_out() { /bin/bash "$AB_DIR/account-warn.sh" 2>/dev/null; }

fresh_cache() {
  python3 - "$BANK_DIR/.usage-cache.json" "$1" <<'PY'
import json, sys
json.dump({"accounts": [{"provider": "claude", "email": sys.argv[2], "active": True,
                         "status": "ok",
                         "worst_limit": {"percent": 5, "kind": "five_hour",
                                         "resets_at": "2026-01-01T00:00:00Z"}}]},
          open(sys.argv[1], "w"))
PY
}

STATE=".drift-announce.json"

# ---------------------------------------------------------------------------
# first sight announces; the identical drift is silent afterwards
# ---------------------------------------------------------------------------
new_env v102_debounce_repeat >/dev/null
set_active a@x.com AT-B RT-B "$FUT" max claude_max     # a same-plan keychain-first /login
bank_record a@x.com AT-A RT-A "$FUT" max claude_max    # -> the hook must defer, not re-bank
fresh_cache a@x.com

out1="$(hook_out)"
assert_contains "deferred" "$out1" "first sight of a drift ANNOUNCES the deferral"
assert_file_present "$BANK_DIR/$STATE" "...and records what it announced"
assert_eq "600" "$(stat -f %Lp "$BANK_DIR/$STATE" 2>/dev/null)" \
  "the debounce record is 0600"

out2="$(hook_out)"
assert_eq "" "$out2" "the SAME drift on the next session is SILENT (no repeat paragraph)"
out3="$(hook_out)"
assert_eq "" "$out3" "...and stays silent on every session after that"

# the bank record is still untouched — the debounce suppresses the message, not the refusal
assert_eq "AT-A" "$(python3 -c '
import json,sys
print((json.load(open(sys.argv[1])).get("claudeAiOauth") or {}).get("accessToken",""))' \
  "$BANK_DIR/a@x.com.json")" \
  "silence did not turn into a re-bank — the record is still deferred, untouched"

# every deferral is still LOGGED, even the silent ones
assert_eq "3" "$(grep -c 'login-sync DEFERRED' "$BANK_DIR/.hook-failures.log" 2>/dev/null)" \
  "diag() logged ALL THREE deferrals — the debounce hides the line, never the log"

# ---------------------------------------------------------------------------
# a NEW drift fingerprint announces again
# ---------------------------------------------------------------------------
set_active a@x.com AT-C RT-C "$FUT" max claude_max     # the credential moved AGAIN
out4="$(hook_out)"
assert_contains "deferred" "$out4" "a DIFFERENT drift is a new fingerprint and announces"
out5="$(hook_out)"
assert_eq "" "$out5" "...and then debounces on its own fingerprint"

# a different ACCOUNT is also a different fingerprint
set_active z@x.com AT-C RT-C "$FUT" max claude_max
bank_record z@x.com AT-Z RT-Z "$FUT" max claude_max
fresh_cache z@x.com
out6="$(hook_out)"
assert_contains "deferred" "$out6" "the same credential under a DIFFERENT account announces"

# ---------------------------------------------------------------------------
# a plan change keeps its own announcement (v102 ITEM 1 heals it in the poll; the hook
# still has no oracle, so it still defers — and still says so, once)
# ---------------------------------------------------------------------------
new_env v102_debounce_plan >/dev/null
set_active a@x.com AT-1 RT-2 "$FUT" pro claude_pro
bank_record a@x.com AT-1 RT-1 "$FUT" max claude_max
fresh_cache a@x.com
out="$(hook_out)"
assert_contains "plan change detected (max -> pro)" "$out" \
  "a plan change announces with both tiers on first sight"
assert_eq "" "$(hook_out)" "...and is debounced like any other deferral"

# ---------------------------------------------------------------------------
# (v102-r2) CONSECUTIVE TIER CHANGES WITH UNCHANGED TOKENS.
# The fingerprint used to hash the two credential fingerprints and the refusal reason — none
# of which move when only the plan does (cred_fingerprint excludes subscriptionType by
# design). So max -> pro announced, and the pro -> free that followed hashed identically and
# was SUPPRESSED: the debounce silencing the exact class of news it exists to preserve.
# ---------------------------------------------------------------------------
new_env v102_debounce_tier_walk >/dev/null
bank_record a@x.com AT-1 RT-1 "$FUT" max claude_max
set_active a@x.com AT-1 RT-1 "$FUT" pro claude_pro      # SAME tokens, MAX -> PRO
fresh_cache a@x.com
assert_contains "plan change detected (max -> pro)" "$(hook_out)" \
  "an unchanged-token tier change announces"
assert_eq "" "$(hook_out)" "...and debounces on its own fingerprint"

set_active a@x.com AT-1 RT-1 "$FUT" free free           # SAME tokens again, PRO -> FREE
fresh_cache a@x.com
assert_contains "plan change detected (max -> free)" "$(hook_out)" \
  "a SECOND tier change with the same tokens is new news, not a repeat"
assert_eq "" "$(hook_out)" "...and then debounces on ITS fingerprint"

# a change WITHIN a tier is a different announcement too: the raw plan strings are part of the
# drift's identity, not just the normalized tier.
new_env v102_debounce_tier_variant >/dev/null
bank_record a@x.com AT-1 RT-1 "$FUT" max_5x claude_max
set_active a@x.com AT-1 RT-1 "$FUT" max_20x claude_max_20x
fresh_cache a@x.com
assert_contains "plan change detected (max_5x -> max_20x)" "$(hook_out)" \
  "a Max 5x -> Max 20x move announces (same tier, different plan)"
assert_eq "" "$(hook_out)" "...once"

# the ANNOUNCEMENT CLASS is part of the key: a credential drift and a plan change are
# different news even when every other input is the same.
new_env v102_debounce_class >/dev/null
bank_record a@x.com AT-A RT-A "$FUT" max claude_max
set_active a@x.com AT-B RT-B "$FUT" max claude_max      # credential drift, same plan
fresh_cache a@x.com
assert_contains "no longer matches its bank record" "$(hook_out)" \
  "a credential drift announces in the credential wording"
set_active a@x.com AT-B RT-B "$FUT" pro claude_pro      # now the plan moves too
fresh_cache a@x.com
assert_contains "plan change detected (max -> pro)" "$(hook_out)" \
  "the same credential drift, now ALSO a plan change, announces under the plan class"

# ---------------------------------------------------------------------------
# a HEALED state clears the record: the next real drift is news again
# ---------------------------------------------------------------------------
new_env v102_debounce_heal >/dev/null
set_active a@x.com AT-B RT-B "$FUT" max claude_max
bank_record a@x.com AT-A RT-A "$FUT" max claude_max
fresh_cache a@x.com
assert_contains "deferred" "$(hook_out)" "drift announced once"
assert_eq "" "$(hook_out)" "...then silent"

# the poll (or the owner) heals it: the keychain and the record agree again
bank_record a@x.com AT-B RT-B "$FUT" max claude_max
fresh_cache a@x.com
assert_eq "" "$(hook_out)" "an in-sync state says nothing"
assert_file_absent "$BANK_DIR/$STATE" \
  "...and CLEARS the debounce record (the state it was suppressing is gone)"

# the very same drift, returning after the heal, is news again
set_active a@x.com AT-D RT-D "$FUT" max claude_max
fresh_cache a@x.com
assert_contains "deferred" "$(hook_out)" \
  "a drift that returns after a heal ANNOUNCES again (post-heal reset)"

# ---------------------------------------------------------------------------
# a hook-side re-bank (the one drift it CAN prove offline) also clears the record
# ---------------------------------------------------------------------------
new_env v102_debounce_rebank >/dev/null
set_active a@x.com AT-B RT-B "$FUT" max claude_max
bank_record a@x.com AT-A RT-A "$FUT" max claude_max
fresh_cache a@x.com
assert_contains "deferred" "$(hook_out)" "an unprovable drift is deferred + announced"
# now the drift becomes the provable kind: same access token, rotated refresh token
set_active a@x.com AT-A RT-9 "$FUT" max claude_max
fresh_cache a@x.com
out="$(hook_out)"
assert_eq "" "$out" "a provable rotation re-banks silently (routine, not news)"
assert_file_absent "$BANK_DIR/$STATE" "...and clears the debounce record it had outstanding"

# ---------------------------------------------------------------------------
# fail OPEN: an unreadable debounce record must never be the reason the owner is not told
# ---------------------------------------------------------------------------
new_env v102_debounce_failopen >/dev/null
set_active a@x.com AT-B RT-B "$FUT" max claude_max
bank_record a@x.com AT-A RT-A "$FUT" max claude_max
fresh_cache a@x.com
printf 'not json at all' > "$BANK_DIR/$STATE"
assert_contains "deferred" "$(hook_out)" \
  "a corrupt debounce record announces (fail OPEN — silence is never the failure mode)"

# ---------------------------------------------------------------------------
# latency: the debounce adds file IO only, no subprocess, inside the 5s hook budget
# ---------------------------------------------------------------------------
python3 - "$AB_DIR/account-warn.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = src[src.index("def drift_already_announced"):src.index("def _security_bin")]
assert "subprocess" not in block and "urllib" not in block and "run_child" not in block, \
    "the debounce helpers must not spawn or call out — they run inside the 5s hook budget"
assert "DRIFTSTATE" in src and '.drift-announce.json' in src, "the state file is not wired"
assert re.search(r'DRIFTSTATE\s*=\s*os\.path\.join\(BANK,', src), \
    "the debounce state must live in the RESOLVED bank dir, not a second one"
PY
assert_eq 0 "$?" "the debounce path is pure file IO (no subprocess, no network)"

finish "v102_debounce"
