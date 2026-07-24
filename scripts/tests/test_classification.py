#!/usr/bin/env python3
"""Auth-vs-transient classification in isolated_refresh (findings 24, 37, 21).
Uses the stub `claude` via ACCOUNT_BANK_CLAUDE_BIN. NEVER touches the keychain."""
import os, sys
AB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AB)
STUB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stubs", "claude")
os.environ["ACCOUNT_BANK_CLAUDE_BIN"] = STUB
import isolated_refresh as ir
import tempfile

P = F = 0
def ok(c, name):
    global P, F
    if c: P += 1; print("  ok  ", name)
    else: F += 1; print("  FAIL", name)

CREDS = {"accessToken": "old", "refreshToken": "rold", "expiresAt": 1}

# (r4 #5/#9) A rotation now REQUIRES a durable journal (an identity + an available
# reconcile subsystem) to report "ok"; a missing journal fails closed. Point the
# reconcile module at a TEMP bank dir and pass a real email so rotations journal
# safely here (never the real ~/.claude/accounts) — keeping this a valid, non-vacuous
# classification test rather than one that leaned on the old silent no-email path.
_TMP_BANK = tempfile.mkdtemp(prefix="acctbank-classif-")
if ir._rec is not None:
    ir._rec.BANK_DIR = _TMP_BANK
    ir._rec.SWAP_JOURNAL = os.path.join(_TMP_BANK, ".swap-journal.json")
    ir._rec.SWAP_UNRESOLVED = os.path.join(_TMP_BANK, ".swap-unresolved")
assert ir._rec is not None, "reconcile must import for the classification test to be valid"

def run(mode, timeout=30):
    os.environ["STUB_CLAUDE_MODE"] = mode
    return ir.refresh_via_config_dir(dict(CREDS), email="classif@x.com",
                                     bank_dir=_TMP_BANK, timeout=timeout)

# ok -> rotated, alive, reason ok
r = run("ok")
ok(r.rotated and r.reason == "ok" and not r.auth_failed, "rotate -> rotated/ok, not dead")
ok(r.creds.get("accessToken") != "old", "rotate -> new access token returned")

# norotate -> turn ran (cli_ok), not rotated, not dead
r = run("norotate")
ok((not r.rotated) and r.cli_ok and not r.auth_failed and r.reason == "ok",
   "turn ran without rotation -> healthy, not dead")

# authfail (OAuth signature on STDOUT) -> CONFIRMED dead
r = run("authfail")
ok(r.auth_failed and r.reason == "auth_rejected", "OAuth auth failure -> auth_failed (dead)")

# forbidden 403 -> AMBIGUOUS, must stay transient (findings 24/37)
r = run("forbidden")
ok((not r.auth_failed) and r.reason in ("nonzero",), "ambiguous 403 -> transient, NOT dead")

# generic nonzero -> transient
r = run("nonzero")
ok((not r.auth_failed) and r.reason == "nonzero", "generic nonzero -> transient")

# (re-review issue 12) a 403 "OAuth token not permitted" must NOT be read as
# auth-death even though it contains "oauth token" — the 403 marker forces transient.
r = run("oauth403")
ok((not r.auth_failed) and r.reason == "nonzero",
   "403 'OAuth token not permitted' stays TRANSIENT, not needs-relogin (issue 12)")

# timeout -> transient (whole-group kill), not dead
r = run("timeout", timeout=2)
ok((not r.auth_failed) and r.reason == "timeout", "timeout -> transient, not dead")

# became-active guard (finding 27): if claude_json names this account active, skip
import json, tempfile
cj = os.path.join(tempfile.mkdtemp(), "claude.json")
json.dump({"oauthAccount": {"emailAddress": "me@x.com"}}, open(cj, "w"))
r = ir.refresh_via_config_dir(dict(CREDS), email="me@x.com", claude_json=cj, timeout=5)
ok(r.reason == "became_active" and not r.rotated, "active-guard: skip refresh of now-active account")

print(f"  -- classification: {P} passed, {F} failed")
sys.exit(1 if F else 0)
