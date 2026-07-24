#!/usr/bin/env python3
"""Tests for autopick_v2.py — ratified ladder policy on the pointer substrate."""
import json
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import autopick_v2  # noqa: E402
import registry  # noqa: E402
import repoint  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def setup(accts):
    acc = tempfile.mkdtemp(prefix="ap2-acc-")
    # (r10 #8) auto-pick is OPT-IN: enable it explicitly for the ladder tests below.
    with open(os.path.join(acc, ".config.json"), "w") as f:
        json.dump({"auto_pick": True}, f)
    for email, meta in accts.items():
        home = os.path.join(acc, "homes", email.replace("@", "-at-"))
        os.makedirs(home)
        registry.publish_ready(acc, email, home, f"uuid-{email}")
        with open(os.path.join(acc, f"{email}.json"), "w") as f:
            json.dump(meta, f)
    return acc


def pick_email(acc):
    p = autopick_v2.choose(acc)
    return p[0] if p else None


def main():
    now = time.time()

    # ladder: healthy Max beats healthy Pro
    acc = setup({
        "max@x.com": {"plan": "max", "weekly_util": 50, "resets_at_epoch": now + 100, "status": "ok"},
        "pro@x.com": {"plan": "pro", "weekly_util": 10, "resets_at_epoch": now + 50, "status": "ok"},
    })
    ok(pick_email(acc) == "max@x.com", "healthy Max beats healthier Pro (ladder)")

    # tier-down only when ALL Max provably exhausted (>=99)
    acc = setup({
        "max@x.com": {"plan": "max", "weekly_util": 99.5, "resets_at_epoch": now + 100, "status": "ok"},
        "pro@x.com": {"plan": "pro", "weekly_util": 40, "resets_at_epoch": now + 50, "status": "ok"},
    })
    ok(pick_email(acc) == "pro@x.com", "all Max >=99 -> Pro picked")

    # Max at 98 still holds the ladder
    acc = setup({
        "max@x.com": {"plan": "max", "weekly_util": 98, "resets_at_epoch": now + 100, "status": "ok"},
        "pro@x.com": {"plan": "pro", "weekly_util": 5, "resets_at_epoch": now + 50, "status": "ok"},
    })
    ok(pick_email(acc) == "max@x.com", "Max at 98 not abandoned")

    # among eligible same-tier: worst<90 guard + soonest reset
    acc = setup({
        "a@x.com": {"plan": "max", "weekly_util": 95, "resets_at_epoch": now + 10, "status": "ok"},
        "b@x.com": {"plan": "max", "weekly_util": 40, "resets_at_epoch": now + 500, "status": "ok"},
        "c@x.com": {"plan": "max", "weekly_util": 30, "resets_at_epoch": now + 200, "status": "ok"},
    })
    ok(pick_email(acc) == "c@x.com", "healthy pool: soonest reset wins (95%% one excluded by <90 guard)")

    # needs-relogin excluded entirely
    acc = setup({
        "sick@x.com": {"plan": "max", "weekly_util": 5, "resets_at_epoch": now + 1, "status": "needs-relogin"},
        "wellp@x.com": {"plan": "pro", "weekly_util": 20, "resets_at_epoch": now + 9, "status": "ok"},
    })
    ok(pick_email(acc) == "wellp@x.com", "needs-relogin never picked")

    # config gate
    acc = setup({"m@x.com": {"plan": "max", "weekly_util": 1, "resets_at_epoch": now, "status": "ok"}})
    with open(os.path.join(acc, ".config.json"), "w") as f:
        json.dump({"auto_pick": False}, f)
    ok(pick_email(acc) is None, "auto_pick=false -> no pick")

    # (r10 #8) OPT-IN: with NO .config.json at all, auto-pick is OFF (a bare launch must
    # never silently repoint). This is the inverted-default the review flagged.
    acc = setup({"m@x.com": {"plan": "max", "weekly_util": 1, "resets_at_epoch": now, "status": "ok"}})
    os.remove(os.path.join(acc, ".config.json"))
    ok(pick_email(acc) is None, "no .config.json -> auto-pick OFF (opt-in default) (r10 #8)")
    # and an empty/omitted auto_pick key is also OFF
    with open(os.path.join(acc, ".config.json"), "w") as f:
        json.dump({"some_other_key": 1}, f)
    ok(pick_email(acc) is None, "auto_pick key omitted -> OFF (opt-in) (r10 #8)")

    # main(): repoints to the choice; idempotent when already pointed
    acc = setup({
        "max@x.com": {"plan": "max", "weekly_util": 50, "resets_at_epoch": now + 100, "status": "ok"},
        "pro@x.com": {"plan": "pro", "weekly_util": 10, "resets_at_epoch": now + 50, "status": "ok"},
    })
    sys.argv = ["autopick_v2.py", acc]
    autopick_v2.main()
    tgt = repoint.read_current(acc)
    ok(tgt and tgt.endswith("max-at-x.com"), "main() repoints to the pick")
    logn = sum(1 for _ in open(os.path.join(acc, "pointer.log")))
    autopick_v2.main()
    ok(sum(1 for _ in open(os.path.join(acc, "pointer.log"))) == logn,
       "already-pointed -> no new transaction (idempotent)")

    # (r8 #12) the REAL data source is usage.py's .usage-cache.json — v2-seeded homes have
    # NO per-email <email>.json. Seed two READY homes with NO per-email metadata, put the
    # current figures ONLY in the cache (usage's field shapes: plan + worst_limit.percent +
    # five_hour.resets_at ISO), and prove the ladder still discriminates by plan/quota
    # rather than collapsing to a lexicographic (unknown-everything) pick.
    def setup_cache(entries):
        acc = tempfile.mkdtemp(prefix="ap2-cache-")
        with open(os.path.join(acc, ".config.json"), "w") as f:
            json.dump({"auto_pick": True}, f)     # (r10 #8) opt-in
        for email in entries:
            home = os.path.join(acc, "homes", email.replace("@", "-at-"))
            os.makedirs(home)
            registry.publish_ready(acc, email, home, f"uuid-{email}")
        with open(os.path.join(acc, ".usage-cache.json"), "w") as f:
            json.dump({"accounts": list(entries.values())}, f)
        return acc

    def iso(ep):
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ep))

    # "zzz@x.com" sorts LAST lexicographically but is the healthy Max — a correct read of
    # the cache must pick it over the lexicographically-first exhausted Pro.
    acc = setup_cache({
        "zzz@x.com": {"provider": "claude", "email": "zzz@x.com", "plan": "max", "status": "ok",
                      "worst_limit": {"percent": 20.0}, "five_hour": {"resets_at": iso(now + 100)}},
        "aaa@x.com": {"provider": "claude", "email": "aaa@x.com", "plan": "pro", "status": "ok",
                      "worst_limit": {"percent": 95.0}, "five_hour": {"resets_at": iso(now + 50)}},
    })
    ok(pick_email(acc) == "zzz@x.com",
       "cache-sourced figures: healthy Max beats lexicographically-first Pro (r8 #12)")
    ok(autopick_v2._meta(acc, "zzz@x.com").get("weekly_util") == 20.0,
       "_meta reads worst_limit.percent from .usage-cache.json (r8 #12)")
    ok(autopick_v2._meta(acc, "zzz@x.com").get("resets_at_epoch") is not None,
       "_meta parses five_hour.resets_at ISO -> epoch (r8 #12)")

    print(f"-- autopick_v2: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
