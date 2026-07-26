#!/usr/bin/env bash
# account-warn.sh — SessionStart hook. AUTO-PICK: picks the best Claude account
# for future sessions (plan-tiered ladder), or falls back to a warn note.
#
# Safety posture (2026-07-21 hardening):
#   - ONE hook-wide cooperative deadline; each child gets the REMAINING budget
#     (findings #42/#43). We NEVER externally SIGKILL a lock-owning operation
#     (findings #42/#44): on budget overrun we DETACH the child (its own session)
#     and let it finish + release its lock cooperatively. Children are internally
#     bounded (usage.py TOTAL_DEADLINE, swap sub-second commit), so detaching is
#     safe and cannot strand the lock.
#   - Exactly ONE hook JSON object is emitted (finding #46): messages accumulate.
#   - Child scripts run with /bin/bash and a sanitized env (finding #48).
#   - Child failures are recorded to a 0600 diagnostics log, and a swap failure is
#     reported as such, not misattributed to lock contention (finding #47).
# (release-eve) resolve the scripts dir the way add-account.sh/claude-acct do: env override,
# else THIS script's OWN dir, else the legacy path only if the resolved dir lacks the modules.
# The hard-coded legacy path made this hook a silent no-op on every machine that installs to
# the XDG location — the `import autopick` below fails, `sys.exit(0)` swallows it, and the
# hook emits nothing while looking healthy. On the author's box the two paths coincide, so
# behavior there is unchanged.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
SELF_DIR="${ACCOUNT_BANK_SCRIPTS_DIR:-$_SELF_DIR}"
[ -f "$SELF_DIR/bank_common.py" ] || SELF_DIR="$HOME/.claude/scripts/account-bank"

SELF_DIR="$SELF_DIR" python3 - "$SELF_DIR" <<'PY' 2>/dev/null || true
import json, os, sys, time, subprocess, glob, urllib.request, datetime, pwd

self_dir = sys.argv[1]
sys.path.insert(0, self_dir)
try:
    import autopick
    import bank_common
except Exception:
    sys.exit(0)

HOME = os.path.expanduser("~")
# (v101-confirm) THE bank-directory rule, shared with lib.sh:22 and every other entry point:
# BANK_DIR -> ACCOUNT_BANK_DIR -> default. This hook used to stop at BANK_DIR, so an
# ACCOUNT_BANK_DIR-only setup had it READ the default bank's cache/config while the children it
# spawns (bank-account.sh, usage.py, swap-account.sh) all resolved to the custom one — it could
# decide an auto-swap from one bank and execute it against another. The resolved value is
# exported to every child below so none of them can re-resolve differently.
BANK = bank_common.resolve_bank_dir()
CACHE = os.path.join(BANK, ".usage-cache.json")
CONFIG = os.path.join(BANK, ".config.json")
CLAUDE_JSON = os.environ.get("CLAUDE_JSON", os.path.join(HOME, ".claude.json"))
FAILLOG = os.path.join(BANK, ".hook-failures.log")
KEYCHAIN_SERVICE = "Claude Code-credentials"
KEYCHAIN_ACCOUNT = os.environ.get("KEYCHAIN_ACCOUNT") or pwd.getpwuid(os.getuid()).pw_name

HOOK_DEADLINE = time.time() + float(os.environ.get("ACCOUNT_BANK_HOOK_BUDGET", "5"))
def remaining():
    return max(0.0, HOOK_DEADLINE - time.time())

# --- one-object output (finding #46): accumulate, emit once ------------------
_messages = []
def note(m):
    _messages.append(m)
def done(code=0):
    if _messages:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SessionStart", "additionalContext": " ".join(_messages)}}))
    sys.exit(code)

def diag(msg):
    """Bounded, redacted 0600 diagnostics (finding #47) — never a secret."""
    try:
        line = f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {msg}\n"
        with open(FAILLOG, "a") as f:
            f.write(line)
        os.chmod(FAILLOG, 0o600)
        if os.path.getsize(FAILLOG) > 64 * 1024:
            data = open(FAILLOG).read()[-32 * 1024:]
            with open(FAILLOG, "w") as f:
                f.write(data)
            os.chmod(FAILLOG, 0o600)
    except Exception:
        pass

def _security_bin():
    o = os.environ.get("ACCOUNT_BANK_SECURITY_BIN")
    if o and os.path.isfile(o) and os.access(o, os.X_OK):
        return o
    return "/usr/bin/security" if os.path.exists("/usr/bin/security") else "security"

BASH = "/bin/bash" if os.path.exists("/bin/bash") else "bash"
def _san_env(extra=None):
    env = {k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV", "CDPATH")}
    # (v101-confirm) pin BOTH rungs of the bank-directory rule to the value WE resolved, so a
    # child can never resolve to a different bank than the one this hook read its decision from.
    env["BANK_DIR"] = BANK
    env["ACCOUNT_BANK_DIR"] = BANK
    if extra:
        env.update(extra)
    return env

def run_child(cmd, extra_env=None, budget=None):
    """Run a lock-owning child. NEVER SIGKILL it (findings #42/#44): on budget
    overrun DETACH (own session) and let it finish + release its lock. Returns
    (rc, out, err, status) where status in {"ok","spawn-failed","timeout-detached"}.
    rc is None when detached/failed."""
    if budget is None:
        budget = remaining()
    if budget <= 0.3:
        return (None, "", "", "no-budget")
    try:
        p = subprocess.Popen(cmd, env=_san_env(extra_env), stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                             text=True, start_new_session=True)
    except Exception as e:
        diag(f"spawn failed {cmd[:2]}: {type(e).__name__}")
        return (None, "", "", "spawn-failed")
    try:
        out, err = p.communicate(timeout=max(0.5, budget))
        return (p.returncode, out or "", err or "", "ok")
    except subprocess.TimeoutExpired:
        # Do NOT kill — it may be mid-commit holding the lock. Leave it detached to
        # finish cooperatively; its own trap/finally releases the lock.
        diag(f"child exceeded hook budget; DETACHED (not killed): {cmd[:2]}")
        return (None, "", "", "timeout-detached")

def emit_ctx(ctx):   # legacy single-message helper
    note(ctx)

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
    done(0)
config = load_config()

# --- auto-bank on first login -------------------------------------------------
bank_file = os.path.join(BANK, f"{act}.json")
if not os.path.exists(bank_file):
    run_child([BASH, os.path.join(self_dir, "bank-account.sh")],
              {"ACCOUNT_BANK_LOCK_WAIT": "2"}, budget=min(remaining(), 4))
    if os.path.exists(bank_file):
        plan = "?"
        try:
            plan = (json.load(open(bank_file)).get("claudeAiOauth") or {}).get("subscriptionType", "?")
        except Exception:
            pass
        note(f"New account {act} auto-banked (plan: {plan}) — now tracked in the usage bar "
             f"and auto-pick pool.")
        done(0)
    # banking failed (lock busy / no creds) -> fall through fail-soft to the pick

# --- login-sync (auto re-bank) ------------------------------------------------
# Compare the FULL canonical OAuth object (finding #45): a refresh-token/expiry
# rotation with an unchanged accessToken is still drift. Require the re-bank child
# to SUCCEED before announcing a re-sync (never announce on an ignored failure).
#
# (v101-confirm) This hook NO LONGER re-banks ambiguous drift. It re-banks only the one case
# it can PROVE offline — the banked account's own access token, unchanged, with rotated
# refresh/expiry fields — and DEFERS everything else to usage.py's oracle-gated poll heal,
# which asks the live G9 identity endpoint who the credential belongs to before writing.
# bank_common.hook_rebank_refusal is that rule and carries the reasoning.
#
# The gate is deliberately offline. This hook runs against a 5s cooperative deadline, and a
# blocking identity lookup here is the historical hook-timeout/false-death hazard — so the
# hook's job is to be RIGHT or SILENT, and the poll's job is to resolve what silence left
# behind. A deferral is always announced: the user learns their credentials changed, that the
# bank record is deliberately untouched, and that nothing is lost.
else:
    try:
        raw = subprocess.run([_security_bin(), "find-generic-password", "-s", KEYCHAIN_SERVICE,
                              "-a", KEYCHAIN_ACCOUNT, "-w"],
                             capture_output=True, text=True, timeout=min(3, max(0.5, remaining())),
                             stdin=subprocess.DEVNULL, env=_san_env()).stdout
        kc = (json.loads(raw or "{}") or {}).get("claudeAiOauth") or {}
        rec = (json.load(open(bank_file)) or {}).get("claudeAiOauth") or {}
        # full-object drift, not just accessToken/subscriptionType
        drift = bool(kc.get("accessToken")) and not bank_common.same_credentials(kc, rec)
        drift = drift or (kc.get("subscriptionType") != rec.get("subscriptionType") and bool(kc.get("accessToken")))
        if drift:
            refusal = bank_common.hook_rebank_refusal(kc, rec)
            if not refusal:
                # PROVABLY this account's own credential: a rotation of the refresh token or
                # expiry behind an unchanged access token. Re-bank silently, as before —
                # routine rotation is not news.
                rc, out, err, st = run_child([BASH, os.path.join(self_dir, "bank-account.sh")],
                                             {"ACCOUNT_BANK_LOCK_WAIT": "2"},
                                             budget=min(remaining(), 4))
                if rc != 0 and st != "timeout-detached":
                    diag(f"login-sync re-bank did not succeed (status={st}, rc={rc})")
            else:
                old_plan, new_plan = rec.get("subscriptionType"), kc.get("subscriptionType")
                if old_plan and new_plan and old_plan != new_plan:
                    note(f"{act}: plan change detected ({old_plan} -> {new_plan}). The bank "
                         f"record is UNCHANGED for now — re-banking is deferred to the "
                         f"identity-verified poll, which confirms the credential's owner "
                         f"before writing. Run bank-account.sh to link it immediately.")
                else:
                    note(f"{act}: the active credential no longer matches its bank record "
                         f"({refusal}). Not re-banked from this hook — deferred to the "
                         f"identity-verified poll. The bank record is untouched; if the "
                         f"account shows as unlinked, /swap still works and bank-account.sh "
                         f"re-links it.")
                diag(f"login-sync DEFERRED to the poll heal: {refusal}")
    except Exception as e:
        diag(f"login-sync error: {type(e).__name__}")

# --- get a usage doc: fresh cache (full, multi-account) or a fallback poll ----
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

# Cache stale/missing and QuotaBar not running -> this hook is the only scheduler.
# One full poll via usage.py (runs maybe_autoping), parked-refresh DISABLED in this
# short path (finding #2) and bounded by the REMAINING hook budget (not a fixed 5s
# that could exceed the hook deadline, finding #43). On overrun we DETACH, never
# SIGKILL (findings #42/#44); usage.py's cache write is atomic so a detach is safe.
if doc is None:
    try:
        qb = subprocess.run(["pgrep", "-x", "QuotaBar"], capture_output=True,
                            timeout=min(2, max(0.5, remaining()))).returncode == 0
    except Exception:
        qb = True
    if not qb and remaining() > 1.0:
        run_child([sys.executable, os.path.join(self_dir, "usage.py")],
                  {"ACCOUNT_BANK_LOCK_WAIT": "2", "ACCOUNT_BANK_NO_PARKED_REFRESH": "1"},
                  budget=min(remaining(), 4))
        doc = load_cache_fresh()

if doc is None:
    # active-only poll -> can only warn (decide() won't swap without alternatives)
    try:
        raw = subprocess.run([_security_bin(), "find-generic-password", "-s", KEYCHAIN_SERVICE,
                              "-a", KEYCHAIN_ACCOUNT, "-w"],
                             capture_output=True, text=True,
                             timeout=min(3, max(0.5, remaining())), env=_san_env()).stdout
        tok = json.loads(raw)["claudeAiOauth"]["accessToken"]
        req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage",
            headers={"Authorization": f"Bearer {tok}", "anthropic-beta": "oauth-2025-04-20"})
        with urllib.request.urlopen(req, timeout=min(3, max(0.5, remaining()))) as r:
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
    except Exception as e:
        diag(f"fallback active-only poll failed: {type(e).__name__}")
        done(0)

decision = autopick.decide(doc, config, act)
action = decision.get("action")

# --- refuse to auto-swap on stale data (finding #3, defense-in-depth) ---------
active_entry = next((a for a in doc.get("accounts", []) if a.get("email") == act), None)
cache_unsafe = bool(doc.get("stale")) or bool(
    active_entry and (active_entry.get("error") or active_entry.get("stale_entry")))
if action == "swap" and cache_unsafe:
    action = "warn"

def warn_text():
    active = next((a for a in doc.get("accounts", []) if a.get("email") == act), None)
    wl = (active or {}).get("worst_limit") or {}
    others = decision.get("others")
    if others is None:
        others = "no other swappable accounts banked"
    return (f"Active Claude account {act} is at {round(wl.get('percent', 0))}% of its "
            f"{wl.get('kind')} limit (resets {to_ist(wl.get('resets_at'))}). "
            f"Consider /swap — bank has: {others}.")

if action == "none":
    done(0)

if action == "warn":
    note(warn_text())
    done(0)

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
        note(f"Auto-pick (dry-run): WOULD swap active account to {target} ({tpct}%{rp}) — "
             f"would move this and all running sessions; active {act} at {apct}%. No change made.")
        done(0)
    # lock-wait 2s: swap acquires+finishes fast, or aborts cleanly at acquire
    # BEFORE any write. --expect-active (finding #11): abort if a newer switch
    # happened under the lock. We NEVER SIGKILL the swap (findings #1/#44): on
    # budget overrun we DETACH it — swap protects its own keychain->metadata commit
    # and finishes cooperatively, releasing its lock. A detached swap is reported
    # honestly as "did not confirm", never as success.
    budget = min(remaining(), 15)
    rc, out, err, st = run_child([BASH, os.path.join(self_dir, "swap-account.sh"),
                                  target, "--expect-active", act],
                                 {"ACCOUNT_BANK_LOCK_WAIT": "2"}, budget=budget)
    if rc == 0:
        rp = f", {reason_txt}" if reason_txt else ""
        note(f"Auto-pick: swapped active account to {target} ({tpct}%{rp}) — this and all "
             f"running sessions now bill it (was {act} at {apct}%).")
    else:
        # preserve the real category (finding #47): expected-active abort (rc 3),
        # detached, spawn-failure, or a genuine failure — not a blanket "lock busy".
        if st == "timeout-detached":
            why = "swap still running (did not confirm within the hook budget)"
        elif rc == 6:
            # (v101-confirm) rc 6 is "commit landed, cleanup failed" — the switch DID happen
            # and reporting it as a failed swap would be a lie in the other direction.
            note(f"Auto-pick: swapped active account to {target} ({tpct}%) — but its recovery "
                 f"journal could not be cleared. The switch is in effect; run reconcile.py "
                 f"(or bank-account.sh) before the next swap.")
            diag(f"auto-swap committed but journal clear failed err={(err or '')[:180]}")
            done(0)
        elif rc == 3:
            why = "the active account changed under the lock (a newer switch won)"
        elif st in ("spawn-failed", "no-budget"):
            why = "the swap could not be started in time"
        else:
            why = "the swap did not complete (lock busy or aborted)"
            diag(f"auto-swap failed rc={rc} st={st} err={(err or '')[:180]}")
        note(f"Auto-pick wanted to switch to {target} ({tpct}%) but {why}. "
             f"Active {act} is at {apct}%. You can /swap manually.")
    done(0)

done(0)
PY
exit 0
