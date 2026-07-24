#!/usr/bin/env python3
"""(r5 #2) isolated_refresh._quarantine_cfgdir's cross-filesystem (EXDEV) fallback
must fsync the copied credential file AND the destination dir BEFORE deleting the
source, and delete the source ONLY if both fsyncs succeed — otherwise preserve
BOTH and report both paths. We force the EXDEV branch by monkeypatching os.rename;
no real cross-filesystem move or real credential is involved.

PRE-FIX: the fallback checked only that the copied file EXISTED, then deleted the
source unconditionally (no fsync). The 'not durable -> keep BOTH' assertion below
fails on pre-fix code (it deleted the source regardless of fsync)."""
import errno
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)
import isolated_refresh as ir

_pass = _fail = 0
def ok(cond, name):
    global _pass, _fail
    if cond:
        _pass += 1; print(f"  ok   {name}")
    else:
        _fail += 1; print(f"  FAIL {name}")


def _make_cfgdir(base, tok):
    d = os.path.join(base, f"cfg-{tok}")
    os.makedirs(d)
    with open(os.path.join(d, ".credentials.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"ROT","refreshToken":"rROT","expiresAt":1}}')
    return d


def main():
    base = tempfile.mkdtemp(prefix="exdev-")
    bank = os.path.join(base, "bank"); os.makedirs(bank)

    real_rename = os.rename
    def exdev_rename(a, b):
        raise OSError(errno.EXDEV, "Invalid cross-device link")

    # ---- durable path: EXDEV, fsyncs succeed -> source deleted, copy kept ----
    d1 = _make_cfgdir(base, "durable")
    ir.os.rename = exdev_rename
    try:
        q1 = ir._quarantine_cfgdir(d1, bank, "p@x.com", "test-durable")
    finally:
        ir.os.rename = real_rename
    ok(q1 and os.path.isdir(q1) and os.path.exists(os.path.join(q1, ".credentials.json")),
       "EXDEV: copy landed in the bank with its credential file")
    ok(not os.path.exists(d1),
       "EXDEV durable: source deleted ONLY after fsyncs succeeded")

    # ---- non-durable path: EXDEV, a dir fsync FAILS -> keep BOTH, return source ----
    d2 = _make_cfgdir(base, "nondurable")
    real_fsync_dir = ir._fsync_dir
    def failing_fsync_dir(p):
        raise OSError(errno.EIO, "simulated fsync failure")
    ir.os.rename = exdev_rename
    ir._fsync_dir = failing_fsync_dir
    try:
        q2 = ir._quarantine_cfgdir(d2, bank, "p@x.com", "test-nondurable")
    finally:
        ir.os.rename = real_rename
        ir._fsync_dir = real_fsync_dir
    ok(q2 == d2, "EXDEV non-durable: returns the SOURCE path (preserved, not the copy)")
    ok(os.path.exists(os.path.join(d2, ".credentials.json")),
       "EXDEV non-durable: SOURCE preserved (never deleted on an un-fsync'd copy)")

    print(f"  -- isolated_exdev: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
