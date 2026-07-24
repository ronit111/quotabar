#!/bin/bash
# Tests for session-hook.sh — managed-session gating, lifecycle wiring, fail-closed
# prompt, idle_prompt edge, escaped-launch telemetry. Fully isolated (fake HOME).
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAILS=0
ok() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $2"; else FAILS=$((FAILS+1)); echo "  FAIL $2"; fi; }

T="$(mktemp -d)"; ACC="$T/accounts"
mkdir -p "$ACC/homes/a-at-x.com"
SID="11111111-2222-3333-4444-555555555555"
HOOK="$HERE/session-hook.sh"
# (r3 IB3) pin the hook's originating pid to THIS live test process so lifecycle events
# bind consistently (command-substitution subshells would otherwise vary PPID). A live
# pid also makes the binding meaningful.
ENV=(env ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" ACCOUNT_BANK_HOOK_PID="$$")

payload() { printf '{"session_id":"%s","cwd":"/tmp","transcript_path":"/tp.jsonl"%s}' "$SID" "${1:-}"; }

# unmanaged session (no CLAUDE_CONFIG_DIR, epoch v1): silent no-op
out="$(payload | "${ENV[@]}" bash "$HOOK" start 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && [ ! -f "$ACC/sessions.json" ] && ok 0 "unmanaged start -> silent no-op" || ok 1 "unmanaged start -> silent no-op (rc=$rc out=$out)"

# escaped-launch telemetry under EPOCH v2
python3 -c "import sys; sys.path.insert(0,'$HERE'); import epoch; epoch.write_epoch('$ACC','v2',1)"
out="$(payload | "${ENV[@]}" bash "$HOOK" start 2>&1)"; rc=$?
echo "$out" | grep -q "BYPASSED" && [ $rc -eq 0 ] && ok 0 "escaped v2 launch -> telemetry banner, non-blocking" || ok 1 "escaped v2 launch -> telemetry banner (rc=$rc out=$out)"

# managed start registers
out="$(payload | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" start 2>&1)"
python3 -c "
import json,sys
d=json.load(open('$ACC/sessions.json'))
r=d.get('$SID',{})
sys.exit(0 if r.get('home','').endswith('a-at-x.com') else 1)" && ok 0 "managed start registered" || ok 1 "managed start registered"

# prompt -> BUSY; stop stays BUSY; idle_prompt notification -> IDLE
payload | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" prompt >/dev/null 2>&1
ST="$(python3 -c "import json; print(json.load(open('$ACC/sessions.json'))['$SID']['state'])")"
[ "$ST" = "BUSY" ] && ok 0 "prompt -> BUSY" || ok 1 "prompt -> BUSY (got $ST)"
payload | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" stop >/dev/null 2>&1
ST="$(python3 -c "import json; print(json.load(open('$ACC/sessions.json'))['$SID']['state'])")"
[ "$ST" = "BUSY" ] && ok 0 "stop advisory -> still BUSY" || ok 1 "stop advisory -> still BUSY (got $ST)"
printf '{"session_id":"%s","notification_type":"other_thing"}' "$SID" | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" notify >/dev/null 2>&1
ST="$(python3 -c "import json; print(json.load(open('$ACC/sessions.json'))['$SID']['state'])")"
[ "$ST" = "BUSY" ] && ok 0 "non-idle notification ignored" || ok 1 "non-idle notification ignored (got $ST)"
printf '{"session_id":"%s","notification_type":"idle_prompt"}' "$SID" | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" notify >/dev/null 2>&1
ST="$(python3 -c "import json; print(json.load(open('$ACC/sessions.json'))['$SID']['state'])")"
[ "$ST" = "IDLE" ] && ok 0 "idle_prompt -> IDLE" || ok 1 "idle_prompt -> IDLE (got $ST)"

# (r3 IB3) a DELAYED predecessor idle (different originating pid) must NOT flip the
# active successor to IDLE. Session is IDLE now; send an idle bound to a foreign pid and
# confirm it is ignored (state stays IDLE, but the point is it is not re-driven by a
# stale pid — assert via a BUSY->foreign-idle no-op).
python3 -c "import sys; sys.path.insert(0,'$HERE'); import sessions; sessions.record_event('$ACC','prompt','$SID',{'pid':$$})"  # back to BUSY (our pid)
printf '{"session_id":"%s","notification_type":"idle_prompt"}' "$SID" | env ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" ACCOUNT_BANK_HOOK_PID=999999999 env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" notify >/dev/null 2>&1
ST="$(python3 -c "import json; print(json.load(open('$ACC/sessions.json'))['$SID']['state'])")"
[ "$ST" = "BUSY" ] && ok 0 "delayed predecessor idle (foreign pid) IGNORED -> stays BUSY (r3 IB3)" || ok 1 "delayed predecessor idle ignored (got $ST)"
# a delayed predecessor END (foreign pid) must NOT tombstone the successor
printf '{"session_id":"%s"}' "$SID" | env ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" ACCOUNT_BANK_HOOK_PID=999999999 env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" end >/dev/null 2>&1
python3 -c "
import json,sys
d=json.load(open('$ACC/sessions.json'))
sys.exit(1 if d['$SID'].get('tombstone') else 0)" && ok 0 "delayed predecessor end (foreign pid) does NOT tombstone (r3 IB3)" || ok 1 "delayed predecessor end tombstoned the successor"
# restore IDLE via our own pid for the lease test below
printf '{"session_id":"%s","notification_type":"idle_prompt"}' "$SID" | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" notify >/dev/null 2>&1

# prompt blocked (exit 2) while RESTARTING lease held
python3 -c "import sys; sys.path.insert(0,'$HERE'); import sessions; sessions.lease_acquire('$ACC','$SID')"
out="$(payload | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" prompt 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -qi "restart" && ok 0 "prompt blocked under lease (exit 2)" || ok 1 "prompt blocked under lease (rc=$rc)"
python3 -c "import sys; sys.path.insert(0,'$HERE'); import sessions; sessions.lease_release('$ACC','$SID')"

# fail-closed: sessions store unwritable -> prompt blocked (exit 2)
chmod 0500 "$ACC"
out="$(payload | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" prompt 2>&1)"; rc=$?
chmod 0755 "$ACC"
[ $rc -eq 2 ] && echo "$out" | grep -qi "fail-closed" && ok 0 "BUSY persistence failure -> prompt BLOCKED (r6 fail-closed)" || ok 1 "BUSY persistence failure -> blocked (rc=$rc out=${out:0:120})"

# end -> tombstone
payload | "${ENV[@]}" env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" end >/dev/null 2>&1
python3 -c "
import json,sys
d=json.load(open('$ACC/sessions.json'))
sys.exit(0 if d['$SID'].get('tombstone') else 1)" && ok 0 "end -> tombstone" || ok 1 "end -> tombstone"

# (r12 #1 / r13 #3) a MANAGED session whose helpers are MISSING (broken install). Rev 9: BUSY
# persistence fails CLOSED. Precise rule — prompt + a session REGISTRY present -> BLOCK (exit 2,
# a restart controller could target the registered session); prompt + NO registry -> fail OPEN.
BROKEN="$T/no-scripts-here"; mkdir -p "$BROKEN"        # deliberately lacks sessions.py
# CASE A: registry PRESENT ($ACC/sessions.json exists from the managed-start test above) -> BLOCK.
[ -f "$ACC/sessions.json" ] || ok 1 "precondition: sessions.json exists"
out="$(payload | env HOME="$T" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$BROKEN" ACCOUNT_BANK_HOOK_PID="$$" \
        env CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" bash "$HOOK" prompt 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok 0 "broken install + registry present -> prompt BLOCKS (fail-closed, exit 2) (r13 #3)" || ok 1 "broken-install+registry fail-closed (rc=$rc: $out)"
echo "$out" | grep -q "broken/incomplete" && ok 0 "broken install surfaces LOUDLY on stderr (r12 #1)" || ok 1 "broken install loud (got: $out)"
# CASE B: NO registry (a fresh accounts dir with no sessions.json) -> fail OPEN (nothing can be restarted).
FRESH="$T/fresh-acc"; mkdir -p "$FRESH/homes/a-at-x.com"
out="$(payload | env HOME="$T" ACCOUNT_BANK_DIR="$FRESH" ACCOUNT_BANK_SCRIPTS_DIR="$BROKEN" ACCOUNT_BANK_HOOK_PID="$$" \
        env CLAUDE_CONFIG_DIR="$FRESH/homes/a-at-x.com" bash "$HOOK" prompt 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok 0 "broken install + NO registry -> prompt FAILS OPEN (exit 0) (r13 #3)" || ok 1 "broken-install+no-registry fail-open (rc=$rc: $out)"

rm -rf "$T"
echo "-- session_hook: $PASS passed, $FAILS failed"
[ $FAILS -eq 0 ]
