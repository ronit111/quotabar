#!/usr/bin/env python3
"""Tests for sessions.py — registry lifecycle, liveness sweep, leases, prompt gate."""
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import sessions  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    acc = tempfile.mkdtemp(prefix="sess-acc-")
    sid = "11111111-2222-3333-4444-555555555555"

    # (finding 7) register with OUR OWN pid (live) -> BUSY: a fresh session is NOT
    # restartable until an idle_prompt notification arrives. A missing idle edge must
    # leave it BUSY (safe), never inferred IDLE at registration.
    me = os.getpid()
    rec = sessions.record_event(acc, "start", sid,
                                {"home": "/h", "cwd": "/c", "pid": me,
                                 "transcript": "/t.jsonl"})
    ok(rec["state"] == "BUSY" and rec["generation"] == 1, "start -> BUSY gen 1 (finding 7)")
    ok(rec["proc_start"] != "", "proc-start-time captured")

    # prompt -> BUSY; stop is ADVISORY (state stays BUSY); idle_prompt -> IDLE
    ok(sessions.record_event(acc, "prompt", sid)["state"] == "BUSY", "prompt -> BUSY")
    rec = sessions.record_event(acc, "stop", sid)
    ok(rec["state"] == "BUSY" and "last_stop" in rec, "stop advisory: still BUSY (r6)")
    rec = sessions.record_event(acc, "idle", sid)
    ok(rec["state"] == "IDLE" and rec["generation"] == 4, "idle_prompt -> IDLE")

    # live_sessions: our pid is alive -> listed
    live = sessions.live_sessions(acc)
    ok(sid in live, "live session listed")

    # a dead-pid session gets tombstoned by the sweeper
    sid2 = "22222222-2222-3333-4444-555555555555"
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    sessions.record_event(acc, "start", sid2, {"home": "/h", "cwd": "/c",
                                               "pid": p.pid, "transcript": "/t2"})
    live = sessions.live_sessions(acc)
    ok(sid2 not in live, "dead pid swept to tombstone")
    ok(sid in live, "live one survives the sweep")

    # end -> tombstone
    sessions.record_event(acc, "end", sid)
    ok(sid not in sessions.live_sessions(acc), "end -> tombstoned")

    # unknown kind rejected
    raised = False
    try:
        sessions.record_event(acc, "meow", sid)
    except ValueError:
        raised = True
    ok(raised, "unknown event kind rejected")

    # leases: exclusive, re-entrant refusal, release, stale reclaim
    ok(sessions.lease_acquire(acc, sid), "lease acquired")
    ok(not sessions.lease_acquire(acc, sid), "second acquire refused")
    ok(sessions.lease_held(acc, sid), "lease_held true")
    sessions.lease_release(acc, sid)
    ok(not sessions.lease_held(acc, sid), "released")
    # stale: fabricate an old dead-owner lease (no restart journal -> reclaimable)
    ld = sessions._lease_dir(acc, sid)
    os.makedirs(ld)
    with open(os.path.join(ld, "owner"), "w") as f:
        json.dump({"pid": p.pid, "proc_start": "long gone", "ts": int(time.time()) - 999}, f)
    ok(sessions.lease_acquire(acc, sid), "stale dead-owner lease reclaimed (no journal)")
    sessions.lease_release(acc, sid)

    # (finding 9) a stale dead-owner lease with a mid-flight restart journal (SPAWNED)
    # must NOT be reclaimed — recovery, not a blind reclaim, adjudicates it.
    os.makedirs(ld, exist_ok=True)
    with open(os.path.join(ld, "owner"), "w") as f:
        json.dump({"pid": p.pid, "proc_start": "long gone", "ts": int(time.time()) - 999}, f)
    with open(os.path.join(acc, "sessions", f"{sid}.restart.json"), "w") as f:
        json.dump({"phase": "SPAWNED", "sid": sid}, f)
    ok(not sessions.lease_acquire(acc, sid),
       "stale lease with SPAWNED restart journal NOT reclaimed (finding 9)")
    # a TERMINAL journal (ABORTED) is reclaimable again
    with open(os.path.join(acc, "sessions", f"{sid}.restart.json"), "w") as f:
        json.dump({"phase": "ABORTED", "sid": sid}, f)
    ok(sessions.lease_acquire(acc, sid), "stale lease with terminal journal reclaimable")
    sessions.lease_release(acc, sid)
    os.remove(os.path.join(acc, "sessions", f"{sid}.restart.json"))

    # (r3 #9) CONCURRENT reclaim of a stale DEAD-owner lease: the reclaim mutex + owner
    # re-verification must yield EXACTLY ONE winner, never two controllers both acquiring.
    import threading
    sidr = "88888888-2222-3333-4444-555555555555"
    ldr = sessions._lease_dir(acc, sidr)
    os.makedirs(ldr, exist_ok=True)
    d2 = subprocess.Popen(["true"]); d2.wait()          # a provably-dead pid
    with open(os.path.join(ldr, "owner"), "w") as f:
        json.dump({"pid": d2.pid, "proc_start": "long gone", "token": "x", "txn": "x", "ts": 0}, f)
    _res = []
    _rlock = threading.Lock()
    def _racer():
        r = sessions.lease_acquire(acc, sidr)
        with _rlock:
            _res.append(r)
    _threads = [threading.Thread(target=_racer) for _ in range(8)]
    for t in _threads: t.start()
    for t in _threads: t.join()
    ok(_res.count(True) == 1,
       f"concurrent stale-lease reclaim yields EXACTLY ONE winner (r3 #9: {_res.count(True)} of 8)")
    sessions.lease_release(acc, sidr, force=True)

    # (r4 #9) the reclaim mutex is STRICTLY positive-death — the age fallback is gone, so a
    # suspended reclaimer's fresh (or ownerless) mutex can never be blind-deleted by a
    # contender. Invariants:
    #   (a) a LIVE-owner mutex is NEVER reclaimed, even when ancient;
    #   (b) an OWNERLESS/unreadable mutex is NEVER reclaimed, even when ancient;
    #   (c) a readable DEAD-owner mutex IS reclaimable.
    livep = subprocess.Popen(["sleep", "30"])
    rdA = tempfile.mkdtemp()
    with open(os.path.join(rdA, "owner"), "w") as f:
        f.write(f"{livep.pid} tok {sessions._proc_start(livep.pid)}")
    os.utime(rdA, (0, 0))                                 # make it ancient
    ok(sessions._reclaim_mutex_dead(rdA) is False,
       "live-owner reclaim mutex NOT reclaimed even when ancient (r4 #9 no ABA)")
    livep.kill(); livep.wait()
    rdB = tempfile.mkdtemp()                              # no owner file at all
    os.utime(rdB, (0, 0))
    ok(sessions._reclaim_mutex_dead(rdB) is False,
       "ownerless reclaim mutex NOT age-reclaimed (r4 #9 no blind delete)")
    deadp = subprocess.Popen(["true"]); deadp.wait()
    rdC = tempfile.mkdtemp()
    with open(os.path.join(rdC, "owner"), "w") as f:
        f.write(f"{deadp.pid} tok long gone")
    ok(sessions._reclaim_mutex_dead(rdC) is True,
       "readable DEAD-owner reclaim mutex IS reclaimable (r4 #9)")

    # (finding 10) a lease owned by a DIFFERENT, LIVE controller is never released by
    # another caller — not by a plain release, and not even by force (transaction
    # protection). Only after the owner is provably DEAD may force reclaim it (ABA-safe).
    live = subprocess.Popen(["sleep", "30"])
    os.makedirs(ld, exist_ok=True)
    with open(os.path.join(ld, "owner"), "w") as f:
        json.dump({"pid": live.pid, "proc_start": sessions._proc_start(live.pid),
                   "token": "foreign", "txn": "foreign", "ts": int(time.time())}, f)
    ok(not sessions.lease_release(acc, sid), "non-owner plain release refused (live foreign owner)")
    ok(sessions.lease_held(acc, sid), "live foreign-owned lease not released (finding 10)")
    ok(not sessions.lease_release(acc, sid, force=True),
       "force refused while the owner is still ALIVE (finding 10 transaction protection)")
    ok(sessions.lease_held(acc, sid), "lease still held while owner alive")
    live.kill(); live.wait()
    ok(sessions.lease_release(acc, sid, force=True), "force reclaims a provably-DEAD owner")
    ok(not sessions.lease_held(acc, sid), "dead-owner lease reclaimed (ABA-safe)")

    # (finding 14) malformed session-ids are rejected before any filesystem use
    for bad in ("../escape", "a/b", "not-a-uuid", ""):
        raised = False
        try:
            sessions._lease_dir(acc, bad)
        except ValueError:
            raised = True
        ok(raised, f"malformed sid {bad!r} rejected by _lease_dir (finding 14)")
        raised = False
        try:
            sessions.record_event(acc, "start", bad, {"pid": me})
        except ValueError:
            raised = True
        ok(raised, f"malformed sid {bad!r} rejected by record_event (finding 14)")

    # (finding 8) prompt_admit: admits (BUSY) with no lease, BLOCKS under a lease
    sid3 = "77777777-2222-3333-4444-555555555555"
    sessions.record_event(acc, "start", sid3, {"home": "/h", "cwd": "/c", "pid": me,
                                               "transcript": "/t3"})
    ok(sessions.prompt_admit(acc, sid3) is True, "prompt_admit admits without lease")
    ok(sessions._load(acc).get(sid3, {}).get("state") == "BUSY", "prompt_admit set BUSY")
    sessions.lease_acquire(acc, sid3)
    ok(sessions.prompt_admit(acc, sid3) is False, "prompt_admit blocks under RESTARTING lease")
    sessions.lease_release(acc, sid3)

    # prompt gate CLI: allow without lease, block (exit 2) with lease
    sp = os.path.join(HERE, "sessions.py")
    r = subprocess.run([sys.executable, sp, "prompt-gate", acc, sid], capture_output=True)
    ok(r.returncode == 0, "prompt-gate allows without lease")
    sessions.lease_acquire(acc, sid)
    r = subprocess.run([sys.executable, sp, "prompt-gate", acc, sid],
                       capture_output=True, text=True)
    ok(r.returncode == 2 and "restarting" in r.stderr, "prompt-gate blocks (exit 2) under lease")
    sessions.lease_release(acc, sid)

    # (r12 #10) an idle/prompt/stop/end event for a sid with NO prior SessionStart must NOT
    # fabricate an authoritative record (a failed start + idle_prompt would otherwise create a
    # home-less/pid-less IDLE record that restart.py accepts as a candidate).
    acc10 = tempfile.mkdtemp(prefix="sess10-")
    ghost = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    sessions.record_event(acc10, "idle", ghost, {"pid": 1234})
    live10 = sessions.live_sessions(acc10)
    ok(ghost not in live10, "idle on an unregistered sid creates NO record (r12 #10)")
    # a proper start THEN idle does register + go IDLE (normal path still works)
    sessions.record_event(acc10, "start", ghost, {"home": "/h", "cwd": "/c", "pid": os.getpid(),
                                                  "transcript": "/t"})
    sessions.record_event(acc10, "idle", ghost, {"pid": os.getpid()})
    live10b = sessions.live_sessions(acc10)
    ok(ghost in live10b and live10b[ghost].get("state") == "IDLE",
       "start-then-idle registers + goes IDLE (normal path intact) (r12 #10)")

    # (r13 #4) prompt_admit must NOT fabricate a record for an unknown sid (failed-start race).
    acc4 = tempfile.mkdtemp(prefix="sess4-")
    unk = "12121212-3434-5656-7878-909090909090"
    admitted = sessions.prompt_admit(acc4, unk, ev_pid=os.getpid())
    ok(admitted is True, "prompt_admit on an unregistered sid admits as a no-op (r13 #4)")
    ok(unk not in sessions.live_sessions(acc4), "prompt_admit creates NO record for an unknown sid (r13 #4)")

    # (r13 #5) lease_acquire REFUSES when the owner start-time is unprovable (empty) — else a
    # later recovery could never prove the dead controller gone (permanent lease block).
    acc5 = tempfile.mkdtemp(prefix="sess5-")
    lsid = "aaaaaaaa-1111-2222-3333-444444444444"
    _orig_ps = sessions._proc_start
    sessions._proc_start = lambda pid: ""       # simulate a persistent ps failure
    try:
        got = sessions.lease_acquire(acc5, lsid, txn="t5")
    finally:
        sessions._proc_start = _orig_ps
    ok(got is False, "lease_acquire REFUSES with an unprovable (empty) start-time (r13 #5)")
    ok(not sessions.lease_held(acc5, lsid), "no lease left behind after the refused acquire (r13 #5)")
    # with a real start-time it acquires normally
    ok(sessions.lease_acquire(acc5, lsid, txn="t5b") is True, "lease_acquire succeeds with a real start-time (r13 #5)")
    sessions.lease_release(acc5, lsid)

    print(f"-- sessions: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
