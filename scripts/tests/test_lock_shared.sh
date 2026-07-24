#!/bin/bash
# (r5 item 6) The shell (lib.sh) and Python (banklock.py) bank locks must be
# byte-compatible (same .lock dir, same "pid token start" owner format) AND both must
# reclaim a stale lock ONLY on POSITIVE death — an ownerless/unreadable/live stale lock
# is NEVER reclaimed. Isolated sandbox; no real keychain.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
new_env locksh >/dev/null
export AB_DIR                       # child python heredocs read it via os.environ
source "$AB_DIR/lib.sh"; ensure_bank
PYLOCK() { python3 - "$BANK_DIR" "$1" <<'PY'
import sys, os
sys.path.insert(0, os.environ["AB_DIR"])
import banklock
lk = banklock.BankLock(sys.argv[1])
if sys.argv[2] == "acquire":
    sys.exit(0 if lk.acquire(timeout=1) else 1)
PY
}

# 1. byte-compat: shell holds -> python acquire refused
acquire_lock >/dev/null 2>&1; assert_eq 0 "$?" "shell acquire_lock succeeds"
AB_DIR="$AB_DIR" PYLOCK acquire; assert_eq 1 "$?" "python banklock refused while shell holds (byte-compat)"
release_lock
# 2. byte-compat: python held then released -> shell can acquire
AB_DIR="$AB_DIR" python3 - "$BANK_DIR" <<'PY'
import sys, os; sys.path.insert(0, os.environ["AB_DIR"])
import banklock
lk = banklock.BankLock(sys.argv[1]); assert lk.acquire(timeout=1); lk.release()
PY
acquire_lock >/dev/null 2>&1; assert_eq 0 "$?" "shell acquires after python released (byte-compat)"
release_lock

# 3. positive-death: a DEAD-owner stale lock IS reclaimed by shell acquire
python3 - "$BANK_DIR" <<'PY'
import subprocess; p = subprocess.Popen(["true"]); p.wait()
import os, time, sys
ld = os.path.join(sys.argv[1], ".lock"); os.makedirs(ld, exist_ok=True)
open(os.path.join(ld, "owner"), "w").write(f"{p.pid} tok long-gone-start\n")
os.utime(ld, (0, 0))   # ancient (> 5 min)
PY
LOCK_TOKEN=""; acquire_lock >/dev/null 2>&1; assert_eq 0 "$?" "dead-owner stale lock reclaimed (positive death)"
release_lock

# 4. positive-death: an OWNERLESS ancient lock is NEVER reclaimed (fail-closed)
mkdir "$BANK_DIR/.lock" 2>/dev/null; : > /dev/null; touch -t 200001010000 "$BANK_DIR/.lock" 2>/dev/null || python3 -c "import os,sys;os.utime(os.path.join(sys.argv[1],'.lock'),(0,0))" "$BANK_DIR"
LOCK_TOKEN=""; acquire_lock 2 >/dev/null 2>&1; assert_ne 0 "$?" "ownerless ancient lock NOT reclaimed (positive-death only)"
rm -rf "$BANK_DIR/.lock"

# 5. python side: dead-owner stale lock reclaimed; ownerless never
python3 - "$BANK_DIR" <<'PY'
import subprocess; p = subprocess.Popen(["true"]); p.wait()
import os, sys; sys.path.insert(0, os.environ["AB_DIR"])
import banklock
bd = sys.argv[1]
ld = os.path.join(bd, ".lock"); os.makedirs(ld, exist_ok=True)
open(os.path.join(ld, "owner"), "w").write(f"{p.pid} tok long-gone-start\n"); os.utime(ld, (0, 0))
lk = banklock.BankLock(bd); assert lk.acquire(timeout=3), "python must reclaim dead-owner stale lock"; lk.release()
os.makedirs(ld, exist_ok=True); os.utime(ld, (0, 0))   # ownerless ancient
lk2 = banklock.BankLock(bd); assert not lk2.acquire(timeout=2), "python must NOT reclaim ownerless lock"
print("PYOK")
PY
assert_eq 0 "$?" "python positive-death reclaim behavior matches shell"

# (r14 #4) lib.sh acquire_lock REFUSES to publish an owner record with an empty (unprovable)
# start-time. Override _proc_starttime to return empty in a subshell and assert acquire fails
# and leaves NO lock dir (else a future reclaim could never prove death -> permanent lock-out).
new_env locksh_empty >/dev/null
( source "$AB_DIR/lib.sh"; ensure_bank
  _proc_starttime() { echo ""; }               # simulate a persistent ps failure
  acquire_lock 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ ! -d "$BANK_DIR/.lock" ] && exit 0 || exit 1 )
assert_eq 0 "$?" "lib.sh acquire_lock refuses an empty start-time + leaves no lock (r14 #4)"

finish "lock_shared"
