#!/usr/bin/env python3
"""Tests for repoint.py — pointer transaction, recovery, --back (rev 5 §4)."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import repoint  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def log_records(acc):
    p = os.path.join(acc, "pointer.log")
    if not os.path.exists(p):
        return []
    out = []
    with open(p) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def main():
    acc = tempfile.mkdtemp(prefix="repoint-acc-")
    homes = {}
    for e in ("a", "b", "c"):
        h = os.path.join(acc, "homes", e)
        os.makedirs(h)
        homes[e] = h
    ready = lambda h: h in homes.values()  # noqa: E731

    # READY gate is mandatory and fail-closed
    raised = False
    try:
        repoint.repoint(acc, homes["a"], "t")
    except repoint.RepointError:
        raised = True
    ok(raised, "no registry_check -> refused")
    raised = False
    try:
        repoint.repoint(acc, os.path.join(acc, "homes", "ghost"), "t", registry_check=ready)
    except repoint.RepointError:
        raised = True
    ok(raised, "non-READY target refused")

    # first repoint: intent + commit, live symlink correct
    r1 = repoint.repoint(acc, homes["a"], "seed", registry_check=ready)
    ok(repoint.read_current(acc) == homes["a"], "pointer -> a")
    recs = log_records(acc)
    ok([x["kind"] for x in recs] == ["intent", "commit"], "intent+commit logged")
    ok(recs[0]["from"] is None and recs[0]["to"] == homes["a"], "intent from=None to=a")

    # second repoint records from=a
    repoint.repoint(acc, homes["b"], "switch", registry_check=ready)
    ok(repoint.read_current(acc) == homes["b"], "pointer -> b")
    recs = log_records(acc)
    ok(recs[2]["from"] == homes["a"] and recs[2]["to"] == homes["b"], "second intent from=a to=b")

    # crash simulation 1: intent without commit + moved symlink -> synthetic commit
    # (append a bare intent, move the pointer manually, then run any transaction)
    with open(os.path.join(acc, "pointer.log"), "a") as f:
        f.write(json.dumps({"kind": "intent", "txn": "crashed-txn",
                            "from": homes["b"], "to": homes["c"],
                            "why": "crash", "pid": 0, "ts": 0}) + "\n")
    os.remove(os.path.join(acc, repoint.POINTER_NAME))
    os.symlink(homes["c"], os.path.join(acc, repoint.POINTER_NAME))
    repoint.repoint(acc, homes["a"], "after-crash", registry_check=ready)
    recs = log_records(acc)
    kinds = [x["kind"] for x in recs]
    ok("synthetic-commit" in kinds, "crash intent healed with synthetic-commit")
    syn = [x for x in recs if x["kind"] == "synthetic-commit"][0]
    ok(syn["txn"] == "crashed-txn" and syn["observed_target"] == homes["c"],
       "synthetic-commit bound to crashed txn + OBSERVED target")

    # crash simulation 2: partial trailing line is physically truncated
    with open(os.path.join(acc, "pointer.log"), "a") as f:
        f.write('{"kind": "intent", "txn": "torn')   # no newline
    repoint.repoint(acc, homes["b"], "after-heal", registry_check=ready)
    recs = log_records(acc)
    ok(all(r.get("txn") != "torn" for r in recs), "torn tail physically removed")
    ok(repoint.read_current(acc) == homes["b"], "pointer -> b after torn-tail heal")

    # --back: returns to the previous committed target, as a forward transaction
    repoint.back(acc, registry_check=ready)
    ok(repoint.read_current(acc) == homes["a"], "--back returns to a")
    recs = log_records(acc)
    ok(recs[-1]["kind"] == "commit" and recs[-2]["kind"] == "intent"
       and recs[-2]["why"] == "back", "--back is an appended forward transaction")

    # --back gate: registry check still applies
    raised = False
    try:
        repoint.back(acc, registry_check=lambda h: False)
    except repoint.RepointError:
        raised = True
    ok(raised, "--back refuses a non-READY 'from'")

    # (finding 17) refuse to point current at itself (current -> current)
    raised = False
    try:
        repoint.repoint(acc, os.path.join(acc, repoint.POINTER_NAME), "self",
                        registry_check=lambda h: True)
    except repoint.RepointError as e:
        raised = "self-referential" in str(e)
    ok(raised, "self-referential pointer refused (finding 17)")

    # (finding 16) recovery must REJECT a non-READY observed target — a corrupted
    # `current -> /tmp/x` is an incident (pointer frozen), NOT laundered into history.
    acc2 = tempfile.mkdtemp(prefix="repoint-inc-")
    hz = os.path.join(acc2, "homes", "z")
    os.makedirs(hz)
    ready2 = lambda x: x == hz  # noqa: E731
    repoint.repoint(acc2, hz, "seed", registry_check=ready2)
    with open(os.path.join(acc2, "pointer.log"), "a") as f:
        f.write(json.dumps({"kind": "intent", "txn": "bad", "from": hz, "to": "/tmp/x",
                            "why": "crash", "pid": 0, "ts": 0}) + "\n")
    os.remove(os.path.join(acc2, repoint.POINTER_NAME))
    os.symlink("/tmp/x", os.path.join(acc2, repoint.POINTER_NAME))
    raised = False
    try:
        repoint.repoint(acc2, hz, "after", registry_check=ready2)
    except repoint.RepointError as e:
        raised = "not a ready" in str(e).lower() or "incident" in str(e).lower()
    ok(raised, "recovery refuses a non-READY observed target (finding 16)")
    recs2 = log_records(acc2)
    ok(all(not (r.get("kind") == "synthetic-commit" and r.get("txn") == "bad") for r in recs2),
       "no synthetic-commit laundered for the incident target (finding 16)")

    # (r2 finding 16) a crashed intent with a MISSING `to` is an incident, not
    # synthesized. observed target is READY (hz) but the intent `to` is absent.
    acc3 = tempfile.mkdtemp(prefix="repoint-inc2-")
    hy = os.path.join(acc3, "homes", "y"); os.makedirs(hy)
    ready3 = lambda x: x == hy  # noqa: E731
    repoint.repoint(acc3, hy, "seed", registry_check=ready3)
    with open(os.path.join(acc3, "pointer.log"), "a") as f:
        f.write(json.dumps({"kind": "intent", "txn": "noto", "from": hy,
                            "why": "crash", "pid": 0, "ts": 0}) + "\n")   # NO "to"
    raised = False
    try:
        repoint.repoint(acc3, hy, "after", registry_check=ready3)
    except repoint.RepointError as e:
        raised = "missing" in str(e).lower() or "not ready" in str(e).lower()
    ok(raised, "crashed intent with missing `to` -> incident, not synthesized (finding 16)")

    # (r2 finding 17) an ALIAS symlink that resolves to a READY home is refused as a
    # pointer target (would enable an indirect current -> alias -> current cycle).
    alias = os.path.join(acc, "homes", "alias-to-a")
    os.symlink(homes["a"], alias)
    raised = False
    try:
        repoint.repoint(acc, alias, "alias", registry_check=lambda h: True)
    except repoint.RepointError as e:
        raised = "symlink" in str(e) or "alias" in str(e)
    ok(raised, "symlink/alias pointer target refused (finding 17 indirect cycle)")

    # (r3 #17) a non-canonical spelling that RESOLVES to a READY home (passes isdir +
    # registry_check) but uses `..`/pointer-name components must be refused — storing it
    # verbatim as the symlink target is how an indirect current -> …/current/… cycle
    # gets created. `homes/b/../a` resolves to homes/a (a real dir) yet embeds `..`.
    embed = os.path.join(acc, "homes", "b", "..", "a")
    ok(os.path.isdir(embed), "sanity: the `..` spelling resolves to a real dir")
    raised = False
    try:
        repoint.repoint(acc, embed, "embed", registry_check=lambda h: True)
    except repoint.RepointError as e:
        raised = "'..'" in str(e) or "component" in str(e)
    ok(raised, "non-canonical `..`-embedding target refused (r3 #17)")
    # and a spelling with the pointer NAME as a component is refused too
    subdir = os.path.join(homes["a"], "sub"); os.makedirs(subdir, exist_ok=True)
    embed2 = os.path.join(acc, repoint.POINTER_NAME, "sub")   # current/sub -> homes/a/sub
    raised = False
    try:
        repoint.repoint(acc, embed2, "embed2", registry_check=lambda h: True)
    except repoint.RepointError as e:
        raised = "pointer name" in str(e) or "component" in str(e)
    ok(raised, "target spelling with the pointer name as a component refused (r3 #17)")

    # (r9 #7) the pointer transaction is a shadow|v2 operation. A PRESENT EPOCH in v1
    # (a rollback) refuses repoint AND --back; shadow|v2 permit; an ABSENT EPOCH stays
    # permissive (the whole test above ran with no EPOCH file).
    import epoch  # noqa: E402
    epoch.write_epoch(acc, "v1", 5)
    raised = False
    try:
        repoint.repoint(acc, homes["a"], "v1-should-refuse", registry_check=ready)
    except repoint.EpochRefused:
        raised = True
    ok(raised, "repoint REFUSED under EPOCH v1 (EpochRefused) (r9 #7)")
    ok(isinstance(repoint.EpochRefused(), repoint.RepointError),
       "EpochRefused is a RepointError subclass (existing callers still fail safe) (r9 #7)")
    raised = False
    try:
        repoint.back(acc, registry_check=ready)
    except repoint.EpochRefused:
        raised = True
    ok(raised, "--back REFUSED under EPOCH v1 (r9 #7)")
    # shadow and v2 both permit the transaction
    epoch.write_epoch(acc, "shadow", 6)
    r_sh = repoint.repoint(acc, homes["c"], "shadow-ok", registry_check=ready)
    ok(r_sh["to"] == homes["c"], "repoint PERMITTED under EPOCH shadow (r9 #7)")
    epoch.write_epoch(acc, "v2", 7)
    r_v2 = repoint.repoint(acc, homes["a"], "v2-ok", registry_check=ready)
    ok(r_v2["to"] == homes["a"], "repoint PERMITTED under EPOCH v2 (r9 #7)")
    # a broken EPOCH fails closed
    with open(os.path.join(acc, "EPOCH"), "w") as f:
        f.write("{not json")
    raised = False
    try:
        repoint.repoint(acc, homes["b"], "broken-epoch", registry_check=ready)
    except repoint.EpochRefused:
        raised = True
    ok(raised, "repoint REFUSED under a broken EPOCH (fail-closed) (r9 #7)")

    # (r11 #5) TOCTOU: the epoch is re-checked UNDER the pointer lock. Simulate a concurrent
    # shadow->v1 flip landing between the pre-lock check and the under-lock check by returning
    # shadow on the first read_epoch and v1 on the second — repoint must refuse (EpochRefused).
    epoch.write_epoch(acc, "shadow", 10)
    _seq = [{"state": "shadow", "generation": 10}, {"state": "v1", "generation": 11}]
    _orig_read = repoint._epoch.read_epoch
    _reads = [0]
    def _fake_read(a):
        _reads[0] += 1
        return _seq.pop(0) if _seq else {"state": "v1", "generation": 11}
    repoint._epoch.read_epoch = _fake_read
    try:
        raised = False
        try:
            repoint.repoint(acc, homes["a"], "toctou", registry_check=ready)
        except repoint.EpochRefused:
            raised = True
        ok(raised and _reads[0] >= 2,
           f"repoint re-checks epoch UNDER the lock; a flip between checks is caught (r11 #5, reads={_reads[0]})")
    finally:
        repoint._epoch.read_epoch = _orig_read

    print(f"-- repoint: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
