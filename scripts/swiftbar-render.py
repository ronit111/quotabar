#!/usr/bin/env python3
"""Render usage.py output as SwiftBar plugin text.
Reads the normalized usage JSON on stdin, prints SwiftBar menu-bar + dropdown.

Menu bar: Claude accounts' worst-limit % (active first), separated by " · ";
Codex figure(s) after a " ǀ " divider, each prefixed "▸". needs-relogin accounts
are excluded from the title. Colored by the active Claude account's severity.

Dropdown: one card per account. Claude cards get Ping + (if parked) Switch items.
Codex card is read-only (no swap, no ping). needs-relogin cards render red.
"""
import json, sys, os, datetime, time

SELF = os.path.dirname(os.path.abspath(__file__))
SWAP = os.path.join(SELF, "swap-account.sh")
PING = os.path.join(SELF, "ping-account.sh")
TOGGLE = os.path.join(SELF, "toggle-autoping.sh")
_HOME = os.path.expanduser("~")
# (r13 #11) resolve the bank dir with the SAME order as lib.sh (BANK_DIR -> ACCOUNT_BANK_DIR
# -> ~/.claude/accounts). The old XDG default (~/.local/share/quotabar) read a DIFFERENT
# .config.json than the scripts mutate, so the menu showed stale auto-ping/cooldown state
# and offered actions inconsistent with what ping/swap actually operate on.
BANK_DIR = (os.environ.get("BANK_DIR") or os.environ.get("ACCOUNT_BANK_DIR")
            or os.path.join(_HOME, ".claude", "accounts"))
CONFIG_FILE = os.path.join(BANK_DIR, ".config.json")
PING_COOLDOWN = 1800  # 30 min, must match ping-account.sh


def autoping_enabled():
    try:
        ap = json.load(open(CONFIG_FILE)).get("auto_ping")
        if isinstance(ap, list):
            return {e for e in ap if isinstance(e, str)}
    except Exception:
        pass
    return set()


def color_for(pct):
    if pct is None:
        return "gray"
    if pct < 60:
        return "#3fb950"
    if pct <= 85:
        return "#d29922"
    return "#f85149"


def to_ist(iso):
    if not iso:
        return "?"
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        ist = dt.astimezone(datetime.timezone(datetime.timedelta(hours=5, minutes=30)))
        return ist.strftime("%a %d %b %H:%M IST")
    except Exception:
        return iso


def bar(pct, width=10):
    if pct is None:
        return "—"
    filled = int(round(min(pct, 100) / 100 * width))
    return "█" * filled + "░" * (width - filled)


def worst_pct(a):
    w = a.get("worst_limit")
    return w["percent"] if w else None


def is_relogin(a):
    return a.get("status") == "needs-relogin" or a.get("error") == "needs-relogin"


def last_ping_for(email):
    try:
        rec = json.load(open(os.path.join(BANK_DIR, f"{email}.json")))
        return float(rec.get("last_ping", 0) or 0)
    except Exception:
        return 0.0


def main():
    try:
        doc = json.load(sys.stdin)
    except Exception:
        print("⚡ ?"); print("---"); print("Could not read usage data"); return

    accounts = doc.get("accounts", [])
    _autoping = autoping_enabled()
    claude = [a for a in accounts if a.get("provider") == "claude"]
    codex = [a for a in accounts if a.get("provider") == "codex"]
    claude.sort(key=lambda a: (not a.get("active"), a.get("email", "")))
    stale = doc.get("stale")

    # ---- menu bar title: icon-only, color = worst across all healthy accounts ----
    healthy = [worst_pct(a) for a in accounts
               if not is_relogin(a) and not a.get("error") and worst_pct(a) is not None]
    tcolor = "gray" if (stale or not healthy) else color_for(max(healthy))
    icon = "bolt.trianglebadge.exclamationmark" if any(is_relogin(a) for a in claude) else "bolt.fill"
    print(f"| sfimage={icon} sfcolor={tcolor}")

    # ---- dropdown ----
    print("---")
    if stale:
        print(f"Showing last-good cache ({doc.get('stale_reason','stale')}) | color=#d29922 size=11")
        print("---")

    def render_card(a, is_codex=False):
        email = a.get("email") or ("Codex" if is_codex else "?")
        if is_relogin(a):
            print(f"⚠ {email}: re-login needed | color=#f85149 font=Menlo")
            print(f"-- Run /login in Claude Code, pick {email}, then re-bank | color=gray size=11")
            print(f"-- Re-bank after re-login | bash=\"{SELF}/bank-account.sh\" terminal=true refresh=true")
            print("-----")
            return
        dot = "● " if a.get("active") else ("▸ " if is_codex else "○ ")
        wp = worst_pct(a)
        plan = f"  [{a.get('plan')}]" if a.get("plan") else ""
        cached = "  (cached)" if a.get("stale_entry") else ""
        print(f"{dot}{email}{plan}{cached} | color={color_for(wp)} font=Menlo")
        if a.get("error"):
            print(f"-- {a['error']} | color=#f85149 font=Menlo length=60")
        else:
            fh = a.get("five_hour") or {}
            sd = a.get("seven_day") or {}
            fhu, sdu = fh.get("utilization"), sd.get("utilization")
            if fhu is not None:
                print(f"-- 5h   {bar(fhu)}  {('%g%%' % fhu):>5} | font=Menlo color={color_for(fhu)}")
                print(f"--       resets {to_ist(fh.get('resets_at'))} | font=Menlo color=gray size=11")
            sd_label = "week" if is_codex else "week"
            if sdu is not None:
                print(f"-- {sd_label} {bar(sdu)}  {('%g%%' % sdu):>5} | font=Menlo color={color_for(sdu)}")
                print(f"--       resets {to_ist(sd.get('resets_at'))} | font=Menlo color=gray size=11")
            w = a.get("worst_limit")
            if w:
                print(f"-- worst: {w['kind']} {('%g%%' % w['percent'])} | font=Menlo color={color_for(w['percent'])}")
        # actions (claude only)
        if not is_codex:
            if email in _autoping:
                print(f"-- ⟳ auto-ping: on — click to disable | bash=\"{TOGGLE}\" param1={email} terminal=false refresh=true")
            else:
                print(f"-- ⟳ auto-ping: off — click to enable | color=gray | bash=\"{TOGGLE}\" param1={email} terminal=false refresh=true")
            # Manual Ping only when auto-ping is OFF — with auto-ping on, the window
            # restarts on lapse automatically, so there's never one to start by hand.
            if email not in _autoping:
                lp = last_ping_for(email)
                remain = PING_COOLDOWN - (time.time() - lp) if lp else 0
                if remain > 0:
                    print(f"-- ⏱ Ping on cooldown ({int(remain//60)}m left) | color=gray font=Menlo")
                else:
                    print(f"-- ⏻ Ping (start 5h window) | bash=\"{PING}\" param1={email} terminal=false refresh=true")
            if not a.get("active"):
                print(f"-- ⇄ Switch terminal to {email} | bash=\"{SWAP}\" param1={email} terminal=false refresh=true")
        print("-----")

    for a in claude:
        render_card(a, is_codex=False)
    for a in codex:
        render_card(a, is_codex=True)

    print("Refresh now | refresh=true")
    print(f"Updated {doc.get('generated_at','?')} | color=gray size=11")


if __name__ == "__main__":
    main()
