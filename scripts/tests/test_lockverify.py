#!/usr/bin/env python3
"""(r12 #11) banklock.verify_caller_holds — a caller may only be TRUSTED to hold the bank
lock (ACCOUNT_BANK_HOLDS_LOCK=1) when it can prove it: the exported ACCOUNT_BANK_LOCK_TOKEN
matches the on-disk owner token AND the owner is alive. A process that merely sets the flag
without holding the lock (no token) fails. Hermetic: writes a fake owner record, no real lock."""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import banklock  # noqa: E402

_pass = _fail = 0
def ok(c, m):
    global _pass, _fail
    if c:
        _pass += 1; print(f"  ok   {m}")
    else:
        _fail += 1; print(f"  FAIL {m}")


def _start_token():
    # a stable start-time token for THIS live pid, so the owner reads as alive
    return banklock._proc_starttime(os.getpid())


def main():
    acc = tempfile.mkdtemp(prefix="lockverify-")
    lockdir = os.path.join(acc, ".lock")
    os.makedirs(lockdir)
    tok = "tok-abc123"
    start = _start_token()
    # owner record format: "pid token start..."
    with open(os.path.join(lockdir, "owner"), "w") as f:
        f.write(f"{os.getpid()} {tok} {start}")

    # no exported token -> not verified (a plain HOLDS_LOCK=1 liar)
    os.environ.pop("ACCOUNT_BANK_LOCK_TOKEN", None)
    ok(banklock.verify_caller_holds(acc) is False,
       "no ACCOUNT_BANK_LOCK_TOKEN exported -> NOT verified (a bare HOLDS_LOCK liar) (r12 #11)")

    # wrong token -> not verified
    os.environ["ACCOUNT_BANK_LOCK_TOKEN"] = "tok-WRONG"
    ok(banklock.verify_caller_holds(acc) is False, "wrong token -> NOT verified (r12 #11)")

    # matching token + live owner -> verified
    os.environ["ACCOUNT_BANK_LOCK_TOKEN"] = tok
    ok(banklock.verify_caller_holds(acc) is True,
       "matching exported token + live owner -> verified (r12 #11)")

    # a DEAD owner (gone pid) with the right token -> NOT verified (stale lock)
    import subprocess
    dp = subprocess.Popen(["true"]); dp.wait()
    with open(os.path.join(lockdir, "owner"), "w") as f:
        f.write(f"{dp.pid} {tok} some-old-start")
    ok(banklock.verify_caller_holds(acc) is False,
       "matching token but provably-dead owner -> NOT verified (stale lock) (r12 #11)")

    # no owner file at all -> not verified
    os.remove(os.path.join(lockdir, "owner"))
    ok(banklock.verify_caller_holds(acc) is False, "no owner record -> NOT verified (r12 #11)")

    os.environ.pop("ACCOUNT_BANK_LOCK_TOKEN", None)

    # (r14 #4) BankLock.acquire REFUSES to publish an owner record with an empty (unprovable)
    # start-time — else future reclaim could never prove death and every acquisition would
    # time out forever. Simulate a persistent ps failure.
    acc4 = tempfile.mkdtemp(prefix="lockstart-")
    _orig_pstart = banklock._proc_starttime
    banklock._proc_starttime = lambda pid: ""
    try:
        got = banklock.BankLock(acc4).acquire(timeout=1)
    finally:
        banklock._proc_starttime = _orig_pstart
    ok(got is False, "BankLock.acquire REFUSES an empty (unprovable) start-time (r14 #4)")
    ok(not os.path.isdir(os.path.join(acc4, ".lock")), "no ownerless lock dir left behind (r14 #4)")
    # with a real start-time it acquires
    lk4 = banklock.BankLock(acc4)
    ok(lk4.acquire(timeout=2) is True, "BankLock.acquire succeeds with a real start-time (r14 #4)")
    lk4.release()

    print(f"  -- lockverify: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
