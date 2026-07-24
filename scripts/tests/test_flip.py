#!/usr/bin/env python3
"""Tests for flip.py — adjacency, idempotence, SEEDING block, generation ABA."""
import json, os, sys, tempfile, time
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import epoch, flip, seedflow  # noqa: E402


def _attest(acc, fails=0, age=0, checks=None, ts=None):
    if checks is None:
        checks = [{"check": s, "ok": True, "detail": "ok"} for s in flip.REQUIRED_SURFACES]
    rec = {"ts": int(time.time()) - age if ts is None else ts, "fails": fails, "checks": checks}
    with open(os.path.join(acc, "attestation.json"), "w") as f:
        json.dump(rec, f)

FAILS = []; C = [0]
def ok(c, m):
    C[0] += 1; print(("  ok   " if c else "  FAIL ") + m)
    if not c: FAILS.append(m)

def main():
    acc = tempfile.mkdtemp(prefix="flip-acc-")
    os.makedirs(os.path.join(acc, "homes"))
    fake = os.path.join(acc, "fake-kc.json")
    open(fake, "w").write('{"claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 9}}')
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fake
    ok(flip.flip(acc, "shadow") == {"state": "shadow", "generation": 1}, "v1 -> shadow")
    ok(flip.flip(acc, "shadow") == {"state": "shadow", "generation": 1}, "idempotent same-state")

    # (finding 28) shadow -> v2 REFUSED without a fresh passing attestation
    raised = False
    try: flip.flip(acc, "v2")
    except RuntimeError as e: raised = "attestation" in str(e)
    ok(raised, "shadow -> v2 refused with NO attestation (finding 28)")
    _attest(acc, fails=2)                    # a failing report is not enough
    raised = False
    try: flip.flip(acc, "v2")
    except RuntimeError as e: raised = "failing" in str(e)
    ok(raised, "shadow -> v2 refused with a FAILING attestation (finding 28)")
    _attest(acc, fails=0, age=1200)          # passing but stale (>10 min)
    raised = False
    try: flip.flip(acc, "v2")
    except RuntimeError as e: raised = "stale" in str(e)
    ok(raised, "shadow -> v2 refused with a STALE attestation (finding 28)")

    # (r2 finding 28) an EMPTY-checks report attests nothing -> refused
    _attest(acc, fails=0, age=0, checks=[])
    raised = False
    try: flip.flip(acc, "v2")
    except RuntimeError as e: raised = "NO checks" in str(e) or "no checks" in str(e).lower()
    ok(raised, "shadow -> v2 refused with an EMPTY-checks report (finding 28)")

    # (r2 finding 28) a FUTURE timestamp (forgery/clock) -> refused
    _attest(acc, fails=0, ts=int(time.time()) + 100000)
    raised = False
    try: flip.flip(acc, "v2")
    except RuntimeError as e: raised = "FUTURE" in str(e)
    ok(raised, "shadow -> v2 refused with a FUTURE-timestamp report (finding 28)")

    # (r2 finding 28) a report missing a REQUIRED surface -> refused
    _attest(acc, fails=0, age=0, checks=[{"check": "shim-installed", "ok": True}])
    raised = False
    try: flip.flip(acc, "v2")
    except RuntimeError as e: raised = "missing required surfaces" in str(e)
    ok(raised, "shadow -> v2 refused when a required surface is absent (finding 28)")

    _attest(acc, fails=0, age=0)             # fresh + passing + complete -> allowed
    ok(flip.flip(acc, "v2") == {"state": "v2", "generation": 2}, "shadow -> v2 with fresh attestation")
    raised = False
    try: flip.flip(acc, "v1")
    except RuntimeError: raised = True
    ok(raised, "v2 -> v1 (non-adjacent) refused")
    ok(flip.flip(acc, "shadow")["generation"] == 3, "rollback v2 -> shadow bumps gen")
    seedflow.freeze(acc, "a@x.com")
    raised = False
    try: flip.flip(acc, "v2")
    except RuntimeError as e: raised = "SEEDING" in str(e)
    ok(raised, "SEEDING freeze blocks flip")
    print(f"-- flip: {C[0]-len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0

if __name__ == "__main__":
    raise SystemExit(main())
