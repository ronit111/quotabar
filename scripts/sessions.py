#!/usr/bin/env python3
"""sessions.py — session registry, lifecycle state, and restart leases
(ISOLATION-DESIGN.md rev 6 §0/§13).

State store: accounts/sessions.json (records keyed by session-id, per-record
generation, tombstones), serialized under a sessions lock (banklock at
accounts/.sessions.lock/). Lifecycle events come from the SHARED hooks:

    SessionStart      -> register {home, cwd, pid, proc-start-time, transcript}
    UserPromptSubmit  -> state=BUSY   (BLOCKED with a message while a RESTARTING
                                       lease is held for that session; the hook
                                       itself exits blocking if BUSY cannot be
                                       persisted — fail-closed, r6)
    Notification idle_prompt -> state=IDLE   (the ONLY authoritative idle edge —
                                       Stop is advisory: a parallel Stop hook can
                                       continue the turn, r6)
    Stop              -> recorded (advisory; state stays BUSY)
    SessionEnd        -> tombstone

Restart lease: atomic mkdir accounts/sessions/<id>.lease/ + owner record. Restart
and prompt admission contend for the same lease; IDLE→RESTARTING while held.

CLI (called from hook scripts and QuotaBar):
    sessions.py event <acc> <kind> <session-id> [json-payload-on-stdin]
    sessions.py list <acc>                  -> live records JSON
    sessions.py lease-acquire <acc> <id>    -> 0 acquired / 1 held
    sessions.py lease-release <acc> <id>
    sessions.py prompt-gate <acc> <id>      -> 0 allow / 2 BLOCK (restarting)
stdlib only.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import banklock

STORE = "sessions.json"
LOCK_DIRNAME = ".sessions.lock"
LEASE_STALE_S = 300

# (finding 14) session-ids become filesystem paths (journals, leases) — they MUST be
# canonical UUIDs or a crafted id with path separators escapes accounts/sessions/.
_SID_RE = re.compile(
    r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z")


def valid_sid(sid):
    return isinstance(sid, str) and bool(_SID_RE.match(sid))


def _require_sid(sid):
    if not valid_sid(sid):
        raise ValueError(f"invalid session-id (must be a UUID): {sid!r}")
    return sid


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _proc_start(pid):
    """Process start-time token, or "" when the pid is gone OR a ZOMBIE — ps still
    reports lstart for zombies, but a zombie is dead for every purpose we have
    (it can hold no lease, write no transcript, own no session)."""
    try:
        out = subprocess.run(["ps", "-o", "stat=,lstart=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=3).stdout
        parts = out.split()
        if not parts or parts[0].startswith("Z"):
            return ""
        return " ".join(parts[1:])
    except Exception:
        return ""


def _proc_state(pid, expected_start=None):
    """(r5 item 2) THREE-VALUED process state — never conflates "provably absent" with
    "probe failed":
       'DEAD'    — kill(pid,0) -> ESRCH (gone), a zombie, or a proven start-time mismatch
                   (pid reused); the original process is provably gone.
       'ALIVE'   — the pid exists and (when expected_start given) its start-time matches.
       'UNKNOWN' — the state cannot be determined (EPERM without proof, ps failure, an
                   alive pid whose start-time we cannot read). NEVER treated as death.
    Restart's STOPPED transition and recovery's death checks require DEAD and treat
    UNKNOWN as fail-closed (retry, then ABORT/BLOCK — never spawn)."""
    st = banklock._kill0_state(pid)
    if st == "DEAD":
        return "DEAD"
    if st == "UNKNOWN":
        return "UNKNOWN"
    cur = _proc_start(pid)                 # "" for a zombie OR a ps failure
    if cur == "":
        try:
            r = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                               capture_output=True, text=True, timeout=3)
        except Exception:
            return "UNKNOWN"
        stat = r.stdout.strip()
        if r.returncode != 0 or stat == "":
            return "UNKNOWN"               # ps couldn't report -> unknown, not dead
        if stat.startswith("Z"):
            return "DEAD"                  # zombie -> dead for every purpose we have
        return "UNKNOWN"                   # alive but unreadable start-time -> unknown
    # (r8 #2) an EMPTY expected start-time is UNKNOWN, never a token to diff against. A
    # transient ps failure at SessionStart records proc_start="" for a live pid; comparing
    # a real nonempty `cur` against "" would falsely read the LIVE predecessor as DEAD
    # (pid-reuse), so restart would skip its SIGTERM and spawn a concurrent successor. With
    # no baseline we cannot prove reuse — fall back to bare existence (the pid is ALIVE).
    if expected_start not in (None, "") and cur != expected_start:
        return "DEAD"                      # start-time mismatch -> pid reused -> gone
    return "ALIVE"


def _lock(acc):
    lk = banklock.BankLock(acc)
    lk.lock_dir = os.path.join(acc, LOCK_DIRNAME)
    lk.owner = os.path.join(lk.lock_dir, "owner")
    lk.reclaim_dir = os.path.join(acc, LOCK_DIRNAME + ".reclaim")
    return lk


def _load(acc):
    p = os.path.join(acc, STORE)
    if not os.path.exists(p):
        return {}
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        # a torn store is rebuilt from live hooks; losing display state is safe,
        # losing a LEASE is not — leases live on the filesystem, not in here.
        return {}


def _save(acc, d):
    fd, tmp = tempfile.mkstemp(dir=acc, prefix=".sessions.")
    with os.fdopen(fd, "w") as f:
        json.dump(d, f)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(acc, STORE))
    _fsync_dir(acc)   # (finding 15) durably commit the rename (a reported BUSY edge
    #                    must survive power loss — the write-ahead/durable contract)


def record_event(acc, kind, sid, payload=None):
    """Serialized under the sessions lock. Unknown kinds are an error."""
    if kind not in ("start", "prompt", "idle", "stop", "end"):
        raise ValueError(f"unknown event kind {kind!r}")
    _require_sid(sid)   # (finding 14) reject non-UUID ids before any store write
    lk = _lock(acc)
    if not lk.acquire(timeout=8):
        raise RuntimeError("sessions lock contended")
    try:
        d = _load(acc)
        # (r12 #10) a lifecycle event for a sid with NO prior SessionStart must NOT fabricate
        # an authoritative record. A FAILED start hook followed by idle_prompt would otherwise
        # create a home-less / pid-less IDLE record that live_sessions() retains and restart.py
        # accepts as a restart candidate — a broken transition on a session that never existed.
        # Only `start` may create a record; every other kind on an unknown sid is ignored.
        if kind != "start" and sid not in d:
            sys.stderr.write(f"sessions: ignoring {kind} for unregistered sid {sid} (no SessionStart)\n")
            return {"generation": 0}
        rec = d.get(sid) or {"generation": 0}
        # (r3 IB3) bind lifecycle mutations to the registered pid: a DELAYED predecessor
        # event (idle/end/prompt/stop, originating from the OLD process) must NOT mutate
        # or tombstone the CURRENT (successor) record — that could mark an active
        # successor IDLE (restartable) or tombstone it. The hook passes its PPID (the
        # claude process) as the event's originating pid; a mismatch => ignore + log.
        if kind in ("prompt", "idle", "stop", "end") and isinstance(payload, dict):
            ev_pid = payload.get("pid")
            reg_pid = rec.get("pid")
            if ev_pid is not None and reg_pid is not None and ev_pid != reg_pid:
                sys.stderr.write(
                    f"sessions: ignoring {kind} for {sid} from pid {ev_pid} "
                    f"(registered pid {reg_pid}); delayed predecessor event\n")
                return rec
        rec["generation"] += 1
        now = int(time.time())
        if kind == "start":
            payload = payload or {}
            pid = payload.get("pid")
            # (r8 #2) the SessionStart pid is the just-launched claude process (alive); a
            # bare _proc_start() can still transiently fail and record "" — a poisoned
            # token that later reads as DEAD. Retry a few times to capture the real
            # start-time; a persistent "" is now safely handled downstream (empty ==
            # UNKNOWN, never DEAD) but recording the real token is strictly better.
            pstart = ""
            if pid:
                for _ in range(4):
                    pstart = _proc_start(pid)
                    if pstart:
                        break
                    time.sleep(0.05)
            rec.update({
                "home": payload.get("home", ""), "cwd": payload.get("cwd", ""),
                "pid": pid, "proc_start": pstart,
                "transcript": payload.get("transcript", ""),
                # (finding 7) a fresh session is BUSY until idle_prompt fires — a
                # missing/failed idle notification must NEVER leave it restartable
                # (§0/§13: IDLE is a TRACKED edge, never inferred from registration).
                "state": "BUSY", "tombstone": False, "registered": now,
            })
        elif kind == "prompt":
            rec["state"] = "BUSY"
        elif kind == "idle":
            rec["state"] = "IDLE"          # idle_prompt notification (authoritative)
        elif kind == "stop":
            rec["last_stop"] = now         # advisory only (r6): Stop can be overridden
        elif kind == "end":
            rec["tombstone"] = True
            rec["state"] = "ENDED"
        rec["updated"] = now
        d[sid] = rec
        _save(acc, d)
        return rec
    finally:
        lk.release()


def live_sessions(acc):
    """Non-tombstoned records whose {pid, proc-start-time} still match a live
    process; dead ones are tombstoned as a side effect (the liveness sweeper)."""
    lk = _lock(acc)
    if not lk.acquire(timeout=8):
        return {}
    try:
        d = _load(acc)
        changed = False
        for sid, rec in d.items():
            if rec.get("tombstone"):
                continue
            pid, ps = rec.get("pid"), rec.get("proc_start", "")
            # (r6 b5) three-valued liveness: tombstone ONLY on POSITIVE death. A transient
            # UNKNOWN (ps failure / EPERM) must NEVER evict a live session — the old boolean
            # `_proc_start(pid) == ps` read a probe failure as death and killed live
            # records. With a recorded start-time we also prove pid-reuse; WITHOUT one we
            # fall back to a bare existence probe (expected_start=None) so a genuinely gone
            # pid is still swept, while an alive/unprobeable one is left in place.
            dead = bool(pid) and _proc_state(pid, ps if ps != "" else None) == "DEAD"
            if dead:
                rec["tombstone"] = True
                rec["state"] = "DEAD"
                rec["generation"] = rec.get("generation", 0) + 1
                changed = True
        if changed:
            _save(acc, d)
        return {sid: r for sid, r in d.items() if not r.get("tombstone")}
    finally:
        lk.release()


# ---- leases (banklock ABA-safe protocol; the store is display state, lease = truth) ---
# The per-session restart lease reuses banklock's rename/reclaim-mutex protocol
# (r2 findings 9/10/13): acquisition is a token-owned mkdir; reclaim of a stale lease
# is serialized under a reclaim mutex and re-verified (no two contenders can both
# reclaim the same lease); release is TOKEN-bound in-process and TRANSACTION-bound in
# recovery (a dead controller's lease is force-released only when the on-disk owner
# still matches the recovering controller's identity — never a newer owner).
# (banklock is imported at module top; reused here for RECLAIM_STALE_SECS.)

_HELD_LEASE_TOKENS = {}     # sid -> token this process holds (for token-bound release)


def _lease_dir(acc, sid):
    return os.path.join(acc, "sessions", f"{_require_sid(sid)}.lease")   # (finding 14)


def _lease_reclaim_dir(acc, sid):
    return _lease_dir(acc, sid) + ".reclaim"


def _lease_owner(acc, sid):
    try:
        with open(os.path.join(_lease_dir(acc, sid), "owner")) as f:
            return json.load(f)
    except Exception:
        return None


def _lease_owner_dead(acc, sid):
    """(r5 item 2) POSITIVE-death only via the three-valued _proc_state: True ONLY when
    the recorded owner is provably DEAD (pid gone / zombie / start-time proves reuse). An
    unreadable owner, a missing start-time, an EPERM/UNKNOWN probe, or a ps failure all
    yield NOT-dead — never reclaimed."""
    own = _lease_owner(acc, sid)
    if own is None:
        return False
    ps = own.get("proc_start", "")
    if not ps:
        return False
    return _proc_state(own.get("pid", -1), ps) == "DEAD"


def _restart_journal_reclaimable(acc, sid):
    """(finding 9) A stale lease may be reclaimed ONLY when no restart transaction is
    mid-flight. A present, non-terminal restart journal means recovery — not a blind
    reclaim — must adjudicate. Absent journal => reclaimable. Corrupt/unreadable =>
    fail closed (NOT reclaimable). Mirrors restart._jread's corrupt≠absent rule."""
    jp = os.path.join(acc, "sessions", f"{sid}.restart.json")
    if not os.path.exists(jp):
        return True
    try:
        with open(jp) as f:
            j = json.load(f)
    except Exception:
        return False           # present-but-corrupt -> fail closed
    return j.get("phase") in ("REGISTERED", "ABORTED")


# (r5 item 9) expose the mutex-death predicate for tests; delegates to the shared
# positive-death-only primitive (owner format "pid token start", start at field 2).
def _reclaim_mutex_dead(rd):
    return banklock.owner_provably_dead(os.path.join(rd, "owner"), start_from=2)


def _reclaim_stale_lease(acc, sid):
    """(r5 item 1) Reclaim a provably-dead lease under the RENAME-FIRST-VERIFY-INSIDE
    discipline, so deletion is always bound to the exact inspected instance:
      * the per-lease reclaim MUTEX is reclaimed (when abandoned) ONLY via
        banklock.reclaim_dir_if_dead (rename-away-verify-inside, positive-death-only,
        no age fallback) — never a delete at the original path after a separate probe;
      * under the mutex we FINALLY re-verify we still own it (own-token check), then
        reclaim the LEASE itself via the same rename-first primitive.
    Returns True iff the lease was removed and the caller may retry its mkdir."""
    if not _lease_owner_dead(acc, sid):
        return False
    rd = _lease_reclaim_dir(acc, sid)
    my_tok = f"{os.getpid()}-{os.urandom(8).hex()}"
    try:
        os.mkdir(rd)
    except FileExistsError:
        # reclaim the mutex ONLY via the safe rename-first primitive (positive-death-only,
        # no age fallback, deletion bound to the renamed instance).
        banklock.reclaim_dir_if_dead(rd, start_from=2)
        return False
    except OSError:
        return False
    mutex_owner = os.path.join(rd, "owner")
    tmp = None
    try:
        # owner format: "<pid> <token> <proc_start...>" (token at fixed index 1). (r6 b3)
        # if we cannot durably write our owner record, the mutex dir we just created would
        # be left OWNERLESS — and ownerless reclaim now (correctly) fails closed, so it
        # would wedge every future reclaimer forever. We exclusively own `rd` (just
        # mkdir'd, no owner yet), so tear OUR OWN just-created dir down wholesale and bail.
        try:
            fd, tmp = tempfile.mkstemp(dir=rd, prefix=".own.")
            with os.fdopen(fd, "w") as f:
                f.write(f"{os.getpid()} {my_tok} {_proc_start(os.getpid())}")
            os.replace(tmp, mutex_owner)
        except Exception:
            import shutil
            if tmp is not None:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
            shutil.rmtree(rd, ignore_errors=True)
            return False
        ld = _lease_dir(acc, sid)
        if not os.path.isdir(ld):
            return True                            # already gone -> caller retries
        if not _lease_owner_dead(acc, sid):
            return False                           # a fresh live lease -> do NOT touch
        # (r5 item 1) FINAL own-token verification immediately before the lease rename.
        try:
            cur = open(mutex_owner).read().split()
        except OSError:
            cur = []
        if len(cur) < 2 or cur[1] != my_tok:
            return False
        # reclaim the LEASE via the same rename-first-verify-inside primitive. The lease
        # owner is JSON, so we do the rename here (the lease death was verified above) —
        # rename is atomic, so exactly one contender wins even without the mutex.
        stolen = f"{ld}.stale.{os.getpid()}.{os.urandom(4).hex()}"
        try:
            os.rename(ld, stolen)
        except OSError:
            return False
        if _proc_state_of_lease_owner_dead(stolen):
            import shutil
            shutil.rmtree(stolen, ignore_errors=True)
            return True
        # (r6 b1) NOT provably dead on the frozen copy: NEVER delete `stolen` (it may hold
        # a LIVE lease owner) and NEVER clobber a fresh acquirer that re-mkdir'd `ld`
        # (POSIX rename silently REPLACES an empty destination dir). Restore only into a
        # still-absent path; otherwise leave `stolen` as inert, uniquely-named debris — it
        # blocks no acquisition and, being token-owned, cannot be stomped on release.
        try:
            if not os.path.exists(ld):
                os.rename(stolen, ld)
        except OSError:
            pass
        return False
    finally:
        # tear down OUR mutex only (own-token bound) via a rename-away, not a raw rmtree
        # at the original path — so we never delete a contender's mutex.
        try:
            cur = open(mutex_owner).read().split()
        except OSError:
            cur = []
        if len(cur) >= 2 and cur[1] == my_tok:
            import shutil
            gone = f"{rd}.done.{os.getpid()}.{os.urandom(4).hex()}"
            try:
                os.rename(rd, gone)
                shutil.rmtree(gone, ignore_errors=True)
            except OSError:
                # (r6 b2) the rename-away failed: NEVER fall back to an rmtree at the LIVE
                # original path — a contender may already hold our mutex path. Leave it;
                # once we exit it is a provably-dead-owner mutex the rename-first reclaim
                # primitive removes safely on a later pass.
                pass


def _proc_state_of_lease_owner_dead(lease_dir):
    """Death check for a lease owner record inside a specific (possibly renamed) dir."""
    try:
        with open(os.path.join(lease_dir, "owner")) as f:
            own = json.load(f)
    except Exception:
        return False
    ps = own.get("proc_start", "")
    if not ps:
        return False
    return _proc_state(own.get("pid", -1), ps) == "DEAD"


def lease_acquire(acc, sid, txn=None):
    """Acquire the session's restart lease. Token-owned; a stale (provably-dead-owner)
    lease is reclaimed ABA-safely, and never while a non-terminal restart journal is
    mid-flight (finding 9). The controller identity is recorded so recovery can bind
    a force-release to exactly this owner (finding 10)."""
    _require_sid(sid)
    sd = os.path.join(acc, "sessions")
    os.makedirs(sd, exist_ok=True)
    _fsync_dir(acc)            # (finding 15) durably root the new sessions/ dir entry
    ld = _lease_dir(acc, sid)
    try:
        os.mkdir(ld)
    except FileExistsError:
        if not _restart_journal_reclaimable(acc, sid):
            return False
        if not _reclaim_stale_lease(acc, sid):
            return False
        try:
            os.mkdir(ld)
        except OSError:
            return False
    except OSError:
        return False
    # (r13 #5) the lease owner's start-time is what recovery uses to PROVE the owner dead. A
    # transient ps failure recording an EMPTY start-time would make a later recovery unable to
    # prove the (dead) controller gone — permanently lease-blocking the session. Retry (r8 #2
    # discipline); if still empty, REFUSE to acquire with an unprovable identity — tear down the
    # lease dir we mkdir'd and fail transiently so the caller retries.
    _ps = ""
    for _ in range(4):
        _ps = _proc_start(os.getpid())
        if _ps:
            break
        time.sleep(0.05)
    if not _ps:
        import shutil
        shutil.rmtree(ld, ignore_errors=True)
        return False
    tok = f"{os.getpid()}-{os.urandom(8).hex()}"
    rec = {"pid": os.getpid(), "proc_start": _ps,
           "token": tok, "txn": txn, "ts": int(time.time())}
    try:
        fd, tmp = tempfile.mkstemp(dir=ld, prefix=".own.")
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f)
            f.flush()
            os.fsync(f.fileno())               # (finding 13) fsync lease ownership
        os.replace(tmp, os.path.join(ld, "owner"))
        _fsync_dir(ld)
        _fsync_dir(sd)   # (r3 MINOR1) durably root the new lease DIR entry under sessions/
    except Exception:
        # (r6 b3) the owner write failed -> `ld` would be OWNERLESS, and ownerless reclaim
        # now fails closed, wedging this lease forever. `os.rmdir` cannot remove it while
        # the mkstemp temp still sits inside; rmtree OUR OWN just-created lease dir whole.
        import shutil
        shutil.rmtree(ld, ignore_errors=True)
        return False
    _HELD_LEASE_TOKENS[sid] = tok
    return True


def lease_release(acc, sid, force=False, expect_pid=None, expect_start=None, expect_txn=None):
    """Release the lease. Precedence:
      1. TOKEN-bound: if this process holds the lease token, remove it.
      2. force + expect_pid/start[/txn] (recovery): TRANSACTION-bound — remove ONLY if
         the current on-disk owner still matches the expected controller's FULL identity
         (pid + proc-start AND, when given, the transaction id) AND is provably dead
         (never a newer owner; finding 10 / r4 blocker 2), via the ABA-safe reclaim.
      3. force without an expectation (orphan lease): reclaim only a provably-dead
         owner, ABA-safe.
      4. non-force, non-owner: reclaim a provably-dead owner ABA-safely; a LIVE foreign
         owner is never torn down.
    Returns True iff the lease was removed."""
    ld = _lease_dir(acc, sid)
    own = _lease_owner(acc, sid)
    tok = _HELD_LEASE_TOKENS.get(sid)
    if own is not None and tok is not None and own.get("token") == tok:
        _HELD_LEASE_TOKENS.pop(sid, None)
        import shutil
        shutil.rmtree(ld, ignore_errors=True)
        return True
    if force and own is not None and expect_pid is not None:
        # (r4 blocker 2) transaction-bound: a DIFFERENT (newer) owner — different pid,
        # start-time, OR transaction id — is never released by an old recovery. The txn
        # comparison closes the pid-reuse-within-the-same-window gap that pid+start alone
        # leaves open.
        if own.get("pid") != expect_pid or own.get("proc_start", "") != expect_start:
            return False
        if expect_txn is not None and own.get("txn") != expect_txn:
            return False
    # everything else may only reclaim a PROVABLY-DEAD owner, ABA-safely.
    return _reclaim_stale_lease(acc, sid)


def lease_held(acc, sid):
    return os.path.isdir(_lease_dir(acc, sid))


# ---- atomic prompt admission + restart transition (findings 8/34) ------------
def prompt_admit(acc, sid, ev_pid=None):
    """(finding 8) UserPromptSubmit admission, ATOMIC under the sessions lock: if a
    RESTARTING lease is held for this session, BLOCK (return False); otherwise record
    BUSY and admit (return True). Because the lease check and the BUSY write happen
    under the same lock that set_restarting takes, restart can never slip its
    IDLE->RESTARTING transition between a prompt's check and its BUSY write.
    (r3 IB3) a prompt whose originating pid does not match the registered record is a
    delayed predecessor event — admit it as a no-op (never mutate the successor)."""
    _require_sid(sid)
    lk = _lock(acc)
    if not lk.acquire(timeout=8):
        raise RuntimeError("sessions lock contended")
    try:
        if lease_held(acc, sid):
            return False
        d = _load(acc)
        # (r13 #4) NO path but `start` may create a record — same class as r12 #10, this is the
        # direct prompt_admit path. A prompt for a sid with no prior SessionStart (a failed-start
        # race) must NOT fabricate a pid-less BUSY record: live_sessions can never sweep it (no
        # pid) and restart.py would treat it as an authoritative candidate. Admit as a no-op (the
        # session runs untracked; with no registry entry no restart can target it).
        if sid not in d:
            return True
        rec = d.get(sid) or {"generation": 0}
        reg_pid = rec.get("pid")
        if ev_pid is not None and reg_pid is not None and ev_pid != reg_pid:
            sys.stderr.write(
                f"sessions: ignoring prompt for {sid} from pid {ev_pid} "
                f"(registered pid {reg_pid}); delayed predecessor event\n")
            return True   # no-op admit; do not set the successor BUSY from a stale prompt
        rec["generation"] = rec.get("generation", 0) + 1
        rec["state"] = "BUSY"
        rec["updated"] = int(time.time())
        d[sid] = rec
        _save(acc, d)
        return True
    finally:
        lk.release()


def set_restarting(acc, sid, expect_pid, expect_start, expect_gen):
    """(findings 8/12/34) Under the sessions lock: verify the record is STILL the exact
    IDLE record the controller selected (same pid + proc-start + generation) and flip
    it IDLE->RESTARTING atomically. Returns the record on success, None if it changed
    (a duplicate SessionStart / lifecycle churn replaced it — abort rather than SIGTERM
    the wrong/newer pid). The caller must already hold the lease."""
    _require_sid(sid)
    lk = _lock(acc)
    if not lk.acquire(timeout=8):
        raise RuntimeError("sessions lock contended")
    try:
        d = _load(acc)
        rec = d.get(sid)
        if (not rec or rec.get("tombstone") or rec.get("state") != "IDLE"
                or rec.get("pid") != expect_pid
                or rec.get("proc_start", "") != expect_start
                or rec.get("generation", 0) != expect_gen):
            return None
        rec["generation"] = rec.get("generation", 0) + 1
        rec["state"] = "RESTARTING"
        rec["updated"] = int(time.time())
        d[sid] = rec
        _save(acc, d)
        return rec
    finally:
        lk.release()


def _cli():
    cmd, acc = sys.argv[1], sys.argv[2]
    if cmd == "event":
        kind, sid = sys.argv[3], sys.argv[4]
        payload = None
        if not sys.stdin.isatty():
            raw = sys.stdin.read().strip()
            if raw:
                try:
                    payload = json.loads(raw)
                except ValueError:
                    payload = None
        record_event(acc, kind, sid, payload)
        return 0
    if cmd == "list":
        print(json.dumps(live_sessions(acc), indent=1))
        return 0
    if cmd == "lease-acquire":
        return 0 if lease_acquire(acc, sys.argv[3]) else 1
    if cmd == "lease-release":
        lease_release(acc, sys.argv[3])
        return 0
    if cmd == "lease-held":
        # (r10 #9) report via STDOUT ("held"/"free"), NOT the exit code — so a caller
        # (claude-acct) never confuses a real "held" verdict with python's own exit 2
        # (e.g. a missing sessions.py). Exit 0 on a clean answer.
        print("held" if lease_held(acc, sys.argv[3]) else "free")
        return 0
    if cmd == "lease-gate":
        # (r13 #1) authorization gate for --resume: prints
        #   "free"  — no lease held (any resume may proceed)
        #   "owner" — held AND the supplied token matches the lease owner (the restart
        #             CONTROLLER that owns the lease is launching its authorized resume)
        #   "held"  — held by someone else / no matching token (an UNAUTHORIZED duplicate resume)
        sid = sys.argv[3]
        tok = sys.argv[4] if len(sys.argv) > 4 else ""
        if not lease_held(acc, sid):
            print("free")
            return 0
        own = _lease_owner(acc, sid)
        print("owner" if (own and tok and own.get("token") == tok) else "held")
        return 0
    if cmd == "prompt-gate":
        # exit 2 = hooks' blocking signal (UserPromptSubmit shows stderr to the user)
        if lease_held(acc, sys.argv[3]):
            print("QuotaBar is restarting this session on another account; "
                  "wait a moment (or release via QuotaBar).", file=sys.stderr)
            return 2
        return 0
    if cmd == "prompt-admit":
        # (finding 8) atomic lease-check + BUSY-write. Exit 2 = blocked by a
        # RESTARTING lease; exit 3 = BUSY could not be persisted (fail-closed — the
        # hook wrapper turns 3 into a block with a distinct message); 0 = admitted.
        # (r3 IB3) optional argv[4] = the hook's originating pid (PPID) for binding.
        sid = sys.argv[3]
        ev_pid = None
        if len(sys.argv) > 4:
            try:
                ev_pid = int(sys.argv[4])
            except ValueError:
                ev_pid = None
        try:
            admitted = prompt_admit(acc, sid, ev_pid=ev_pid)
        except Exception:
            return 3
        if not admitted:
            print("QuotaBar is restarting this session on another account; "
                  "wait a moment (or release via QuotaBar).", file=sys.stderr)
            return 2
        return 0
    print(f"sessions.py: unknown command {cmd!r}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(_cli())
