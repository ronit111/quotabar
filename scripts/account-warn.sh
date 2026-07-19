#!/usr/bin/env bash
# account-warn.sh — SessionStart hook. AUTO-PICK: picks the best Claude account
# for future sessions (hysteresis + home-base bias), or falls back to a warn note.
#
# Cheap + safe: uses .usage-cache.json when <10 min old (needed for a full,
# multi-account decision); otherwise a single 3s active-only poll that can only
# warn, never swap ("never swap on stale/cache-miss data"). Always exits 0,
# total budget < 5s. A swap is bounded (short lock-wait, 4s cap) and aborts
# cleanly before any write if the lock is busy -> falls back to a warn note.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
# Resolve the scripts dir from this file's own location so the hook works wherever
# it is installed. QUOTABAR_SCRIPTS_DIR overrides (e.g. a symlinked hook copy).
SELF_DIR="${QUOTABAR_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

python3 - "$SELF_DIR" <<'PY' 2>/dev/null || true
import json, os, sys, time, subprocess, glob, urllib.request, datetime, pwd

self_dir = sys.argv[1]
sys.path.insert(0, self_dir)
try:
    import autopick
except Exception:
    sys.exit(0)

HOME = os.path.expanduser("~")
_XDG_DATA = os.environ.get("XDG_DATA_HOME", os.path.join(HOME, ".local", "share"))
BANK = os.environ.get("BANK_DIR", os.path.join(_XDG_DATA, "quotabar"))
CACHE = os.path.join(BANK, ".usage-cache.json")
CONFIG = os.path.join(BANK, ".config.json")
CLAUDE_JSON = os.path.join(HOME, ".claude.json")
KEYCHAIN_SERVICE = "Claude Code-credentials"
# EXACT service+account selector, identical to lib.sh kc_read (finding #6).
KEYCHAIN_ACCOUNT = os.environ.get("KEYCHAIN_ACCOUNT") or pwd.getpwuid(os.getuid()).pw_name

def emit(ctx):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart", "additionalContext": ctx}}))

def active_email():
    try:
        return (json.load(open(CLAUDE_JSON)).get("oauthAccount") or {}).get("emailAddress", "")
    except Exception:
        return ""

def load_config():
    try:
        c = json.load(open(CONFIG))
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}

def to_ist(iso):
    if not iso: return "?"
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        ist = dt.astimezone(datetime.timezone(datetime.timedelta(hours=5, minutes=30)))
        return ist.strftime("%a %d %b %H:%M IST")
    except Exception:
        return iso

act = active_email()
if not act:
    sys.exit(0)
config = load_config()

# --- auto-bank on first login: if the active account has no bank file, bank it
#     now (fast, locked, idempotent) and announce. Then stop — the freshly banked
#     account is active and healthy, so auto-pick has nothing to do this run. ---
bank_file = os.path.join(BANK, f"{act}.json")
if not os.path.exists(bank_file):
    try:
        subprocess.run(["bash", os.path.join(self_dir, "bank-account.sh")],
                       capture_output=True, text=True, timeout=4, stdin=subprocess.DEVNULL,
                       env=dict(os.environ, ACCOUNT_BANK_LOCK_WAIT="2"))
    except Exception:
        pass
    if os.path.exists(bank_file):
        plan = "?"
        try:
            plan = (json.load(open(bank_file)).get("claudeAiOauth") or {}).get("subscriptionType", "?")
        except Exception:
            pass
        emit(f"New account {act} auto-banked (plan: {plan}) — now tracked in the usage bar "
             f"and auto-pick pool.")
        sys.exit(0)
    # banking failed (lock busy / no creds) -> fall through fail-soft to the pick

# --- login-sync (auto re-bank): the bank file exists, but a /login may have
#     rotated credentials or changed the plan since it was written. Compare the
#     live keychain blob to the bank record; on ANY drift, re-bank silently so
#     the plan chip and tokens are always in sync — no manual Re-bank needed
#     after a routine login. (Re-bank button remains for needs-relogin recovery.)
else:
    try:
        raw = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
                              "-a", KEYCHAIN_ACCOUNT, "-w"],
                             capture_output=True, text=True, timeout=3,
                             stdin=subprocess.DEVNULL).stdout
        kc = (json.loads(raw or "{}") or {}).get("claudeAiOauth") or {}
        rec = (json.load(open(bank_file)) or {}).get("claudeAiOauth") or {}
        drift = (kc.get("accessToken") and (
            kc.get("accessToken") != rec.get("accessToken")
            or kc.get("subscriptionType") != rec.get("subscriptionType")))
        if drift:
            old_plan = rec.get("subscriptionType")
            subprocess.run(["bash", os.path.join(self_dir, "bank-account.sh")],
                           capture_output=True, text=True, timeout=4,
                           stdin=subprocess.DEVNULL,
                           env=dict(os.environ, ACCOUNT_BANK_LOCK_WAIT="2"))
            new_plan = kc.get("subscriptionType")
            if new_plan and old_plan and new_plan != old_plan:
                emit(f"{act}: plan change detected ({old_plan} -> {new_plan}) — bank re-synced.")
            # token-only drift: silent (routine rotation), bank now fresh
    except Exception:
        pass   # fail-soft: sync retries next session / next swap re-bank

# --- get a usage doc: fresh cache (full, multi-account) or a fallback poll ---
def load_cache_fresh():
    try:
        if os.path.exists(CACHE) and (time.time() - os.path.getmtime(CACHE)) < 600:
            d = json.load(open(CACHE))
            if isinstance(d, dict):
                return d
    except Exception:
        pass
    return None

doc = load_cache_fresh()

# Cache is stale/missing. If QuotaBar isn't running, its 5-min poll loop isn't
# refreshing the cache or firing auto-pings, so this hook is the only scheduler
# (finding #9). Do ONE full poll via usage.py (which runs maybe_autoping) instead
# of an active-only request, giving hook-time auto-ping coverage when the app is
# closed. Bounded by a hard 5s timeout to respect the hook budget; on overrun or
# failure we fall through to the active-only poll below. usage.py's cache write is
# atomic, so a timeout-kill can't corrupt it.
if doc is None:
    try:
        qb = subprocess.run(["pgrep", "-x", "QuotaBar"], capture_output=True).returncode == 0
    except Exception:
        qb = True   # assume running (skip the heavier path) if pgrep is unavailable
    if not qb:
        try:
            subprocess.run(["python3", os.path.join(self_dir, "usage.py")],
                           capture_output=True, text=True, timeout=5,
                           stdin=subprocess.DEVNULL,
                           env=dict(os.environ, ACCOUNT_BANK_LOCK_WAIT="2"))
        except Exception:
            pass
        doc = load_cache_fresh()

if doc is None:
    # active-only poll -> can only warn (decide() won't swap without alternatives)
    try:
        raw = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
                              "-a", KEYCHAIN_ACCOUNT, "-w"],
                             capture_output=True, text=True, timeout=3).stdout
        tok = json.loads(raw)["claudeAiOauth"]["accessToken"]
        req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage",
            headers={"Authorization": f"Bearer {tok}", "anthropic-beta": "oauth-2025-04-20"})
        with urllib.request.urlopen(req, timeout=3) as r:
            u = json.load(r)
        cands = []
        for l in (u.get("limits") or []):
            if l.get("percent") is not None:
                cands.append((float(l["percent"]), l.get("kind"), l.get("resets_at")))
        for k in ("five_hour", "seven_day"):
            b = u.get(k) or {}
            if b.get("utilization") is not None:
                cands.append((float(b["utilization"]), k, b.get("resets_at")))
        w = max(cands, default=(None, None, None), key=lambda c: c[0] if c[0] is not None else -1)
        doc = {"accounts": [{"provider": "claude", "email": act, "active": True, "status": "ok",
                             "worst_limit": ({"percent": w[0], "kind": w[1], "resets_at": w[2]}
                                             if w[0] is not None else None)}]}
    except Exception:
        sys.exit(0)

decision = autopick.decide(doc, config, act)
action = decision.get("action")

# --- refuse to auto-swap on stale data (finding #3) ---
# A failed/backoff poll can be persisted with a FRESH mtime, so the <600s mtime
# check above is not proof of freshness. If the doc is flagged stale, or the
# active entry carries an error / stale_entry, downgrade any swap to a warn.
# (autopick already guards this; this is a defense-in-depth check that does not
# depend on autopick's internals.)
active_entry = next((a for a in doc.get("accounts", []) if a.get("email") == act), None)
cache_unsafe = bool(doc.get("stale")) or bool(
    active_entry and (active_entry.get("error") or active_entry.get("stale_entry")))
if action == "swap" and cache_unsafe:
    action = "warn"

def warn_text():
    # active pct/kind/resets from the doc
    active = next((a for a in doc.get("accounts", []) if a.get("email") == act), None)
    wl = (active or {}).get("worst_limit") or {}
    others = decision.get("others")
    if others is None:
        others = "no other swappable accounts banked"
    return (f"Active Claude account {act} is at {round(wl.get('percent', 0))}% of its "
            f"{wl.get('kind')} limit (resets {to_ist(wl.get('resets_at'))}). "
            f"Consider /swap — bank has: {others}.")

if action == "none":
    sys.exit(0)

if action == "warn":
    emit(warn_text())
    sys.exit(0)

if action == "swap":
    target = decision["target"]
    tpct = round(decision.get("target_pct", 0))
    apct = round(decision.get("active_pct", 0))
    reason = decision.get("reason")
    reason_txt = {"better-max": "healthier max", "max-exhausted-to-pro": "all max exhausted",
                  "return-to-max": "returning to max", "better-pro": "healthier pro",
                  "pro-exhausted-to-free": "all max+pro exhausted",
                  "return-to-pro": "returning to pro"}.get(reason, "")
    if os.environ.get("ACCOUNT_BANK_AUTOPICK_DRYRUN") == "1":
        rp = f", {reason_txt}" if reason_txt else ""
        emit(f"Auto-pick (dry-run): WOULD swap active account to {target} ({tpct}%{rp}) — "
             f"would move this and all running sessions; active {act} at {apct}%. No change made.")
        sys.exit(0)
    # lock-wait 2s: swap either acquires and finishes fast (~1.5s of local ops)
    # or aborts cleanly at acquire BEFORE any write. The 4s subprocess cap then
    # never lands mid-write, and the whole hook stays well under its 5s budget.
    # Pass the account we DECIDED against as --expect-active (finding #11): if a
    # manual/QuotaBar swap changed the active account between our read and the
    # swap acquiring the lock, swap-account.sh aborts (exit 3) rather than
    # overwrite the newer switch. We never externally kill the swap while it is
    # committing (finding #1): the 2s lock-wait is the only slow part; once past
    # it the swap is sub-second. We bound a true hang with a generous SIGTERM cap
    # (not SIGKILL), and swap-account.sh protects its keychain->metadata commit
    # from that TERM, so a timeout can never tear the commit.
    env = dict(os.environ, ACCOUNT_BANK_LOCK_WAIT="2")
    ok = False
    try:
        p = subprocess.Popen(["bash", os.path.join(self_dir, "swap-account.sh"),
                              target, "--expect-active", act],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             stdin=subprocess.DEVNULL, text=True, start_new_session=True)
        try:
            p.communicate(timeout=15)
            ok = (p.returncode == 0)
        except subprocess.TimeoutExpired:
            p.terminate()   # SIGTERM -> swap finishes its commit, then exits
            try:
                p.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill(); p.communicate()
            ok = (p.returncode == 0)
    except Exception:
        ok = False
    if ok:
        rp = f", {reason_txt}" if reason_txt else ""
        emit(f"Auto-pick: swapped active account to {target} ({tpct}%{rp}) — this and all "
             f"running sessions now bill it (was {act} at {apct}%).")
    else:
        emit(f"Auto-pick wanted to switch to {target} ({tpct}%) but the swap did not complete "
             f"(lock busy — will retry next session). Active {act} is at {apct}%. You can /swap manually.")
    sys.exit(0)
PY
exit 0
