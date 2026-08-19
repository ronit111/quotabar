#!/bin/bash
# test_relogin.sh — the guided re-login recovery flow (relogin-account.sh +
# relogin_capture.py + the Re-bank routing in bank-account.sh + the revocation
# notification).
#
# HERMETIC: no test opens a Terminal, performs a login, calls api.anthropic.com, or
# touches the real keychain. Three seams do that work, each the existing house pattern:
#   ACCOUNT_BANK_RELOGIN_TERMINAL_CMD  stands in for the Terminal-open (it is handed the
#                                      launcher path + config dir and plays "the owner
#                                      completed the login" by writing a seat).
#   ACCOUNT_BANK_FAKE_PROFILE          stands in for the G9 identity oracle.
#   ACCOUNT_BANK_FAKE_KEYCHAIN         per-service slot files (seedflow-native), so slot
#                                      creation/deletion is observable on disk.
#   ACCOUNT_BANK_NOTIFY_BIN            a recording stub instead of osascript.
source "$(dirname "${BASH_SOURCE[0]}")/testlib.sh"

RELOGIN="$AB_DIR/relogin-account.sh"
CAPTURE="$AB_DIR/relogin_capture.py"
BANK="$AB_DIR/bank-account.sh"

TARGET="parked@example.com"
OTHER="active@example.com"

# A fake "login completed" terminal: $1 launcher, $2 config dir, $3 email. Writes the
# credential into the config dir's FILE seat and the metadata the CLI would write.
_make_terminal_stub() {  # <path> <email-to-write> [delay]
  local out="$1" em="$2" delay="${3:-0}"
  cat > "$out" <<STUB
#!/bin/bash
sleep ${delay}
cfg="\$2"
printf '{"claudeAiOauth":{"accessToken":"fresh-at","refreshToken":"fresh-rt","expiresAt":$FUT,"subscriptionType":"max"}}' > "\$cfg/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"%s","organizationType":"claude_max"}}' "$em" > "\$cfg/.claude.json"
STUB
  chmod +x "$out"
}

_notify_stub() {  # <path> <record-file>
  cat > "$1" <<STUB
#!/bin/bash
cat >/dev/null            # swallow the AppleScript on stdin
printf '%s | %s\n' "\$2" "\$3" >> "$2"
exit 0
STUB
  chmod +x "$1"
}

# ---------------------------------------------------------------------------
# 1. ROUTING — a needs-relogin card routes Re-bank into the re-login flow
# ---------------------------------------------------------------------------
new_env relogin-route >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
set_active "$OTHER" "at-other"
bank_record "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"

# route only — the flow itself aborts on the (deliberately absent) terminal stub
out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=1 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD='true' \
       ACCOUNT_BANK_FAKE_PROFILE="INDETERMINATE" \
       /bin/bash "$BANK" "$TARGET" 2>&1)"
assert_contains "Handing off to relogin-account.sh" "$out" "needs-relogin card routes to the re-login flow"
assert_contains "relogin-account.sh $TARGET — starting" "$out" "the re-login orchestrator actually runs"

# the OTHER account's record must be untouched by a routed re-bank
assert_eq "at-other" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$BANK_DIR/$OTHER.json")" \
  "routing never re-banks the active account under the target's name"

# ---------------------------------------------------------------------------
# 2. ROUTING — the active card is the unchanged normal path; a healthy parked
#    card refuses honestly instead of silently banking the active account
# ---------------------------------------------------------------------------
new_env relogin-route2 >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
set_active "$OTHER" "at-other"
bank_record "$OTHER" "stale-at"
bank_record "$TARGET" "target-at"

out="$(/bin/bash "$BANK" "$OTHER" 2>&1)"; rc=$?
assert_eq "0" "$rc" "re-banking the ACTIVE card takes the normal path"
assert_contains "Banked $OTHER" "$out" "the active card banks the live credential"
assert_eq "at-other" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$BANK_DIR/$OTHER.json")" \
  "the active card's record picked up the live token"

out="$(/bin/bash "$BANK" "$TARGET" 2>&1)"; rc=$?
assert_ne "0" "$rc" "a healthy parked card refuses rather than banking the wrong account"
assert_contains "no credential for it to capture" "$out" "the refusal says why"
assert_eq "target-at" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$BANK_DIR/$TARGET.json")" \
  "the refused re-bank left the parked record byte-identical"

# no-argument invocation is the SessionStart auto-bank path and must not change
out="$(/bin/bash "$BANK" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the no-argument form still banks the active account"
assert_contains "Banked $OTHER" "$out" "the no-argument form is unchanged"

# ---------------------------------------------------------------------------
# 3. IDENTITY MISMATCH — the owner picked the wrong account in the browser
# ---------------------------------------------------------------------------
new_env relogin-mismatch >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
set_active "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
_make_terminal_stub "$base/term.sh" "somebody-else@example.com"

out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/term.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="RESOLVED somebody-else@example.com" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "5" "$rc" "a mismatched login aborts with the confirmed-bad exit code"
assert_contains "the browser login was somebody-else@example.com" "$out" "the abort names what was actually picked"
assert_eq "old-at" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$BANK_DIR/$TARGET.json")" \
  "a mismatched login banks NOTHING"
assert_eq "needs-relogin" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$BANK_DIR/$TARGET.json")" \
  "a mismatched login leaves the record needs-relogin"
leftover="$(find "$BANK_DIR" -maxdepth 1 -name '.relogin.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$leftover" "the throwaway config dir is cleaned up after a mismatch"

# an INVALID verdict (server rejected the captured credential) is equally confirmed
new_env relogin-invalid >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
set_active "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
_make_terminal_stub "$base/term.sh" "$TARGET"
out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/term.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="INVALID" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "5" "$rc" "a server-rejected capture aborts confirmed, not transient"

# INDETERMINATE must NEVER become an accusation — it is a transient abort
new_env relogin-indet >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
set_active "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
_make_terminal_stub "$base/term.sh" "$TARGET"
out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/term.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="INDETERMINATE" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "6" "$rc" "an unconfirmable identity is transient, never a mismatch verdict"
assert_contains "unchanged" "$out" "a transient abort says the account is unchanged"

# ---------------------------------------------------------------------------
# 4. TIMEOUT — nobody completed the login
# ---------------------------------------------------------------------------
new_env relogin-timeout >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
set_active "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=4 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD='true' \
       ACCOUNT_BANK_FAKE_PROFILE="RESOLVED $TARGET" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "4" "$rc" "an unanswered login window times out cleanly"
assert_contains "Nothing banked" "$out" "the timeout is explicit that nothing changed"
leftover="$(find "$BANK_DIR" -maxdepth 1 -name '.relogin.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$leftover" "the throwaway config dir is cleaned up after a timeout"

# ---------------------------------------------------------------------------
# 5. SUCCESS — capture, verify, bank, clear the breaker
# ---------------------------------------------------------------------------
new_env relogin-success >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
set_active "$TARGET" "fresh-at" "fresh-rt" "$FUT" "max"    # the login landed on the seat
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
python3 - "$BANK_DIR/$TARGET.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["needs_login_since"] = 1; d["ping_fail_streak"] = 9
json.dump(d, open(p, "w"))
PY
_make_terminal_stub "$base/term.sh" "$TARGET"
NOTELOG="$base/notify.log"; _notify_stub "$base/notify-stub" "$NOTELOG"

out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/term.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="RESOLVED $TARGET" \
       ACCOUNT_BANK_NOTIFY_BIN="$base/notify-stub" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "0" "$rc" "a matching login completes the whole flow"
assert_contains "Re-login complete" "$out" "the flow reports success"
assert_eq "fresh-at" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$BANK_DIR/$TARGET.json")" \
  "the freshly captured credential is what got banked"
assert_eq "ok" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$BANK_DIR/$TARGET.json")" \
  "the record is healthy again"
assert_eq "" "$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('needs_login_since',''))" "$BANK_DIR/$TARGET.json")" \
  "the auto-ping breaker (needs_login_since) is cleared on success"
assert_eq "" "$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('ping_fail_streak',''))" "$BANK_DIR/$TARGET.json")" \
  "the failure streak is cleared on success"
leftover="$(find "$BANK_DIR" -maxdepth 1 -name '.relogin.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$leftover" "the throwaway config dir is deleted after a successful bank"

# ---------------------------------------------------------------------------
# 5b. MATERIALIZATION — a SLOT-only seat becomes the dir's .credentials.json
#     (fact 2: cred_read follows CLAUDE_CONFIG_DIR for the FILE form only, so a
#     login that landed in the per-config-dir keychain slot must be written out as
#     the file or bank-account.sh would see nothing). Proved directly, because the
#     sandbox's redirected cred_read cannot distinguish the two on its own.
# ---------------------------------------------------------------------------
new_env relogin-materialize >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
cfg="$base/slotseat"; mkdir -p "$cfg"
svc="$(python3 -c "import sys;sys.path.insert(0,'$AB_DIR');import seedflow;print(seedflow.config_slot_service(sys.argv[1]))" "$cfg")"
printf '{"claudeAiOauth":{"accessToken":"slot-at","refreshToken":"slot-rt","expiresAt":%s}}' "$FUT" \
  > "$base/fakekc.svc-${svc##*-}"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$TARGET" > "$cfg/.claude.json"
assert_file_absent "$cfg/.credentials.json" "the dir starts with no file seat (slot only)"
ACCOUNT_BANK_FAKE_PROFILE="RESOLVED $TARGET" python3 "$CAPTURE" watch "$cfg" "$TARGET" 20 >/dev/null 2>&1
assert_eq "0" "$?" "a slot-only seat is captured"
assert_file_present "$cfg/.credentials.json" "the slot seat is materialized as the dir's .credentials.json"
assert_contains "slot-at" "$(cat "$cfg/.credentials.json")" "the materialized file holds the captured credential"
assert_eq "600" "$(stat -f '%OLp' "$cfg/.credentials.json")" "the materialized credential is 0600"

# ---------------------------------------------------------------------------
# 6. SLOT SWEEP — cleanup deletes every path spelling's per-config-dir slot
# ---------------------------------------------------------------------------
new_env relogin-slots >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
cfg="$base/cfgdir"; mkdir -p "$cfg"
for spelling in "$cfg" "$cfg/"; do
  svc="$(python3 -c "import sys;sys.path.insert(0,'$AB_DIR');import seedflow;print(seedflow.config_slot_service(sys.argv[1]))" "$spelling")"
  printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$base/fakekc.svc-${svc##*-}"
done
made="$(find "$base" -maxdepth 1 -name 'fakekc.svc-*' | wc -l | tr -d ' ')"
assert_ne "0" "$made" "both path spellings produced distinct slot files"
python3 "$CAPTURE" cleanup "$cfg" >/dev/null 2>&1
left="$(find "$base" -maxdepth 1 -name 'fakekc.svc-*' | wc -l | tr -d ' ')"
assert_eq "0" "$left" "cleanup sweeps the slot for EVERY path spelling"
assert_file_absent "$cfg" "cleanup removes the throwaway config dir"
unset ACCOUNT_BANK_FAKE_KEYCHAIN

# the bare default slot must never be a deletion target
svcs="$(python3 -c "
import sys; sys.path.insert(0,'$AB_DIR')
import relogin_capture as r
print('\n'.join(sorted(r._slot_services('/tmp/whatever'))))")"
assert_eq "" "$(printf '%s\n' "$svcs" | grep -x 'Claude Code-credentials' || true)" \
  "the bare default slot is never among the sweep targets"

# ---------------------------------------------------------------------------
# 7. NOTIFICATION DEBOUNCE — once per arming, not once per poll
# ---------------------------------------------------------------------------
new_env relogin-notify >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
NOTELOG="$base/notify.log"; _notify_stub "$base/notify-stub" "$NOTELOG"
export ACCOUNT_BANK_NOTIFY_BIN="$base/notify-stub"

python3 "$AB_DIR/notify.py" relogin "$BANK_DIR" "$TARGET" "revoked" >/dev/null 2>&1
python3 "$AB_DIR/notify.py" relogin "$BANK_DIR" "$TARGET" "revoked" >/dev/null 2>&1
python3 "$AB_DIR/notify.py" relogin "$BANK_DIR" "$TARGET" "revoked" >/dev/null 2>&1
assert_eq "1" "$(wc -l < "$NOTELOG" | tr -d ' ')" "three armings in a row notify exactly once"
assert_contains "$TARGET" "$(cat "$NOTELOG")" "the notification names the account"

python3 "$AB_DIR/notify.py" clear "$BANK_DIR" "$TARGET" >/dev/null 2>&1
python3 "$AB_DIR/notify.py" relogin "$BANK_DIR" "$TARGET" "revoked again" >/dev/null 2>&1
assert_eq "2" "$(wc -l < "$NOTELOG" | tr -d ' ')" "a cleared account notifies again on the NEXT revocation"

: > "$NOTELOG"
ACCOUNT_BANK_NOTIFY=0 python3 "$AB_DIR/notify.py" clear "$BANK_DIR" "$TARGET" >/dev/null 2>&1
ACCOUNT_BANK_NOTIFY=0 python3 "$AB_DIR/notify.py" relogin "$BANK_DIR" "$TARGET" "off" >/dev/null 2>&1
assert_eq "0" "$(wc -l < "$NOTELOG" | tr -d ' ')" "ACCOUNT_BANK_NOTIFY=0 silences the surface entirely"

# a ping that confirms death arms the notification exactly once, via the marker writer
new_env relogin-notify-ping >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
NOTELOG="$base/notify.log"; _notify_stub "$base/notify-stub" "$NOTELOG"
export ACCOUNT_BANK_NOTIFY_BIN="$base/notify-stub"
bank_record "$TARGET" "old-at"
snap="$(python3 "$AB_DIR/epoch.py" snapshot "$BANK_DIR" 2>/dev/null)"
ACCOUNT_BANK_EPOCH_SNAP="$snap" python3 "$AB_DIR/_ping_marker.py" "$BANK_DIR/$TARGET.json" 100 needs-relogin >/dev/null 2>&1
ACCOUNT_BANK_EPOCH_SNAP="$snap" python3 "$AB_DIR/_ping_marker.py" "$BANK_DIR/$TARGET.json" 200 needs-relogin >/dev/null 2>&1
assert_eq "1" "$(wc -l < "$NOTELOG" | tr -d ' ')" "re-stamping needs-relogin does not re-notify"
# Healing the record is what re-arms the announcement. A ping success does NOT: ping
# refuses a needs-relogin record outright, so `status` only returns to ok via a re-bank
# or a healthy poll (usage.py set_bank_status), and that is the path that clears here.
python3 - "$BANK_DIR/$TARGET.json" <<HEAL
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["status"] = "ok"; json.dump(d, open(p, "w"))
HEAL
python3 "$AB_DIR/notify.py" clear "$BANK_DIR" "$TARGET" >/dev/null 2>&1
ACCOUNT_BANK_EPOCH_SNAP="$snap" python3 "$AB_DIR/_ping_marker.py" "$BANK_DIR/$TARGET.json" 400 needs-relogin >/dev/null 2>&1
assert_eq "2" "$(wc -l < "$NOTELOG" | tr -d ' ')" "a healed account announces the NEXT revocation"
unset ACCOUNT_BANK_NOTIFY_BIN

finish "relogin"
