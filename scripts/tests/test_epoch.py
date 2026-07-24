#!/usr/bin/env python3
"""Tests for epoch.py — state/generation fencing (ISOLATION-DESIGN rev 5 §8).
Hard-fail fixtures only (suite policy)."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import epoch  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    d = tempfile.mkdtemp(prefix="epochtest-")

    # absent file == v1/0 (defined pre-v2 world)
    ok(epoch.read_epoch(d) == {"state": "v1", "generation": 0},
       "absent EPOCH reads as v1/0")

    # write + read round-trip, durable perms
    epoch.write_epoch(d, "shadow", 3)
    ok(epoch.read_epoch(d) == {"state": "shadow", "generation": 3},
       "write/read round-trip")
    ok(oct(os.stat(os.path.join(d, "EPOCH")).st_mode & 0o777) == "0o600",
       "EPOCH file is 0600")

    # bump increments generation, preserves state unless told otherwise
    ok(epoch.bump(d) == {"state": "shadow", "generation": 4}, "bump keeps state")
    ok(epoch.bump(d, "v2") == {"state": "v2", "generation": 5}, "bump can transition")

    # fence: exact-match pass
    snap = epoch.read_epoch(d)
    ok(epoch.fence(d, snap, ("v2",)) == snap, "fence passes on exact match")

    # fence: generation moved (the SEEDING/flip case) -> fenced even if state same
    epoch.bump(d)
    fenced = False
    try:
        epoch.fence(d, snap, ("v2",))
    except epoch.EpochFenced:
        fenced = True
    ok(fenced, "generation change alone trips the fence (ABA-proof)")

    # fence: right generation, disallowed state
    snap2 = epoch.read_epoch(d)
    fenced = False
    try:
        epoch.fence(d, snap2, ("v1", "shadow"))
    except epoch.EpochFenced:
        fenced = True
    ok(fenced, "disallowed state trips the fence")

    # malformed EPOCH: read raises, fence fails closed, bump refuses
    with open(os.path.join(d, "EPOCH"), "w") as f:
        f.write("{ not json")
    raised = False
    try:
        epoch.read_epoch(d)
    except epoch.EpochError:
        raised = True
    ok(raised, "malformed EPOCH raises EpochError (never defaults)")
    fenced = False
    try:
        epoch.fence(d, snap2, ("v2",))
    except epoch.EpochFenced:
        fenced = True
    ok(fenced, "malformed EPOCH fences (fail-closed)")
    raised = False
    try:
        epoch.bump(d)
    except epoch.EpochError:
        raised = True
    ok(raised, "bump refuses a broken EPOCH")

    # state/generation validation on write
    for bad in (("nope", 1), ("v1", -1), ("v1", True)):
        raised = False
        try:
            epoch.write_epoch(d, *bad)
        except ValueError:
            raised = True
        ok(raised, f"write rejects {bad!r}")

    # shell bridge: snapshot + fence pass/fail + exit codes
    epoch.write_epoch(d, "v1", 9)
    ep = os.path.join(HERE, "epoch.py")
    snapout = subprocess.run([sys.executable, ep, "snapshot", d],
                             capture_output=True, text=True)
    ok(snapout.returncode == 0 and snapout.stdout.split() == ["v1", "9"],
       "CLI snapshot prints 'state gen'")
    r = subprocess.run([sys.executable, ep, "fence", d, "v1", "9", "v1", "shadow"],
                       capture_output=True, text=True)
    ok(r.returncode == 0, "CLI fence passes on match")
    r = subprocess.run([sys.executable, ep, "fence", d, "v1", "8", "v1"],
                       capture_output=True, text=True)
    ok(r.returncode == epoch.EXIT_FENCED, "CLI fence exits 78 on generation mismatch")
    r = subprocess.run([sys.executable, ep, "fence", d, "v1", "9", "v2"],
                       capture_output=True, text=True)
    ok(r.returncode == epoch.EXIT_FENCED, "CLI fence exits 78 on disallowed state")

    print(f"-- epoch: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
