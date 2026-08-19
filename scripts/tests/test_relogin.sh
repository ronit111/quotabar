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
#   ACCOUNT_BANK_OSASCRIPT_BIN         /usr/bin/true, so no window-close can ever reach
#                                      the real Terminal.
source "$(dirname "${BASH_SOURCE[0]}")/testlib.sh"

RELOGIN="$AB_DIR/relogin-account.sh"
CAPTURE="$AB_DIR/relogin_capture.py"
BANK="$AB_DIR/bank-account.sh"

TARGET="parked@example.com"
OTHER="active@example.com"

# A fake "login completed" terminal: $1 launcher, $2 config dir, $3 email. Writes the
# credential into the config dir's FILE seat and the metadata the CLI would write.
_make_terminal_stub() {  # <path> <email-to-write> [token] [delay]
  local out="$1" em="$2" tok="${3:-fresh-at}" delay="${4:-0}"
  cat > "$out" <<STUB
#!/bin/bash
# witness what the journal held at the moment the "Terminal" was opened — the whole
# point of the journal is that it is already on disk by now
cp "$BANK_DIR/.relogin-journal.json" "$BANK_DIR/../journal-at-open.json" 2>/dev/null
sleep ${delay}
cfg="\$2"
printf '{"claudeAiOauth":{"accessToken":"$tok","refreshToken":"r-$tok","expiresAt":$FUT,"subscriptionType":"max"}}' > "\$cfg/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"%s","organizationType":"claude_max"}}' "$em" > "\$cfg/.claude.json"
STUB
  chmod +x "$out"
}

# A "login" that opens and then just sits there, the way a real one does while the human
# is in the browser. Records its pid exactly as the generated launcher does.
_make_hanging_terminal_stub() {  # <path> <witness-pid-file>
  cat > "$1" <<STUB
#!/bin/bash
cfg="\$2"
# Drop the inherited stdout FIRST. A real Terminal-open returns immediately; this stub
# lingers, and if it kept the caller's capture pipe open the test would measure pipe
# closure instead of what it is actually about — whether the login process gets killed.
exec >/dev/null 2>&1
sleep 600 &
lp=\$!
# BOTH files, exactly as the generated launcher writes them: the pid is not proof on its
# own, and without the start-time token the flow correctly refuses to signal anything.
echo "\$lp" > "\$cfg/login.pid"
ps -o stat=,lstart= -p "\$lp" 2>/dev/null | tr -s " " | sed "s/^ *//;s/^[^ ]* //;s/ *\\\$//" > "\$cfg/login.start"
echo "\$lp" > "$2"
wait
STUB
  chmod +x "$1"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
#
# Both sides hold the SAME token here, deliberately: in the sandbox `cred_read` is
# force-redirected to the stub keychain (the hermetic guard), so bank-account.sh can
# never actually read the config dir's file and no test can prove WHICH source was
# banked by watching this path. That attribution is what test 5c covers, by making the
# two differ and requiring the flow to notice. This test covers everything else.
# ---------------------------------------------------------------------------
new_env relogin-success >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
# the heal poll must never leave the machine: a dead local port is a NetError, which is
# transient by contract and leaves the freshly-banked status standing.
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
# The stub keychain must carry the SAME credential the "login" writes into the config
# dir (refresh token included — the fingerprint covers accessToken+refreshToken+
# expiresAt), because the sandbox's redirected cred_read is what bank-account.sh reads.
set_active "$TARGET" "fresh-at" "r-fresh-at" "$FUT" "max"
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
# 5c. THE BANKED-CREDENTIAL ASSERTION (r2 finding 1)
#
# The bug: bank-account.sh re-reads the credential itself, and cred_read accepts a config
# dir's file only when the raw text carries "claudeAiOauth"/"oauth" — a FLAT blob falls
# through to the BARE default slot, i.e. the ACTIVE account, and every downstream check
# still agrees because the email comes from the target's own metadata. Here the captured
# credential and the default slot simply differ, which is that bug's exact signature: the
# flow must NOT report success, and must not leave another account's tokens banked under
# this email.
# ---------------------------------------------------------------------------
new_env relogin-fpmismatch >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
set_active "$TARGET" "DEFAULT-SLOT-TOKEN"          # what cred_read will actually return
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
_make_terminal_stub "$base/term.sh" "$TARGET" "CAPTURED-FROM-LOGIN"
NOTELOG="$base/notify.log"; _notify_stub "$base/notify-stub" "$NOTELOG"

out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/term.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="RESOLVED $TARGET" \
       ACCOUNT_BANK_NOTIFY_BIN="$base/notify-stub" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "8" "$rc" "banking a credential other than the captured one is a HARD failure"
assert_contains "MISMATCH" "$out" "the failure names the mismatch"
assert_ne "Re-login complete" "$out" "a mismatch never reports completion"
assert_eq "old-at" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$BANK_DIR/$TARGET.json")" \
  "the pre-login record is restored — the wrong credential is NOT left banked"
assert_eq "needs-relogin" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$BANK_DIR/$TARGET.json")" \
  "the restored record does not read as healthy"
leftover="$(find "$BANK_DIR" -maxdepth 1 -name '.relogin.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$leftover" "the throwaway config dir is cleaned up after a mismatch"

# and with no prior record at all, the correct restoration is to remove what we wrote
new_env relogin-fpmismatch-norec >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
set_active "$TARGET" "DEFAULT-SLOT-TOKEN"
_make_terminal_stub "$base/term.sh" "$TARGET" "CAPTURED-FROM-LOGIN"
out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/term.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="RESOLVED $TARGET" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "8" "$rc" "the assertion fires with no prior record too"
assert_file_absent "$BANK_DIR/$TARGET.json" "a mismatched first-ever bank leaves no record behind"

# ---------------------------------------------------------------------------
# 5d. THE PENDING JOURNAL (r2 finding 2)
# ---------------------------------------------------------------------------
new_env relogin-journal >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
export ACCOUNT_BANK_TOTAL_DEADLINE="8"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
set_active "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
_make_terminal_stub "$base/term.sh" "$TARGET"
rm -f "$base/journal-at-open.json"

out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/term.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="RESOLVED $TARGET" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"

# the journal existed, and already pointed at the config dir, BEFORE the login could run
assert_file_present "$base/journal-at-open.json" "the journal is on disk before the Terminal opens"
assert_contains "$TARGET" "$(cat "$base/journal-at-open.json" 2>/dev/null)" \
  "the journal names the account before the login can write anything"
assert_contains ".relogin." "$(cat "$base/journal-at-open.json" 2>/dev/null)" \
  "the journal records the config dir, so every slot spelling stays recomputable"
assert_eq "{}" "$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))" "$BANK_DIR/.relogin-journal.json" 2>/dev/null || echo '{}')" \
  "a completed flow leaves no pending entry"

# a stale entry (dead owner, no live login) is reaped: process, slot, dir, entry
new_env relogin-sweep >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
stale="$BANK_DIR/.relogin.STALE1234"; mkdir -p "$stale"
svc="$(python3 -c "import sys;sys.path.insert(0,'$AB_DIR');import seedflow;print(seedflow.config_slot_service(sys.argv[1]))" "$stale")"
printf '{"claudeAiOauth":{"accessToken":"stranded"}}' > "$base/fakekc.svc-${svc##*-}"
dead=99999   # a pid nothing can be running under in this sandbox
python3 - "$BANK_DIR/.relogin-journal.json" "$TARGET" "$stale" "$dead" <<'JRNL'
import json, sys, time
p, email, cfg, pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
json.dump({email: {"config_dir": cfg, "started_at": int(time.time()),
                   "owner_pid": pid, "term_window": ""}}, open(p, "w"))
JRNL
assert_file_present "$base/fakekc.svc-${svc##*-}" "the stranded slot exists before the sweep"
python3 "$CAPTURE" journal-sweep "$BANK_DIR" 900 >/dev/null 2>&1
assert_file_absent "$stale" "the sweep deletes the abandoned config dir"
assert_file_absent "$base/fakekc.svc-${svc##*-}" "the sweep deletes the slot that would otherwise be unrecomputable"
assert_eq "{}" "$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))" "$BANK_DIR/.relogin-journal.json")" \
  "the sweep drops the reaped entry"

# A RECYCLED pid must never be signalled. This is the sweep's most dangerous moment: an
# age-expired entry whose recorded pid now belongs to an unrelated process — most likely
# right after a reboot, when low pids are handed out again. Proof is the start-time token
# the launcher wrote beside its pid; an innocent process cannot match it, so it must be
# left strictly alone while the sweep still reclaims everything else.
new_env relogin-recycled >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
recycled="$BANK_DIR/.relogin.RECYCLED1"; mkdir -p "$recycled"
svc="$(python3 -c "import sys;sys.path.insert(0,'$AB_DIR');import seedflow;print(seedflow.config_slot_service(sys.argv[1]))" "$recycled")"
printf '{"claudeAiOauth":{"accessToken":"stranded"}}' > "$base/fakekc.svc-${svc##*-}"

sleep 300 & innocent=$!
echo "$innocent" > "$recycled/login.pid"
# the token an EARLIER process wrote — the innocent one cannot have this start time
printf 'Mon Jan  1 00:00:00 2001' > "$recycled/login.start"
# age-expired, so the entry is swept rather than treated as pending
python3 - "$BANK_DIR/.relogin-journal.json" "$TARGET" "$recycled" "$innocent" <<'JRNL'
import json, sys, time
p, email, cfg, pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
json.dump({email: {"config_dir": cfg, "started_at": int(time.time()) - 99999,
                   "owner_pid": pid, "term_window": ""}}, open(p, "w"))
JRNL

python3 "$CAPTURE" journal-sweep "$BANK_DIR" 900 >/dev/null 2>&1
if kill -0 "$innocent" 2>/dev/null; then alive=1; else alive=0; fi
assert_eq "1" "$alive" "a recycled pid is NOT killed — no proof, no signal"
assert_file_absent "$recycled" "the sweep still reclaims the dir when it may not kill"
assert_file_absent "$base/fakekc.svc-${svc##*-}" "the sweep still reclaims the slot when it may not kill"
assert_eq "{}" "$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))" "$BANK_DIR/.relogin-journal.json")" \
  "the sweep still drops the entry when it may not kill"
kill "$innocent" 2>/dev/null; wait "$innocent" 2>/dev/null

# and the proof works in the other direction: a MATCHING token permits the kill
new_env relogin-proven >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
proven="$BANK_DIR/.relogin.PROVEN1"; mkdir -p "$proven"
sleep 300 & real=$!
echo "$real" > "$proven/login.pid"
ps -o stat=,lstart= -p "$real" 2>/dev/null | tr -s " " | sed "s/^ *//;s/^[^ ]* //;s/ *\$//" > "$proven/login.start"
python3 - "$BANK_DIR/.relogin-journal.json" "$TARGET" "$proven" 99999 <<'JRNL'
import json, sys, time
p, email, cfg, pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
json.dump({email: {"config_dir": cfg, "started_at": int(time.time()) - 99999,
                   "owner_pid": pid, "term_window": ""}}, open(p, "w"))
JRNL
python3 "$CAPTURE" journal-sweep "$BANK_DIR" 900 >/dev/null 2>&1
sleep 1
if kill -0 "$real" 2>/dev/null; then alive=1; else alive=0; fi
assert_eq "0" "$alive" "a PROVEN login pid is terminated by the sweep"
kill "$real" 2>/dev/null; wait "$real" 2>/dev/null

# The sweep must not hold the journal lock across its slow work. Closing a Terminal
# window can take seconds; two such entries under the lock would blow past the
# stale-lock threshold, and a concurrent claimer that stole the lock would then have its
# fresh claim clobbered by the sweep's own write. Both halves are checked here: the claim
# lands promptly WHILE the sweep is in its slow phase, and it survives the sweep's finish.
new_env relogin-sweeplock >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
cat > "$base/slow-osascript" <<'SLOW'
#!/bin/bash
cat >/dev/null
sleep 4
SLOW
chmod +x "$base/slow-osascript"
export ACCOUNT_BANK_OSASCRIPT_BIN="$base/slow-osascript"

for n in 1 2; do mkdir -p "$BANK_DIR/.relogin.SLOW$n"; done
python3 - "$BANK_DIR/.relogin-journal.json" "$BANK_DIR" <<'JRNL'
import json, sys, time
p, bank = sys.argv[1], sys.argv[2]
old = int(time.time()) - 99999
json.dump({"a@x.com": {"config_dir": bank + "/.relogin.SLOW1", "started_at": old,
                       "owner_pid": 99999, "term_window": "101"},
           "b@x.com": {"config_dir": bank + "/.relogin.SLOW2", "started_at": old,
                       "owner_pid": 99999, "term_window": "102"}}, open(p, "w"))
JRNL

python3 "$CAPTURE" journal-sweep "$BANK_DIR" 900 >/dev/null 2>&1 &
sweep_pid=$!
sleep 1                                  # the sweep is now inside its slow phase
claim_start=$(date +%s)
python3 "$CAPTURE" journal-claim "$BANK_DIR" "$TARGET" "$$" 900 >/dev/null 2>&1
claim_rc=$?
claim_took=$(( $(date +%s) - claim_start ))
assert_eq "0" "$claim_rc" "a claim taken during a sweep succeeds"
# The sweep's slow phase is 2 entries x ~4s of window-closing, so an unlocked claim
# returns in well under a second and a BLOCKED one waits 5-8s. The threshold sits at 3s
# rather than 2s because it only has to separate those two populations, and a 2s bound
# was tight enough to flake once under load from a parallel suite — a timing test that
# fails when the machine is busy reports load, not behaviour.
if [ "$claim_took" -le 3 ]; then quick=1; else quick=0; fi
assert_eq "1" "$quick" "the claim is not blocked behind the sweep's slow work (${claim_took}s)"
wait "$sweep_pid" 2>/dev/null
assert_ne "" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('$TARGET',''))" "$BANK_DIR/.relogin-journal.json")" \
  "the sweep does not clobber a claim taken while it was running"
assert_eq "" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('a@x.com',''))" "$BANK_DIR/.relogin-journal.json")" \
  "the sweep still reaped the stale entries"
unset ACCOUNT_BANK_OSASCRIPT_BIN

# a LIVE entry is left alone by the sweep and REFUSES a second invocation
new_env relogin-double >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
set_active "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
sleep 30 & live_pid=$!
python3 - "$BANK_DIR/.relogin-journal.json" "$TARGET" "$BANK_DIR/.relogin.LIVE" "$live_pid" <<'JRNL'
import json, sys, time
p, email, cfg, pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
json.dump({email: {"config_dir": cfg, "started_at": int(time.time()),
                   "owner_pid": pid, "term_window": ""}}, open(p, "w"))
JRNL
out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=20 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD='true' \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "9" "$rc" "a second re-login is refused while one is pending"
assert_contains "already running" "$out" "the refusal says a login is already open"
assert_ne "" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('$TARGET',''))" "$BANK_DIR/.relogin-journal.json")" \
  "the refusal leaves the live entry intact"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null

# an abandoned flow TERMINATES its login instead of deleting the dir out from under it
new_env relogin-terminate >/dev/null
base="$(dirname "$BANK_DIR")"
export ACCOUNT_BANK_FAKE_KEYCHAIN="$base/fakekc"
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
set_active "$OTHER" "at-other"
bank_record "$TARGET" "old-at" "old-rt" "$PAST" "max" "claude_max" "needs-relogin"
_make_hanging_terminal_stub "$base/hang.sh" "$base/hanging.pid"
out="$(ACCOUNT_BANK_RELOGIN_DETACH=0 ACCOUNT_BANK_RELOGIN_TIMEOUT=4 \
       ACCOUNT_BANK_RELOGIN_TERMINAL_CMD="/bin/bash $base/hang.sh" \
       ACCOUNT_BANK_FAKE_PROFILE="RESOLVED $TARGET" \
       /bin/bash "$RELOGIN" "$TARGET" --sync 2>&1)"; rc=$?
assert_eq "4" "$rc" "the hanging login times out"
sleep 1
hung="$(cat "$base/hanging.pid" 2>/dev/null || echo 0)"
if [ "$hung" -gt 0 ] && kill -0 "$hung" 2>/dev/null; then survivors=1; else survivors=0; fi
assert_eq "0" "$survivors" "the abandoned login process is killed, not left to strand a credential"
kill "$hung" 2>/dev/null
assert_eq "{}" "$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))" "$BANK_DIR/.relogin-journal.json")" \
  "an abandoned flow releases its journal entry"

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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
cfg="$base/.relogin.slotseat"; mkdir -p "$cfg"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
cfg="$base/.relogin.cfgdir"; mkdir -p "$cfg"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
export ACCOUNT_BANK_OSASCRIPT_BIN="/usr/bin/true"
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
