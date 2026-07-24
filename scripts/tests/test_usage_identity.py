#!/usr/bin/env python3
"""(r5 #4) usage.py must bind the live keychain to an account through the single
fail-closed resolver before attributing quota or marking a bank status ok. When the
identity is UNRESOLVED (here: the active account's token drifted ahead of its bank
record, offline-indistinguishable from a keychain-first /login), usage must NOT mark
that account's bank status ok and must NOT attribute the keychain quota to it.

PRE-FIX: usage bound `kc` to `act` with status 'ok' (claude_accts[act] = (kc, bp,
'ok', ...)) on mere stability, so an active poll flipped act's bank record to ok and
labelled the live quota as act. Both assertions below fail on pre-fix code."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)

_pass = _fail = 0
def ok(cond, name):
    global _pass, _fail
    if cond:
        _pass += 1; print(f"  ok   {name}")
    else:
        _fail += 1; print(f"  FAIL {name}")


def main():
    base = tempfile.mkdtemp(prefix="usage-id-")
    bank = os.path.join(base, "bank"); os.makedirs(bank)
    os.environ["BANK_DIR"] = bank
    os.environ["CLAUDE_JSON"] = os.path.join(base, "claude.json")

    import usage
    usage.BANK_DIR = bank
    usage.CACHE_FILE = os.path.join(bank, ".usage-cache.json")
    usage.CLAUDE_JSON = os.environ["CLAUDE_JSON"]

    # a@x.com's BANKED credential is X, and the record is needs-relogin so a wrongful
    # flip to ok is observable.
    a_path = os.path.join(bank, "a@x.com.json")
    rec = {"email": "a@x.com", "status": "needs-relogin", "banked_at": "x", "banked_at_epoch": 1,
           "claudeAiOauth": {"accessToken": "X", "refreshToken": "rX", "expiresAt": 1,
                             "subscriptionType": "max"},
           "oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}}
    with open(a_path, "w") as f:
        json.dump(rec, f)

    # the LIVE keychain holds a DRIFTED token (accessToken X2) that matches NO current
    # bank record; metadata still names a@x.com. resolve_identity -> UNRESOLVED.
    kc_drift = {"accessToken": "X2", "refreshToken": "rX", "expiresAt": 1, "subscriptionType": "max"}

    calls = []
    def fake_process_claude(email, oauth, is_active, bank_path, status, oauth_account=None):
        calls.append((email, is_active, bank_path))
        if is_active:                       # an active poll would mark the bound record ok
            usage.set_bank_status(bank_path, "ok")
        return ({"provider": "claude", "email": email, "active": is_active, "status": "ok",
                 "worst_limit": {"percent": 5.0}, "fetched_at": usage.now()}, False)

    usage.acquire_lock = lambda timeout=10: True
    usage.release_lock = lambda: None
    usage._reconcile = None
    usage._stable_identity = lambda retries=3: ("a@x.com", kc_drift, True)
    usage.process_claude = fake_process_claude
    usage.process_codex = lambda: (None, False)
    usage.maybe_autoping = lambda results, bank_paths: []

    usage.main()

    on_disk = json.load(open(a_path))
    ok(on_disk.get("status") == "needs-relogin",
       "(#4) an UNRESOLVED live identity NEVER flips a@x.com's bank status to ok")

    doc = json.load(open(usage.CACHE_FILE))
    emails = [a.get("email") for a in doc.get("accounts", []) if a.get("provider") == "claude"]
    ok("(active/unresolved)" in emails,
       "(#4) the unbound live keychain is surfaced under a distinct non-attributing key")

    # the live keychain must NEVER have been polled as bound to a@x.com's bank_path
    bound_to_a = any(e == "a@x.com" and act and bp == a_path for (e, act, bp) in calls)
    ok(not bound_to_a,
       "(#4) the live keychain quota is not attributed to a@x.com's bank record")

    print(f"  -- usage_identity: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
