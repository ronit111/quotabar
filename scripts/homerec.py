#!/usr/bin/env python3
"""homerec.py — the home reconciler (ISOLATION-DESIGN.md rev 7 §5).

Repairs a READY home ONLY while it is provably broken:
  - .credentials.json unreadable / schema-invalid, or
  - G9 says the credential belongs to a DIFFERENT account (foreign blob), or
  - G9 says INVALID (server-rejected credential) -> surfaced as needs-reconnect
    (repair only if a healthier archived candidate exists).

Commit discipline (under the home lock; the CLI is acknowledged unfenceable):
  re-verify the precondition IMMEDIATELY before commit -> tier-1 write
  (homewrite: pre-archive + temp+rename+fsync + identity gate) -> post-commit
  re-read + G9 verify -> converge loop (bounded). Never touches a home whose
  current blob is healthy-and-own. Never installs a blob without RESOLVED G9
  identity. Never deletes anything.

Candidates come from the home's archive/ (newest first). All G9 INDETERMINATE
verdicts abort the run (fail-closed) — a reconciler that cannot see identity
must not repair. stdlib only.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
import banklock
import epoch
import homewrite
import identity
import registry

MAX_CONVERGE = 3


def _read_oauth(path):
    try:
        with open(path) as f:
            d = json.load(f)
        o = d.get("claudeAiOauth")
        return o if isinstance(o, dict) else None
    except Exception:
        return None


def _read_seat_oauth(home):
    """(seat) The home's LIVE credential from its SEAT — the .credentials.json file OR the
    migrated per-config-dir keychain slot — via the shared seedflow.seat_read. Returns the
    claudeAiOauth dict, or None (absent / error / unparseable)."""
    import seedflow
    blob, _raw, status, _kind = seedflow.seat_read(home)
    if status != "present" or not isinstance(blob, dict):
        return None
    o = blob.get("claudeAiOauth")
    return o if isinstance(o, dict) else None


def _diagnose(home, email):
    """('healthy'|'broken'|'indeterminate', detail). broken => repair allowed."""
    o = _read_seat_oauth(home)   # (seat) file OR migrated slot
    if not bank_common.valid_oauth(o):
        return "broken", "credential file unreadable/schema-invalid"
    r = identity.resolve(o.get("accessToken", ""))
    if r.verdict == "INDETERMINATE":
        return "indeterminate", r.detail
    if r.verdict == "INVALID":
        return "broken", "server rejected the credential (INVALID)"
    if r.email != email:
        return "broken", f"foreign credential (belongs to {r.email})"
    return "healthy", "ok"


def _candidates(home):
    adir = os.path.join(home, "archive")
    if not os.path.isdir(adir):
        return []
    files = [os.path.join(adir, e) for e in os.listdir(adir) if e.endswith(".json")]
    # (r12 #6) NEWEST-FIRST by real write time (st_mtime_ns), NOT lexicographic name order.
    # Archive names embed <utc>-<pid>-<monotonic>, so a lexicographic reverse sort orders
    # same-second entries by PID (non-chronological) and can put a STALE (spent-token)
    # predecessor ahead of the newer grant — reconcile would then install the stale one.
    # mtime_ns is the true chronological key; the name is a stable tiebreak.
    def _mtime(p):
        try:
            return os.stat(p).st_mtime_ns
        except OSError:
            return -1
    return sorted(files, key=lambda p: (_mtime(p), p), reverse=True)


def _epoch_verdict(acc):
    """(r10 #14) Present-EPOCH gate: explicit v1 refuses, shadow|v2 proceed, absent EPOCH
    permissive (pre-v2 / tests), broken EPOCH fails closed. Returns a refusal verdict
    string when the reconciler must NOT mutate, else None."""
    if not os.path.exists(os.path.join(acc, "EPOCH")):
        return None
    try:
        if epoch.read_epoch(acc)["state"] not in ("shadow", "v2"):
            return "epoch-parked: reconciler is shadow|v2 only (rolled back to v1); no repair"
    except epoch.EpochError:
        return "epoch-unreadable: fail-closed, no repair"
    return None


def reconcile_home(acc, email, resolver=None):
    """One reconciliation run for one home. Returns a verdict string.
    `resolver` overrides identity.resolve for tests."""
    res = resolver or identity.resolve
    # (r10 #14) the reconciler INSTALLS an archived credential — a v2 home mutation, allowed
    # only in shadow|v2. Fast pre-lock reject here; the AUTHORITATIVE re-check is under the
    # home lock below (r11 #6) — the pre-lock check races a concurrent shadow->v1 flip.
    _ev = _epoch_verdict(acc)
    if _ev:
        return _ev
    home = registry.ready_home(acc, email)
    if not home:
        return "not-ready: nothing to reconcile"
    # (finding 38) the READY registry records the account's IMMUTABLE uuid. Ownership
    # is (email AND uuid), not email alone — a distinct or recreated identity that
    # happens to reuse the same email is NOT this home's owner.
    try:
        reg_ent = registry.load(acc).get(email) or {}
    except registry.RegistryError:
        return "registry-unreadable: fail-closed, no repair"
    reg_uuid = reg_ent.get("uuid")
    # (r2 finding 38) ownership REQUIRES a real registered uuid. A missing/"unknown"
    # uuid means we cannot prove ownership — do NOT fall back to email-only (a distinct
    # or recreated identity reusing the email would be treated as owner). Fail closed.
    if not reg_uuid or reg_uuid == "unknown":
        return ("registry uuid missing/unknown: cannot verify home ownership; "
                "operator card (re-seed to record the account uuid)")

    def _is_own(r):
        return r.email == email and r.uuid == reg_uuid

    lk = banklock.BankLock(home)
    if not lk.acquire(timeout=10):
        return "lock-contended: retry later"
    try:
        # (r11 #6) RE-CHECK epoch UNDER the home lock before any diagnose/mutate. The flip
        # holds every home lock (seedflow._ordered_locks) while it writes EPOCH, so an epoch
        # change is impossible while we hold this lock — a shadow->v1 flip that landed
        # between the pre-lock check and here is caught here, before we touch .credentials.json.
        _ev2 = _epoch_verdict(acc)
        if _ev2:
            return _ev2
        def diagnose():
            o = _read_seat_oauth(home)   # (seat) file OR migrated slot
            if not bank_common.valid_oauth(o):
                return "broken", "schema-invalid", None
            r = res(o.get("accessToken", ""))
            if r.verdict == "INDETERMINATE":
                return "indeterminate", r.detail, None
            if r.verdict == "INVALID":
                return "broken", "INVALID", o
            if not _is_own(r):
                return "broken", f"foreign (email {r.email}, uuid {r.uuid})", o
            return "healthy", "ok", o

        state, why, _ = diagnose()
        if state == "healthy":
            return "healthy: untouched"
        if state == "indeterminate":
            return f"indeterminate ({why}): fail-closed, no repair"

        for attempt in range(MAX_CONVERGE):
            # find the newest archived candidate that G9 says is OURS
            chosen = None
            for cand in _candidates(home):
                o = _read_oauth(cand)
                if not bank_common.valid_oauth(o):
                    continue
                r = res(o.get("accessToken", ""))
                if r.verdict == "INDETERMINATE":
                    return "indeterminate (candidate check): fail-closed, no repair"
                if r.verdict == "RESOLVED" and _is_own(r):   # (finding 38) email AND uuid
                    chosen = o
                    break
            if chosen is None:
                return f"broken ({why}) but no healthy archived candidate: needs-reconnect card"
            # re-verify the precondition IMMEDIATELY before commit (rev 7 §5)
            state2, why2, _ = diagnose()
            if state2 == "healthy":
                return "healed-externally: CLI wrote a valid own blob; untouched"
            if state2 == "indeterminate":
                return "indeterminate (pre-commit): fail-closed, no repair"
            try:
                # (seat) install into the home's EXISTING seat — the keychain SLOT when the CLI
                # has migrated the home, the FILE otherwise — via seedflow.seat_write, which keeps
                # the same never-destroy + identity gate as homewrite.
                import seedflow
                seedflow.seat_write(
                    home, chosen, f"reconcile-{attempt}", expected_email=email,
                    identity_check=lambda tok: (
                        (lambda r: (None, r) if r.verdict == "INDETERMINATE"
                         else (_is_own(r), r))(res(tok))))
            except (homewrite.HomeWriteError, RuntimeError) as e:
                return f"repair write refused ({e})"
            # post-commit verify + converge
            state3, _, _ = diagnose()
            if state3 == "healthy":
                return f"repaired (attempt {attempt + 1})"
        return "converge budget exhausted: operator card"
    finally:
        lk.release()


def main():
    acc = os.environ.get("ACCOUNT_BANK_DIR", os.path.expanduser("~/.claude/accounts"))
    email = sys.argv[1]
    print(reconcile_home(acc, email))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
