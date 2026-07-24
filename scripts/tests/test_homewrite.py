#!/usr/bin/env python3
"""Tests for homewrite.py — the tier-1 guaranteed writer (rev 5 §5)."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import homewrite  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def oauth(tag):
    return {"accessToken": f"at-{tag}", "refreshToken": f"rt-{tag}", "expiresAt": 9999999999999}


def read_cred(home):
    with open(os.path.join(home, ".credentials.json")) as f:
        return json.load(f)["claudeAiOauth"]


def archives(home):
    adir = os.path.join(home, "archive")
    return sorted(os.listdir(adir)) if os.path.isdir(adir) else []


def main():
    home = tempfile.mkdtemp(prefix="hw-home-")

    # first write: no predecessor, commits, 0600, readback verified
    p = homewrite.write_credential(home, oauth("v1"), "seed")
    ok(read_cred(home) == oauth("v1"), "first write lands")
    ok(oct(os.stat(p).st_mode & 0o777) == "0o600", "credential file 0600")
    ok(archives(home) == [], "no archive entry when no predecessor existed")

    # second write archives the predecessor first
    homewrite.write_credential(home, oauth("v2"), "rotate")
    ok(read_cred(home) == oauth("v2"), "second write lands")
    a = archives(home)
    ok(len(a) == 1, "exactly one archive entry")
    with open(os.path.join(home, "archive", a[0])) as f:
        ok(json.load(f)["claudeAiOauth"] == oauth("v1"), "archive holds the predecessor")
    ok(oct(os.stat(os.path.join(home, "archive", a[0])).st_mode & 0o777) == "0o600",
       "archive entry 0600")

    # schema-invalid refused, nothing changed
    raised = False
    try:
        homewrite.write_credential(home, {"accessToken": ""}, "bad")
    except homewrite.HomeWriteError:
        raised = True
    ok(raised and read_cred(home) == oauth("v2"), "schema-invalid write refused, state intact")

    # identity gate: False (foreign) refused; None (indeterminate) refused; True passes
    for verdict, label, should_pass in ((False, "foreign", False),
                                        (None, "indeterminate", False),
                                        (True, "owned", True)):
        try:
            homewrite.write_credential(
                home, oauth(f"id-{label}"), "idtest", expected_email="a@x.com",
                identity_check=lambda tok, v=verdict: (v, "stub"))
            passed = True
        except homewrite.HomeWriteError:
            passed = False
        ok(passed == should_pass, f"identity {label} -> {'commit' if should_pass else 'refusal'}")
    ok(read_cred(home) == oauth("id-owned"), "owned write landed last")

    # pre-archive failure aborts the write (never-destroy is a precondition):
    # replace archive/ with a FILE so makedirs genuinely fails (a chmod would be
    # undone by the helper's own chmod-to-0700)
    import shutil
    adir = os.path.join(home, "archive")
    saved = adir + ".saved"
    shutil.move(adir, saved)
    with open(adir, "w") as f:
        f.write("not a dir")
    raised = False
    try:
        homewrite.write_credential(home, oauth("v3"), "blocked")
    except homewrite.HomeWriteError:
        raised = True
    os.remove(adir)
    shutil.move(saved, adir)
    ok(raised and read_cred(home) == oauth("id-owned"),
       "pre-archive failure aborts commit, predecessor intact")

    # prune keeps ARCHIVE_KEEP newest, only after successful commits
    for i in range(homewrite.ARCHIVE_KEEP + 5):
        homewrite.write_credential(home, oauth(f"bulk-{i}"), "bulk")
    ok(len(archives(home)) == homewrite.ARCHIVE_KEEP,
       f"archive pruned to {homewrite.ARCHIVE_KEEP}")
    # newest archive entry is the immediate predecessor of the final write
    newest = sorted(archives(home))[-1]
    with open(os.path.join(home, "archive", newest)) as f:
        ok(json.load(f)["claudeAiOauth"] == oauth(f"bulk-{homewrite.ARCHIVE_KEEP + 3}"),
       "newest archive entry is the immediate predecessor")

    print(f"-- homewrite: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
