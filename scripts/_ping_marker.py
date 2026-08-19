#!/usr/bin/env python3
"""_ping_marker.py <bankfile> <epoch> <kind>  — stamp a ping marker on a bank
record, VALIDATED (finding #39).

kind:
  success      -> set last_ping=<epoch>, clear last_ping_failed (next window may ping)
  failed       -> set last_ping_failed=<epoch> (5-min failure cooldown)
  needs-relogin-> set status="needs-relogin" (+ last_ping_failed)

Refuses (exit 2) if the existing record is malformed: a marker-only rewrite of a
broken record would DELETE the credentials it holds (the exact "malformed record
destroys credentials" bug). Writes atomically + fsync; exit 0 only on a verified
write. Caller MUST check the exit status.
"""
import sys, os, json, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
import epoch as _epoch

tf, epoch, kind = sys.argv[1], int(sys.argv[2] or "0"), sys.argv[3]

# (r6 b10) a marker write mutates a v1 bank record, so it must pass the SAME epoch gate
# as kc_write BEFORE touching the record: (1) v1-gate (state v1|shadow, no SEEDING freeze),
# (2) generation fence against the lock-acquire snapshot the lock-holding caller captured
# and passes in ACCOUNT_BANK_EPOCH_SNAP ("<state> <gen>"). A missing/malformed snapshot
# means the caller did not acquire the lock -> refuse (fail-closed, rc 78, record UNCHANGED).
_bank_dir = os.path.dirname(os.path.abspath(tf))
try:
    _epoch.v1_gate(_bank_dir)
    _snap = os.environ.get("ACCOUNT_BANK_EPOCH_SNAP", "").split()
    if len(_snap) != 2:
        raise _epoch.EpochFenced("no epoch snapshot (caller did not acquire_lock)")
    _epoch.fence(_bank_dir, {"state": _snap[0], "generation": int(_snap[1])}, ("v1", "shadow"))
except _epoch.EpochFenced as e:
    sys.stderr.write(f"_ping_marker: epoch gate refused the mutation ({e}); rc 78, record UNCHANGED\n")
    sys.exit(78)
except ValueError as e:
    sys.stderr.write(f"_ping_marker: bad epoch snapshot ({e}); rc 78, record UNCHANGED\n")
    sys.exit(78)

br = bank_common.load_bank_record(tf)
if not br.ok:
    # A malformed / unreadable record: do NOT overwrite it with a marker-only
    # object — that would erase whatever credentials it still holds. Fail loud.
    sys.stderr.write(f"_ping_marker: refusing to stamp a malformed bank record ({br.reason})\n")
    sys.exit(2)

rec = br.record
# (relogin-recovery) Whether THIS stamp is the one that arms needs-relogin — the
# once-per-arming event the notification below announces. Read before the mutation.
_was_relogin = rec.get("status") == "needs-relogin"
if kind == "success":
    rec["last_ping"] = epoch
    rec.pop("last_ping_failed", None)
elif kind == "failed":
    rec["last_ping_failed"] = epoch
elif kind == "needs-relogin":
    rec["status"] = "needs-relogin"
    rec["last_ping_failed"] = epoch
else:
    sys.stderr.write(f"_ping_marker: unknown kind {kind!r}\n")
    sys.exit(3)

dirn = os.path.dirname(tf) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f, indent=2)
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, tf)
    d = os.open(dirn, os.O_RDONLY)
    try:
        os.fsync(d)
    finally:
        os.close(d)
except Exception as e:
    try: os.unlink(tmp)
    except OSError: pass
    sys.stderr.write(f"_ping_marker: write FAILED ({type(e).__name__})\n")
    sys.exit(1)

# (relogin-recovery) Announce a revocation once, after the stamp is durably on disk, so
# the owner learns about it now instead of the next time they look at the menu bar.
# Best-effort by design: the stamp is the contract, the notification is a courtesy.
try:
    import notify
    _email = os.path.basename(tf)[:-5]
    if "@" in _email:
        if kind == "needs-relogin" and not _was_relogin:
            notify.relogin_armed(_bank_dir, _email, "parked token confirmed dead")
        elif kind == "success":
            notify.clear(_bank_dir, _email)
except Exception:
    pass
sys.exit(0)
