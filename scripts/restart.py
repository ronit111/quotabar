#!/usr/bin/env python3
"""restart.py — the assisted-restart controller (ISOLATION-DESIGN.md rev 8 §0.4).

One restart = one durable journaled transaction at accounts/sessions/<id>.restart.json:

    LEASED -> STOPPING -> STOPPED -> SPAWNED{child pid, proc-start, home}
           -> REGISTERED            (terminal; lease released HERE, never earlier)
    any failure -> ABORTED          (terminal; lease released)

REGISTERED is transaction-bound: the successor's registry entry must carry the SAME
session-id, the journaled expected child pid + proc-start-time, the journaled
target home, and a registry generation newer than the journaled pre-spawn
generation. Stale recovery (recover()) implements rev 8's exhaustive per-phase
rules; every ambiguity remains blocked + operator card.

The spawn callback is injected (QuotaBar opens a terminal; tests use a stub).
stdlib only.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import uuid as uuidlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registry
import sessions

STOP_TIMEOUT_S = 20
SETTLE_QUIET_S = 1.0


class RestartError(Exception):
    pass


def _jpath(acc, sid):
    return os.path.join(acc, "sessions", f"{sessions._require_sid(sid)}.restart.json")  # (finding 14)


def _jwrite(acc, sid, rec):
    d = os.path.join(acc, "sessions")
    existed = os.path.isdir(d)
    os.makedirs(d, exist_ok=True)
    if not existed:
        # (finding 15) the FIRST creation of accounts/sessions/ must fsync the parent
        # accounts/ so the new directory entry itself is durable before the journal.
        pfd = os.open(acc, os.O_RDONLY)
        try:
            os.fsync(pfd)
        finally:
            os.close(pfd)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".rst.")
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, _jpath(acc, sid))
    # (finding 15) durably commit the journal rename — a STOPPED/SPAWNED phase must
    # survive power loss (the durable-journal contract that recovery relies on).
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def _jread(acc, sid):
    """(r2 finding 13) A PRESENT-but-corrupt journal is NOT the same as an absent one:
    it returns {"phase":"CORRUPT"} so recovery blocks (a corrupt post-SPAWN journal
    must never be mistaken for "nothing spawned" and force-released). Absent => None."""
    p = _jpath(acc, sid)
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {"phase": "CORRUPT"}


def _phase(acc, sid, rec, phase, **extra):
    rec["phase"] = phase
    rec["ts"] = int(time.time())
    rec.update(extra)
    _jwrite(acc, sid, rec)


def _proc_start(pid):
    return sessions._proc_start(pid)


def _pstate(pid, proc_start):
    """(r5 item 2) Three-valued: 'ALIVE' | 'DEAD' | 'UNKNOWN' (never conflates a vanished
    process with a probe failure)."""
    return sessions._proc_state(pid, proc_start)


def _alive(pid, proc_start):
    """True ONLY when the process is positively ALIVE with a matching start-time. An
    UNKNOWN state is NOT alive here — callers that need positive death use _dead()."""
    return _pstate(pid, proc_start) == "ALIVE"


def _dead(pid, proc_start):
    """(r5 item 2) POSITIVE death only — UNKNOWN is NOT dead (fail-closed for STOPPED and
    recovery: an unverifiable predecessor/controller is never presumed exited)."""
    return _pstate(pid, proc_start) == "DEAD"


def restart_session(acc, sid, target_email, spawn, stop_timeout=STOP_TIMEOUT_S,
                    reg_timeout=30):
    """Full transaction. `spawn(email, cwd, sid) -> (pid, proc_start)` launches the
    successor (QuotaBar: `claude-acct <email> --resume <sid>` in a terminal at cwd).
    Returns the terminal journal record. Raises RestartError on refusal.
    `reg_timeout` bounds the wait for the successor's transaction-bound registration
    (a parameter so tests can shorten it without monkeypatching the clock)."""
    sessions._require_sid(sid)   # (finding 14) validate before any path/lease use
    target_home = registry.ready_home(acc, target_email)
    if not target_home:
        raise RestartError(f"no READY home for {target_email}")
    live = sessions.live_sessions(acc)
    rec0 = live.get(sid)
    if not rec0:
        raise RestartError("session not in live registry")
    if rec0.get("state") != "IDLE":
        raise RestartError(f"session is {rec0.get('state')}, not IDLE — user-mediated only")
    pre_gen = rec0.get("generation", 0)
    pid0, ps0 = rec0.get("pid"), rec0.get("proc_start", "")

    # (r4 blocker 2) collision-proof transaction id — uuid4, NOT a second-resolution
    # timestamp+pid which repeats within the same second and process.
    txn = f"rst-{uuidlib.uuid4()}"
    if not sessions.lease_acquire(acc, sid, txn=txn):
        raise RestartError("restart lease already held")
    # (r13 #5) the controller start-time in the journal is what recovery uses to prove the
    # controller dead; an empty one (transient ps failure) would permanently block recovery.
    # Retry; refuse the transaction (release the lease) if we cannot record a provable identity.
    _cstart = ""
    for _ in range(4):
        _cstart = _proc_start(os.getpid())
        if _cstart:
            break
        time.sleep(0.05)
    if not _cstart:
        sessions.lease_release(acc, sid)
        raise RestartError("could not read a stable controller start-time (transient); retry")
    # (finding 13) durable LEASED intent is armed IMMEDIATELY after the lease so a
    # crash never leaves a lease with no journal for recovery to reason about. The
    # controller identity is what recovery binds a force-release to (finding 10).
    j = {"txn": txn, "sid": sid,
         "target_email": target_email, "target_home": target_home,
         "pre_generation": pre_gen, "cwd": rec0.get("cwd", ""),
         "controller_pid": os.getpid(), "controller_start": _cstart}
    spawned = False
    try:
        _phase(acc, sid, j, "LEASED")
        # (findings 8/12/34) atomically re-verify the EXACT selected IDLE record (pid +
        # proc-start + generation) under the sessions lock and flip it to RESTARTING.
        # None => a duplicate SessionStart / lifecycle churn replaced the record; abort
        # rather than SIGTERM a newer/wrong pid.
        rec1 = sessions.set_restarting(acc, sid, pid0, ps0, pre_gen)
        if rec1 is None:
            _phase(acc, sid, j, "ABORTED", why="record changed before stop (state/pid/generation)")
            sessions.lease_release(acc, sid)
            return _jread(acc, sid)

        pid, ps = rec1.get("pid"), rec1.get("proc_start", "")
        _phase(acc, sid, j, "STOPPING", pred_pid=pid, pred_start=ps)
        # (r5 item 2) STOPPED requires POSITIVE death of the predecessor. We SIGTERM and
        # wait until the predecessor is provably DEAD; an UNKNOWN state (ps failure, EPERM)
        # is NOT treated as exited — it keeps us waiting, and if the predecessor is not
        # DEAD by the timeout we ABORT and never spawn a successor (a live/uncertain
        # predecessor + a successor would be the duplicate-session hazard §0 forbids).
        if not _dead(pid, ps):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            t0 = time.time()
            while time.time() - t0 < stop_timeout:
                if _dead(pid, ps):
                    break
                time.sleep(0.2)
            if not _dead(pid, ps):
                _phase(acc, sid, j, "ABORTED",
                       why=f"predecessor not provably DEAD in time (state={_pstate(pid, ps)})")
                sessions.lease_release(acc, sid)
                return _jread(acc, sid)
        # transcript settle
        tp = rec1.get("transcript", "")
        if tp and os.path.exists(tp):
            while True:
                m = os.path.getmtime(tp)
                time.sleep(SETTLE_QUIET_S)
                if os.path.getmtime(tp) == m:
                    break
        _phase(acc, sid, j, "STOPPED")

        # (finding 11) the spawn callback may LAUNCH the child and then raise before
        # returning its pid. We cannot prove no successor exists, so a spawn exception
        # must leave the lease HELD (journal SPAWNED, blocked + operator card), never
        # release. Only PRE-spawn failures (above) abort + release.
        spawn_cwd = rec1.get("cwd") or j.get("cwd") or os.getcwd()
        j["cwd"] = spawn_cwd
        try:
            child_pid, child_start = spawn(target_email, spawn_cwd, sid)
        except Exception as e:
            spawned = True
            _phase(acc, sid, j, "SPAWNED", child_pid=None, child_start=None,
                   spawn_error=f"{type(e).__name__}: {e}")
            return _jread(acc, sid)               # lease HELD
        spawned = True                                    # (finding 11) successor exists
        _phase(acc, sid, j, "SPAWNED", child_pid=child_pid, child_start=child_start)

        # await transaction-bound registration
        t0 = time.time()
        while time.time() - t0 < reg_timeout:
            live = sessions.live_sessions(acc)
            r = live.get(sid)
            # (r3 IB4) the successor's registered cwd MUST match the journaled one — a
            # session that launched from Terminal's fallback dir (cd failed) is NOT a
            # valid resume and must never reach REGISTERED.
            if (r and r.get("pid") == child_pid
                    and r.get("proc_start") == child_start
                    and os.path.realpath(r.get("home", "")) == os.path.realpath(target_home)
                    and os.path.realpath(r.get("cwd", "")) == os.path.realpath(spawn_cwd)
                    and r.get("generation", 0) > j["pre_generation"]):
                _phase(acc, sid, j, "REGISTERED")
                sessions.lease_release(acc, sid)          # released ONLY at REGISTERED
                return _jread(acc, sid)
            time.sleep(0.3)
        # (finding 41) not registered in time: leave the journal at SPAWNED — no
        # invented phase. The lease stays HELD (§0: STOPPED/SPAWNED-without-REGISTERED
        # = blocked + operator card; recovery never re-spawns).
        return _jread(acc, sid)
    except Exception as e:
        # (finding 11) once a successor has been spawned, a later failure must NEVER
        # release the lease — a released lease would admit a duplicate resume while an
        # unregistered successor already exists. Leave the journal at SPAWNED (blocked
        # + operator card). Only PRE-spawn failures abort + release.
        if spawned:
            raise
        _phase(acc, sid, j, "ABORTED", why=f"{type(e).__name__}: {e}")
        sessions.lease_release(acc, sid)
        raise


def recover(acc, sid):
    """Rev 8 exhaustive stale-recovery. Only acts when the CONTROLLER is dead. All
    lease releases are transaction-bound (bound to the journaled controller identity)
    and ABA-safe, so an old recovery can never delete a newer controller's lease."""
    sessions._require_sid(sid)
    j = _jread(acc, sid)
    if j is None:
        # (finding 13) a lease with NO journal is a crash between lease_acquire and the
        # LEASED intent — nothing was spawned, predecessor untouched. Release the orphan
        # lease ONLY when its owner is provably dead, via the ABA-safe reclaim (a live
        # owner or a lease a newer controller just took is never evicted). Bounded: one
        # attempt, no loop.
        if sessions.lease_held(acc, sid):
            if sessions.lease_release(acc, sid, force=True):
                return "released (orphan lease, no journal; nothing spawned)"
            return "lease held by a live owner but no journal; leave it alone"
        return "no-transaction"
    phase = j.get("phase", "UNKNOWN")
    if phase == "CORRUPT":
        # (finding 13) a present-but-corrupt journal is UNKNOWN state — a corrupt
        # post-SPAWN journal must never be force-released. Block unconditionally.
        return "BLOCKED: journal present but corrupt/unreadable; operator card (never release)"
    # (r3 #13) a PARSEABLE-BUT-INCOMPLETE journal (e.g. `{"phase":"LEASED"}` missing the
    # controller identity) is just as ambiguous as a corrupt one — it must NEVER enter a
    # forced release. Require the transaction-identifying fields before trusting it.
    required = ("txn", "sid", "controller_pid", "controller_start")
    missing = [k for k in required if not j.get(k)]
    if missing:
        return (f"BLOCKED: journal incomplete (missing {missing}); operator card "
                "(never release an unbound journal)")
    # (r4 blocker 2) the journal must be for THIS session — a journal whose recorded sid
    # differs from the one we were asked to recover is a mispaired/foreign record; never
    # act on it.
    if j.get("sid") != sid:
        return (f"BLOCKED: journal sid {j.get('sid')!r} != requested {sid!r} "
                "(mispaired journal); operator card")
    # (r5 item 2) recovery ACTS only when the controller is PROVABLY DEAD. An ALIVE or
    # UNKNOWN controller is left alone (fail-closed) — presuming death on a probe failure
    # could recover/release a transaction whose controller is still running.
    cstate = _pstate(j.get("controller_pid"), j.get("controller_start", ""))
    if cstate == "ALIVE":
        return "controller-alive: leave it alone"
    if cstate != "DEAD":
        return f"controller-{cstate.lower()}: not provably DEAD, leave it alone"
    cid, cstart, ctxn = j.get("controller_pid"), j.get("controller_start", ""), j.get("txn")
    pred_state = _pstate(j.get("pred_pid"), j.get("pred_start", ""))
    if phase in ("LEASED",) or (phase == "STOPPING" and pred_state == "ALIVE"):
        # (r3 MAJOR3 / r4 blocker 2) report the ACTUAL release outcome; the release is
        # bound to the FULL transaction identity (pid + start + txn), so a newer
        # controller's lease is never released.
        released = sessions.lease_release(acc, sid, force=True, expect_pid=cid,
                                          expect_start=cstart, expect_txn=ctxn)
        if released:
            return f"released (phase {phase}, predecessor alive/no action taken)"
        return (f"BLOCKED: phase {phase} but the lease is owned by a newer controller "
                "(not released); operator card")
    if phase == "STOPPING" and pred_state != "ALIVE":
        # DEAD or UNKNOWN predecessor: the kill may have landed (or we can't prove it did
        # not) — never a second spawn from recovery.
        return (f"BLOCKED: STOPPING with predecessor state {pred_state} "
                "(kill may have landed); operator card")
    if phase in ("STOPPED", "SPAWNED"):
        return f"BLOCKED: phase {phase} without REGISTERED; operator card (never re-spawn)"
    if phase in ("REGISTERED", "ABORTED"):
        released = sessions.lease_release(acc, sid, force=True, expect_pid=cid,
                                          expect_start=cstart, expect_txn=ctxn)
        if released or not sessions.lease_held(acc, sid):
            return f"released (terminal phase {phase})"
        return (f"BLOCKED: terminal phase {phase} but the lease is owned by a newer "
                "controller (not released); operator card")
    return f"BLOCKED: unknown phase {phase!r}; operator card"


def restart_exit_note(acc, sid, rec):
    """(review #3) One-line stderr note for a restart CLI exit, or None when REGISTERED (rc 0).
    Pure/testable (the _cli path that would otherwise carry this opens Terminal). A STOPPED/
    SPAWNED phase deliberately HOLDS the lease (recovery adjudicates — never a second spawn from
    here); ABORTED already released it. The note is observability only; it changes no state."""
    phase = rec.get("phase") if isinstance(rec, dict) else None
    if phase == "REGISTERED":
        return None
    if phase in ("STOPPED", "SPAWNED"):
        return (f"successor not registered in time (phase {phase}); lease intentionally held — "
                f"run: restart.py {acc} recover {sid}")
    if phase == "ABORTED":
        return f"restart aborted ({rec.get('why', 'no reason recorded')}); lease released"
    return f"restart did not complete (phase {phase}); run: restart.py {acc} recover {sid}"


def _terminal_spawn(scripts_dir, acc):
    """Production spawn (r2 item 4): open a NEW Terminal.app window that resumes the
    session on the target home at the original cwd, and return the resumed process's
    (pid, proc_start). The launcher writes its own pid to a pidfile BEFORE `exec`-ing
    claude-acct; because exec preserves the pid through claude-acct -> shim -> claude,
    that pid is the real claude process (and the SessionStart hook's PPID), so the
    controller's transaction-bound registration match holds. macOS only."""
    import shlex
    claude_acct = os.path.join(scripts_dir, "claude-acct")

    def spawn(email, cwd, sid):
        pidfile = tempfile.mktemp(prefix="rst-pid-")
        # (r13 #1) pass the LEASE TOKEN we own so claude-acct's --resume gate authorizes THIS
        # (controller-launched) resume instead of refusing it as a duplicate. We hold the lease
        # for `sid`; its token is in sessions._HELD_LEASE_TOKENS (same process).
        _lease_tok = sessions._HELD_LEASE_TOKENS.get(sid, "")
        # (r3 IB4) `cd ... || exit 1` — NEVER continue from Terminal's fallback dir if the
        # original cwd is gone. (r3 MAJOR2) export the SAME account bank + scripts dir the
        # controller is using, so a non-default ACCOUNT_BANK_DIR resumes through the same
        # bank claude-acct reads.
        inner = (
            f"cd {shlex.quote(cwd)} || exit 1; "
            f"export ACCOUNT_BANK_DIR={shlex.quote(acc)} "
            f"ACCOUNT_BANK_SCRIPTS_DIR={shlex.quote(scripts_dir)} "
            f"ACCOUNT_BANK_RESUME_LEASE_TOKEN={shlex.quote(_lease_tok)}; "
            f"echo $$ > {shlex.quote(pidfile)}; "
            f"exec {shlex.quote(claude_acct)} {shlex.quote(email)} "
            f"--resume {shlex.quote(sid)}")
        osa = 'tell application "Terminal" to do script ' + json.dumps(inner)
        subprocess.run(["osascript", "-e", osa], check=True,
                       capture_output=True, text=True)
        for _ in range(200):                    # up to ~20s for the launcher to report
            try:
                pid = int(open(pidfile).read().strip())
                if pid > 0 and _proc_start(pid):
                    return pid, _proc_start(pid)
            except Exception:
                pass
            time.sleep(0.1)
        raise RestartError("spawn: Terminal launcher never reported a live pid")

    return spawn


def _cli():
    """restart.py <acc> restart <sid> <email>   — run the assisted-restart transaction
       restart.py <acc> recover <sid>            — run stale recovery
    Invocable by QuotaBar/scripts (the Swift wiring may inject its own spawn instead)."""
    if len(sys.argv) < 3:
        print("usage: restart.py <acc> restart <sid> <email> | <acc> recover <sid>",
              file=sys.stderr)
        return 64
    acc, cmd = sys.argv[1], sys.argv[2]
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    if cmd == "restart":
        if len(sys.argv) < 5:
            print("usage: restart.py <acc> restart <sid> <email>", file=sys.stderr)
            return 64
        sid, email = sys.argv[3], sys.argv[4]
        if not sessions.valid_sid(sid):
            print(f"restart: invalid session-id (must be a UUID): {sid!r}", file=sys.stderr)
            return 64
        try:
            rec = restart_session(acc, sid, email, _terminal_spawn(scripts_dir, acc))
        except RestartError as e:
            print(f"restart refused: {e}", file=sys.stderr)
            return 65
        print(json.dumps(rec))
        note = restart_exit_note(acc, sid, rec)
        if note is None:
            return 0
        # (review #3) non-REGISTERED exit (rc 75): emit a ONE-LINE stderr so the exit is not a
        # silent "Script failed" upstream. Observability only — transaction semantics untouched.
        print(note, file=sys.stderr)
        return 75
    if cmd == "recover":
        if len(sys.argv) < 4:
            print("usage: restart.py <acc> recover <sid>", file=sys.stderr)
            return 64
        sid = sys.argv[3]
        if not sessions.valid_sid(sid):
            print(f"recover: invalid session-id (must be a UUID): {sid!r}", file=sys.stderr)
            return 64
        verdict = recover(acc, sid)
        print(verdict)
        # (r3 MAJOR3) non-zero exit for BLOCKED / operator-required states so callers and
        # scripts can tell a clean resolution from one that needs a human.
        if verdict.startswith("BLOCKED") or "operator card" in verdict:
            return 75
        if verdict.startswith("controller-alive") or "leave it alone" in verdict:
            return 70
        return 0
    print(f"restart.py: unknown command {cmd!r}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(_cli())
