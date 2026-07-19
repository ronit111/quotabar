#!/usr/bin/env python3
"""autopick.py — the account-warn auto-pick POLICY (pure + unit-testable).

decide(doc, config, active_email) -> a decision dict:
  {"action": "none"}
  {"action": "warn", active, active_pct, kind, resets, others}
  {"action": "swap", target, target_pct, active, active_pct, reason}

Policy (PLAN-TIERED ladder Max > Pro > Free — higher tiers always preferred
for capability/quota; there is no home_base). Pro mirrors Max one rung down:
leave a hot Pro (>=90) only for a healthier Pro; fall to Free only when EVERY
banked Max AND Pro is provably exhausted (>=99, fresh eligible data); from
Free climb back to the highest tier with any account <99. Unknown plans stay
outside every tier (never a target, never tiered).
  - Active is a MAX account:
      * worst < 90%   -> stay (nothing).
      * worst >= 90%  -> swap to the healthiest OTHER max whose worst is lower.
                         If none such:
                           - if ALL max accounts are >= 99% and a pro account is
                             eligible -> swap to the healthiest pro.
                           - else -> stay and warn (hot max, nowhere better).
  - Active is a PRO account:
      * swap back to the healthiest max as soon as ANY max's worst < 99%.
      * else -> stay (warn if the pro itself is >= 80%).
  - auto_pick off / stale data / active not eligible -> warn-only fallback.

Target selection among same-tier candidates (ratified refinement — applies to
the swap-away-from-hot-max and return-to-max-from-pro choices, NOT the pro
fallback): instead of "lowest worst%", (1) prefer targets with worst_limit < 90
(headroom guard — a near-dead window is a wall, not free quota); (2) among those
prefer the SOONEST five_hour.resets_at (use-it-or-lose-it — spend a window about
to reset, preserve fresh ones); (3) tie-break equal/missing resets_at by lowest
worst%. Missing resets_at sorts last but is never excluded for that alone. This
only reorders target choice; it adds no swap trigger and changes no threshold
(if the headroom guard would empty the set, it falls back to the healthiest of
the original candidates so a warranted swap is never dropped).

Eligible = Claude account, has a worst_limit, no error, not a stale/cached
figure, not needs-relogin. Plan comes from each account's "plan" field
(subscriptionType "max"/"pro"); anything not "max" counts as non-max. Never
swaps on stale/cache-miss data, lock contention, or to a needs-relogin account.
"""
import datetime

MAX_HOT = 90        # a max account is eligible to leave at/above this
MAX_EXHAUSTED = 99  # a max account counts as exhausted at/above this
WARN_AT = 80


def worst_of(a):
    wl = a.get("worst_limit")
    return wl.get("percent") if isinstance(wl, dict) else None


def _reset_epoch(a):
    """Epoch seconds of an account's five_hour.resets_at, or None if absent/bad."""
    fh = a.get("five_hour")
    if not isinstance(fh, dict):
        return None
    iso_s = fh.get("resets_at")
    if not iso_s:
        return None
    try:
        return datetime.datetime.fromisoformat(iso_s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _select_target(cands, by_email):
    """Pick the swap target from {email: worst_pct} same-tier candidates, applying
    the reset-proximity refinement (see module docstring). by_email maps email ->
    account dict (for five_hour.resets_at). Returns an email or None."""
    if not cands:
        return None
    inf = float("inf")
    def key(email):
        re = _reset_epoch(by_email.get(email) or {})
        return (re if re is not None else inf, cands[email])   # soonest reset, then lowest worst%
    headroom = [e for e in cands if cands[e] < MAX_HOT]        # (1) headroom guard
    pool = headroom if headroom else list(cands)              # fall back so a swap is never dropped
    return min(pool, key=key)


def is_max(a):
    return a.get("plan") == "max"


def is_pro(a):
    # Tier membership requires a LITERAL plan string (finding #5). An unknown /
    # None / unrecognized plan belongs to NO tier — never a target, never tiered.
    return a.get("plan") == "pro"


def is_free(a):
    return a.get("plan") == "free"


def plan_tag(a):
    return ("max" if is_max(a) else "pro" if is_pro(a)
            else "free" if is_free(a) else "unknown")


def eligible(a):
    return (a.get("provider") == "claude"
            and worst_of(a) is not None
            and not a.get("error")
            and not a.get("stale_entry")
            and a.get("status") != "needs-relogin")


def _pct(elig, email):
    for a in elig:
        if a.get("email") == email:
            return worst_of(a)
    return None


def decide(doc, config, active_email):
    accounts = [a for a in doc.get("accounts", []) if a.get("provider") == "claude"]
    active = next((a for a in accounts if a.get("email") == active_email), None)
    active_pct = worst_of(active) if active else None

    def build_warn():
        others = []
        for a in accounts:
            if a.get("email") == active_email:
                continue
            if a.get("status") == "needs-relogin" or a.get("error"):
                continue
            p = worst_of(a)
            tag = plan_tag(a)
            others.append(f"{a.get('email')} [{tag}] at {round(p)}%" if p is not None
                          else f"{a.get('email')} [{tag}] (unknown)")
        wl = active.get("worst_limit") or {}
        return {"action": "warn", "active": active_email, "active_pct": active_pct,
                "kind": wl.get("kind"), "resets": wl.get("resets_at"),
                "others": "; ".join(others) if others else "no other swappable accounts banked"}

    def warn_or_none():
        # fallback gate (auto_pick off / stale / ineligible): warn only if hot.
        if active is None or active_pct is None or active_pct < WARN_AT:
            return {"action": "none"}
        return build_warn()

    if not config.get("auto_pick"):
        return warn_or_none()
    if doc.get("stale"):
        return warn_or_none()
    if active is None or not eligible(active):
        return warn_or_none()

    elig = [a for a in accounts if eligible(a)]
    elig_by_email = {a["email"]: a for a in elig}
    maxes = {a["email"]: worst_of(a) for a in elig if is_max(a)}
    # Tier TARGETS must be eligible AND carry the literal plan (finding #5).
    pros = {a["email"]: worst_of(a) for a in elig if is_pro(a)}
    frees = {a["email"]: worst_of(a) for a in elig if is_free(a)}
    # Every banked account of a tier, eligible or not — used to gate a
    # tier-down fallback conservatively (finding #4): can't prove a tier is
    # exhausted while any of its accounts lacks fresh eligible data.
    all_max_accts = [a for a in accounts if is_max(a)]
    all_pro_accts = [a for a in accounts if is_pro(a)]

    def tier_exhausted(tier_accts, tier_elig):
        return bool(tier_elig) and all(
            eligible(a) and (worst_of(a) or 0) >= MAX_EXHAUSTED for a in tier_accts)

    target = reason = None
    if is_max(active):
        if active_pct >= MAX_HOT:
            better = {e: w for e, w in maxes.items() if e != active_email and w < active_pct}
            picked = _select_target(better, elig_by_email) if better else None
            if picked:
                target, reason = picked, "better-max"
            else:
                # Pro fallback only when EVERY banked max account has fresh,
                # eligible data AND is >= 99% (finding #4). A max with missing /
                # errored / stale / relogin / unknown-plan data blocks the
                # fallback: we can't prove it is exhausted, so we stay conservative.
                usable_pros = {e: w for e, w in pros.items() if w < MAX_EXHAUSTED}
                usable_frees = {e: w for e, w in frees.items() if w < MAX_EXHAUSTED}
                if tier_exhausted(all_max_accts, maxes) and usable_pros:
                    target, reason = min(usable_pros, key=usable_pros.get), "max-exhausted-to-pro"
                elif (tier_exhausted(all_max_accts, maxes)
                      and tier_exhausted(all_pro_accts, pros) and usable_frees):
                    # both higher tiers provably exhausted -> free is better than blocked
                    target, reason = min(usable_frees, key=usable_frees.get), "pro-exhausted-to-free"
                # else: stay and warn (via warn_or_none below)
        # active_pct < MAX_HOT -> stay
    elif is_pro(active):  # active is pro -> return to a max as soon as any max < 99%
        avail = {e: w for e, w in maxes.items() if w < MAX_EXHAUSTED}
        picked = _select_target(avail, elig_by_email) if avail else None
        if picked:
            target, reason = picked, "return-to-max"
        elif active_pct >= MAX_HOT:
            better = {e: w for e, w in pros.items() if e != active_email and w < active_pct}
            picked = _select_target(better, elig_by_email) if better else None
            if picked:
                target, reason = picked, "better-pro"
            else:
                usable_frees = {e: w for e, w in frees.items() if w < MAX_EXHAUSTED}
                if (tier_exhausted(all_pro_accts, pros)
                        and tier_exhausted(all_max_accts, maxes) and usable_frees):
                    target, reason = min(usable_frees, key=usable_frees.get), "pro-exhausted-to-free"
    elif is_free(active):  # active is free -> climb back up ASAP, highest tier first
        for pool, rsn in ((maxes, "return-to-max"), (pros, "return-to-pro")):
            avail = {e: w for e, w in pool.items() if w < MAX_EXHAUSTED}
            picked = _select_target(avail, elig_by_email) if avail else None
            if picked:
                target, reason = picked, rsn
                break
    else:
        # active plan is unknown/None: we cannot tier it — warn only, never swap.
        return warn_or_none()

    if target and target != active_email:
        return {"action": "swap", "target": target, "target_pct": _pct(elig, target),
                "active": active_email, "active_pct": active_pct, "reason": reason}
    return warn_or_none()
