#!/bin/bash
# test_v112_blob_schema.sh — CLI 2.1.235 turned the credential keychain item into a
# shared container: `mcpOAuth` (MCP connector OAuth tokens) now sits beside
# `claudeAiOauth`, and `claudeAiOauth` gained `rateLimitTier`.
#
# Two consequences, both covered here:
#   1. An OAuth `scope` is space-delimited by specification, so the live blob contains a
#      space inside a STRING VALUE. validate_blob's old character scan rejected that as
#      "not compact", which is what aborted every swap at the capture gate.
#   2. The bank holds only `claudeAiOauth`, so installing a banked blob wholesale would
#      drop mcpOAuth and log the owner out of every MCP connector on every swap.
#
# The fixture below is the real 2.1.235 SHAPE (synthetic values — no real token material
# appears in this repo).
source "$(dirname "${BASH_SOURCE[0]}")/testlib.sh"

VALIDATE="$AB_DIR/validate_blob.py"
BC="$AB_DIR/bank_common.py"

# the 2.1.235 shape: extra top-level key, extra field inside claudeAiOauth, and a
# space-bearing scope string inside mcpOAuth
B235='{"claudeAiOauth":{"accessToken":"AT-235","refreshToken":"RT-235","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{"example-server|0123456789abcdef":{"scope":"read write offline_access","accessToken":"MCP-AT"}}}'
B_PLAIN='{"claudeAiOauth":{"accessToken":"AT-1","refreshToken":"RT-1","expiresAt":4102444800000}}'

new_env v112 >/dev/null

# ---------------------------------------------------------------------------
# 1. validate_blob accepts the new shape
# ---------------------------------------------------------------------------
printf '%s' "$B235" | python3 "$VALIDATE" >/dev/null 2>&1
assert_eq "0" "$?" "the 2.1.235 blob (mcpOAuth + rateLimitTier + spaced scope) VALIDATES"

printf '%s' "$B_PLAIN" | python3 "$VALIDATE" >/dev/null 2>&1
assert_eq "0" "$?" "an ordinary space-free blob still validates"

# unknown keys are tolerated in both positions — this is schema EVOLUTION, not laxity
printf '%s' '{"claudeAiOauth":{"accessToken":"A","refreshToken":"R","expiresAt":1,"futureField":{"x":1}},"someFutureTopLevel":{"a":"b c"}}' \
  | python3 "$VALIDATE" >/dev/null 2>&1
assert_eq "0" "$?" "unknown top-level keys AND unknown claudeAiOauth fields are tolerated"

# ...but the parts we depend on are still enforced, exactly as before
printf '%s' '{"claudeAiOauth":{"accessToken":"","refreshToken":"R","expiresAt":1}}' | python3 "$VALIDATE" >/dev/null 2>&1
assert_ne "0" "$?" "an empty accessToken is still rejected"
printf '%s' '{"claudeAiOauth":{"accessToken":"A","refreshToken":"R","expiresAt":true}}' | python3 "$VALIDATE" >/dev/null 2>&1
assert_ne "0" "$?" "a boolean expiresAt is still rejected"
printf '%s' '{"mcpOAuth":{"s":{"scope":"a b"}}}' | python3 "$VALIDATE" >/dev/null 2>&1
assert_ne "0" "$?" "a blob with mcpOAuth but NO credential is still rejected"

# formatting whitespace — the thing the check is actually for — is still caught
printf '%s' '{"claudeAiOauth": {"accessToken": "A", "refreshToken": "R", "expiresAt": 1}}' \
  | python3 "$VALIDATE" >/dev/null 2>&1
assert_ne "0" "$?" "pretty-printed JSON is still rejected (kc_write needs one token)"
printf '%s\n%s' '{"claudeAiOauth":{"accessToken":"A","refreshToken":"R",' '"expiresAt":1}}' \
  | python3 "$VALIDATE" >/dev/null 2>&1
assert_ne "0" "$?" "an embedded newline between tokens is still rejected"

# a space inside a KEY is content too (mcpOAuth server ids are arbitrary strings)
printf '%s' '{"claudeAiOauth":{"accessToken":"A","refreshToken":"R","expiresAt":1},"mcpOAuth":{"my server|x":{}}}' \
  | python3 "$VALIDATE" >/dev/null 2>&1
assert_eq "0" "$?" "a space inside a string KEY is content, not formatting"

# ---------------------------------------------------------------------------
# 2. compact_blob is not the fix and never could be
# ---------------------------------------------------------------------------
compacted="$(printf '%s' "$B235" | bash -c "source '$AB_DIR/lib.sh'; compact_blob")"
spaces_before="$(printf '%s' "$B235" | tr -cd ' ' | wc -c | tr -d ' ')"
spaces_after="$(printf '%s' "$compacted" | tr -cd ' ' | wc -c | tr -d ' ')"
assert_eq "$spaces_before" "$spaces_after" "compact_blob cannot remove spaces inside string values"
assert_ne "0" "$spaces_after" "the fixture really does carry in-string spaces"

# ---------------------------------------------------------------------------
# 3. the merge: target's credential, device's everything else
# ---------------------------------------------------------------------------
TB="$BANK_DIR/../target.json"
printf '%s' '{"claudeAiOauth":{"accessToken":"TARGET-AT","refreshToken":"TARGET-RT","expiresAt":4102444800000}}' > "$TB"
merged="$(printf '%s' "$B235" | python3 "$BC" --merge-device-state "$TB")"; mrc=$?
assert_eq "0" "$mrc" "merge succeeds against a live 2.1.235 blob"
assert_eq "TARGET-AT" "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['claudeAiOauth']['accessToken'])" "$merged")" \
  "the TARGET's credential is what gets installed"
assert_eq "read write offline_access" "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['mcpOAuth']['example-server|0123456789abcdef']['scope'])" "$merged")" \
  "mcpOAuth SURVIVES the swap — MCP connector logins are not destroyed"
assert_eq "" "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['claudeAiOauth'].get('rateLimitTier',''))" "$merged")" \
  "the OUTGOING account's claudeAiOauth is fully replaced, not blended"
printf '%s' "$merged" | python3 "$VALIDATE" >/dev/null 2>&1
assert_eq "0" "$?" "the merged blob validates (it is what kc_write will be handed)"

# a STALE banked mcpOAuth can never be written over a live one: the target side
# contributes only claudeAiOauth, whatever else it happens to carry
printf '%s' '{"claudeAiOauth":{"accessToken":"TARGET-AT","refreshToken":"TARGET-RT","expiresAt":4102444800000},"mcpOAuth":{"stale|999":{"scope":"STALE","accessToken":"STALE-MCP"}}}' > "$TB"
merged2="$(printf '%s' "$B235" | python3 "$BC" --merge-device-state "$TB")"
assert_eq "" "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['mcpOAuth'].get('stale|999',''))" "$merged2")" \
  "a stale mcpOAuth on the target side is NEVER installed"
assert_eq "read write offline_access" "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['mcpOAuth']['example-server|0123456789abcdef']['scope'])" "$merged2")" \
  "the LIVE device state wins over anything the target carried"

# future unknown top-level keys are device state too — dropping one is silent data loss
merged3="$(printf '%s' '{"claudeAiOauth":{"accessToken":"L","refreshToken":"L","expiresAt":1},"someFutureKey":{"k":"v w"}}' | python3 "$BC" --merge-device-state "$TB")"
assert_eq "v w" "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['someFutureKey']['k'])" "$merged3")" \
  "an unrecognised top-level key is preserved, not dropped"

# and with no live blob at all (first swap into an empty item) the target stands alone
merged4="$(printf '%s' '' | python3 "$BC" --merge-device-state "$TB")"
assert_eq "TARGET-AT" "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['claudeAiOauth']['accessToken'])" "$merged4")" \
  "an empty live item yields the target's credential alone"

# a target blob with no credential is refused rather than silently installing nothing
printf '%s' '{"mcpOAuth":{}}' > "$TB"
printf '%s' "$B235" | python3 "$BC" --merge-device-state "$TB" >/dev/null 2>&1
assert_ne "0" "$?" "a target blob with no claudeAiOauth is refused"

# ---------------------------------------------------------------------------
# 4. the round trip through the real write encoding (fake keychain, no real item)
# ---------------------------------------------------------------------------
# kc_write escapes the blob for `security -i`; prove a space-bearing blob survives the
# escape/unescape round trip the shell performs.
esc="$(printf '%s' "$B235" | python3 -c 'import sys; s=sys.stdin.read(); sys.stdout.write(s.replace(chr(92), chr(92)*2).replace(chr(34), chr(92)+chr(34)))')"
back="$(printf '%s' "$esc" | python3 -c 'import sys; s=sys.stdin.read(); sys.stdout.write(s.replace(chr(92)+chr(34), chr(34)).replace(chr(92)*2, chr(92)))')"
assert_eq "$B235" "$back" "the kc_write escape round-trips the 2.1.235 blob exactly"

# ---------------------------------------------------------------------------
# 5. a blanked credential is still 'absent' even when mcpOAuth is populated
#    (v109's breaker must not read "the item has data" as "there is a login")
# ---------------------------------------------------------------------------
blanked='{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0},"mcpOAuth":{"srv|1":{"scope":"a b","accessToken":"MCP"}}}'
verdict="$(printf '%s' "$blanked" | python3 -c "
import json, sys
b = json.load(sys.stdin)
o = b.get('claudeAiOauth') or {}
blank = not str(o.get('accessToken') or '').strip() and not str(o.get('refreshToken') or '').strip()
print('absent' if blank else 'present')")"
assert_eq "absent" "$verdict" "a blanked credential reads ABSENT even with mcpOAuth populated"
printf '%s' "$blanked" | python3 "$VALIDATE" >/dev/null 2>&1
assert_ne "0" "$?" "a blanked credential is not a valid blob however much else the item holds"

# ---------------------------------------------------------------------------
# 6. reconcile carries the SAME gate — a torn swap must stay recoverable
#
# The swap journal stores the full pre-swap blob, which now includes mcpOAuth. reconcile
# had its own copy of the character scan, so under 2.1.235 it would have REFUSED to
# restore that blob: a torn swap would have become permanently unrecoverable, which is
# the exact failure the journal exists to prevent.
# ---------------------------------------------------------------------------
verdict="$(python3 -c "
import sys; sys.path.insert(0, '$AB_DIR')
import reconcile
print('reject' if reconcile._formatting_whitespace(sys.argv[1]) else 'accept')" "$B235")"
assert_eq "accept" "$verdict" "reconcile accepts a journalled 2.1.235 blob (torn swaps stay recoverable)"

verdict="$(python3 -c "
import sys; sys.path.insert(0, '$AB_DIR')
import reconcile
print('reject' if reconcile._formatting_whitespace(sys.argv[1]) else 'accept')" '{"claudeAiOauth": {"accessToken": "A"}}')"
assert_eq "reject" "$verdict" "reconcile still rejects pretty-printed JSON"

# and its write encoding matches kc_write's, or a restore would land corrupted
enc="$(python3 -c "
import sys; sys.path.insert(0, '$AB_DIR')
b = sys.argv[1]
print(b.replace(chr(92), chr(92)*2).replace(chr(34), chr(92)+chr(34)))" "$B235")"
assert_eq "$esc" "$enc" "reconcile escapes the blob identically to kc_write"

# ---------------------------------------------------------------------------
# 7. the failure is SELF-IDENTIFYING next time (Ronit's addendum)
#
# Tonight's abort said "transient keychain read failure" while the read had in fact
# succeeded — the blob was present, parsed, and carried a claudeAiOauth; only a shape
# rule refused it. Those two causes have opposite fixes (retry vs "the schema moved"),
# so the classifier that tells them apart is itself worth a test.
# ---------------------------------------------------------------------------
cls() { printf '%s' "$1" | bash -c "source '$AB_DIR/lib.sh'; blob_reject_reason"; }
assert_eq "schema" "$(cls "$B235")" "a readable blob carrying claudeAiOauth => SCHEMA drift"
assert_eq "schema" "$(cls '{"claudeAiOauth":{"accessToken":""}}')" "a readable-but-invalid credential => SCHEMA drift"
assert_eq "unreadable" "$(cls '')" "an empty read => transient, not schema"
assert_eq "unreadable" "$(cls 'not json at all')" "unparseable bytes => transient, not schema"
assert_eq "unreadable" "$(cls '{"mcpOAuth":{}}')" "JSON without a credential key => transient, not schema"

# and the swap capture gate emits the distinct wording. Reproduce tonight's failure by
# giving the gate a validate_blob that rejects everything: the blob is perfectly
# readable, so the abort must name a SCHEMA change and must not say "transient".
scratch="$BANK_DIR/../scratch-ab"; rm -rf "$scratch"; mkdir -p "$scratch"
cp "$AB_DIR"/*.sh "$AB_DIR"/*.py "$scratch"/ 2>/dev/null
printf '#!/usr/bin/env python3\nimport sys\nsys.stdin.read()\nsys.stderr.write("blob invalid: forced\\n")\nsys.exit(1)\n' > "$scratch/validate_blob.py"
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" pro claude_pro
out="$(/bin/bash "$scratch/swap-account.sh" b@x.com 2>&1)"; rc=$?
assert_ne "0" "$rc" "the gate still aborts when validation refuses the blob"
assert_contains "credential blob shape not recognized" "$out" "the abort names the SCHEMA cause distinctly"
assert_contains "CLI schema may have changed" "$out" "the abort points at the CLI, not at a retry"
assert_contains "This is not a retry" "$out" "the abort says plainly that re-running will not help"
case "$out" in *"transient keychain read failure"*) fail "the abort must NOT claim a transient read failure";; *) pass "the misleading 'transient' wording is gone";; esac
rm -rf "$scratch"

finish "v112_blob_schema"
