#!/usr/bin/env python3
"""Inactive accounts stay out of polling and auto-pick; the plan chip follows the backend's name;
an Ultra account with no 5-hour limit is never auto-pinged."""
import json, os, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
SANDBOX = tempfile.mkdtemp()
os.environ["ACCOUNT_BANK_DIR"] = SANDBOX
os.environ["ACCOUNT_BANK_CLAUDE_URL"] = "http://127.0.0.1:9/usage"
import autopick, bank_common, usage

fails = 0
def ok(cond, name):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

pn = bank_common.plan_name
ok(pn("claude_max", "default_claude_max_20x") == "max_20x", "rate-limit tier separates the Max sizes")
ok(pn("claude_max", "default_claude_max_5x") == "max_5x", "the 5x size")
ok(pn("claude_pro", "default_claude_ai") == "pro", "a generic rate-limit tier is skipped")
ok(pn("claude_ultra", None) == "ultra", "a renamed organization type passes through")
ok(pn(None, "default_claude_titan") == "titan", "an unseen name passes through")
ok(pn(None, None, "max") == "max", "the credential stamp is the last fallback")
ok(pn(None, None, None) is None, "no field means no name")

pt = bank_common.plan_tier
ok(pt("claude_ultra") == "max" and pt("ultra") == "max", "Ultra stays on the Max rung for policy")
ok(pt("claude_max_20x") == "max" and pt("pro") == "pro" and pt("titan") is None, "the tier rule is otherwise unchanged")

no_limit = usage._reports_no_session_limit
weekly = {"kind": "weekly_all", "group": "weekly", "percent": 20}
ok(no_limit({"five_hour": None, "limits": [weekly]}), "the live Ultra shape: weekly limits only")
ok(not no_limit({"five_hour": None, "limits": [weekly, {"kind": "session", "percent": 0}]}), "idle, with a session limit")
ok(not no_limit({"five_hour": {"utilization": 3}, "limits": [weekly]}), "a running window")
ok(not no_limit({"five_hour": None}), "no limits list says nothing")
ok(not no_limit({"five_hour": None, "limits": []}), "an empty limits list says nothing")

ok(not usage.five_hour_lapsed({"five_hour": None, "no_five_hour_limit": True}), "a plan with no 5-hour limit never counts as lapsed")
ok(usage.five_hour_lapsed({"five_hour": None}), "an idle account still counts as lapsed")

usage.LOCKED = True
usage.CONFIG_FILE = os.path.join(SANDBOX, ".config.json")
json.dump({"auto_ping": ["b@x"], "inactive": ["b@x", 7]}, open(usage.CONFIG_FILE, "w"))
ok(usage.load_inactive() == {"b@x"}, "the config list is read, non-strings dropped")
fired = []
real_spawn = usage._spawn_autoping
usage._spawn_autoping = lambda e: fired.append(e) or True
bank = os.path.join(SANDBOX, "b@x.json")
json.dump({}, open(bank, "w"))
usage.maybe_autoping([{"provider": "claude", "email": "b@x", "inactive": True, "status": "ok"}], {"b@x": bank})
ok(fired == [], "auto-ping skips an inactive account that is still on the auto-ping list")
usage._spawn_autoping = real_spawn
open(usage.CONFIG_FILE, "w").write("{broken")
ok(usage.load_inactive() == set(), "a broken config means nothing is inactive")

doc = {"accounts": [
    {"provider": "claude", "email": "a@x", "active": True, "status": "ok", "plan": "max",
     "worst_limit": {"percent": 95, "kind": "weekly_all"}},
    {"provider": "claude", "email": "b@x", "active": False, "status": "needs-relogin", "plan": "pro",
     "inactive": True, "worst_limit": None}]}
d = autopick.decide(doc, {"auto_pick": False}, "a@x")
ok("b@x" not in json.dumps(d), "the warning does not offer an inactive account")

print(f"\n{fails} failure(s)")
sys.exit(1 if fails else 0)
