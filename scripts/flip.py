#!/usr/bin/env python3
"""flip.py — epoch state transitions under the FULL ordered lock barrier (rev 7 §8).

    flip.py to <state>        v1 -> shadow -> v2 (and any rollback direction)
    flip.py status

Rules:
  - the barrier acquires bank -> pointer -> homes (lexicographic) with timeout +
    exact-reverse unwind (seedflow._ordered_locks is THE implementation);
  - the home registry is FROZEN by the barrier (seeding also takes the bank lock,
    so no home can appear mid-flip);
  - every transition increments generation (ABA);
  - a SEEDING freeze blocks any flip (recover it first);
  - transitions are restricted to adjacent states (v1<->shadow<->v2): skipping a
    state would skip its verification phase, so it is refused.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import epoch
import seedflow

ADJACENT = {("v1", "shadow"), ("shadow", "v1"), ("shadow", "v2"), ("v2", "shadow")}
ATTESTATION_MAX_AGE_S = 600     # (finding 28) a cutover attestation older than 10 min is stale


# the launch surfaces §8 requires attested; every one must be PRESENT and ok. (r5 item 3)
# the archiver-health surface is included — cutover must not proceed without the tier-2
# archiver daemon loaded and heartbeating.
REQUIRED_SURFACES = ("shim-installed", "zsh-login-shell", "live-shells",
                     "vscode-hosts", "launchd-jobs", "cron-jobs", "quotabar-process",
                     "archiver")


def _require_fresh_attestation(acc):
    """(finding 28) The shadow->v2 cutover is gated on a FRESH, passing, COMPLETE
    launch-surface attestation (attest-cutover.sh writes accounts/attestation.json).
    An empty report, a future timestamp, a missing/failing required surface, a failing
    report, or a stale (>10 min) one all refuse the flip — a direct `flip.py to v2`
    must NOT bypass the launch-surface gate, and a forged `{ts:future,fails:0,checks:[]}`
    proves nothing."""
    p = os.path.join(acc, "attestation.json")
    try:
        with open(p) as f:
            rep = json.load(f)
    except Exception as e:
        raise RuntimeError(
            f"cutover to v2 requires a fresh attestation.json ({e}); run attest-cutover.sh first")
    if not isinstance(rep, dict) or rep.get("fails", 1) != 0:
        raise RuntimeError(
            f"attestation reports {rep.get('fails')!r} failing launch surface(s); refusing v2")
    checks = rep.get("checks")
    if not isinstance(checks, list) or not checks:
        raise RuntimeError(
            "attestation has NO checks (an empty report attests nothing); re-run attest-cutover.sh")
    got = {c.get("check"): c.get("ok") for c in checks if isinstance(c, dict)}
    missing = [s for s in REQUIRED_SURFACES if s not in got]
    if missing:
        raise RuntimeError(f"attestation is missing required surfaces {missing}; re-run attest-cutover.sh")
    not_ok = [s for s in REQUIRED_SURFACES if got.get(s) is not True]
    if not_ok:
        raise RuntimeError(f"attestation surfaces not passing {not_ok}; refusing v2")
    ts = rep.get("ts") or 0
    now = time.time()
    if ts > now + 60:                       # (finding 28) a future ts is a forgery/clock fault
        raise RuntimeError(f"attestation timestamp is in the FUTURE ({int(ts)} > now); refusing v2")
    age = now - ts
    if age > ATTESTATION_MAX_AGE_S:
        raise RuntimeError(
            f"attestation is stale ({int(age)}s > {ATTESTATION_MAX_AGE_S}s); "
            "re-run attest-cutover.sh immediately before flipping to v2")


def flip(acc, target):
    if target not in epoch.STATES:
        raise ValueError(f"unknown state {target!r}")
    locks = seedflow._ordered_locks(acc)
    try:
        if seedflow._journal_read(acc) is not None:
            raise RuntimeError("SEEDING transaction present; recover it before flipping")
        cur = epoch.read_epoch(acc)
        if cur["state"] == target:
            return cur                       # idempotent
        if (cur["state"], target) not in ADJACENT:
            raise RuntimeError(f"non-adjacent transition {cur['state']} -> {target} refused")
        if (cur["state"], target) == ("shadow", "v2"):
            _require_fresh_attestation(acc)  # (finding 28) ONLY the cutover transition
        return epoch.bump(acc, target)
    finally:
        seedflow._release(locks)


def main():
    acc = os.environ.get("ACCOUNT_BANK_DIR", os.path.expanduser("~/.claude/accounts"))
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        try:
            print(epoch.read_epoch(acc))
        except epoch.EpochError as e:
            print(f"EPOCH broken: {e}", file=sys.stderr)
            return 2
        return 0
    if cmd == "to":
        try:
            print(flip(acc, sys.argv[2]))
            return 0
        except (RuntimeError, ValueError, epoch.EpochError) as e:
            print(f"flip: {e}", file=sys.stderr)
            return 1
    print("usage: flip.py status | to <v1|shadow|v2>", file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
