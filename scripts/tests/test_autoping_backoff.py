#!/usr/bin/env python3
"""v105 — auto-ping must stop retrying a hopeless home.

Regression cover for the fault found 2026-08-13: the failure debounce was FLAT at 5 min,
so a home whose credential was gone got re-pinged every poll cycle indefinitely (60
consecutive failures over ~33h, both homes, observed in .autoping.log 11-13 Aug 2026).
v104's expired-seat-token trigger stays true forever on such a home, so nothing upstream
could ever break the loop.

Two brakes are asserted here: an escalating failure cooldown, and a needs-login circuit
breaker. The healthy path must be untouched — that is the risk this file guards.
"""
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import usage  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    base = usage.AUTOPING_FAIL_COOLDOWN
    cap = usage.AUTOPING_FAIL_COOLDOWN_MAX
    cd = usage._autoping_fail_cooldown

    # --- the historical behaviour must survive for ordinary one-off failures
    ok(cd({}) == base, "no marker yet -> the historical 5-min debounce, unchanged")
    ok(cd({"ping_fail_streak": 0}) == base, "streak 0 -> unchanged")
    ok(cd({"ping_fail_streak": 1}) == base, "a single failure -> unchanged (no penalty)")

    # --- escalation
    ok(cd({"ping_fail_streak": 2}) == base * 2, "2 consecutive failures -> doubles")
    ok(cd({"ping_fail_streak": 3}) == base * 4, "3 -> quadruples")
    ok(cd({"ping_fail_streak": 5}) == base * 16, "5 -> 16x")
    ok(cd({"ping_fail_streak": 4}) > cd({"ping_fail_streak": 3}),
       "cooldown is monotonic in the streak")

    # --- the cap, and the reason it exists: a broken home must cost ~4 turns/day, not 144
    ok(cd({"ping_fail_streak": 99}) == cap, "long streak is capped, never unbounded")
    ok(cd({"ping_fail_streak": 10 ** 9}) == cap,
       "absurd streak still caps (no overflow from the 2** shift)")
    ok(86400 / cap <= 6,
       "at the cap a hopeless home costs at most ~6 futile turns/day (was ~144)")

    # --- corrupt/hostile marker values must not throw; a marker file is on-disk state
    for bad in ({"ping_fail_streak": "seven"}, {"ping_fail_streak": None},
                {"ping_fail_streak": -5}, {"ping_fail_streak": [1]}):
        try:
            v = cd(bad)
            ok(base <= v <= cap, f"corrupt streak {bad!r} -> a sane cooldown, no raise")
        except Exception as e:
            ok(False, f"corrupt streak {bad!r} raised {e!r}")

    # --- the needs-login breaker is what ping-account.sh stamps, and a success clears it
    src = open(os.path.join(HERE, "usage.py")).read()
    ok('rec.get("needs_login_since")' in src,
       "usage.py skips a home flagged needs_login_since")
    ping = open(os.path.join(HERE, "ping-account.sh")).read()
    ok('needs_login_since' in ping, "ping-account.sh stamps needs_login_since")
    ok('d.pop("needs_login_since", None)' in ping,
       "a SUCCESSFUL ping clears the flag — the breaker cannot wedge a healed home")
    ok('d["ping_fail_streak"] = 0' in ping,
       "a SUCCESSFUL ping resets the streak — backoff cannot wedge a healthy home")
    ok('not logged in|please run /login' in ping,
       "the no-credential signature is matched")
    ok('403|forbidden' in ping,
       "an ambiguous/transient response vetoes the needs-login verdict (fail-closed)")
    ok('>"${_out:-/dev/null}" 2>&1' in ping,
       "the turn's output is captured for classification, not discarded")
    ok('rm -f "$_out"' in ping, "the captured output is deleted, never logged")

    print(f"-- autoping_backoff: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
