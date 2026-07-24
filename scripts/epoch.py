#!/usr/bin/env python3
"""epoch.py — the v2 protocol epoch: {state, generation} with lock-serialized fencing.

Design: ISOLATION-DESIGN.md §8 (rev 5). stdlib only.

The EPOCH file (`<bank_dir>/EPOCH`) carries `{"state": "v1"|"shadow"|"v2",
"generation": N}`. Absent file == {"state": "v1", "generation": 0} (pre-v2 world).

Fencing contract (the whole point):
  - A mutator records `snapshot = read_epoch(bank_dir)` at the moment it ACQUIRES its
    lock, and calls `fence(bank_dir, snapshot, allowed_states)` immediately before its
    FIRST mutation, while STILL holding the lock. Any difference in state OR
    generation (exact compare — ABA-proof, generations only ever increment) raises
    EpochFenced, and the caller must release + exit 78.
  - Transitions and the SEEDING freeze increment `generation` under the full ordered
    lock barrier (bank → pointer → homes lexicographic), so an in-flight mutator that
    was admitted under the old generation trips its fence deterministically.

Writes are temp+rename+fsync (file and directory). Malformed/unreadable EPOCH is
FAIL-CLOSED for mutators: fence() treats it as a mismatch, read_epoch() reports it
distinctly rather than defaulting.
"""
import json
import os
import tempfile

EXIT_FENCED = 78          # the one exit code for "epoch says this tool must not act"
STATES = ("v1", "shadow", "v2")


class EpochError(Exception):
    """EPOCH file exists but is unreadable/malformed — fail closed, never default."""


class EpochFenced(Exception):
    """The world changed between lock-acquire and mutate; caller exits EXIT_FENCED."""


def _path(bank_dir):
    return os.path.join(bank_dir, "EPOCH")


def read_epoch(bank_dir):
    """Returns {"state": ..., "generation": int}. Absent file => v1/0 (the pre-v2
    world is a valid, well-defined state). A PRESENT-but-broken file raises
    EpochError — mutators must treat that as a fence, never as v1."""
    p = _path(bank_dir)
    if not os.path.exists(p):
        return {"state": "v1", "generation": 0}
    try:
        with open(p) as f:
            d = json.load(f)
    except Exception as e:
        raise EpochError(f"EPOCH unreadable: {e}")
    st, gen = d.get("state"), d.get("generation")
    if st not in STATES or not isinstance(gen, int) or isinstance(gen, bool) or gen < 0:
        raise EpochError(f"EPOCH malformed: {d!r}")
    return {"state": st, "generation": gen}


def write_epoch(bank_dir, state, generation):
    """Durable temp+rename+fsync write. Caller MUST hold the full ordered barrier
    (this module does not lock — banklock composition happens in the flip tool, so
    lock ordering lives in exactly one place)."""
    if state not in STATES:
        raise ValueError(f"bad state {state!r}")
    if not isinstance(generation, int) or isinstance(generation, bool) or generation < 0:
        raise ValueError(f"bad generation {generation!r}")
    dirn = bank_dir
    fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".epoch.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"state": state, "generation": generation}, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, _path(bank_dir))
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(dirn, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def bump(bank_dir, state=None):
    """generation += 1 (and optionally a state change) — used by transitions AND the
    SEEDING freeze/unfreeze. Caller holds the full barrier. Returns the new epoch."""
    try:
        cur = read_epoch(bank_dir)
    except EpochError:
        # A broken EPOCH can only be repaired by an explicit owner-driven flip; bump
        # refuses to guess (fail-closed).
        raise
    new = {"state": state if state is not None else cur["state"],
           "generation": cur["generation"] + 1}
    write_epoch(bank_dir, new["state"], new["generation"])
    return new


def fence(bank_dir, snapshot, allowed_states):
    """The pre-mutation check. `snapshot` is what the caller read at lock-acquire.
    Raises EpochFenced unless the CURRENT epoch (a) still equals the snapshot
    EXACTLY (state and generation) and (b) is in `allowed_states`. An EpochError
    (broken file) fences too — fail closed."""
    try:
        cur = read_epoch(bank_dir)
    except EpochError as e:
        raise EpochFenced(str(e))
    if cur != snapshot:
        raise EpochFenced(f"epoch moved: had {snapshot}, now {cur}")
    if cur["state"] not in allowed_states:
        raise EpochFenced(f"state {cur['state']!r} not in {allowed_states}")
    return cur


SEEDING_MARKER = ".seeding.json"


def v1_gate(bank_dir, allowed=("v1", "shadow")):
    """Current-state gate for v1 credential mutators (rev 6 §7/§8): the state must
    be in `allowed` AND no SEEDING freeze may be active. This is the new-entrant
    check (the generation fence handles in-flight mutators). Raises EpochFenced."""
    if os.path.exists(os.path.join(bank_dir, SEEDING_MARKER)):
        raise EpochFenced("SEEDING freeze active; v1 mutation refused")
    try:
        cur = read_epoch(bank_dir)
    except EpochError as e:
        raise EpochFenced(str(e))
    if cur["state"] not in allowed:
        raise EpochFenced(f"state {cur['state']!r} not in {allowed}")
    return cur


# ---- shell bridge -----------------------------------------------------------
# v1 shell mutators call:  epoch.py snapshot <bank_dir>          -> "state gen"
#                          epoch.py fence <bank_dir> <state> <gen> <allowed...>
#                          epoch.py v1-gate <bank_dir>
# fence/v1-gate exit 0 (pass) or EXIT_FENCED. Anything else (usage, IO) exits 2.
def _cli():
    import sys
    try:
        cmd, bank_dir = sys.argv[1], sys.argv[2]
        if cmd == "snapshot":
            e = read_epoch(bank_dir)
            print(f"{e['state']} {e['generation']}")
            return 0
        if cmd == "fence":
            snap = {"state": sys.argv[3], "generation": int(sys.argv[4])}
            allowed = tuple(sys.argv[5:])
            try:
                fence(bank_dir, snap, allowed)
                return 0
            except EpochFenced as e:
                print(f"epoch fence: {e}", file=sys.stderr)
                return EXIT_FENCED
        if cmd == "v1-gate":
            try:
                v1_gate(bank_dir)
                return 0
            except EpochFenced as e:
                print(f"epoch v1-gate: {e}", file=sys.stderr)
                return EXIT_FENCED
        print(f"epoch.py: unknown command {cmd!r}", file=sys.stderr)
        return 2
    except EpochError as e:
        # snapshot of a broken EPOCH: report distinctly; shell callers treat
        # nonzero-non-78 as "do not proceed" too.
        print(f"epoch: {e}", file=sys.stderr)
        return 2
    except (IndexError, ValueError) as e:
        print(f"epoch.py usage error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
