#!/bin/bash
# (r9 #4) gate-g8.sh's keychain sampling must be FAIL-CLOSED: a read that fails or is
# empty is never turned into a comparable hash (two failed reads must not both hash
# sha256("") and compare EQUAL into a false "keychain unchanged" PASS). Exercised via the
# hermetic --kc-selftest mode driven by ACCOUNT_BANK_FAKE_KEYCHAIN (never the real slot).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB="$(cd "$HERE/.." && pwd)"
PASS=0; FAILS=0
ok() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $2"; else FAILS=$((FAILS+1)); echo "  FAIL $2"; fi; }

T="$(mktemp -d)"
FAKE="$T/kc.json"
printf '{"claudeAiOauth":{"accessToken":"KC","refreshToken":"r","expiresAt":9}}' > "$FAKE"

# present + stable -> PASS (rc 0)
out="$(ACCOUNT_BANK_SCRIPTS_DIR="$AB" ACCOUNT_BANK_FAKE_KEYCHAIN="$FAKE" bash "$AB/gate-g8.sh" dummy@x.com --kc-selftest 2>&1)"; rc=$?
[ $rc -eq 0 ]; ok $? "present keychain, stable -> SELFTEST PASS (rc 0)"
echo "$out" | grep -q "SELFTEST PASS" && ok 0 "reports PASS on a present, unchanged keychain" || ok 1 "reports PASS (got: $out)"

# read FAILURE (locked/denied) -> FAIL-CLOSED (rc != 0), never a false equal-hash pass
out="$(ACCOUNT_BANK_SCRIPTS_DIR="$AB" ACCOUNT_BANK_FAKE_KEYCHAIN="$FAKE" ACCOUNT_BANK_FAKE_KEYCHAIN_MODE=error bash "$AB/gate-g8.sh" dummy@x.com --kc-selftest 2>&1)"; rc=$?
[ $rc -ne 0 ]; ok $? "failed keychain read -> SELFTEST FAIL (rc != 0), fail-closed (r9 #4)"
echo "$out" | grep -q "SELFTEST FAIL" && ok 0 "two failed reads never compare equal into a PASS (r9 #4)" || ok 1 "reports FAIL on a failed read (got: $out)"

# empty slot (absent) is also non-'present' -> FAIL-CLOSED (cannot anchor an isolation baseline)
: > "$FAKE"
out="$(ACCOUNT_BANK_SCRIPTS_DIR="$AB" ACCOUNT_BANK_FAKE_KEYCHAIN="$FAKE" bash "$AB/gate-g8.sh" dummy@x.com --kc-selftest 2>&1)"; rc=$?
[ $rc -ne 0 ]; ok $? "empty/absent slot -> SELFTEST FAIL (no comparable hash) (r9 #4)"

# (r12 #4) gate-g8.sh resolves its scripts dir from its OWN location (no env override). Stage
# it with its --kc-selftest deps in a fresh dir and run with ACCOUNT_BANK_SCRIPTS_DIR UNSET.
SELFG="$T/g8-install"; mkdir -p "$SELFG"
cp "$AB/gate-g8.sh" "$AB/seedflow.py" "$AB/bank_common.py" "$AB/banklock.py" "$AB/epoch.py" "$AB/registry.py" "$AB/identity.py" "$AB/homewrite.py" "$SELFG/" 2>/dev/null
printf '{"claudeAiOauth":{"accessToken":"KC2"}}' > "$T/kc2.json"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_FAKE_KEYCHAIN="$T/kc2.json" "$SELFG/gate-g8.sh" dummy@x.com --kc-selftest 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "SELFTEST PASS" && ok 0 "gate-g8.sh resolves scripts from its OWN dir (no env) (r12 #4)" || ok 1 "gate-g8 self-dir resolution (rc $rc: $out)"

# (r13 #8) G8 must hold the per-home lock across its backdate read-modify-writes.
grep -q "BankLock(home)" "$AB/gate-g8.sh" && ok 0 "gate-g8 acquires the per-home lock for trials (r13 #8)" || ok 1 "gate-g8 takes the home lock (r13 #8)"

# (seat) the STRUCTURAL (non-live) check must pass on BOTH seat kinds — it resolves the READY
# home + checks the tier-1 writer is importable, never reading the credential, so a slot-seat
# home (no .credentials.json file) passes just like a file-seat home.
GACC="$T/g8-accounts"; mkdir -p "$GACC/homes/file-at-x.com" "$GACC/homes/slot-at-x.com"
printf '{"claudeAiOauth":{"accessToken":"F"}}' > "$GACC/homes/file-at-x.com/.credentials.json"  # file seat
# slot-at-x.com deliberately has NO .credentials.json -> slot seat
python3 - "$AB" "$GACC" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1]); import registry
acc = sys.argv[2]
registry.publish_ready(acc, "file@x.com", os.path.join(acc, "homes", "file-at-x.com"), "uuid-f")
registry.publish_ready(acc, "slot@x.com", os.path.join(acc, "homes", "slot-at-x.com"), "uuid-s")
PY
env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$GACC" ACCOUNT_BANK_SCRIPTS_DIR="$AB" bash "$AB/gate-g8.sh" file@x.com >/dev/null 2>&1
[ $? -eq 0 ] && ok 0 "gate-g8 structural check passes on a FILE-seat home (seat)" || ok 1 "gate-g8 structural on file seat (seat)"
env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$GACC" ACCOUNT_BANK_SCRIPTS_DIR="$AB" bash "$AB/gate-g8.sh" slot@x.com >/dev/null 2>&1
[ $? -eq 0 ] && ok 0 "gate-g8 structural check passes on a SLOT-seat home (no file) (seat)" || ok 1 "gate-g8 structural on slot seat (seat)"

rm -rf "$T"
echo "-- gate_g8: $PASS passed, $FAILS failed"
[ $FAILS -eq 0 ]
