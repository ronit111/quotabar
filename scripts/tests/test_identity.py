#!/usr/bin/env python3
"""(r5 #1/#4/#6) The SINGLE fail-closed identity primitive + the never-destroy
archive invariant. Everything runs in a throwaway temp bank; the real keychain /
bank are never touched, and no token value is ever printed.

Coverage:
  * resolve_identity fail-closed decision table (empty keychain is #1's core; a
    metadata/fingerprint mismatch and self-drift are #4; multi-match is ambiguity).
  * archive_blob durability + per-account pruning (PRINCIPLE 2).
  * the #6 scenario end-to-end: write_bank_record overwriting A.json with a
    DIFFERENT same-plan credential must leave A's original blob in <bank>/archive/.
"""
import glob
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)
import bank_common

_pass = _fail = 0
def ok(cond, name):
    global _pass, _fail
    if cond:
        _pass += 1; print(f"  ok   {name}")
    else:
        _fail += 1; print(f"  FAIL {name}")


def _rec(email, at, rt="r", exp=1, plan="max", org="claude_max", status="ok"):
    return {"email": email, "status": status, "banked_at": "x", "banked_at_epoch": 1,
            "claudeAiOauth": {"accessToken": at, "refreshToken": rt, "expiresAt": exp,
                              "subscriptionType": plan},
            "oauthAccount": {"emailAddress": email, "organizationType": org}}


def main():
    bd = tempfile.mkdtemp(prefix="ident-")
    a = _rec("a@x.com", "AA", "rAA")
    b = _rec("b@x.com", "BB", "rBB")
    for r in (a, b):
        with open(os.path.join(bd, r["email"] + ".json"), "w") as f:
            json.dump(r, f)

    a_oauth = a["claudeAiOauth"]
    a_blob = {"claudeAiOauth": a_oauth}

    # ---- resolve_identity decision table ----
    ok(bank_common.resolve_identity(bd, a_blob, "a@x.com") == "a@x.com",
       "RESOLVED: fp matches exactly one record AND metadata names it")
    ok(bank_common.resolve_identity(bd, "", "a@x.com") is None,
       "UNRESOLVED: empty/unreadable keychain (finding #1 core)")
    ok(bank_common.resolve_identity(bd, {}, "a@x.com") is None,
       "UNRESOLVED: invalid ({}) keychain -> empty fingerprint, no bypass (#1)")
    ok(bank_common.resolve_identity(bd, a_blob, "b@x.com") is None,
       "UNRESOLVED: metadata names a different account than the fingerprint (#4)")
    ok(bank_common.resolve_identity(bd, a_blob, "") is None,
       "UNRESOLVED: metadata missing")
    drift = {"accessToken": "AA2", "refreshToken": "rAA", "expiresAt": 1}
    ok(bank_common.resolve_identity(bd, drift, "a@x.com") is None,
       "UNRESOLVED: active token drifted ahead of its bank record (#4/#6)")
    ok(bank_common.fp_owner(bd, a_oauth) == "a@x.com",
       "fp_owner binds a credential to its single owning account")
    ok(bank_common.fp_owner(bd, drift) is None,
       "fp_owner: unknown/drifted credential owns nothing")

    # multi-match ambiguity: two records carrying the SAME credential -> UNRESOLVED
    dup = _rec("c@x.com", "AA", "rAA")   # identical cred to a@x.com
    with open(os.path.join(bd, "c@x.com.json"), "w") as f:
        json.dump(dup, f)
    ok(bank_common.fp_owner(bd, a_oauth) is None,
       "fp_owner: a fingerprint matching MORE THAN ONE account is ambiguous -> None")
    ok(bank_common.resolve_identity(bd, a_blob, "a@x.com") is None,
       "UNRESOLVED: multiple accounts share the fingerprint (ambiguous) (#4)")
    os.remove(os.path.join(bd, "c@x.com.json"))

    # a malformed bank record has no trustworthy identity and never matches
    with open(os.path.join(bd, "d@x.com.json"), "w") as f:
        f.write("{ not json")
    ok(bank_common.resolve_identity(bd, a_blob, "a@x.com") == "a@x.com",
       "a malformed sibling record does not disturb a valid resolution")
    os.remove(os.path.join(bd, "d@x.com.json"))

    # ---- archive_blob durability + pruning ----
    p = bank_common.archive_blob(bd, "a@x.com", a_blob)
    ok(p and os.path.exists(p) and (os.stat(p).st_mode & 0o777) == 0o600,
       "archive_blob writes a 0600 file")
    ok(bank_common.archive_blob(bd, "a@x.com", "") is None
       and bank_common.archive_blob(bd, "a@x.com", None) is None,
       "archive_blob no-ops on a blank/None blob")
    pu = bank_common.archive_blob(bd, "../evil", a_blob)   # unsafe email -> unknown
    ok(pu and os.path.basename(pu).startswith("unknown."),
       "archive_blob files an unsafe/empty email under 'unknown'")
    for _ in range(14):
        bank_common.archive_blob(bd, "prune@x.com", {"claudeAiOauth": a_oauth}, keep=10)
    kept = glob.glob(os.path.join(bd, "archive", "prune@x.com.*.json"))
    ok(len(kept) <= 10, f"archive_blob prunes to keep<=10 per account (kept {len(kept)})")

    # ---- (#6) write_bank_record overwriting A.json archives A FIRST ----
    bd2 = tempfile.mkdtemp(prefix="ident6-")
    a_path = os.path.join(bd2, "a@x.com.json")
    with open(a_path, "w") as f:
        json.dump(_rec("a@x.com", "AAAA", "rAAAA"), f)   # A's REAL credential
    cj = os.path.join(bd2, "claude.json")
    with open(cj, "w") as f:                              # metadata (stably) names A
        json.dump({"oauthAccount": {"emailAddress": "a@x.com",
                                     "organizationType": "claude_max"}}, f)
    # a keychain-first /login to a DIFFERENT same-plan account leaves B' creds live;
    # bank-account.sh would hand write_bank_record.py B' under identity A.
    bprime = json.dumps({"claudeAiOauth": {"accessToken": "BPRIME", "refreshToken": "rBP",
                                           "expiresAt": 1, "subscriptionType": "max"}})
    r = subprocess.run([sys.executable, os.path.join(AB, "write_bank_record.py"),
                        cj, "a@x.com", a_path, "2026-07-21T00:00:00Z", "1"],
                       input=bprime, text=True, capture_output=True)
    ok(r.returncode == 0, "write_bank_record accepts the same-plan write (race undetectable)")
    now_a = json.load(open(a_path))
    ok(now_a["claudeAiOauth"]["accessToken"] == "BPRIME",
       "A.json now holds B' (the race is not preventable at this layer)")
    arch = glob.glob(os.path.join(bd2, "archive", "a@x.com.*.json"))
    survived = any(json.load(open(p2)).get("claudeAiOauth", {}).get("accessToken") == "AAAA"
                   for p2 in arch)
    ok(survived,
       "(#6) A's ORIGINAL credential survives in <bank>/archive/ (recoverable, not lost)")

    print(f"  -- identity: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
