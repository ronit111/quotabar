#!/usr/bin/env python3
"""autopick_v2.py — the ratified auto-pick policy, pointer edition (rev 6 §3 rule 4).

Runs inside the shim BEFORE exec (never in a SessionStart hook — r1 #10). Reads the
same bank metadata usage.py maintains (utilization, resets_at, plan), applies the
Owner-ratified ladder (Max > Pro > Free; tier-down targets <99%; leave Max >=90 only
for healthier Max; Pro only when ALL Max >=99; return when any Max <99; prefer
soonest 5h reset among eligible, worst<90 guard), and — when the best choice differs
from the current pointer — repoints via the §4 transaction. Advisory: any failure
leaves the pointer untouched (the shim then launches on the existing pointer).

v2 differences from v1 autopick.py: no keychain read (the pointer names the active
choice), no swap invocation (repoint is the whole action), READY-gated targets only.
Policy config gate: accounts/.config.json auto_pick (same as v1).
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registry
import repoint


def _cfg(acc):
    try:
        with open(os.path.join(acc, ".config.json")) as f:
            return json.load(f)
    except Exception:
        return {}


def _iso_to_epoch(s):
    """Parse the ISO-8601 UTC timestamps usage.py writes (epoch_to_iso), else None."""
    if not isinstance(s, str) or not s:
        return None
    import calendar
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return calendar.timegm(time.strptime(s, fmt))
        except ValueError:
            continue
    return None


def _meta(acc, email):
    """Per-account figures the ladder needs, normalized to {plan, weekly_util,
    resets_at_epoch, status}.

    (r8 #12) The REAL source is usage.py's `.usage-cache.json` — v2 seeding writes NO
    per-email `<email>.json`, and usage stores current figures ONLY in the cache, under
    DIFFERENT field names (plan; five_hour/seven_day with `utilization`+ISO `resets_at`).
    Reading the non-existent per-email files made every candidate "unknown", collapsing
    the ratified ladder to a lexicographic pick. So: read the cache entry for this email
    and mirror v1 autopick.py's inputs — util = worst_limit.percent (the same worst-case
    the >=99 / <90 guards key on), resets = five_hour.resets_at (the "soonest 5h reset"
    preference), plan = plan. A legacy `<email>.json` (if one exists) is honored as a
    fallback so existing tooling/tests keep working; {} when neither is present."""
    try:
        with open(os.path.join(acc, ".usage-cache.json")) as f:
            cache = json.load(f)
        for a in cache.get("accounts", []):
            if a.get("provider") == "claude" and a.get("email") == email:
                wl = a.get("worst_limit") or {}
                util = wl.get("percent")
                fh = a.get("five_hour") or {}
                return {"plan": a.get("plan"),
                        "weekly_util": util,
                        "resets_at_epoch": _iso_to_epoch(fh.get("resets_at")),
                        "status": a.get("status", "ok")}
    except Exception:
        pass
    try:
        with open(os.path.join(acc, f"{email}.json")) as f:
            return json.load(f)               # legacy per-email metadata (fallback)
    except Exception:
        return {}


def _tier(plan):
    return {"max": 2, "pro": 1, "free": 0}.get((plan or "").lower(), -1)


def _util(meta):
    u = meta.get("weekly_util", meta.get("utilization"))
    return float(u) if isinstance(u, (int, float)) and not isinstance(u, bool) else None


def _resets(meta):
    r = meta.get("resets_at_epoch")
    return float(r) if isinstance(r, (int, float)) else float("inf")


def choose(acc):
    """Returns (email, home) for the pick, or None to leave the pointer alone."""
    cfg = _cfg(acc)
    # (r10 #8) auto-pick is OPT-IN (v1 contract): enabled ONLY when auto_pick is literally
    # true. A missing/absent .config.json must NOT silently repoint a bare `claude` launch.
    if cfg.get("auto_pick") is not True:
        return None
    try:
        reg = registry.load(acc)
    except registry.RegistryError:
        return None
    cands = []
    for email, ent in reg.items():
        if not (isinstance(ent, dict) and ent.get("ready") is True):
            continue
        home = ent.get("home")
        if not (isinstance(home, str) and os.path.isdir(home)):
            continue
        m = _meta(acc, email)
        if m.get("status") not in (None, "ok"):
            continue                      # needs-relogin etc: never pick
        u = _util(m)
        cands.append({"email": email, "home": home, "tier": _tier(m.get("plan")),
                      "util": u, "resets": _resets(m)})
    if not cands:
        return None

    # ladder: highest tier first; within a tier the policy filters below
    best_tier = max(c["tier"] for c in cands)
    top = [c for c in cands if c["tier"] == best_tier]

    def eligible(pool):
        # unknown utilization = eligible (fail-open for PICKING, never for mutation:
        # picking a home only decides where the next terminal opens)
        return [c for c in pool if c["util"] is None or c["util"] < 99.0]

    pick_pool = eligible(top)
    if not pick_pool and best_tier == 2:
        # every Max provably >=99 -> tier down to Pro (ratified: ALL Max exhausted)
        lower = [c for c in cands if c["tier"] < best_tier]
        if lower:
            next_tier = max(c["tier"] for c in lower)
            pick_pool = eligible([c for c in lower if c["tier"] == next_tier])
    if not pick_pool:
        return None

    # worst<90 guard + soonest reset preference (ratified)
    healthy = [c for c in pick_pool if c["util"] is None or c["util"] < 90.0]
    pool = healthy or pick_pool
    pool.sort(key=lambda c: (c["resets"], c["util"] if c["util"] is not None else 50.0))
    c = pool[0]
    return c["email"], c["home"]


def main():
    acc = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/accounts")
    pick = choose(acc)
    if not pick:
        return 0
    email, home = pick
    cur = repoint.read_current(acc)
    if cur and os.path.realpath(cur) == os.path.realpath(home):
        return 0                          # already pointed there
    try:
        repoint.repoint(acc, home, f"auto-pick:{email}",
                        registry_check=lambda h: registry.is_ready_home(acc, h))
        print(f"auto-pick -> {email}")
    except repoint.RepointError as e:
        print(f"auto-pick: leaving pointer unchanged ({e})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
