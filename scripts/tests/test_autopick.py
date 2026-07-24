#!/usr/bin/env python3
"""autopick policy: plan normalization tiers + unknown-plan blocks tier-down
(finding 49), plus the never-swap-on-stale guards."""
import os, sys
AB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AB)
import autopick

P = F = 0
def ok(c, name):
    global P, F
    if c: P += 1; print("  ok  ", name)
    else: F += 1; print("  FAIL", name)

def acct(email, plan, pct, **kw):
    a = {"provider": "claude", "email": email, "plan": plan, "status": "ok",
         "worst_limit": ({"percent": pct, "kind": "five_hour"} if pct is not None else None),
         "five_hour": {"utilization": pct, "resets_at": None}}
    a.update(kw)
    return a

def decide(accounts, active, auto_pick=True):
    return autopick.decide({"accounts": accounts, "stale": False}, {"auto_pick": auto_pick}, active)

# plan tiers
ok(autopick.is_max(acct("a", "max", 10)), "is_max literal")
ok(autopick.is_pro(acct("a", "pro", 10)), "is_pro literal")
ok(not autopick.is_max(acct("a", None, 10)), "unknown plan is not max")
ok(autopick.plan_tag(acct("a", "weird", 10)) == "unknown", "unrecognized plan -> unknown tag")

# hot max swaps to a healthier max
d = decide([acct("hot@x", "max", 95), acct("cool@x", "max", 20)], "hot@x")
ok(d["action"] == "swap" and d["target"] == "cool@x", "hot max -> healthier max")

# UNKNOWN-plan account present blocks tier-DOWN to pro (finding 49)
d = decide([acct("hot@x", "max", 99), acct("mystery@x", "weird", 30), acct("p@x", "pro", 10)], "hot@x")
ok(d["action"] != "swap" or d.get("target") != "p@x",
   "unknown-plan account blocks max->pro tier-down")

# with NO unknown plan, exhausted max DOES fall to pro
d = decide([acct("hot@x", "max", 99), acct("p@x", "pro", 10)], "hot@x")
ok(d["action"] == "swap" and d["target"] == "p@x", "all-max-exhausted -> pro when no unknown plan")

# never swap on stale doc
d = autopick.decide({"accounts": [acct("hot@x", "max", 99), acct("c@x", "max", 10)], "stale": True},
                    {"auto_pick": True}, "hot@x")
ok(d["action"] != "swap", "stale doc -> never swap")

# never swap to a needs-relogin target
d = decide([acct("hot@x", "max", 95), acct("dead@x", "max", 5, status="needs-relogin", error="needs-relogin")], "hot@x")
ok(d["action"] != "swap", "needs-relogin target excluded")

# auto_pick off -> warn only
d = decide([acct("hot@x", "max", 95), acct("cool@x", "max", 10)], "hot@x", auto_pick=False)
ok(d["action"] != "swap", "auto_pick off -> no swap")

print(f"  -- autopick: {P} passed, {F} failed")
sys.exit(1 if F else 0)
