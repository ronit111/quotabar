#!/usr/bin/env python3
"""(r4 #6) The production usage refresh path must (a) pass bank_dir so a refresh
quarantine lands INSIDE the credential bank (surviving reboot/tmp cleanup), and
(b) SURFACE rr.quarantine in the account's error/status output instead of silently
discarding it. Drives usage.process_claude for a PARKED, expired account with a
stubbed isolated_refresh — the real keychain/bank are never touched."""
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)

_pass = _fail = 0
def eq(exp, act, name):
    global _pass, _fail
    if exp == act:
        _pass += 1; print(f"  ok   {name}")
    else:
        _fail += 1; print(f"  FAIL {name} (expected {exp!r} got {act!r})")
def truthy(cond, name):
    eq(True, bool(cond), name)


def main():
    base = tempfile.mkdtemp(prefix="usage-r46-")
    os.environ["BANK_DIR"] = os.path.join(base, "bank")
    os.makedirs(os.environ["BANK_DIR"], exist_ok=True)
    os.environ["CLAUDE_JSON"] = os.path.join(base, "claude.json")

    import usage

    # force the module into a state that REACHES the parked-refresh call
    usage.BANK_DIR = os.environ["BANK_DIR"]
    usage.LOCKED = True
    usage.NO_PARKED_REFRESH = False
    usage.REFRESH_ENABLED = True
    usage.DEADLINE = usage.now() + 3600      # ample time budget
    usage.active_email = lambda: "someoneelse@x.com"   # target is NOT active

    captured = {}
    fake_q = os.path.join(usage.BANK_DIR, ".refresh-quarantine-p@x.com-1-1")

    def fake_refresh(oauth, email=None, claude_json=None, bank_dir=None, timeout=60):
        captured["bank_dir"] = bank_dir
        return types.SimpleNamespace(
            creds=oauth, rotated=False, cli_ok=False,
            err="credentials readback invalid or missing oauth after turn",
            auth_failed=False, reason="readback_torn", quarantine=fake_q)

    usage.isolated_refresh = types.SimpleNamespace(refresh_via_config_dir=fake_refresh)

    # a PARKED, EXPIRED oauth so process_claude takes the refresh branch
    oauth = {"accessToken": "P", "refreshToken": "rP", "expiresAt": 1}   # long expired
    bank_path = os.path.join(usage.BANK_DIR, "p@x.com.json")
    res, netfail = usage.process_claude("p@x.com", oauth, is_active=False,
                                        bank_path=bank_path, status="ok")

    eq(usage.BANK_DIR, captured.get("bank_dir"),
       "usage passes bank_dir=BANK_DIR into the parked refresh (r4 #6)")
    truthy(str(usage.BANK_DIR) in str(captured.get("bank_dir")),
           "quarantine dir would land inside the credential bank (r4 #6)")
    eq(fake_q, res.get("quarantine"),
       "usage surfaces rr.quarantine on the account result (r4 #6)")
    truthy(fake_q in res.get("error", ""),
           "the quarantine path appears in the account error text (r4 #6)")

    print(f"  -- usage_refresh: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
