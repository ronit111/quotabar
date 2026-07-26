#!/usr/bin/env python3
"""(v101-confirm) Python-side fixes from the confirmation review.

  #1  The SessionStart hook's re-bank gate (bank_common.hook_rebank_refusal). The hook has no
      identity oracle inside its 5s budget, so it may re-bank ONLY what it can prove offline —
      an unchanged access token whose refresh/expiry rotated — and must defer every other
      drift, including a same-plan keychain-first /login, to the oracle-gated poll heal.
  #5  archiverd's upgrade preflight: a pre-v1.0.1 daemon holds no single-instance lock, so
      only a process-table scan can see it. Asserted here: what counts as a rival and what
      does not, plus a real end-to-end stand-down naming the live pid.
  #7  reconcile's "resolved" verdict is a claim about disk. A journal that survived removal,
      or a removal that could not be proven durable, must come back UNRESOLVED.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)

import bank_common  # noqa: E402

_pass = _fail = 0


def ok(cond, name):
    global _pass, _fail
    if cond:
        _pass += 1
        print(f"  ok   {name}")
    else:
        _fail += 1
        print(f"  FAIL {name}")


def cred(at="AT-1", rt="RT-1", exp=4102444800, plan="max"):
    return {"accessToken": at, "refreshToken": rt, "expiresAt": exp, "subscriptionType": plan}


# --------------------------------------------------------------------------- #
# (#1) the hook's offline re-bank gate
# --------------------------------------------------------------------------- #
def test_hook_rebank_gate():
    banked = cred()

    # THE one provable case: same access token, rotated refresh token / expiry. An access
    # token is issued to exactly one account, so this is that account's own credential.
    ok(bank_common.hook_rebank_refusal(cred(rt="RT-2"), banked) == "",
       "(#1) a rotated refreshToken behind an UNCHANGED access token re-banks (offline proof)")
    ok(bank_common.hook_rebank_refusal(cred(exp=4102444999), banked) == "",
       "(#1) a rotated expiresAt behind an unchanged access token re-banks")
    ok(bank_common.hook_rebank_refusal(cred(rt="RT-2", exp=4102445000), banked) == "",
       "(#1) both rotating together still re-banks")

    # THE critical failure the review found: a keychain-first /login to a SAME-PLAN account.
    # Every offline check agrees; only a live identity lookup can tell it from a rotation.
    r = bank_common.hook_rebank_refusal(cred(at="AT-B", rt="RT-B"), banked)
    ok(r != "", "(#1) a same-plan account's DIFFERENT credential is REFUSED (the critical case)")
    ok("access token" in r,
       "(#1) the refusal names the access token as the thing it cannot attribute")
    ok(bank_common.hook_rebank_refusal(cred(at="AT-B", plan="max"), cred(plan="max")) != "",
       "(#1) identical plan strings do not make a different token attributable")

    # a plan change defers even with a matching access token: a distinct event, and the same
    # tell write_bank_record uses for crossed identities.
    ok(bank_common.hook_rebank_refusal(cred(rt="RT-2", plan="pro"), banked) == "the plan tier changed",
       "(#1) a plan-tier change is deferred, not re-banked")
    ok(bank_common.hook_rebank_refusal(cred(rt="RT-2", plan="claude_max_20x"), banked) == "",
       "(#1) claude_max_20x and max are the SAME tier — not a plan change")
    ok(bank_common.hook_rebank_refusal(cred(rt="RT-2", plan=None), banked) == "",
       "(#1) an ABSENT plan on one side is no evidence of a change")

    # degenerate inputs are refusals, never silent passes.
    ok(bank_common.hook_rebank_refusal(banked, banked) == "no drift to re-bank",
       "(#1) an identical credential is not drift at all")
    ok(bank_common.hook_rebank_refusal({"accessToken": "AT-1"}, banked) != "",
       "(#1) an incomplete live credential is refused")
    ok(bank_common.hook_rebank_refusal(cred(rt="RT-2"), None) != "",
       "(#1) a missing bank record is refused, never treated as a free pass")
    ok(bank_common.hook_rebank_refusal(cred(rt="RT-2"), {}) != "",
       "(#1) an empty bank record cannot match an access token")
    ok(bank_common.hook_rebank_refusal(cred(at=""), banked) != "",
       "(#1) an empty access token never compares equal into a re-bank")

    ok(bank_common.plan_tier("claude_max_20x") == "max" and bank_common.plan_tier("MAX") == "max"
       and bank_common.plan_tier("claude_pro") == "pro" and bank_common.plan_tier("nonsense") is None,
       "(#1) plan_tier is THE tier rule (prefix-based, case-insensitive, None when unknown)")


# --------------------------------------------------------------------------- #
# (#5) archiverd upgrade preflight
# --------------------------------------------------------------------------- #
def _fake_ps(path, rows):
    """A stand-in `ps` emitting canned `uid pid command... KEY=VALUE...` rows."""
    with open(path, "w") as f:
        f.write("#!/bin/sh\ncat <<'PSEOF'\n" + "\n".join(rows) + "\nPSEOF\n")
    os.chmod(path, 0o755)


def test_archiverd_preflight():
    import archiverd  # noqa: E402

    base = tempfile.mkdtemp(prefix="v101-preflight-")
    bank = os.path.join(base, "acc")
    os.makedirs(bank)
    uid, other_uid = os.getuid(), os.getuid() + 1
    ps = os.path.join(base, "ps")

    _fake_ps(ps, [
        f"  {uid} 4001 /usr/bin/python3 /opt/qb/archiverd.py ACCOUNT_BANK_DIR={bank} HOME={base}",
        f"  {uid} 4002 /usr/bin/python3 /opt/qb/tests/test_archiverd.py ACCOUNT_BANK_DIR={bank}",
        f"  {uid} 4003 /bin/zsh -c grep archiverd.py /opt/qb ACCOUNT_BANK_DIR={bank}",
        f"  {uid} 4004 /usr/bin/python3 /opt/qb/archiverd.py --once ACCOUNT_BANK_DIR={bank}",
        f"  {uid} 4005 /usr/bin/python3 /opt/qb/archiverd.py --converge ACCOUNT_BANK_DIR={bank}",
        f"  {other_uid} 4006 /usr/bin/python3 /opt/qb/archiverd.py ACCOUNT_BANK_DIR={bank}",
        f"  {uid} 4007 /usr/bin/python3 /opt/qb/archiverd.py ACCOUNT_BANK_DIR={base}/other-bank",
        f"  {uid} 4008 /usr/bin/python3 /opt/qb/archiverd.py",
    ])
    got = archiverd.other_archiverd_pids(bank, ps_bin=ps)

    ok(4001 in got, "(#5) an unlocked daemon on THIS bank is a rival")
    ok(4002 not in got, "(#5) test_archiverd.py is not archiverd.py (basename match, not substring)")
    ok(4003 not in got, "(#5) a shell whose ARGUMENTS mention archiverd.py is not a daemon")
    ok(4004 not in got and 4005 not in got,
       "(#5) bounded one-shots (--once/--converge) never make the daemon stand down")
    ok(4006 not in got, "(#5) another user's daemon cannot write our 0700 bank")
    ok(4007 not in got, "(#5) a daemon watching a DIFFERENT bank is not a coexisting writer")
    ok(4008 in got, "(#5) a candidate whose bank cannot be determined counts as a rival (fail-closed)")

    _fake_ps(ps, [f"  {uid} {os.getpid()} /usr/bin/python3 /opt/qb/archiverd.py HOME={base}"])
    ok(archiverd.other_archiverd_pids(bank, ps_bin=ps) == [],
       "(#5) we never stand down for ourselves")

    ok(archiverd.other_archiverd_pids(bank, ps_bin=os.path.join(base, "no-such-ps")) == [],
       "(#5) a scan that could not run is not evidence of a duplicate")

    # END TO END: a real live process whose argv is `python3 .../archiverd.py` on this bank.
    # The daemon must acquire its lock, discover the rival, name its pid and stand down —
    # a locked new daemon must never coexist-write with an unlocked old one.
    old_dir = os.path.join(base, "oldcopy")
    os.makedirs(old_dir)
    with open(os.path.join(old_dir, "archiverd.py"), "w") as f:
        f.write("import time\ntime.sleep(120)\n")
    env = dict(os.environ, ACCOUNT_BANK_DIR=bank, BANK_DIR=bank)
    old = subprocess.Popen([sys.executable, os.path.join(old_dir, "archiverd.py")], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(0.5)
        r = subprocess.run([sys.executable, os.path.join(AB, "archiverd.py")], env=env,
                           capture_output=True, text=True, timeout=30)
        ok(r.returncode == 0, "(#5) the new daemon stands down cleanly (rc 0, launchd retries)")
        ok("REFUSING to start" in r.stderr,
           "(#5) it refuses out loud instead of becoming a second writer")
        ok(str(old.pid) in r.stderr, "(#5) the refusal NAMES the live pre-upgrade pid")
        ok(not os.path.exists(os.path.join(bank, archiverd.DAEMON_LOCK_NAME)),
           "(#5) it releases the lock it took, so the next attempt is not blocked by itself")
        ok(not os.path.exists(os.path.join(bank, archiverd.STATUS_NAME)),
           "(#5) the stood-down daemon wrote NO status (no alternating writes)")
    finally:
        old.kill()
        old.wait()

    # with the rival gone, the same daemon starts normally (the refusal is not sticky).
    p = subprocess.Popen([sys.executable, os.path.join(AB, "archiverd.py")], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        t0 = time.time()
        while not os.path.exists(os.path.join(bank, archiverd.DAEMON_LOCK_NAME)) and time.time() - t0 < 10:
            time.sleep(0.05)
        ok(os.path.exists(os.path.join(bank, archiverd.DAEMON_LOCK_NAME)),
           "(#5) once the old process is gone the daemon starts and takes the lock")
    finally:
        p.kill()
        p.wait()
    shutil.rmtree(base, ignore_errors=True)


# --------------------------------------------------------------------------- #
# (#7) reconcile must prove "resolved" on disk
# --------------------------------------------------------------------------- #
def _reconcile_env(base):
    """A bank whose swap journal is in the Case-A resolvable state: metadata names the target
    and the live keychain positively holds the target credential."""
    bank = os.path.join(base, "acc")
    os.makedirs(bank, exist_ok=True)
    os.environ["BANK_DIR"] = bank
    os.environ["ACCOUNT_BANK_DIR"] = bank
    cj = os.path.join(base, "claude.json")
    with open(cj, "w") as f:
        json.dump({"oauthAccount": {"emailAddress": "b@x.com"}}, f)
    os.environ["CLAUDE_JSON"] = cj
    return bank


def test_reconcile_resolved_is_proven():
    base = tempfile.mkdtemp(prefix="v101-reconcile-")
    bank = _reconcile_env(base)
    for m in ("reconcile", "bank_common"):
        sys.modules.pop(m, None)
    import reconcile  # noqa: E402

    target_blob = {"claudeAiOauth": {"accessToken": "B", "refreshToken": "rB",
                                     "expiresAt": 4102444800}}
    target_fp = reconcile.bank_common.cred_fingerprint(target_blob)
    reconcile._active_email = lambda: "b@x.com"
    reconcile._live_fp = lambda: target_fp

    def write_journal():
        with open(reconcile.SWAP_JOURNAL, "w") as f:
            json.dump({"type": "swap", "pre_swap_blob": "{}", "pre_fp": "",
                       "target": "b@x.com", "target_fp": target_fp,
                       "current": "a@x.com", "ts": 1}, f)

    # baseline: the happy path still resolves and clears both journal and marker.
    write_journal()
    ok(reconcile.reconcile_swap_journal() == ("resolved", "b@x.com"),
       "(#7) a genuinely consistent swap journal still resolves")
    ok(not os.path.exists(reconcile.SWAP_JOURNAL), "(#7) ...and the journal is gone")
    ok(not os.path.exists(reconcile.SWAP_UNRESOLVED), "(#7) ...and no blocker is left behind")

    # a directory sync that FAILS must not be converted to success: the removal is not proven
    # durable, so a power loss could resurrect the journal on top of a committed swap.
    write_journal()
    real_fsync = reconcile._fsync_dir
    reconcile._fsync_dir = lambda d: False
    verdict, _ = reconcile.reconcile_swap_journal()
    reconcile._fsync_dir = real_fsync
    ok(verdict == "unresolved", "(#7) an unsyncable directory does NOT read as resolved")
    ok(os.path.exists(reconcile.SWAP_UNRESOLVED),
       "(#7) the durable unresolved marker records the failure so mutation stays blocked")
    with open(reconcile.SWAP_UNRESOLVED) as f:
        ok("durable" in f.read(), "(#7) the marker says WHY (removal not durable)")
    os.remove(reconcile.SWAP_UNRESOLVED)

    # a journal that cannot be removed at all is the loudest case: it is secret-bearing and
    # the old code reported "resolved" while leaving it exactly where it was.
    write_journal()
    os.chmod(bank, 0o500)
    try:
        verdict, _ = reconcile.reconcile_swap_journal()
    finally:
        os.chmod(bank, 0o700)
    ok(verdict == "unresolved", "(#7) a journal that cannot be removed does NOT read as resolved")
    ok(os.path.exists(reconcile.SWAP_JOURNAL),
       "(#7) the journal is still there — the report matches the disk")

    for m in ("reconcile", "bank_common"):
        sys.modules.pop(m, None)
    shutil.rmtree(base, ignore_errors=True)


def main():
    test_hook_rebank_gate()
    test_archiverd_preflight()
    test_reconcile_resolved_is_proven()
    print(f"  -- v101_confirm: {_pass} passed, {_fail} failed")
    return 1 if _fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
