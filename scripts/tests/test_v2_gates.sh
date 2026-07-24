#!/bin/bash
# v2 epoch behaviour for ping-account.sh. Fully isolated sandbox (temp bank + stub
# keychain/claude); never touches the real keychain or launches a real claude.
#
# (r9 #5) Under EPOCH v2 a ping is NO LONGER a keychain-refusal (rc 78) — it is a turn
# PINNED to the target's READY home (CLAUDE_CONFIG_DIR = the home). This asserts the v2
# home-ping path: resolves the target from the pointer, runs the (stubbed) claude with
# the home as CLAUDE_CONFIG_DIR, and errors cleanly when there is no pointer / no home.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
new_env v2gates >/dev/null

AB="$HERE/.."

# a valid active account: keychain blob + metadata + a bank record naming a@x.com
BLOB='{"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":9999999999999,"subscriptionType":"max"}}'
printf '%s' "$BLOB" > "$STUB_KC_FILE"
printf '{"oauthAccount":{"emailAddress":"a@x.com","organizationType":"claude_max"}}' > "$CLAUDE_JSON"
cat > "$BANK_DIR/a@x.com.json" <<JSON
{"email":"a@x.com","status":"ok","banked_at":"x","banked_at_epoch":1,"last_verified":"x",
 "last_ping":0,"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":9999999999999,"subscriptionType":"max"},
 "oauthAccount":{"emailAddress":"a@x.com","organizationType":"claude_max"}}
JSON

# EPOCH = v2, but NO READY home and NO pointer yet: the v2 ping must fail CLEANLY (there
# is nothing to ping), NOT run the v1 keychain path.
python3 -c "import sys; sys.path.insert(0,'$AB'); import epoch; epoch.write_epoch('$BANK_DIR','v2',3)"
out="$(ACCOUNT_BANK_PING_MODEL=haiku bash "$AB/ping-account.sh" --active 2>&1)"; rc=$?
assert_ne 0 "$rc" "ping --active under v2 with no pointer -> nonzero (v2 home-ping path)"
assert_contains "no current pointer" "$out" "ping surfaces the v2 no-pointer reason (not a keychain refusal)"

# Now seed a READY home for a@x.com + point at it. The v2 ping must PIN the home:
# CLAUDE_CONFIG_DIR = the home, so the stub claude (mode ok) rotates the HOME credential.
HOMEDIR="$BANK_DIR/homes/a-at-x.com"
mkdir -p "$HOMEDIR"
printf '%s' "$BLOB" > "$HOMEDIR/.credentials.json"
python3 - "$AB" "$BANK_DIR" "$HOMEDIR" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import registry, repoint
acc, home = sys.argv[2], sys.argv[3]
registry.publish_ready(acc, "a@x.com", home, "uuid-a")
repoint.repoint(acc, home, "test", registry_check=lambda h: registry.is_ready_home(acc, h))
PY
out="$(ACCOUNT_BANK_PING_MODEL=haiku bash "$AB/ping-account.sh" --active 2>&1)"; rc=$?
assert_eq 0 "$rc" "ping --active under v2 with a READY home + pointer -> success (v2 home ping)"
newtok="$(python3 -c "import json;print(json.load(open('$HOMEDIR/.credentials.json'))['claudeAiOauth']['accessToken'])")"
assert_contains "ROT-" "$newtok" "v2 ping pinned CLAUDE_CONFIG_DIR to the home (home credential rotated)"
assert_eq "AT" "$(python3 -c "import json;print(json.load(open('$STUB_KC_FILE'))['claudeAiOauth']['accessToken'])")" \
  "v2 ping NEVER touched the shared keychain (still AT)"

# (r11 #9) a SECOND consecutive ping must be SKIPPED by the 30-min success cooldown (the
# marker was written above) — not fire a second turn. Capture the home token before, assert
# unchanged after (no second rotation) and the skip message surfaced.
before2="$(python3 -c "import json;print(json.load(open('$HOMEDIR/.credentials.json'))['claudeAiOauth']['accessToken'])")"
out="$(ACCOUNT_BANK_PING_MODEL=haiku bash "$AB/ping-account.sh" --active 2>&1)"; rc=$?
assert_eq 0 "$rc" "second v2 ping -> exit 0 (cooldown skip, not an error)"
assert_contains "cooldown" "$out" "second v2 ping SKIPPED by the 30-min cooldown (r11 #9)"
assert_eq "$before2" "$(python3 -c "import json;print(json.load(open('$HOMEDIR/.credentials.json'))['claudeAiOauth']['accessToken'])")" \
  "second v2 ping did NOT fire a turn (home credential unchanged) (r11 #9)"

# a target with NO READY home under v2 -> clean error, never the v1 path
out="$(ACCOUNT_BANK_PING_MODEL=haiku bash "$AB/ping-account.sh" nobody@x.com 2>&1)"; rc=$?
assert_ne 0 "$rc" "ping <email> under v2 with no READY home -> nonzero"
assert_contains "no READY home" "$out" "ping surfaces the v2 no-home reason"

# (r12 sweep-c) the v2 ping STRIPS alt-auth env so the turn bills the HOME's OAuth, not an
# inherited ANTHROPIC_API_KEY. Recording stub + a fresh home (avoids the cooldown above).
REC="$BANK_DIR/apikey-seen"
STUB2="$BANK_DIR/recording-claude"
cat > "$STUB2" <<EOF
#!/bin/bash
printf '%s' "\${ANTHROPIC_API_KEY:-<unset>}" > "$REC"
exit 0
EOF
chmod +x "$STUB2"
HOMEDIR2="$BANK_DIR/homes/c-at-x.com"; mkdir -p "$HOMEDIR2"
printf '%s' "$BLOB" > "$HOMEDIR2/.credentials.json"
python3 - "$AB" "$BANK_DIR" "$HOMEDIR2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import registry, repoint
acc, home = sys.argv[2], sys.argv[3]
registry.publish_ready(acc, "c@x.com", home, "uuid-c")
repoint.repoint(acc, home, "t", registry_check=lambda h: registry.is_ready_home(acc, h))
PY
ANTHROPIC_API_KEY=SECRET ACCOUNT_BANK_CLAUDE_BIN="$STUB2" ACCOUNT_BANK_PING_MODEL=haiku bash "$AB/ping-account.sh" c@x.com >/dev/null 2>&1
assert_eq "<unset>" "$(cat "$REC" 2>/dev/null)" "v2 ping STRIPS ANTHROPIC_API_KEY (turn bills the home OAuth) (r12 sweep-c)"

# sanity: under shadow the v2 branch is NOT taken; the v1 active-ping path runs (the gate
# passes under shadow, so it proceeds to launch the stub claude — rc != 78).
python3 -c "import sys; sys.path.insert(0,'$AB'); import epoch; epoch.write_epoch('$BANK_DIR','shadow',4)"
out="$(ACCOUNT_BANK_PING_MODEL=haiku bash "$AB/ping-account.sh" --active 2>&1)"; rc=$?
assert_ne 78 "$rc" "ping-account --active NOT epoch-fenced under shadow (rc $rc)"

# (r13 #6) home pings run in SHADOW too: an EXPLICIT email with a READY home takes the home-ping
# path even under shadow (rev 9 §8: v2 home pings are shadow|v2). EPOCH is shadow here.
HOMEDIR3="$BANK_DIR/homes/d-at-x.com"; mkdir -p "$HOMEDIR3"
printf '%s' "$BLOB" > "$HOMEDIR3/.credentials.json"
python3 - "$AB" "$BANK_DIR" "$HOMEDIR3" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import registry
registry.publish_ready(sys.argv[2], "d@x.com", sys.argv[3], "uuid-d")
PY
out="$(ACCOUNT_BANK_PING_MODEL=haiku bash "$AB/ping-account.sh" d@x.com 2>&1)"; rc=$?
assert_eq 0 "$rc" "(r13 #6) ping <email-with-READY-home> under SHADOW -> home ping success"
newtok3="$(python3 -c "import json;print(json.load(open('$HOMEDIR3/.credentials.json'))['claudeAiOauth']['accessToken'])")"
assert_contains "ROT-" "$newtok3" "(r13 #6) shadow home ping rotated the HOME credential (v2 path, not 'not in the bank')"

finish "v2_gates"
