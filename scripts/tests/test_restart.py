#!/usr/bin/env python3
"""Tests for restart.py — the full transaction, refusals, transaction-bound
registration, fault-injected recovery per rev 8 §0.4. Predecessor/successor are
real subprocesses (sleep) so pid/proc-start semantics are genuine."""
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import registry  # noqa: E402
import restart  # noqa: E402
import sessions  # noqa: E402

FAILS = []
C = [0]


def ok(c, m):
    C[0] += 1
    print(("  ok   " if c else "  FAIL ") + m)
    if not c:
        FAILS.append(m)


_SPAWNED = []


def sleeper():
    # stdout/stderr -> DEVNULL so a lingering successor never holds the test's own
    # stdout pipe open (which would stall a `... | tail` harness after the run).
    p = subprocess.Popen(["sleep", "300"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    _SPAWNED.append(p)
    return p, p.pid, sessions._proc_start(p.pid)


def main():
    acc = tempfile.mkdtemp(prefix="rst-acc-")
    home = os.path.join(acc, "homes", "b-at-x.com")
    os.makedirs(home)
    registry.publish_ready(acc, "b@x.com", home, "uuid-b")
    sid = "33333333-2222-3333-4444-555555555555"

    # register a live predecessor session, IDLE
    pred, ppid, pstart = sleeper()
    sessions.record_event(acc, "start", sid, {"home": "/old", "cwd": "/tmp",
                                              "pid": ppid, "transcript": ""})
    sessions.record_event(acc, "idle", sid)

    # happy path: stop verified, successor spawned + transaction-bound registered
    def spawn_ok(email, cwd, s):
        c, cpid, cstart = sleeper()
        # simulate the successor's SessionStart hook registration
        sessions.record_event(acc, "start", s, {"home": home, "cwd": cwd,
                                                "pid": cpid, "transcript": ""})
        return cpid, cstart

    rec = restart.restart_session(acc, sid, "b@x.com", spawn_ok, stop_timeout=10)
    ok(rec["phase"] == "REGISTERED", f"happy path -> REGISTERED ({rec['phase']})")
    ok(not sessions.lease_held(acc, sid), "lease released at REGISTERED")
    ok(not restart._alive(ppid, pstart), "predecessor actually stopped")

    # refusal: BUSY session
    sid2 = "44444444-2222-3333-4444-555555555555"
    pred2, ppid2, pstart2 = sleeper()
    sessions.record_event(acc, "start", sid2, {"home": "/old", "cwd": "/tmp",
                                               "pid": ppid2, "transcript": ""})
    sessions.record_event(acc, "prompt", sid2)
    raised = False
    try:
        restart.restart_session(acc, sid2, "b@x.com", spawn_ok)
    except restart.RestartError as e:
        raised = "not IDLE" in str(e)
    ok(raised, "BUSY session refused (user-mediated only)")

    # refusal: unknown target
    sessions.record_event(acc, "idle", sid2)
    raised = False
    try:
        restart.restart_session(acc, sid2, "ghost@x.com", spawn_ok)
    except restart.RestartError:
        raised = True
    ok(raised, "non-READY target refused")

    # spawn that never registers -> journal stays SPAWNED, lease HELD. A short
    # reg_timeout (a real parameter, no clock monkeypatching) bounds the wait.
    def spawn_silent(email, cwd, s):
        c, cpid, cstart = sleeper()
        return cpid, cstart          # successor never registers

    rec = restart.restart_session(acc, sid2, "b@x.com", spawn_silent,
                                  stop_timeout=10, reg_timeout=1)
    ok(rec["phase"] == "SPAWNED",
       f"unregistered successor -> journal stays SPAWNED, no invented phase (finding 41: {rec['phase']})")
    ok(sessions.lease_held(acc, sid2), "lease HELD on unregistered spawn (blocked)")

    # recovery on that stale state (controller = us = alive) -> untouched
    ok(restart.recover(acc, sid2).startswith("controller-alive"),
       "recovery leaves live controller alone")

    DEAD, DEADSTART = 999999999, "long gone"

    def fake_dead(phase, **extra):
        """Fake a dead controller AND bind the lease owner to the SAME dead identity,
        so transaction-bound recovery (r2 finding 10) applies to it. Always writes a
        COMPLETE journal (txn/sid present) so the r3 #13 completeness gate is satisfied —
        we are testing the phase rules, not the incompleteness rule, here."""
        jj = {"txn": "fake-txn", "sid": sid2, "target_email": "b@x.com",
              "target_home": home, "pre_generation": 0,
              "controller_pid": DEAD, "controller_start": DEADSTART, "phase": phase}
        jj.update(extra)
        restart._jwrite(acc, sid2, jj)
        ld = sessions._lease_dir(acc, sid2)
        if os.path.isdir(ld):
            with open(os.path.join(ld, "owner"), "w") as f:
                json.dump({"pid": DEAD, "proc_start": DEADSTART, "token": "x",
                           "txn": jj.get("txn"), "ts": 0}, f)
        return jj

    # fake a dead controller -> BLOCKED + operator card (SPAWNED, lease held)
    fake_dead("SPAWNED")
    v = restart.recover(acc, sid2)
    ok(v.startswith("BLOCKED"), f"dead controller + SPAWNED (unregistered) -> BLOCKED ({v})")
    ok(sessions.lease_held(acc, sid2), "lease still held after BLOCKED recovery")

    # (r2 finding 13) a PRESENT-but-corrupt journal -> BLOCKED, never released
    with open(restart._jpath(acc, sid2), "w") as f:
        f.write("{ not json")
    ok(restart.recover(acc, sid2).startswith("BLOCKED"),
       "corrupt journal -> BLOCKED (finding 13, corrupt != absent)")
    ok(sessions.lease_held(acc, sid2), "lease HELD on corrupt-journal recovery (never force-release)")

    # recovery: STOPPING with predecessor DEAD -> BLOCKED
    fake_dead("STOPPING", pred_pid=999999998, pred_start="long gone")
    ok(restart.recover(acc, sid2).startswith("BLOCKED"),
       "STOPPING + predecessor dead -> BLOCKED (r7 rule)")

    # (r2 finding 10) transaction-bound recovery: a LEASED journal whose lease is owned
    # by a DIFFERENT (newer, live) controller must NOT be released by this recovery.
    fake_dead("LEASED")                       # journal + lease bound to the dead id
    with open(os.path.join(sessions._lease_dir(acc, sid2), "owner"), "w") as f:
        json.dump({"pid": os.getpid(), "proc_start": sessions._proc_start(os.getpid()),
                   "token": "newer", "txn": "newer-txn", "ts": int(time.time())}, f)
    v = restart.recover(acc, sid2)
    ok(sessions.lease_held(acc, sid2),
       "recovery does NOT release a lease owned by a newer live controller (finding 10)")

    # (r4 blocker 2) TRANSACTION-bound: a lease whose owner matches the dead controller's
    # pid+start but carries a DIFFERENT txn must NOT be released (pid-reuse-within-window).
    fake_dead("LEASED")
    with open(os.path.join(sessions._lease_dir(acc, sid2), "owner"), "w") as f:
        json.dump({"pid": DEAD, "proc_start": DEADSTART, "token": "x",
                   "txn": "a-different-txn", "ts": 0}, f)
    restart.recover(acc, sid2)
    ok(sessions.lease_held(acc, sid2),
       "recovery does NOT release when lease.txn != journal.txn (r4 blocker 2)")

    # (r4 blocker 2) a journal whose recorded sid != requested sid is mispaired -> BLOCKED
    jmis = {"txn": "t", "sid": "ffffffff-2222-3333-4444-555555555555",
            "controller_pid": DEAD, "controller_start": DEADSTART, "phase": "LEASED"}
    restart._jwrite(acc, sid2, jmis)
    vmis = restart.recover(acc, sid2)
    ok(vmis.startswith("BLOCKED") and "mispaired" in vmis,
       f"journal.sid != requested sid -> BLOCKED (r4 blocker 2: {vmis})")

    # recovery: LEASED + lease bound to the dead controller -> released
    fake_dead("LEASED")
    v = restart.recover(acc, sid2)
    ok(v.startswith("released") and not sessions.lease_held(acc, sid2),
       f"LEASED + dead controller (bound) -> lease released ({v})")

    # recovery: ABORTED with lease present -> release (terminal state)
    sessions.lease_acquire(acc, sid2)
    fake_dead("ABORTED")
    v = restart.recover(acc, sid2)
    ok(v.startswith("released") and not sessions.lease_held(acc, sid2),
       "ABORTED + lease -> released (r7 rule)")

    # recovery: unknown phase -> BLOCKED
    sessions.lease_acquire(acc, sid2)
    fake_dead("GARBLED")
    ok(restart.recover(acc, sid2).startswith("BLOCKED"), "unknown phase -> BLOCKED")

    # (r2 item 4) the controller is invocable as a CLI, not an unused library. Exercise
    # the non-spawning paths (recover + malformed-id rejection + usage) — never the
    # real Terminal spawn in the suite.
    rp = os.path.join(HERE, "restart.py")
    # (r3 MAJOR3) recover CLI exit codes: no-transaction -> 0; BLOCKED -> nonzero (75)
    cleansid = "cccccccc-2222-3333-4444-555555555555"
    r = subprocess.run([sys.executable, rp, acc, "recover", cleansid], capture_output=True, text=True)
    ok(r.returncode == 0, f"restart.py CLI recover (no transaction) -> 0 (rc {r.returncode})")
    bsid = "bbbbbbbb-1111-3333-4444-555555555555"
    restart._jwrite(acc, bsid, {"txn": "t", "sid": bsid, "controller_pid": 999999999,
                                "controller_start": "long gone", "phase": "SPAWNED"})
    r = subprocess.run([sys.executable, rp, acc, "recover", bsid], capture_output=True, text=True)
    ok(r.returncode == 75 and "BLOCKED" in r.stdout,
       f"restart.py CLI recover BLOCKED -> nonzero 75 (r3 MAJOR3: rc {r.returncode})")
    # (r3 #13) a parseable-but-INCOMPLETE journal ({"phase":"LEASED"} only) -> BLOCKED
    isid = "dddddddd-1111-3333-4444-555555555555"
    restart._jwrite(acc, isid, {"phase": "LEASED"})
    v = restart.recover(acc, isid)
    ok(v.startswith("BLOCKED") and "incomplete" in v,
       f"incomplete journal -> BLOCKED, never force-released (r3 #13: {v})")
    r = subprocess.run([sys.executable, rp, acc, "restart", "not-a-uuid", "b@x.com"],
                       capture_output=True, text=True)
    ok(r.returncode == 64 and "invalid session-id" in r.stderr,
       "restart.py CLI rejects a malformed sid BEFORE any spawn (item 4)")
    r = subprocess.run([sys.executable, rp, acc], capture_output=True, text=True)
    ok(r.returncode == 64, "restart.py CLI usage error without a subcommand")

    # (r2 finding 11 / r3 credibility) spawn-callback-THROWS: the successor may exist, so
    # the lease is HELD and the journal is SPAWNED (never released).
    sidx = "eeeeeeee-2222-3333-4444-555555555555"
    predx, ppidx, pstartx = sleeper()
    sessions.record_event(acc, "start", sidx, {"home": "/old", "cwd": "/tmp",
                                               "pid": ppidx, "transcript": ""})
    sessions.record_event(acc, "idle", sidx)
    def spawn_throws(email, cwd, s):
        sleeper()                       # a child WAS launched...
        raise RuntimeError("spawn boom after launch")
    recx = restart.restart_session(acc, sidx, "b@x.com", spawn_throws, stop_timeout=10)
    ok(recx["phase"] == "SPAWNED" and sessions.lease_held(acc, sidx),
       "spawn callback throws AFTER launch -> journal SPAWNED + lease HELD (finding 11)")

    # (r5 item 2) _proc_state is THREE-VALUED: provably-absent vs probe-failure are distinct.
    dpp = subprocess.Popen(["true"]); dpp.wait()
    ok(sessions._proc_state(dpp.pid, "any") == "DEAD", "_proc_state: gone pid -> DEAD")
    ok(sessions._proc_state(os.getpid(), sessions._proc_start(os.getpid())) == "ALIVE",
       "_proc_state: our live pid + matching start -> ALIVE")
    ok(sessions._proc_state(os.getpid(), "a-different-start") == "DEAD",
       "_proc_state: live pid but start mismatch -> DEAD (pid reuse)")
    # (r8 #2) an EMPTY expected start-time is UNKNOWN, never a token: a transient ps
    # failure at SessionStart records proc_start="" for a LIVE pid; comparing a real
    # nonempty start against "" must NOT read the live process as DEAD (which would make
    # restart skip its SIGTERM and spawn a concurrent successor). Empty -> bare existence.
    ok(sessions._proc_state(os.getpid(), "") == "ALIVE",
       "_proc_state: live pid + EMPTY expected start -> ALIVE, never DEAD (r8 #2)")
    ok(sessions._proc_state(dpp.pid, "") == "DEAD",
       "_proc_state: gone pid + EMPTY expected start -> still DEAD (existence probe)")

    # (r5 item 2) an UNKNOWN controller state is NOT presumed dead — recovery leaves it.
    _orig_ps = sessions._proc_state
    sessions._proc_state = lambda pid, start=None: "UNKNOWN"
    try:
        fake_dead("LEASED")                 # dead-id journal, but probe now returns UNKNOWN
        v = restart.recover(acc, sid2)
        ok("not provably DEAD" in v and "leave it alone" in v,
           f"UNKNOWN controller -> recovery leaves it alone, never releases (r5 item 2: {v})")
        ok(sessions.lease_held(acc, sid2), "lease HELD under UNKNOWN controller (fail-closed)")
    finally:
        sessions._proc_state = _orig_ps

    # (review #3) restart_exit_note: the one-line stderr for a non-REGISTERED CLI exit (rc 75).
    ok(restart.restart_exit_note("/acc", "sid-x", {"phase": "REGISTERED"}) is None,
       "(review #3) a REGISTERED restart emits no exit note (rc 0)")
    for ph in ("SPAWNED", "STOPPED"):
        note = restart.restart_exit_note("/acc", "sid-x", {"phase": ph})
        ok(note is not None and "not registered" in note and "lease intentionally held" in note
           and "recover sid-x" in note,
           f"(review #3) a {ph}-without-REGISTERED exit notes the held lease + recover command")
    ok("aborted" in (restart.restart_exit_note("/acc", "sid-x", {"phase": "ABORTED", "why": "x"}) or ""),
       "(review #3) an ABORTED exit notes the abort (lease released)")
    ok("recover sid-x" in (restart.restart_exit_note("/acc", "sid-x", {"phase": "LEASED"}) or ""),
       "(review #3) any other non-terminal phase still points at recover")

    for p in _SPAWNED:
        try:
            p.kill()
            p.wait()
        except Exception:
            pass

    print(f"-- restart: {C[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
