#!/usr/bin/env python3
"""Tests for homerec.py — repair-only-while-broken, fail-closed INDETERMINATE,
foreign-blob repair, healed-externally abort, no-candidate reconnect."""
import json
import os
import sys
import tempfile
from collections import namedtuple

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import homerec  # noqa: E402
import homewrite  # noqa: E402
import registry  # noqa: E402

FAILS = []
C = [0]
R = namedtuple("R", "verdict uuid email plan detail")


def ok(c, m):
    C[0] += 1
    print(("  ok   " if c else "  FAIL ") + m)
    if not c:
        FAILS.append(m)


def oauth(tag):
    return {"accessToken": f"at-{tag}", "refreshToken": f"rt-{tag}", "expiresAt": 9999999999999}


def stub_resolver(mapping):
    """token -> R; unknown tokens are INVALID."""
    def res(tok):
        return mapping.get(tok, R("INVALID", "", "", "", "unknown"))
    return res


def cred_of(home):
    with open(os.path.join(home, ".credentials.json")) as f:
        return json.load(f)["claudeAiOauth"]


def main():
    acc = tempfile.mkdtemp(prefix="hrec-acc-")
    home = os.path.join(acc, "homes", "a-at-x.com")
    os.makedirs(home)
    registry.publish_ready(acc, "a@x.com", home, "uuid-a")

    OWN = lambda tag: (f"at-{tag}", R("RESOLVED", "uuid-a", "a@x.com", "max", "ok"))  # noqa: E731
    FOREIGN = lambda tag: (f"at-{tag}", R("RESOLVED", "uuid-b", "b@x.com", "pro", "ok"))  # noqa: E731

    # healthy home untouched
    homewrite.write_credential(home, oauth("good"), "seed")
    res = stub_resolver(dict([OWN("good")]))
    v = homerec.reconcile_home(acc, "a@x.com", resolver=res)
    ok(v.startswith("healthy"), f"healthy untouched ({v})")

    # foreign blob + own archived candidate -> repaired
    homewrite.write_credential(home, oauth("good2"), "rotate")   # archives good
    with open(os.path.join(home, ".credentials.json"), "w") as f:
        json.dump({"claudeAiOauth": oauth("stray")}, f)          # foreign lands (raw write, like the CLI)
    res = stub_resolver(dict([OWN("good"), OWN("good2"), FOREIGN("stray")]))
    v = homerec.reconcile_home(acc, "a@x.com", resolver=res)
    ok(v.startswith("repaired"), f"foreign blob repaired ({v})")
    ok(cred_of(home)["accessToken"] == "at-good", "newest OWN archived candidate installed (good2 was never archived — raw foreign write)")

    # INDETERMINATE -> fail closed, no repair
    with open(os.path.join(home, ".credentials.json"), "w") as f:
        json.dump({"claudeAiOauth": oauth("stray2")}, f)
    res = stub_resolver({"at-stray2": R("INDETERMINATE", "", "", "", "net")})
    v = homerec.reconcile_home(acc, "a@x.com", resolver=res)
    ok(v.startswith("indeterminate"), f"INDETERMINATE fail-closed ({v})")
    ok(cred_of(home)["accessToken"] == "at-stray2", "nothing written on INDETERMINATE")

    # broken with no healthy candidate -> reconnect card
    res = stub_resolver({"at-stray2": R("INVALID", "", "", "", "401")})
    v = homerec.reconcile_home(acc, "a@x.com", resolver=res)
    ok("needs-reconnect" in v, f"no candidate -> reconnect card ({v})")

    # schema-invalid file counts as broken; repair from archive
    with open(os.path.join(home, ".credentials.json"), "w") as f:
        f.write("{ torn")
    res = stub_resolver(dict([OWN("good"), OWN("good2")]))
    v = homerec.reconcile_home(acc, "a@x.com", resolver=res)
    ok(v.startswith("repaired") and cred_of(home)["accessToken"] in ("at-good", "at-good2"),
       f"torn file repaired from archive ({v})")

    # (finding 38) a credential with the RIGHT email but a DIFFERENT uuid than the
    # registry recorded is FOREIGN, not the home owner: install a same-email/wrong-uuid
    # blob with no own candidate -> reconnect card (never accepted as healthy).
    with open(os.path.join(home, ".credentials.json"), "w") as f:
        json.dump({"claudeAiOauth": oauth("wronguuid")}, f)
    SAME_EMAIL_DIFF_UUID = R("RESOLVED", "uuid-DIFFERENT", "a@x.com", "max", "ok")
    res = stub_resolver({"at-wronguuid": SAME_EMAIL_DIFF_UUID})
    v = homerec.reconcile_home(acc, "a@x.com", resolver=res)
    ok("needs-reconnect" in v or "no healthy" in v,
       f"same email + different uuid treated as foreign (finding 38: {v})")

    # (r2 finding 38) a home whose registry uuid is missing/"unknown" cannot be proven
    # owned -> fail closed, NEVER email-only fallback.
    acc2 = tempfile.mkdtemp(prefix="hrec-uuidless-")
    home2 = os.path.join(acc2, "homes", "a-at-x.com")
    os.makedirs(home2)
    registry.publish_ready(acc2, "a@x.com", home2, "unknown")   # uuid unknown
    homewrite.write_credential(home2, oauth("x"), "seed")
    res2 = stub_resolver({"at-x": R("RESOLVED", "some-uuid", "a@x.com", "max", "ok")})
    v = homerec.reconcile_home(acc2, "a@x.com", resolver=res2)
    ok("uuid missing/unknown" in v,
       f"missing/unknown registry uuid -> fail-closed, no email-only ownership (finding 38: {v})")

    # not-READY -> no-op
    v = homerec.reconcile_home(acc, "ghost@x.com", resolver=res)
    ok(v.startswith("not-ready"), "unknown email -> not-ready no-op")

    # (r10 #14) the reconciler installs an archived credential -> a v2 home mutation,
    # shadow|v2 only. Set up a BROKEN home with a healthy archived candidate, then:
    #   EPOCH v1  -> epoch-parked (no repair);  shadow -> repairs (proceeds).
    import epoch  # noqa: E402
    acc3 = tempfile.mkdtemp(prefix="hrec-epoch-")
    home3 = os.path.join(acc3, "homes", "a-at-x.com")
    os.makedirs(home3)
    registry.publish_ready(acc3, "a@x.com", home3, "uuid-a")
    homewrite.write_credential(home3, oauth("healthy3"), "seed")     # a healthy archived candidate
    homewrite.write_credential(home3, oauth("broken3"), "cli-foreign")  # current = foreign/invalid
    res3 = stub_resolver(dict([OWN("healthy3"), ("at-broken3", R("INVALID", "", "", "", "rejected"))]))
    epoch.write_epoch(acc3, "v1", 1)
    v = homerec.reconcile_home(acc3, "a@x.com", resolver=res3)
    ok(v.startswith("epoch-parked"), f"reconciler PARKED under EPOCH v1 (no v2 home mutation) (r10 #14): {v}")
    ok(cred_of(home3)["accessToken"] == "at-broken3",
       "broken credential left UNTOUCHED while epoch-parked (r10 #14)")
    epoch.write_epoch(acc3, "shadow", 2)
    v = homerec.reconcile_home(acc3, "a@x.com", resolver=res3)
    ok(v.startswith("repaired") or v.startswith("healthy") or "healed" in v,
       f"reconciler PROCEEDS under EPOCH shadow (r10 #14): {v}")
    # a broken EPOCH fails closed (no repair)
    with open(os.path.join(acc3, "EPOCH"), "w") as f:
        f.write("{broken")
    v = homerec.reconcile_home(acc3, "a@x.com", resolver=res3)
    ok("epoch-unreadable" in v, f"broken EPOCH -> fail-closed, no repair (r10 #14): {v}")

    # (r11 #6) TOCTOU: epoch re-checked UNDER the home lock. shadow on the pre-lock read,
    # v1 on the under-lock read (a concurrent flip landed) -> reconciler must park and leave
    # the broken credential untouched.
    import epoch as _ep  # noqa: E402
    acc4 = tempfile.mkdtemp(prefix="hrec-toctou-")
    home4 = os.path.join(acc4, "homes", "a-at-x.com")
    os.makedirs(home4)
    registry.publish_ready(acc4, "a@x.com", home4, "uuid-a")
    homewrite.write_credential(home4, oauth("healthy4"), "seed")
    homewrite.write_credential(home4, oauth("broken4"), "cli-foreign")
    res4 = stub_resolver(dict([OWN("healthy4"), ("at-broken4", R("INVALID", "", "", "", "rejected"))]))
    _ep.write_epoch(acc4, "shadow", 1)
    _seq = [{"state": "shadow", "generation": 1}, {"state": "v1", "generation": 2}]
    _orig = homerec.epoch.read_epoch
    def _fake(a):
        return _seq.pop(0) if _seq else {"state": "v1", "generation": 2}
    homerec.epoch.read_epoch = _fake
    try:
        v = homerec.reconcile_home(acc4, "a@x.com", resolver=res4)
    finally:
        homerec.epoch.read_epoch = _orig
    ok(v.startswith("epoch-parked"), f"reconciler catches a flip UNDER the home lock -> parked (r11 #6): {v}")
    ok(cred_of(home4)["accessToken"] == "at-broken4",
       "broken credential UNTOUCHED when the flip landed under the lock (r11 #6)")

    # (r12 #6) _candidates orders NEWEST-FIRST by mtime, NOT by lexicographic name. Two
    # same-second archives whose names sort the STALE one first (higher PID) must still be
    # returned newest-first by real write time.
    import time as _t
    acc6 = tempfile.mkdtemp(prefix="hrec-sort-")
    adir6 = os.path.join(acc6, "homes", "a-at-x.com", "archive")
    os.makedirs(adir6)
    # name STALE with a higher pid (sorts LATER lexicographically), NEWER with a lower pid
    stale = os.path.join(adir6, "20260101T000000Z-009000-0000000000000001.json")
    newer = os.path.join(adir6, "20260101T000000Z-001000-0000000000000002.json")
    open(stale, "w").write('{"claudeAiOauth":{"accessToken":"STALE"}}')
    open(newer, "w").write('{"claudeAiOauth":{"accessToken":"NEWER"}}')
    # make `newer` the chronologically newer file (later mtime), despite the lower pid in name
    os.utime(stale, ns=(1_000_000_000, 1_000_000_000))
    os.utime(newer, ns=(2_000_000_000, 2_000_000_000))
    cands = homerec._candidates(os.path.join(acc6, "homes", "a-at-x.com"))
    ok(cands and cands[0] == newer,
       f"_candidates returns the chronologically-newest archive first (mtime, not name) (r12 #6): {[os.path.basename(c) for c in cands]}")
    # lexicographic name order would have put the higher-PID STALE entry first
    ok(sorted([stale, newer], reverse=True)[0] == stale,
       "sanity: lexicographic name order WOULD mis-rank the stale entry first (r12 #6)")

    # (seat) reconcile installs into the home's SEAT: when the seat is the per-config-dir SLOT
    # (the CLI migrated the home), the repaired credential is written to the SLOT, not a file.
    import seedflow as _sf
    import epoch as _ep5
    acc5 = tempfile.mkdtemp(prefix="hrec-slot-")
    home5 = os.path.join(acc5, "homes", "a-at-x.com"); os.makedirs(home5)
    registry.publish_ready(acc5, "a@x.com", home5, "uuid-a")
    fk5 = os.path.join(acc5, "fkc")
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fk5
    slotsvc5 = _sf.config_slot_service(home5)
    # a BROKEN (INVALID) credential in the SLOT seat, NO .credentials.json file
    with open(_sf._fake_slot_path(fk5, slotsvc5), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"at-broken5","refreshToken":"r","expiresAt":9}}')
    # a healthy OWN candidate in the archive
    os.makedirs(os.path.join(home5, "archive"))
    with open(os.path.join(home5, "archive", "20260101T000000Z-1-1-observed.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"at-healthy5","refreshToken":"r","expiresAt":9}}')
    res5 = stub_resolver(dict([OWN("healthy5"), ("at-broken5", R("INVALID", "", "", "", "rejected"))]))
    _ep5.write_epoch(acc5, "shadow", 1)
    try:
        v = homerec.reconcile_home(acc5, "a@x.com", resolver=res5)
        ok(v.startswith("repaired"), f"(seat) reconcile repairs a broken SLOT-seat home: {v}")
        ok(not os.path.exists(os.path.join(home5, ".credentials.json")),
           "(seat) reconcile did NOT create a file for a slot seat")
        _b, _r, _st, _k = _sf.seat_read(home5)
        ok(_k == "slot" and _b["claudeAiOauth"]["accessToken"] == "at-healthy5",
           "(seat) reconcile installed the healthy credential INTO THE SLOT")
    finally:
        os.environ.pop("ACCOUNT_BANK_FAKE_KEYCHAIN", None)

    print(f"-- homerec: {C[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
