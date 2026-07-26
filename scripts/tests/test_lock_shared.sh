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

# 4. (v101-confirm) an OWNERLESS lock. FRESH (inside the startup grace) it still blocks — it
# may be an acquisition in flight between its mkdir and its owner publication. PAST the grace
# it is reclaimed: that gap is milliseconds, so a directory still ownerless a minute later is
# an acquisition killed inside it, and refusing forever meant a SIGKILL/power loss there
# permanently wedged every future acquirer (and every launchd restart of the archiver).
# An owner record that EXISTS but is unreadable stays UNKNOWN and is still never reclaimed.
mkdir "$BANK_DIR/.lock" 2>/dev/null
LOCK_TOKEN=""; acquire_lock 2 >/dev/null 2>&1
assert_ne 0 "$?" "(v101-confirm) a FRESH ownerless lock still blocks (acquisition may be in flight)"
assert_file_present "$BANK_DIR/.lock" "(v101-confirm) the fresh ownerless lock was not destroyed"
touch -t 200001010000 "$BANK_DIR/.lock" 2>/dev/null || python3 -c "import os,sys;os.utime(os.path.join(sys.argv[1],'.lock'),(0,0))" "$BANK_DIR"
LOCK_TOKEN=""; acquire_lock 2 >/dev/null 2>&1
assert_eq 0 "$?" "(v101-confirm) an ownerless lock PAST the grace is reclaimed, not wedged forever"
release_lock

# an UNREADABLE (present but garbage) owner is not the ownerless case — still never reclaimed.
mkdir "$BANK_DIR/.lock" 2>/dev/null; printf 'not-a-pid\n' > "$BANK_DIR/.lock/owner"
touch -t 200001010000 "$BANK_DIR/.lock" 2>/dev/null || python3 -c "import os,sys;os.utime(os.path.join(sys.argv[1],'.lock'),(0,0))" "$BANK_DIR"
LOCK_TOKEN=""; acquire_lock 2 >/dev/null 2>&1
assert_ne 0 "$?" "(v101-confirm) an ancient UNREADABLE-owner lock is still never reclaimed (UNKNOWN)"
rm -rf "$BANK_DIR/.lock"

# 5. python side: identical rules. The two implementations contend for the SAME directory, so
# they must agree on exactly what is reclaimable.
python3 - "$BANK_DIR" <<'PY'
import subprocess; p = subprocess.Popen(["true"]); p.wait()
import os, sys, time; sys.path.insert(0, os.environ["AB_DIR"])
import banklock
bd = sys.argv[1]
ld = os.path.join(bd, ".lock"); os.makedirs(ld, exist_ok=True)
open(os.path.join(ld, "owner"), "w").write(f"{p.pid} tok long-gone-start\n"); os.utime(ld, (0, 0))
lk = banklock.BankLock(bd); assert lk.acquire(timeout=3), "python must reclaim dead-owner stale lock"; lk.release()

os.makedirs(ld, exist_ok=True)                          # ownerless, mtime = now
lk2 = banklock.BankLock(bd)
assert not lk2.acquire(timeout=2), "python must NOT reclaim a FRESH ownerless lock"
assert os.path.isdir(ld), "the fresh ownerless lock must survive the refusal"

os.utime(ld, (0, 0))                                    # ownerless, past the grace
lk3 = banklock.BankLock(bd)
assert lk3.acquire(timeout=3), "python must reclaim an ownerless lock past the grace"
lk3.release()

os.makedirs(ld, exist_ok=True)                          # present but unreadable owner
open(os.path.join(ld, "owner"), "w").write("not-a-pid\n"); os.utime(ld, (0, 0))
lk4 = banklock.BankLock(bd)
assert not lk4.acquire(timeout=2), "an unreadable owner is UNKNOWN — never reclaimed"
import shutil; shutil.rmtree(ld, ignore_errors=True)

# the DaemonLock (no age window) reclaims the same interrupted acquisition immediately after
# the grace — this is the launchd-restart case the archiver wedged on.
dl = os.path.join(bd, ".archiverd.lock"); os.makedirs(dl, exist_ok=True)
d1 = banklock.DaemonLock(bd, ".archiverd.lock")
assert not d1.acquire(), "a FRESH ownerless daemon lock still stands the newcomer down"
os.utime(dl, (time.time() - 3600, time.time() - 3600))
d2 = banklock.DaemonLock(bd, ".archiverd.lock")
assert d2.acquire(), "an ownerless daemon lock past the grace is reclaimed on restart"
d2.release()
print("PYOK")
PY
assert_eq 0 "$?" "python reclaim behavior matches shell (v101-confirm: ownerless grace included)"

# (r14 #4) lib.sh acquire_lock REFUSES to publish an owner record with an empty (unprovable)
# start-time. Override _proc_starttime to return empty in a subshell and assert acquire fails
# and leaves NO lock dir (else a future reclaim could never prove death -> permanent lock-out).
new_env locksh_empty >/dev/null
( source "$AB_DIR/lib.sh"; ensure_bank
  _proc_starttime() { echo ""; }               # simulate a persistent ps failure
  acquire_lock 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ ! -d "$BANK_DIR/.lock" ] && exit 0 || exit 1 )
assert_eq 0 "$?" "lib.sh acquire_lock refuses an empty start-time + leaves no lock (r14 #4)"

# (r15 #8) The RECLAIM MUTEX needs the same discipline as the main lock above. Publishing
# an owner with an empty start-time makes the mutex UNRECLAIMABLE forever if that process
# then dies before releasing it: reclaim is positive-death-only by design (no age fallback),
# so an owner nobody can prove dead wedges every bank mutation until someone deletes the
# directory by hand. The release path is stubbed out to model exactly that death.
new_env locksh_mutex >/dev/null
( source "$AB_DIR/lib.sh"; ensure_bank
  # a stale, provably-dead main lock, so acquire_lock takes the reclaim branch
  python3 - "$BANK_DIR" <<'PY'
import subprocess, os, sys
p = subprocess.Popen(["true"]); p.wait()
ld = os.path.join(sys.argv[1], ".lock"); os.makedirs(ld, exist_ok=True)
open(os.path.join(ld, "owner"), "w").write(f"{p.pid} tok long-gone-start\n")
os.utime(ld, (0, 0))
PY
  _proc_starttime() { echo ""; }              # persistent ps failure
  _release_reclaim_mutex() { :; }             # we die before releasing the mutex
  LOCK_TOKEN=""; acquire_lock 2 >/dev/null 2>&1
  # Nothing may have been published that a later contender cannot prove dead.
  if [ -f "$BANK_DIR/.lock.reclaim/owner" ]; then
    start="$(cut -d' ' -f3- "$BANK_DIR/.lock.reclaim/owner" | tr -d ' \n')"
    [ -n "$start" ] || exit 1                 # empty start-time == unreclaimable mutex
  fi
  exit 0 )
assert_eq 0 "$?" "lib.sh never publishes a reclaim-mutex owner with an empty start-time (r15 #8)"

# The Python half of the same lock must behave identically (they share the on-disk format).
AB_DIR="$AB_DIR" python3 - "$BANK_DIR" <<'PY'
import os, subprocess, sys
sys.path.insert(0, os.environ["AB_DIR"])
import banklock
bd = sys.argv[1]
ld = os.path.join(bd, ".lock")
p = subprocess.Popen(["true"]); p.wait()
os.makedirs(ld, exist_ok=True)
open(os.path.join(ld, "owner"), "w").write(f"{p.pid} tok long-gone-start\n")
os.utime(ld, (0, 0))
lk = banklock.BankLock(bd)
banklock._proc_starttime = lambda pid: ""          # persistent ps failure
# With no provable start-time the mutex must not be taken at all: the attempt backs off
# (the outer acquire loop retries) instead of publishing an owner nobody could disprove.
# Before the fix this published "pid token " and went on to reclaim the main lock, so the
# return value is what discriminates the two behaviours.
assert lk._try_reclaim_stale() is False, "reclaim proceeded without a provable start-time"
assert not os.path.exists(os.path.join(bd, ".lock.reclaim")), "left a mutex behind"
assert os.path.isdir(ld), "reclaimed the main lock under an unprovable mutex"
print("PYOK")
PY
assert_eq 0 "$?" "banklock.py never publishes a reclaim-mutex owner with an empty start-time (r15 #8)"

finish "lock_shared"
