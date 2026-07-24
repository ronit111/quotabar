#!/usr/bin/env python3
"""banklock.py — the ONE Python implementation of the token-owned bank lock,
byte-for-byte compatible with lib.sh's mkdir lock so shell and Python contend for
the same directory correctly.

Consolidated here so every Python entrypoint (usage.py, reconcile.py,
isolated_refresh.py) locks identically and every lock fix lands once:
  - finding #3  : the owner record carries the holder's process START TIME, so a
                  reused PID cannot masquerade as a live holder forever.
  - finding #30 : if we win the mkdir but fail to write the owner record, we
                  remove the just-created dir instead of leaking an ownerless lock.
  - stale reclaim: only when age > 5 min AND the holder is provably dead, via
                  rename-away-then-verify (one contender wins the atomic rename).

Usage:
    import banklock
    lk = banklock.BankLock(BANK_DIR)
    if not lk.acquire(timeout=8):
        ... # contended
    try:
        ...
    finally:
        lk.release()
"""
import os
import subprocess
import tempfile
import time

LOCK_STALE_SECS = 300
# (r3 #16) the reclaim mutex is held only for microseconds around a rename, so any
# instance older than this is definitively abandoned by a dead reclaimer. Kept far
# above any legitimate hold, well below the main-lock stale window.
RECLAIM_STALE_SECS = 30


def _proc_starttime(pid):
    """A stable per-process start-time token (macOS `ps lstart`), or "" if the pid
    is gone / ps fails / the process is a ZOMBIE. Used to detect PID reuse (finding
    #3). (r6 b4) a zombie still reports lstart but is DEAD for every purpose we have,
    so it must NOT read as a live matching start-time — return "" so owner_provably_dead
    routes it through the zombie->DEAD branch (mirrors sessions._proc_start)."""
    try:
        out = subprocess.run(["ps", "-o", "stat=,lstart=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=3).stdout
        parts = out.split()
        if not parts or parts[0].startswith("Z"):
            return ""
        return " ".join(parts[1:])
    except Exception:
        return ""


def _is_zombie(pid):
    """(r6 b4) True iff the pid is a reaped-but-not-waited zombie (ps stat starts 'Z').
    A zombie exists to kill(0) but is DEAD (holds no lease, writes nothing). False on
    any probe failure (UNKNOWN — never presumed dead)."""
    try:
        r = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                           capture_output=True, text=True, timeout=3)
    except Exception:
        return False
    return r.returncode == 0 and r.stdout.strip().startswith("Z")


def _kill0_state(pid):
    """(r5 item 2 / r6 b4) POSITIVE process-existence probe via kill(pid,0):
       'DEAD'    — ESRCH: the pid provably does not exist.
       'ALIVE'   — the pid exists (EPERM = alive under another uid, or success).
       'UNKNOWN' — any other error, OR a malformed/non-positive pid: state cannot be
                   determined and is NEVER treated as dead (matches lib.sh, which rejects
                   a non-numeric/empty pid as UNKNOWN rather than reclaiming it)."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return "UNKNOWN"
    if pid <= 0:
        return "UNKNOWN"                   # (r6 b4) malformed/non-positive -> fail-closed
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "DEAD"
    except PermissionError:
        return "ALIVE"
    except OSError:
        return "UNKNOWN"
    return "ALIVE"


def verify_caller_holds(bank_dir):
    """(r12 #11) True IFF the caller genuinely holds the bank lock: the on-disk owner
    token (field 1 of <bank_dir>/.lock/owner, format 'pid token start...') matches the
    token the lock-holder exported as ACCOUNT_BANK_LOCK_TOKEN, AND the owner is not
    provably dead. A process that merely sets ACCOUNT_BANK_HOLDS_LOCK=1 without holding
    the lock does not know the token and fails. Fail-closed on any read/parse error.

    Callers use this to decide whether to TRUST ACCOUNT_BANK_HOLDS_LOCK (skip re-acquiring
    the non-reentrant lock) — when it returns False they must acquire the lock themselves,
    so a lying caller can never mutate without a real physical lock."""
    tok = os.environ.get("ACCOUNT_BANK_LOCK_TOKEN", "")
    if not tok:
        return False
    owner = os.path.join(bank_dir, ".lock", "owner")
    try:
        parts = open(owner).read().split()
    except OSError:
        return False
    if len(parts) < 2 or parts[1] != tok:
        return False
    return not owner_provably_dead(owner, start_from=2)


def owner_provably_dead(owner_path, start_from):
    """(r5 items 1/6) True ONLY on POSITIVE death of a READABLE owner record:
       * the recorded pid is gone (kill(pid,0) -> ESRCH), OR
       * the pid is alive but a recorded start-time PROVES PID reuse.
    An unreadable/ownerless record, an unparseable pid, a missing start-time, an EPERM/
    UNKNOWN probe, or a `ps` that cannot report a start-time all yield UNKNOWN -> False
    (NEVER reclaimed). `start_from` is the field index where the multi-word start-time
    begins (1 for a 'pid start...' record, 2 for a 'pid token start...' record)."""
    try:
        parts = open(owner_path).read().split()
        opid = int(parts[0])
    except Exception:
        return False                       # unreadable/ownerless/unparseable -> UNKNOWN
    ostart = " ".join(parts[start_from:]) if len(parts) > start_from else ""
    state = _kill0_state(opid)
    if state == "DEAD":
        return True
    if state != "ALIVE":
        return False                       # UNKNOWN -> never reclaim
    if not ostart:
        return False                       # alive, no recorded start -> can't prove reuse
    live = _proc_starttime(opid)
    if not live:
        # (r6 b4) kill(0) said the pid exists but no live start-time: distinguish a
        # ZOMBIE (dead — reap it) from a transient ps failure (UNKNOWN — never reclaim).
        if _is_zombie(opid):
            return True                    # zombie -> provably dead
        return False                       # ps failed to report -> UNKNOWN
    return live != ostart                  # start-time mismatch -> pid reused -> dead


def reclaim_dir_if_dead(dirpath, start_from):
    """(r5 items 1/6) Reclaim a stale lock/mutex directory SAFELY via
    RENAME-FIRST-VERIFY-INSIDE: rename the dir away atomically (exactly ONE contender
    wins the rename), then verify the owner is provably dead INSIDE the renamed copy that
    no other process can touch, then delete (dead) or restore (unexpectedly not dead).
    This binds the deletion to the exact inspected instance — a successor created at the
    original path between a separate inspection and a delete can never be destroyed.
    POSITIVE-death-only: an ownerless/unreadable/live owner is never reclaimed. Returns
    True iff the dir was removed (the caller may retry its mkdir)."""
    import shutil
    # cheap pre-check at the original path so we never rename a live/unknown dir away.
    if not owner_provably_dead(os.path.join(dirpath, "owner"), start_from):
        return False
    stolen = f"{dirpath}.stealing.{os.getpid()}.{os.urandom(6).hex()}"
    try:
        os.rename(dirpath, stolen)
    except OSError:
        return False                       # lost the atomic race (gone/renamed) -> retry
    # we now EXCLUSIVELY own `stolen`; re-verify death on the renamed copy before destroying.
    if owner_provably_dead(os.path.join(stolen, "owner"), start_from):
        shutil.rmtree(stolen, ignore_errors=True)
        return True
    # (r6 b1) NOT provably dead on the frozen copy (a transient UNKNOWN probe, or — via a
    # pre-check/rename ABA — a live owner that replaced the dead one between our pre-check
    # and rename). We MUST NOT: (a) delete `stolen` (it may hold a LIVE owner), nor
    # (b) clobber a fresh acquirer that may have mkdir'd the now-free original path
    # (POSIX rename silently REPLACES an empty destination dir). So restore ONLY into a
    # still-absent original path; if a fresh acquirer already holds it, leave `stolen` as
    # inert, uniquely-named debris — it blocks no acquisition and, being token-owned,
    # cannot be stomped on any holder's release. Debris is the accepted fail-closed cost;
    # destroying a non-dead lock or a fresh acquirer is not.
    try:
        if not os.path.exists(dirpath):
            os.rename(stolen, dirpath)
    except OSError:
        pass                               # lost the restore race -> keep debris, never delete
    return False


class BankLock(object):
    __slots__ = ("bank_dir", "lock_dir", "owner", "reclaim_dir", "token")

    def __init__(self, bank_dir):
        self.bank_dir = bank_dir
        self.lock_dir = os.path.join(bank_dir, ".lock")
        self.owner = os.path.join(self.lock_dir, "owner")
        # reclaim MUTEX (re-review issue 1): stale reclamation runs under this so
        # two contenders can never both rename the lock away — the ABA race where
        # one contender deletes a lock a second contender just freshly acquired.
        self.reclaim_dir = os.path.join(bank_dir, ".lock.reclaim")
        self.token = None

    def acquire(self, timeout=10):
        os.makedirs(self.bank_dir, exist_ok=True)
        tok = f"{os.getpid()}-{os.urandom(8).hex()}"
        waited = 0
        while True:
            try:
                os.mkdir(self.lock_dir)
            except FileExistsError:
                if self._try_reclaim_stale():
                    continue
                if waited >= timeout:
                    return False
                time.sleep(1); waited += 1
                continue
            # we created the lock dir; write the owner record atomically. On ANY
            # failure, remove the dir we just made (finding #30) rather than leak
            # an ownerless lock that normal release can never remove.
            # (r14 #4) the owner record MUST carry a provable start-time. A transient ps
            # failure publishing an EMPTY start-time means a future reclaim can never prove
            # this holder dead (nor detect pid reuse) — every later acquisition would then
            # time out forever. Retry (r13 #5 discipline); if still empty, tear down the lock
            # dir we just made and fail transiently rather than publish an unprovable owner.
            _pstart = ""
            for _ in range(4):
                _pstart = _proc_starttime(os.getpid())
                if _pstart:
                    break
                time.sleep(0.05)
            if not _pstart:
                import shutil
                shutil.rmtree(self.lock_dir, ignore_errors=True)
                return False
            try:
                fd, tmp = tempfile.mkstemp(dir=self.lock_dir, prefix=".own.")
                with os.fdopen(fd, "w") as f:
                    f.write(f"{os.getpid()} {tok} {_pstart}")
                os.replace(tmp, self.owner)
            except Exception:
                try:
                    import shutil
                    shutil.rmtree(self.lock_dir, ignore_errors=True)
                except Exception:
                    pass
                return False
            self.token = tok
            return True

    def _stale_and_dead(self):
        """The main lock is reclaimable only when it is older than the 5-min stale
        window AND its holder is PROVABLY dead (positive-death via owner_provably_dead;
        the owner record is 'pid token start', so the start-time begins at field 2)."""
        try:
            age = time.time() - os.path.getmtime(self.lock_dir)
        except OSError:
            return False
        if age <= LOCK_STALE_SECS:
            return False
        return owner_provably_dead(self.owner, start_from=2)

    def _reclaim_mutex(self):
        """(r5 item 6) Reclaim an ABANDONED reclaim mutex ONLY via the safe
        rename-first-verify-inside primitive with POSITIVE-death-only owner inspection —
        NO age fallback, NO ownerless/unreadable reclaim. The mutex owner record is
        'pid token start' (start at field 2), matching the main lock's format."""
        return reclaim_dir_if_dead(self.reclaim_dir, start_from=2)

    def _try_reclaim_stale(self):
        """Reclaim a stale main lock SAFELY. Serialized under a reclaim mutex whose own
        abandonment is handled by the safe rename-first primitive. Under the mutex we
        (1) re-verify the main lock is still stale-and-dead, (2) FINALLY re-verify we
        STILL OWN the mutex (own-token check) immediately before the main-lock rename,
        then (3) reclaim the main lock via the same rename-first-verify-inside primitive.
        Returns True if the caller should retry mkdir."""
        if not self._stale_and_dead():
            return False
        mutex_tok = f"{os.getpid()}-{os.urandom(8).hex()}"
        try:
            os.mkdir(self.reclaim_dir)
        except FileExistsError:
            self._reclaim_mutex()          # positive-death-only; retry next pass either way
            return False
        except OSError:
            return False
        mutex_owner = os.path.join(self.reclaim_dir, "owner")
        try:
            fd, tmp = tempfile.mkstemp(dir=self.reclaim_dir, prefix=".own.")
            with os.fdopen(fd, "w") as f:
                f.write(f"{os.getpid()} {mutex_tok} {_proc_starttime(os.getpid())}")
            os.replace(tmp, mutex_owner)
        except Exception:
            import shutil
            shutil.rmtree(self.reclaim_dir, ignore_errors=True)
            return False
        try:
            if not os.path.isdir(self.lock_dir):
                return True                # already gone -> caller retries mkdir
            if not self._stale_and_dead():
                return False               # a fresh, live lock now sits here -> leave it
            # (r5 item 6) FINAL own-token verification immediately before the rename: if
            # our mutex was somehow taken over, abort rather than reclaim under a lost mutex.
            try:
                cur = open(mutex_owner).read().split()
            except OSError:
                cur = []
            if len(cur) < 2 or cur[1] != mutex_tok:
                return False
            return reclaim_dir_if_dead(self.lock_dir, start_from=2)
        finally:
            # tear down OUR mutex only (own-token bound), via the safe rename-away.
            try:
                cur = open(mutex_owner).read().split()
            except OSError:
                cur = []
            if len(cur) >= 2 and cur[1] == mutex_tok:
                import shutil
                gone = f"{self.reclaim_dir}.done.{os.getpid()}.{os.urandom(4).hex()}"
                try:
                    os.rename(self.reclaim_dir, gone)
                    shutil.rmtree(gone, ignore_errors=True)
                except OSError:
                    # (r6 b2) the protective rename-away failed: NEVER fall back to an
                    # rmtree at the LIVE original path — a contender may already have
                    # replaced our mutex there, and deleting it would break their hold.
                    # Leave it; once we exit it is a provably-dead-owner mutex and the
                    # rename-first reclaim primitive removes it safely on a later pass.
                    pass

    def release(self):
        if not self.token:
            return
        try:
            parts = open(self.owner).read().split()
            cur_tok = parts[1] if len(parts) > 1 else None
        except Exception:
            cur_tok = None
        if cur_tok == self.token:
            import shutil
            shutil.rmtree(self.lock_dir, ignore_errors=True)
            self.token = None
