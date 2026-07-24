#!/usr/bin/env python3
"""(r5 #3) A quarantine/recovery path discovered during a run must SURVIVE to the
persisted cache (and thus the rendered output) — the cached-fallback merge must
NOT silently replace a stranded-token result with a healthy cached figure. Drives
usage.main() end to end against a temp bank; the real keychain/bank are untouched.

PRE-FIX: the netfail branch appended the healthy `good` cache entry and dropped the
quarantine result entirely, so the persisted cache showed stale-healthy data with no
recovery path. The 'quarantine survives into the persisted cache' assertion below
fails on pre-fix code."""
import json
import os
import sys
import tempfile
import types

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
    base = tempfile.mkdtemp(prefix="usage-q-")
    bank = os.path.join(base, "bank"); os.makedirs(bank)
    os.environ["BANK_DIR"] = bank
    os.environ["CLAUDE_JSON"] = os.path.join(base, "claude.json")

    import usage
    usage.BANK_DIR = bank
    usage.CACHE_FILE = os.path.join(bank, ".usage-cache.json")
    usage.CLAUDE_JSON = os.environ["CLAUDE_JSON"]

    # a valid PARKED bank record so the account is polled (and not the active one)
    rec = {"email": "p@x.com", "status": "ok", "banked_at": "x", "banked_at_epoch": 1,
           "claudeAiOauth": {"accessToken": "P", "refreshToken": "rP", "expiresAt": 1,
                             "subscriptionType": "max"},
           "oauthAccount": {"emailAddress": "p@x.com", "organizationType": "claude_max"}}
    with open(os.path.join(bank, "p@x.com.json"), "w") as f:
        json.dump(rec, f)

    # a HEALTHY prior cache entry, but OLD enough that the parked-cache reuse
    # short-circuit does not fire (so process_claude actually runs this cycle).
    prev = {"generated_at": "x", "accounts": [
        {"provider": "claude", "email": "p@x.com", "active": False, "status": "ok",
         "worst_limit": {"percent": 42.0, "label": "5h"}, "five_hour": {"percent": 42.0},
         "fetched_at": 1}]}
    with open(usage.CACHE_FILE, "w") as f:
        json.dump(prev, f)

    qpath = os.path.join(bank, ".refresh-quarantine-p@x.com-1-1")

    def fake_process_claude(email, oauth, is_active, bank_path, status, oauth_account=None):
        # simulate isolated_refresh having stranded a rotated token in quarantine
        return ({"provider": "claude", "email": email, "active": is_active, "status": status,
                 "worst_limit": None, "fetched_at": usage.now(), "quarantine": qpath,
                 "error": f"refresh invalid: readback torn; recovery copy at {qpath}"}, True)

    # deterministic harness: hold the lock, skip reconcile/codex/autoping, no active id
    usage.acquire_lock = lambda timeout=10: True
    usage.release_lock = lambda: None
    usage._reconcile = None
    usage._stable_identity = lambda retries=3: ("", None, True)
    usage.process_claude = fake_process_claude
    usage.process_codex = lambda: (None, False)
    usage.maybe_autoping = lambda results, bank_paths: []

    usage.main()

    doc = json.load(open(usage.CACHE_FILE))
    entry = next((a for a in doc.get("accounts", [])
                  if a.get("provider") == "claude" and a.get("email") == "p@x.com"), None)
    ok(entry is not None, "the account survives to the persisted cache")
    ok(entry and entry.get("quarantine") == qpath,
       "(#3) the quarantine path SURVIVES into the persisted cache (not replaced by healthy cache)")
    ok(entry and entry.get("status") == "needs-recovery",
       "(#3) the account surfaces a needs-recovery status field")
    ok(entry and qpath in str(entry.get("recovery_hint", "")),
       "(#3) a recovery hint pointing at the quarantine is surfaced")
    ok(entry and entry.get("worst_limit") is not None,
       "(#3) the last-good figure still shows (flagged), not blanked")

    print(f"  -- usage_quarantine: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
