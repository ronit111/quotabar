#!/usr/bin/env python3
"""usage.py — poll usage for every Claude bank account + the active keychain
account + the Codex/ChatGPT account, and emit one normalized JSON document.

Providers
  claude : bank files + the live keychain account. Active account is read-only
           (never refreshed). Parked accounts refresh LAZILY (only when their
           token is expired and we actually need to poll) via the isolated
           CLAUDE_CONFIG_DIR technique — the Claude Code CLI does the refresh,
           we never hand-roll OAuth. See isolated_refresh.py.
  codex  : ~/.codex/auth.json (owned by the Codex CLI). STRICTLY READ-ONLY — we
           never refresh its tokens. On 401 we render "re-auth needed (run codex)".

Efficiency (standing directive)
  - No background processes. This script runs only when SwiftBar (5m) or the warn
    hook invokes it.
  - Tiered polling: active-claude + codex every run; PARKED claude accounts only
    when their cached reading is >30 min old (usage barely moves while parked).
  - Zero token spend except the lazy parked-refresh turn (haiku-tier) and only
    when a parked token is actually expired.
  - 5s timeouts, one retry max on network errors, exponential backoff: after 3
    consecutive all-network-failure runs, back off to 30-min attempts and serve
    the stale cache.

Parked-token death is an expected steady state: a revoked/expired parked refresh
token -> status "needs-relogin" written to the bank file; that account is not
polled again until re-banked.

stdlib only. Token values are never printed.
"""
import json, os, sys, time, glob, subprocess, urllib.request, urllib.error, tempfile, socket, datetime, pwd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
import banklock
try:
    import isolated_refresh
except Exception:
    isolated_refresh = None
try:
    import reconcile as _reconcile
except Exception:
    _reconcile = None

LOCKED = False          # True only while we may MUTATE (hold lock AND no unresolved torn swap)
HOLD_LOCK = False       # True while we physically hold the lock (gates release)


def resolve_codex_bin():
    """Absolute path to the codex CLI or None (finding #36), mirroring lib.sh
    codex_bin: honor ACCOUNT_BANK_CODEX_BIN if executable, else PATH, else known
    install dirs. Bare `codex` under the GUI's minimal PATH silently fails."""
    override = os.environ.get("ACCOUNT_BANK_CODEX_BIN")
    if override:
        return override if (os.path.isfile(override) and os.access(override, os.X_OK)) else None
    import shutil
    c = shutil.which("codex")
    if c and os.path.isfile(c) and os.access(c, os.X_OK):
        return c
    for cand in (os.path.expanduser("~/.local/bin/codex"),
                 "/opt/homebrew/bin/codex", "/usr/local/bin/codex"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None
TOTAL_DEADLINE = float(os.environ.get("ACCOUNT_BANK_TOTAL_DEADLINE", "45"))
DEADLINE = float("inf")   # wall-clock run deadline; set in main(), read by process_claude (#28)
LOCK_STALE_SECS = 300

HOME = os.path.expanduser("~")
BANK_DIR = os.environ.get("BANK_DIR", os.path.join(HOME, ".claude", "accounts"))
CLAUDE_JSON = os.environ.get("CLAUDE_JSON", os.path.join(HOME, ".claude.json"))
CACHE_FILE = os.path.join(BANK_DIR, ".usage-cache.json")
# (r8 #3 / r13 #12) the v2 control-plane skip set now lives in bank_common (shared with
# list-accounts.sh) so both apply the identical set. Alias kept for the local reference.
_V2_CONTROL_JSON = bank_common.V2_CONTROL_JSON

# (r13 #7) emails of v2 READY homes discovered from the registry. These are MONITOR-ONLY in
# usage.py: their .credentials.json is owned by the home CLI / tier-2 archiver (they rotate it
# in place). usage.py must NEVER run the legacy parked-refresh on them — with no legacy
# bank_path the rotated token would never be written back, spending the home's refresh token
# and stranding the home. Populated fresh each run by the registry-discovery block in main().
V2_HOME_EMAILS = set()
V2_HOME_PATHS = {}    # email -> READY home path (for auto-ping cooldown markers)
LOCK_DIR = os.path.join(BANK_DIR, ".lock")
CODEX_AUTH = os.path.join(HOME, ".codex", "auth.json")
CONFIG_FILE = os.path.join(BANK_DIR, ".config.json")
AUTOPING_LOG = os.path.join(BANK_DIR, ".autoping.log")
AUTOPING_COOLDOWN = float(os.environ.get("ACCOUNT_BANK_AUTOPING_COOLDOWN", "1800"))
# 5-min debounce after a FAILED ping (finding #8/#10): ping-account.sh stamps
# last_ping_failed on failure, so a ping that never actually started the window
# can't be re-fired every poll cycle.
AUTOPING_FAIL_COOLDOWN = float(os.environ.get("ACCOUNT_BANK_AUTOPING_FAIL_COOLDOWN", "300"))
AUTOPING_DRYRUN = os.environ.get("ACCOUNT_BANK_AUTOPING_DRYRUN", "0") == "1"
# force-fresh: bypass parked-cache AND burst-guard for this email (post-switch trust)
_ff = os.environ.get("ACCOUNT_BANK_FORCE_FRESH", "")
FORCE_FRESH_ALL = _ff.strip() == "*"
FORCE_FRESH = set(e.strip() for e in _ff.split(",") if e.strip()) if not FORCE_FRESH_ALL else set()
# ONLY mode: fresh-poll just this claude account; serve every other entry from
# cache regardless of age (fast post-switch confirmation — one HTTPS call)
ONLY = os.environ.get("ACCOUNT_BANK_ONLY", "").strip()
def _force_fresh(email):
    return FORCE_FRESH_ALL or (email in FORCE_FRESH) or (email == ONLY)
# window phase-staggering (keep the two accounts' 5h resets offset so a refill is
# never far away). A parked auto-ping is held if the new window it would start
# (now+5h) lands within STAGGER_MIN_GAP of another claude account's current reset;
# held at most STAGGER_MAX_HOLD before firing anyway (a running window beats phase).
FIVE_HOUR_SECS = 5 * 3600
STAGGER_MIN_GAP = float(os.environ.get("ACCOUNT_BANK_STAGGER_MIN_GAP", str(75 * 60)))   # 75 min
STAGGER_MAX_HOLD = float(os.environ.get("ACCOUNT_BANK_STAGGER_MAX_HOLD", str(150 * 60)))  # 2.5 h

KEYCHAIN_SERVICE = "Claude Code-credentials"
# EXACT service+account selector, identical to lib.sh kc_read (finding #6): the
# account qualifier is the macOS username (overridable via KEYCHAIN_ACCOUNT).
# Without -a, a service-only query can return the wrong duplicate item and
# misattribute one account's quota to another email.
KEYCHAIN_ACCOUNT = os.environ.get("KEYCHAIN_ACCOUNT") or pwd.getpwuid(os.getuid()).pw_name
USAGE_URL = os.environ.get("ACCOUNT_BANK_CLAUDE_URL", "https://api.anthropic.com/api/oauth/usage")
OAUTH_BETA = "oauth-2025-04-20"
# Codex base is overridable (CodexBar allows chatgpt_base_url in config.toml); the
# env override also lets tests point it at a black hole.
CODEX_USAGE_URL = os.environ.get("ACCOUNT_BANK_CODEX_URL", "https://chatgpt.com/backend-api/wham/usage")

HTTP_TIMEOUT = float(os.environ.get("ACCOUNT_BANK_TIMEOUT", "5"))
REFRESH_ENABLED = os.environ.get("ACCOUNT_BANK_REFRESH", "1") == "1"
# (#2) In the short SessionStart-hook path, parked lazy-refresh is disabled: the
# hook bounds usage.py with a ~5s timeout that can kill a claude grandchild AFTER
# it has rotated the refresh token server-side but BEFORE we commit it — stranding
# the bank on the now-spent old token (permanent false death). When set, we skip
# the isolated_refresh turn for parked expired tokens and just serve cached/stale.
# Parked refresh then happens only from QuotaBar's poll (no short timeout) or an
# explicit ping.
NO_PARKED_REFRESH = os.environ.get("ACCOUNT_BANK_NO_PARKED_REFRESH", "0") == "1"
PARKED_MAX_AGE = float(os.environ.get("ACCOUNT_BANK_PARKED_MAX_AGE", "1800"))   # 30 min
CODEX_PING_ON_401 = os.environ.get("ACCOUNT_BANK_CODEX_PING", "0") == "1"        # gated, off
BACKOFF_FAILS = 3
BACKOFF_SECS = 1800

now = lambda: time.time()
now_ms = lambda: time.time() * 1000
iso = lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def epoch_to_iso(ts):
    if ts is None:
        return None
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(int(ts)))
    except Exception:
        return None


# ---------- lock (the shared banklock; matches lib.sh protocol) ----------
_LOCK = banklock.BankLock(BANK_DIR)   # fixes ownerless-lock leak (#30) + PID reuse (#3)


def acquire_lock(timeout=10):
    return _LOCK.acquire(timeout=timeout)


def release_lock():
    _LOCK.release()


# ---------- sources ----------
def resolve_security_bin():
    """Absolute path to `security` (finding #36), honoring ACCOUNT_BANK_SECURITY_BIN
    (also lets tests stub it). Never a bare name on PATH."""
    o = os.environ.get("ACCOUNT_BANK_SECURITY_BIN")
    if o:
        return o if (os.path.isfile(o) and os.access(o, os.X_OK)) else None
    if os.path.isfile("/usr/bin/security") and os.access("/usr/bin/security", os.X_OK):
        return "/usr/bin/security"
    # (r14 #2) NO PATH fallback for a credential-bearing tool — a `security` proxy on PATH
    # could exfiltrate the OAuth blob. If the absolute binary is gone, fail (return None).
    return None


def read_keychain_blob():
    sec = resolve_security_bin()
    if not sec:
        return None
    try:
        out = subprocess.run([sec, "find-generic-password", "-s", KEYCHAIN_SERVICE,
                              "-a", KEYCHAIN_ACCOUNT, "-w"],
                             capture_output=True, text=True, timeout=5, stdin=subprocess.DEVNULL)
        if out.returncode == 0 and out.stdout.strip():
            return json.loads(out.stdout).get("claudeAiOauth", {})
    except Exception:
        pass
    return None


def active_email():
    try:
        return (json.load(open(CLAUDE_JSON)).get("oauthAccount") or {}).get("emailAddress", "") or ""
    except Exception:
        return ""


def active_oauth_account():
    try:
        d = json.load(open(CLAUDE_JSON)).get("oauthAccount")
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


class NetError(Exception):
    """network-level failure (timeout / DNS / refused) — counts toward backoff."""


def _http_json(url, headers):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError:
        raise                      # HTTP status errors propagate as-is (401 etc)
    except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError) as e:
        raise NetError(str(e))


def http_json_retry(url, headers):
    """One retry, but only on network errors (never on an HTTP status error)."""
    try:
        return _http_json(url, headers)
    except NetError:
        time.sleep(0.4)
        return _http_json(url, headers)


# ---------- claude usage parsing ----------
def _limit_label(lim):
    kind = lim.get("kind", "?")
    scope = lim.get("scope") or {}
    model = (scope.get("model") or {}).get("display_name") if isinstance(scope, dict) else None
    return f"{kind} ({model})" if model else kind


def summarize_claude(raw):
    fh = raw.get("five_hour") or {}
    sd = raw.get("seven_day") or {}
    # (review #1) DROP a window whose utilization is null rather than emitting
    # {"utilization": null}. The API omits the value for a home with no active window
    # (verified on a monitor-only home); a null there is undecodable on the app side
    # (non-optional Double inside the window) and would blank EVERY card, not just this
    # one. A window with no utilization is "no window", represented as None.
    five_hour = {"utilization": fh.get("utilization"), "resets_at": fh.get("resets_at")} \
        if fh.get("utilization") is not None else None
    seven_day = {"utilization": sd.get("utilization"), "resets_at": sd.get("resets_at")} \
        if sd.get("utilization") is not None else None
    cands = []
    for lim in (raw.get("limits") or []):
        p = lim.get("percent")
        if p is not None:
            cands.append({"kind": _limit_label(lim), "percent": float(p), "resets_at": lim.get("resets_at")})
    if fh.get("utilization") is not None:
        cands.append({"kind": "five_hour", "percent": float(fh["utilization"]), "resets_at": fh.get("resets_at")})
    if sd.get("utilization") is not None:
        cands.append({"kind": "seven_day", "percent": float(sd["utilization"]), "resets_at": sd.get("resets_at")})
    worst = max(cands, key=lambda c: c["percent"]) if cands else None
    # model_cap: the highest limit that is genuinely PER-MODEL scoped (has a
    # scope.model.display_name, e.g. Fable/Opus). MUST derive from raw limits by the
    # presence of a model scope — NOT from a label/kind denylist. The API's `limits`
    # array also contains "session" (== the 5h) and "weekly_all" entries with NO
    # model; a denylist that only excluded five_hour/seven_day let the "session"
    # entry through, so model_cap always equalled the 5h number (bug 2026-07-20).
    model_limits = []
    for lim in (raw.get("limits") or []):
        sc = lim.get("scope") or {}
        model = (sc.get("model") or {}).get("display_name") if isinstance(sc, dict) else None
        p = lim.get("percent")
        if model and p is not None:
            model_limits.append({"kind": _limit_label(lim), "percent": float(p),
                                 "resets_at": lim.get("resets_at")})
    model_cap = max(model_limits, key=lambda c: c["percent"]) if model_limits else None
    return five_hour, seven_day, worst, model_cap


def poll_claude(token):
    return http_json_retry(USAGE_URL, {"Authorization": f"Bearer {token}", "anthropic-beta": OAUTH_BETA})


# ---------- bank status write ----------
def set_bank_status(bank_path, status):
    if not LOCKED:      # read-only mode: never write bank state without the lock
        return
    # (r9 #6 / r12 #12) set_bank_status REWRITES a legacy v1 bank record — a v1 mutation,
    # so it must pass the SAME v1_gate as every other v1 mutator: state v1|shadow AND NO
    # active SEEDING freeze (.seeding.json). The r9 fix only checked the epoch state and
    # ignored the freeze — a usage poll during /login could rewrite a record while a seed
    # holds the barrier. v1_gate covers both; absent EPOCH stays permissive (v1 default),
    # v2 / broken EPOCH / a live freeze all fence fail-closed.
    try:
        import epoch as _epoch_mod
        _epoch_mod.v1_gate(BANK_DIR)
    except Exception:
        return          # fenced (v2 / broken EPOCH / SEEDING freeze) -> never mutate
    if not bank_path or not os.path.exists(bank_path):
        return
    try:
        rec = json.load(open(bank_path))
        if rec.get("status") == status and status != "ok":
            return
        rec["status"] = status
        if status == "ok":
            rec["last_verified"] = iso()
        dirn = os.path.dirname(bank_path)
        fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, bank_path)
    except Exception:
        pass


# ---------- per-account: CLAUDE ----------
def _norm_plan(raw):
    """Normalize a plan string from EITHER oauthAccount.organizationType
    ("claude_max", "claude_max_20x") OR claudeAiOauth.subscriptionType ("max") to
    the max|pro|free tier strings autopick matches EXACTLY. Prefix-based so tier
    variants ($100 Max 5x / $200 Max 20x) both collapse to "max" — a naive
    "claude_"-strip would yield "max_20x" and break is_max()'s `== "max"`."""
    if not isinstance(raw, str) or not raw:
        return None
    r = raw.lower()
    if r.startswith("claude_"):
        r = r[len("claude_"):]
    if r.startswith("max"):
        return "max"
    if r.startswith("pro"):
        return "pro"
    if r.startswith("free"):
        return "free"
    return None


def process_claude(email, oauth, is_active, bank_path, status, oauth_account=None):
    # organizationType (from ~/.claude.json, refreshed each session) preferred over
    # Keychain subscriptionType (cached at login, stale after a plan change) —
    # Shashi Jangra's fix (#1). Both normalized so every tier variant maps.
    plan = _norm_plan((oauth_account or {}).get("organizationType")) \
        or _norm_plan((oauth or {}).get("subscriptionType"))
    res = {"provider": "claude", "email": email, "active": is_active,
           "five_hour": None, "seven_day": None, "worst_limit": None, "model_cap": None,
           "status": status, "fetched_at": now(),
           "plan": plan}  # max|pro|free, drives auto-pick
    if email in V2_HOME_EMAILS:
        res["monitor_only"] = True   # (r13 #7) app-visible: cooldown/rotation owned by the home
    if status == "needs-relogin" and not is_active:
        res["error"] = "needs-relogin"
        return res, False

    token = oauth.get("accessToken")
    exp = oauth.get("expiresAt")
    expired = (exp is not None) and (exp <= now_ms())

    if expired:
        if is_active:
            res["error"] = "active token expired (run /login or let a session refresh it; not refreshed by design)"
            return res, False
        if email in V2_HOME_EMAILS:
            # (r13 #7) a v2 READY home is MONITOR-ONLY: NEVER run the legacy parked-refresh. It
            # rotates a throwaway copy of the home credential (bank_path is None -> no write-back),
            # spending the home's refresh token and stranding it. The home CLI/archiver owns rotation.
            res["error"] = "v2 home token expired; rotation owned by the home (monitor-only, not refreshed)"
            return res, True
        if not LOCKED:      # never refresh/rotate without the lock
            res["error"] = "parked token expired; refresh skipped (no lock)"
            return res, False
        if NO_PARKED_REFRESH:
            # (#2) short hook path: don't risk a timeout-killed rotation. Serve the
            # cached/stale figure (netfail=True) — no status change, retried by the
            # next QuotaBar poll or an explicit ping.
            res["error"] = "parked token expired; refresh skipped (hook path)"
            return res, True
        if not REFRESH_ENABLED or isolated_refresh is None:
            res["error"] = "parked token expired; refresh disabled"
            return res, False
        # (#27) re-derive the LIVE active identity right before refreshing: a
        # /login may have activated this parked account since main() classified it.
        # Rotating an account that is now active would spend the refresh token its
        # live session still holds. Skip (transient) if it just became active.
        if active_email() == email:
            res["error"] = "became active during poll; parked refresh skipped"
            return res, True
        # (r2 new blocker) a parked-account refresh here LAUNCHES claude, rotates the
        # v1 refresh grant, and writes rotated bank credentials — a v1 mutation. Gate it
        # like every other v1 mutator: in v2 (or under a SEEDING freeze) it must NEVER
        # fire, so normal usage polling can no longer mutate v1 credentials in v2. The
        # snapshot is re-fenced immediately before the bank write below.
        try:
            import epoch as _epoch_mod
            _epoch_mod.v1_gate(BANK_DIR)
            _usage_snap = _epoch_mod.read_epoch(BANK_DIR)
        except Exception as _eg:
            res["error"] = f"parked refresh skipped (epoch gate: {_eg})"
            return res, True
        rexp = oauth.get("refreshTokenExpiresAt")
        if rexp is not None and rexp <= now_ms():
            # refresh token provably expired -> CONFIRMED death.
            set_bank_status(bank_path, "needs-relogin")
            res["status"] = "needs-relogin"; res["error"] = "needs-relogin"
            return res, False
        # (#28) bound the refresh to the REMAINING run budget so one 60s refresh
        # can't blow past the advertised total deadline while holding the lock.
        remaining = DEADLINE - now()
        if remaining < 10:
            res["error"] = "parked token expired; refresh skipped (insufficient time budget)"
            return res, True
        try:
            # email -> refresh writes a crash-recovery journal before cleanup.
            # claude_json enables the active-guard inside the refresh (finding #27).
            # (r4 #6) pass bank_dir so any quarantine (torn readback, journal
            # unavailable, became-active) lands INSIDE the credential bank, not
            # beside the system temp dir where a reboot / tmp-cleanup could delete
            # the only copy of a freshly rotated refresh token.
            rr = isolated_refresh.refresh_via_config_dir(
                oauth, email=email, claude_json=CLAUDE_JSON, bank_dir=BANK_DIR,
                timeout=int(min(60, remaining)))
            new, rotated = rr.creds, rr.rotated
            if rr.err:
                # changed-but-malformed / torn / journal-unavailable readback: keep
                # the old record, skip this poll rather than commit a partial blob
                # (finding #7). Transient — serve the cached figure, leave the
                # account retriable. (r4 #6) SURFACE the quarantine path instead of
                # discarding it, so the operator can recover a preserved rotation.
                if getattr(rr, "quarantine", None):
                    res["quarantine"] = rr.quarantine
                    res["error"] = f"refresh invalid: {rr.err}; recovery copy at {rr.quarantine}"
                else:
                    res["error"] = f"refresh invalid: {rr.err}"
                return res, True
            still_expired = (new.get("expiresAt") or 0) <= now_ms()
            if not rotated and still_expired:
                if rr.auth_failed:
                    # (#1) CONFIRMED auth rejection is the ONLY refresh-side death.
                    set_bank_status(bank_path, "needs-relogin")
                    res["status"] = "needs-relogin"; res["error"] = "needs-relogin"
                    return res, False
                # (#1) transient (resolver/launch/timeout/non-auth nonzero): keep
                # the existing status, note the deferral, serve the cached figure,
                # and retry next cycle rather than marking a live token dead.
                res["error"] = f"refresh deferred: {rr.reason}"
                return res, True
            if bank_path and os.path.exists(bank_path):
                # (r2 new blocker) EXACT fence immediately before the bank credential
                # write: a flip that landed during the (slow) refresh is caught here.
                try:
                    _epoch_mod.fence(BANK_DIR, _usage_snap, ("v1", "shadow"))
                except _epoch_mod.EpochFenced as _e:
                    res["error"] = f"refresh rotated but bank write fenced ({_e}); NOT committed"
                    return res, True
                rec = json.load(open(bank_path))
                if isinstance(rec, dict):
                    rec["claudeAiOauth"] = new; rec["status"] = "ok"; rec["last_verified"] = iso()
                    _bp_dir = os.path.dirname(bank_path)
                    fd, tmp = tempfile.mkstemp(dir=_bp_dir, prefix=".acct.")
                    with os.fdopen(fd, "w") as f:
                        json.dump(rec, f, indent=2); f.flush(); os.fsync(f.fileno())
                    os.chmod(tmp, 0o600); os.replace(tmp, bank_path)
                    _d = os.open(_bp_dir, os.O_RDONLY)
                    try: os.fsync(_d)
                    finally: os.close(_d)
                    if _reconcile is not None:   # bank committed -> journal redundant
                        try: os.remove(_reconcile.journal_path(email))
                        except OSError: pass
            oauth = new; token = new.get("accessToken"); res["refreshed"] = True
        except Exception as e:
            res["error"] = f"refresh failed: {type(e).__name__}"
            return res, False

    if not token:
        res["error"] = "no access token"
        return res, False
    try:
        raw = poll_claude(token)
    except urllib.error.HTTPError as e:
        # (#37) ONLY an authenticated 401 (OAuth token rejected) marks a parked
        # account dead. A 403 is AMBIGUOUS — WAF, org policy, model/endpoint scope
        # — and must stay TRANSIENT, never a permanent needs-relogin flip.
        if e.code == 401 and not is_active:
            set_bank_status(bank_path, "needs-relogin")
            res["status"] = "needs-relogin"; res["error"] = "needs-relogin"
            return res, False
        res["error"] = f"HTTP {e.code}"
        # 403 (ambiguous), 429 (rate limit), 5xx (server) are transient: report as
        # netfail so the caller serves the cached last-good entry, not a blank card.
        return res, e.code in (403, 429) or e.code >= 500
    except NetError as e:
        res["error"] = f"network: {e}"
        return res, True
    except Exception as e:
        res["error"] = f"{type(e).__name__}"
        return res, False
    fh, sd, worst, model_cap = summarize_claude(raw)
    res["five_hour"], res["seven_day"], res["worst_limit"] = fh, sd, worst
    res["model_cap"] = model_cap
    set_bank_status(bank_path, "ok")
    return res, False


# ---------- provider: CODEX (read-only) ----------
def codex_windows(rl):
    fh = sd = None
    for wname in ("primary_window", "secondary_window"):
        w = rl.get(wname) or {}
        up = w.get("used_percent")
        if up is None:
            continue
        ws = w.get("limit_window_seconds")
        entry = {"utilization": float(up), "resets_at": epoch_to_iso(w.get("reset_at"))}
        if ws is not None:
            if ws <= 6 * 3600:
                fh = entry
            else:
                sd = entry
        else:
            if wname == "primary_window" and fh is None:
                fh = entry
            else:
                sd = entry
    return fh, sd


def process_codex():
    res = {"provider": "codex", "email": None, "active": False,
           "five_hour": None, "seven_day": None, "worst_limit": None, "model_cap": None,
           "status": "ok", "fetched_at": now()}
    def _codex_plan(toks):
        """ChatGPT plan tier from the id_token JWT claims; fail-soft, never logs the token."""
        try:
            import base64
            p = (toks.get("id_token") or "").split(".")[1]
            p += "=" * (-len(p) % 4)
            claims = json.loads(base64.urlsafe_b64decode(p))
            return (claims.get("https://api.openai.com/auth") or {}).get("chatgpt_plan_type") or None
        except Exception:
            return None
    if not os.path.exists(CODEX_AUTH):
        return None, False   # no codex account configured -> omit entirely
    try:
        d = json.load(open(CODEX_AUTH))
        toks = d.get("tokens") or {}
        at, acc = toks.get("access_token"), toks.get("account_id")
        res["plan"] = _codex_plan(toks)
    except Exception as e:
        res["email"] = "Codex"; res["error"] = f"auth.json unreadable: {type(e).__name__}"
        return res, False
    if not at:
        res["email"] = "Codex"; res["error"] = "re-auth needed (run codex)"
        return res, False

    headers = {"Authorization": f"Bearer {at}", "chatgpt-account-id": acc or "",
               "User-Agent": "account-bank/1.0", "Accept": "application/json"}
    try:
        u = http_json_retry(CODEX_USAGE_URL, headers)
    except urllib.error.HTTPError as e:
        if e.code == 401 and CODEX_PING_ON_401:
            try:
                _cx = resolve_codex_bin()   # (#36) absolute path, never bare `codex`
                if not _cx:
                    raise RuntimeError("codex binary unresolved")
                subprocess.run([_cx, "exec", "reply ok", "--skip-git-repo-check"],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=60,
                               env={k: v for k, v in os.environ.items()
                                    if k not in ("BASH_ENV", "ENV", "CDPATH")})
                d = json.load(open(CODEX_AUTH)); toks = d.get("tokens") or {}
                headers["Authorization"] = f"Bearer {toks.get('access_token')}"
                u = http_json_retry(CODEX_USAGE_URL, headers)
            except Exception:
                res["email"] = d.get("email") or "Codex"
                res["error"] = "re-auth needed (run codex)"
                return res, False
        else:
            res["email"] = "Codex"
            res["error"] = "re-auth needed (run codex)" if e.code == 401 else f"HTTP {e.code}"
            return res, False
    except NetError as e:
        res["email"] = "Codex"; res["error"] = f"network: {e}"
        return res, True
    except Exception as e:
        res["email"] = "Codex"; res["error"] = f"{type(e).__name__}"
        return res, False

    res["email"] = u.get("email") or "Codex"
    res["plan"] = u.get("plan_type")
    rl = u.get("rate_limit") or {}
    fh, sd = codex_windows(rl)
    res["five_hour"], res["seven_day"] = fh, sd
    cands = []
    if fh: cands.append({"kind": "5h", "percent": fh["utilization"], "resets_at": fh["resets_at"]})
    if sd: cands.append({"kind": "weekly", "percent": sd["utilization"], "resets_at": sd["resets_at"]})
    res["worst_limit"] = max(cands, key=lambda c: c["percent"]) if cands else None
    return res, False


# ---------- cache ----------
def load_cache():
    """Load + fully validate the cache. Any shape/value error -> discard ({})."""
    try:
        d = json.load(open(CACHE_FILE))
    except Exception:
        return {}
    if not isinstance(d, dict):
        return {}
    accts = d.get("accounts", [])
    if not isinstance(accts, list):
        return {}
    clean = []
    for a in accts:
        if not isinstance(a, dict):
            continue
        # normalize the fields we later index or arithmetic on
        try:
            if a.get("fetched_at") is not None:
                float(a["fetched_at"])
            wl = a.get("worst_limit")
            if wl is not None:
                if not isinstance(wl, dict):
                    a["worst_limit"] = None
                else:
                    float(wl.get("percent"))
        except (TypeError, ValueError):
            a["worst_limit"] = None
            a["fetched_at"] = 0
        # (review #1) sanitize cached usage windows: a block whose utilization is null (an
        # old cache written before summarize_claude dropped it, or a codex row without one)
        # is undecodable app-side, so normalize it to None ("no window") on the way out.
        for _w in ("five_hour", "seven_day"):
            _b = a.get(_w)
            if _b is not None and (not isinstance(_b, dict) or _b.get("utilization") is None):
                a[_w] = None
        if not isinstance(a.get("provider"), str) or not isinstance(a.get("email"), (str, type(None))):
            continue
        clean.append(a)
    d["accounts"] = clean
    try:
        d["fail_streak"] = int(d.get("fail_streak", 0) or 0)
    except (TypeError, ValueError):
        d["fail_streak"] = 0
    try:
        d["backoff_until"] = float(d.get("backoff_until", 0) or 0)
    except (TypeError, ValueError):
        d["backoff_until"] = 0
    return d


def write_cache(doc):
    if not LOCKED:      # read-only mode: don't race the cache without the lock
        return
    try:
        fd, tmp = tempfile.mkstemp(dir=BANK_DIR, prefix=".usage-cache.")
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CACHE_FILE)
    except Exception:
        pass


def prev_good(prev_accounts, provider, email):
    """A previous cache entry with real data (no error) for this account, used to
    keep a figure visible when this run's poll hit a network hiccup."""
    for a in prev_accounts:
        if a.get("provider") == provider and a.get("email") == email \
                and a.get("worst_limit") and not a.get("error"):
            return a
    if provider == "codex":   # codex email is unknown on an errored run
        for a in prev_accounts:
            if a.get("provider") == "codex" and a.get("worst_limit") and not a.get("error"):
                return a
    return None


def serve_stale(prev, reason, fail_streak, backoff_until):
    prev = dict(prev)
    prev["stale"] = True
    prev["stale_reason"] = reason
    prev["fail_streak"] = fail_streak
    prev["backoff_until"] = backoff_until
    print(json.dumps(prev, indent=2))


# ---------- auto-ping (piggybacked on this poll; no separate scheduler) ----------
def load_autoping():
    """Emails opted into auto-ping. Fail-soft: missing/malformed -> empty set."""
    try:
        c = json.load(open(CONFIG_FILE))
        ap = c.get("auto_ping")
        if isinstance(ap, list):
            return {e for e in ap if isinstance(e, str)}
    except Exception:
        pass
    return set()


def _resets_in_future(iso):
    if not iso:
        return False
    try:
        return datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() > time.time()
    except Exception:
        return False


def five_hour_lapsed(res):
    """A 5-hour window is lapsed (no active window) unless its resets_at is in the
    future. A just-started window reports low utilization but a FUTURE resets_at,
    so we key off resets_at, not utilization — this both avoids re-firing right
    after a ping and keeps the cost at ~1 ping per 5h window (~5/day/account)."""
    fh = res.get("five_hour")
    if not isinstance(fh, dict):
        return True
    return not _resets_in_future(fh.get("resets_at"))


def _spawn_autoping(email):
    """Fire ping-account.sh fully DETACHED (own session, output to a 0600 log), so
    the poll never blocks on it. The ping takes the bank lock itself. Returns True
    only if process creation SUCCEEDED (finding #34): a swallowed Popen/log failure
    must NOT be reported as a fired ping. Uses /bin/bash with a sanitized env
    (BASH_ENV/ENV/CDPATH stripped, finding #48)."""
    try:
        if os.path.exists(AUTOPING_LOG) and os.path.getsize(AUTOPING_LOG) > 50 * 1024:
            open(AUTOPING_LOG, "w").close()
    except OSError:
        pass
    bash = "/bin/bash" if os.path.exists("/bin/bash") else (__import__("shutil").which("bash") or "bash")
    try:
        lf = open(AUTOPING_LOG, "a")
        os.chmod(AUTOPING_LOG, 0o600)
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ping-account.sh")
        lf.write(f"[{iso()}] auto-ping firing for {email}\n"); lf.flush()
        env = {k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV", "CDPATH")}
        subprocess.Popen([bash, script, email], stdin=subprocess.DEVNULL,
                         stdout=lf, stderr=lf, start_new_session=True, close_fds=True, env=env)
        return True
    except Exception as e:
        try:
            lf = open(AUTOPING_LOG, "a"); os.chmod(AUTOPING_LOG, 0o600)
            lf.write(f"[{iso()}] auto-ping SPAWN FAILED for {email}: {type(e).__name__}\n"); lf.flush()
        except Exception:
            pass
        return False


def _five_hour_reset_epoch(r):
    """Epoch seconds of a result's 5h window resets_at, or -inf when the window is
    absent/unparseable. Used to order lapsed accounts 'most lapsed first' — the
    earlier (or missing) the reset, the longer the window has been down."""
    fh = r.get("five_hour")
    if not isinstance(fh, dict):
        return float("-inf")
    iso_s = fh.get("resets_at")
    if not iso_s:
        return float("-inf")
    try:
        return datetime.datetime.fromisoformat(iso_s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return float("-inf")


def _reset_epoch_or_none(r):
    """Like _five_hour_reset_epoch but returns None (not -inf) when the window's
    resets_at is absent/unparseable — used by the stagger check, which treats a
    missing reset on the OTHER account as 'no hold'."""
    e = _five_hour_reset_epoch(r)
    return None if e == float("-inf") else e


def _stagger_hold(email, results, bp):
    """Phase-stagger gate (Addendum 2): should this PARKED auto-ping be held so the
    two accounts' 5h resets stay offset? Hold when the window we'd start (now+5h)
    lands within STAGGER_MIN_GAP of another claude account's current reset — unless
    we've already held >= STAGGER_MAX_HOLD (then fire regardless: a running window
    beats perfect phase), or no other account has a known reset (then no hold).
    Reads/persists stagger_hold_since in the bank record so the cap survives
    restarts. Returns True to hold."""
    now = time.time()
    try:
        rec = json.load(open(bp)); rec = rec if isinstance(rec, dict) else {}
    except Exception:
        rec = {}
    held_since = float(rec.get("stagger_hold_since", 0) or 0)
    if held_since and (now - held_since) >= STAGGER_MAX_HOLD:
        return False   # held long enough — fire regardless
    others = []
    for o in results:
        if o.get("provider") != "claude" or o.get("email") == email:
            continue
        oe = _reset_epoch_or_none(o)
        if oe is not None:
            others.append(oe)
    if not others:
        return False   # missing reset on the other account -> fire normally
    new_reset = now + FIVE_HOUR_SECS
    gap = min(abs(new_reset - oe) for oe in others)
    return gap < STAGGER_MIN_GAP


def _mark_stagger_hold(bp):
    """Record the hold start once (preserve the original so the 2.5h cap counts
    from the first hold ≈ the lapse)."""
    try:
        rec = json.load(open(bp)); rec = rec if isinstance(rec, dict) else {}
    except Exception:
        rec = {}
    if rec.get("stagger_hold_since"):
        return
    rec["stagger_hold_since"] = time.time()
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(bp), prefix=".acct.")
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f, indent=2)
        os.chmod(tmp, 0o600); os.replace(tmp, bp)
    except Exception:
        pass


def _clear_stagger_hold(bp):
    try:
        rec = json.load(open(bp)); rec = rec if isinstance(rec, dict) else {}
    except Exception:
        return
    if "stagger_hold_since" not in rec:
        return
    rec.pop("stagger_hold_since", None)
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(bp), prefix=".acct.")
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f, indent=2)
        os.chmod(tmp, 0o600); os.replace(tmp, bp)
    except Exception:
        pass


def maybe_autoping(results, bank_paths):
    """Fire at most ONE detached ping per poll cycle (finding #10), for the
    MOST-lapsed opted-in account whose 5h window has lapsed and whose cooldowns
    have elapsed. We do NOT stamp last_autoping before spawning: the cooldown is
    recorded inside ping-account.sh only AFTER it takes the lock and knows the
    outcome (success -> last_ping, failure -> last_ping_failed, finding #8), so a
    ping that never ran can't suppress the next attempt. Firing one per cycle
    avoids two workers racing the same lock and one losing while cooldown-
    suppressed. Requires the lock (the ping mutates state)."""
    if not LOCKED:
        return []
    enabled = load_autoping()
    if not enabled:
        return []
    candidates = []
    for r in results:
        if r.get("provider") != "claude":
            continue
        email = r.get("email")
        if email not in enabled:
            continue
        # (shadow-day fix 2, 2026-07-24) v2 homes were silently EXCLUDED from auto-ping:
        # their rows carry bank_path=None (r11 #8), so the legacy bank-record requirement
        # below dropped them before candidacy — the toggle looked on but never fired.
        # v2 homes: cooldowns live in <home>/.ping-marker.json (same last_ping/
        # last_ping_failed fields, r11 #9); a poll ERROR must NOT exclude them — an
        # expired monitor-only token is exactly what the home ping exists to recover
        # (ping-account.sh routes them to the shadow-safe home-ping path).
        if email in V2_HOME_EMAILS:
            _home = V2_HOME_PATHS.get(email)
            if not _home:
                continue
            if not five_hour_lapsed(r):
                continue
            try:
                rec = json.load(open(os.path.join(_home, ".ping-marker.json")))
                if not isinstance(rec, dict):
                    rec = {}
            except Exception:
                rec = {}   # no marker yet == no cooldown; the ping itself re-checks
        else:
            if r.get("error") or r.get("status") == "needs-relogin" or r.get("stale_entry"):
                continue
            if not five_hour_lapsed(r):
                continue
            bp = bank_paths.get(email)
            if not bp or not os.path.exists(bp):
                continue
            try:
                rec = json.load(open(bp))
                if not isinstance(rec, dict):
                    continue
            except Exception:
                continue
        # 30-min success/in-flight cooldown, plus a 5-min failed-ping cooldown.
        last_ok = max(float(rec.get("last_ping", 0) or 0),
                      float(rec.get("last_autoping", 0) or 0))
        if time.time() - last_ok < AUTOPING_COOLDOWN:
            continue
        last_fail = float(rec.get("last_ping_failed", 0) or 0)
        if time.time() - last_fail < AUTOPING_FAIL_COOLDOWN:
            continue
        candidates.append((email, r))
    if not candidates:
        return []
    # most-lapsed first: earliest (or absent) 5h resets_at
    candidates.sort(key=lambda c: _five_hour_reset_epoch(c[1]))
    email, chosen_r = candidates[0]
    bp = bank_paths.get(email)
    # phase-stagger (Addendum 2): parked pings only; the ACTIVE account is never
    # held — its window serves live work, so fire on lapse.
    if not chosen_r.get("active") and bp and _stagger_hold(email, results, bp):
        if not AUTOPING_DRYRUN:
            _mark_stagger_hold(bp)
        return ["stagger-hold:" + email]
    if AUTOPING_DRYRUN:
        return [email + " (dry-run)"]
    if bp:
        _clear_stagger_hold(bp)   # firing -> clear any prior hold marker
    if _spawn_autoping(email):
        return [email]
    return ["spawn-failed:" + email]   # (#34) never report a fired ping that didn't start


def _stable_identity(retries=3):
    """Repeatedly read the active identity + live keychain fingerprint and return
    (email, blob, stable) — stable is True only if two consecutive reads agree
    (finding #26). If they disagree a /login is racing us; the caller must not
    attribute the keychain quota to an identity that is moving underneath it."""
    a1 = active_email(); k1 = read_keychain_blob()
    f1 = bank_common.cred_fingerprint(k1 or {})
    for _ in range(max(1, retries - 1)):
        a2 = active_email(); k2 = read_keychain_blob()
        f2 = bank_common.cred_fingerprint(k2 or {})
        if a1 == a2 and f1 == f2:
            return a1, k1, True
        a1, k1, f1 = a2, k2, f2
    return a1, k1, False


def _pointer_active_email():
    """(r8 #8) Under EPOCH v2 the ACTIVE account — the one future sessions launch on — is
    the POINTER target, NOT the shared keychain slot. The keychain is a v1-era leftover
    that pins nothing (sessions pin their home at launch, §0). Determining "active" from
    keychain identity therefore shows the stale account A as ACTIVE while sessions actually
    open on the pointer's B. Return the pointer target's REGISTERED email under v2, else
    None (so v1/shadow behaviour is unchanged — the keychain identity stands)."""
    try:
        import epoch as _ep
        if _ep.read_epoch(BANK_DIR).get("state") != "v2":
            return None
        import repoint as _rp
        import registry as _reg
        tgt = _rp.read_current(BANK_DIR)
        if not tgt:
            return None
        real = os.path.realpath(tgt)
        for em, ent in _reg.load(BANK_DIR).items():
            if (isinstance(ent, dict) and ent.get("ready") is True
                    and isinstance(ent.get("home"), str)
                    and os.path.realpath(ent["home"]) == real):
                return em
    except Exception:
        return None
    return None


def _real_netfail(res):
    """A REAL network/HTTP failure that should count toward backoff (finding #31),
    as opposed to a deliberate skip/deferral (deadline, hook path, became-active,
    insufficient budget) which also returns netfail=True but must NOT trip backoff."""
    e = str((res or {}).get("error", ""))
    return e.startswith("network:") or e.startswith("HTTP ")


# ---------- v2 wiring surface for QuotaBar (epoch, health, ping cooldowns) ----------
# The app is a thin renderer: it never reads EPOCH / archiver.status.json / seed-audit.jsonl
# / <home>/.ping-marker.json itself. Everything it needs to route (v1 swap vs v2 repoint),
# to disable a v2 Ping during its cooldown, and to surface health anomalies flows through
# THIS one JSON payload. All of it is best-effort and fail-soft: a missing/broken source
# degrades to "absent", never an exception that breaks the poll.
PING_COOLDOWN = 1800          # manual/home ping success cooldown (mirrors ping-account.sh)


def epoch_state():
    """The protocol epoch state string for the app's routing: 'v1' | 'shadow' | 'v2', or
    'unknown' when the EPOCH file is present-but-broken (the app then stays on the safe v1
    path — the scripts fence a real mutation regardless). Absent EPOCH == 'v1' (pre-v2)."""
    try:
        import epoch as _ep
        return _ep.read_epoch(BANK_DIR)["state"]
    except Exception:
        return "unknown"


def _v2_ping_cooldown_until(home):
    """(r12 #13) Absolute epoch seconds until a v2 home's Ping is eligible again, read from
    <home>/.ping-marker.json (the same last_ping ping-account.sh stamps). None when no
    cooldown is active. Absolute so a value carried on a cached row stays correct."""
    try:
        d = json.load(open(os.path.join(home, ".ping-marker.json")))
        lp = float(d.get("last_ping", 0) or 0) if isinstance(d, dict) else 0.0
    except Exception:
        return None
    if lp > 0 and lp + PING_COOLDOWN > now():
        return lp + PING_COOLDOWN
    return None


def _health_surface():
    """(r10 app-item) Anomaly-only health for QuotaBar. Best-effort; every field degrades to
    absent on any error. The app renders NOTHING when healthy — it applies the staleness
    threshold and only shows blind/drift/parked/review when the values say so.
      archiver: {heartbeat_age, epoch_parked, blind_homes:[...]}  from archiver.status.json
      fork_drift: {home: [files...]}                              non-empty homes only
      seed_audit: {latest_ts, latest_linked_count, count}          newest seeding event
    """
    health = {}
    try:
        st = json.load(open(os.path.join(BANK_DIR, "archiver.status.json")))
        if isinstance(st, dict):
            homes = st.get("homes") if isinstance(st.get("homes"), dict) else {}
            blind, drift = [], {}
            for h, hd in homes.items():
                if not isinstance(hd, dict):
                    continue
                if hd.get("blind"):
                    blind.append(h)
                fk = hd.get("forked_shared_files")
                if isinstance(fk, list) and fk:
                    drift[h] = fk
            health["archiver"] = {
                "heartbeat_age": int(max(0, now() - float(st.get("ts", 0) or 0))),
                "epoch_parked": bool(st.get("epoch_parked")),
                "blind_homes": blind,
            }
            if drift:
                health["fork_drift"] = drift
    except Exception:
        pass
    try:
        latest_ts, latest_linked, count = 0, 0, 0
        with open(os.path.join(BANK_DIR, "seed-audit.jsonl")) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(e, dict):
                    continue
                count += 1
                ts = int(e.get("ts", 0) or 0)
                if ts >= latest_ts:
                    latest_ts = ts
                    linked = e.get("linked")
                    latest_linked = len(linked) if isinstance(linked, list) else 0
        if count:
            health["seed_audit"] = {"latest_ts": latest_ts,
                                    "latest_linked_count": latest_linked, "count": count}
    except Exception:
        pass
    return health


def main():
    global LOCKED, HOLD_LOCK, DEADLINE
    os.makedirs(BANK_DIR, exist_ok=True)

    # (#1) acquire the lock BEFORE reading identity/keychain/bank, so active vs
    # parked can't change under us. Lock failure -> read-only mode (no writes,
    # no refresh), still poll + print.
    HOLD_LOCK = acquire_lock(timeout=8)
    LOCKED = HOLD_LOCK
    DEADLINE = now() + TOTAL_DEADLINE
    deadline = DEADLINE
    try:
        # (#13) reconcile crash-recovery journals. An UNRESOLVED torn swap means the
        # keychain/metadata pairing is unknown — drop to READ-ONLY (no refresh, no
        # status/cache writes, no auto-ping) so we never mutate on inconsistent
        # state. We keep the lock (HOLD_LOCK) purely to release it.
        unresolved_swap = False
        if LOCKED and _reconcile is not None:
            try:
                _rr = _reconcile.reconcile_journals()
                unresolved_swap = bool(_rr.get("unresolved"))
            except Exception:
                # (re-review issue 3) reconciliation failure is mutation-BLOCKING,
                # never fail-open: go read-only for this run.
                unresolved_swap = True
        # Belt-and-suspenders: honor the durable unresolved marker even if the
        # reconcile module could not be imported.
        if os.path.exists(os.path.join(BANK_DIR, ".swap-unresolved")):
            unresolved_swap = True
        if unresolved_swap:
            LOCKED = False   # gate every mutation this run

        prev = load_cache()
        prev_by_key = {f"{a.get('provider')}|{a.get('email')}": a for a in prev.get("accounts", [])}
        # per-provider backoff (finding #31): a Codex outage must not suppress
        # Claude polling, and vice versa. Legacy single keys are read as the Claude
        # fallback for one cycle of back-compat.
        legacy_bo = float(prev.get("backoff_until", 0) or 0)
        legacy_fs = int(prev.get("fail_streak", 0) or 0)
        claude_bo = float(prev.get("claude_backoff_until", legacy_bo) or 0)
        codex_bo = float(prev.get("codex_backoff_until", 0) or 0)
        claude_fs = int(prev.get("claude_fail_streak", legacy_fs) or 0)
        codex_fs = int(prev.get("codex_fail_streak", 0) or 0)
        claude_backed_off = bool(claude_bo and now() < claude_bo)
        codex_backed_off = bool(codex_bo and now() < codex_bo)

        # (#26) STABLE identity snapshot: abort mutation if the active account is
        # moving under us.
        act, kc, identity_stable = _stable_identity()
        if not identity_stable:
            LOCKED = False   # do not attribute a moving keychain; read-only this run
        # (r8 #8) the DISPLAY-active account. Under EPOCH v2 it is the pointer target, not
        # the keychain identity (`act`). `act` is still used below for KEYCHAIN QUOTA
        # ATTRIBUTION (whose live credential is in the slot) — that is a separate question
        # from "which account do future sessions launch on". Only the active-FLAG and
        # active_email use disp_act, so a stale keychain leftover can no longer be shown
        # ACTIVE while the pointer names a different home. v1/shadow: disp_act == act.
        disp_act = _pointer_active_email() or act
        # (r5 #4) STABILITY is not IDENTITY. Bind the live keychain to a banked
        # account through the SINGLE fail-closed resolver: we may attribute the
        # keychain's quota to `act` and mark that account's bank status ok ONLY when
        # the live credential's fingerprint matches EXACTLY ONE current bank record
        # AND `act` names that same account. Every UNRESOLVED state — a keychain-first
        # /login holding another or an unbanked account, an ambiguous match, or the
        # active account's own token having drifted ahead of its bank record — must
        # NOT be attributed to `act` and must NOT mark its status ok. `kc` is the live
        # oauth dict (or None); resolve against the SAME bank dir usage.py polls.
        identity_resolved = bool(act and kc
                                 and bank_common.resolve_identity(BANK_DIR, kc, act) == act)

        # assemble claude accounts via the VALIDATED loader (finding #35): a
        # malformed bank record becomes an explicit, visible error entry — never a
        # silent disappearance that changes tier/auto-pick decisions.
        claude_accts = {}   # email -> (oauth, bank_path, status, oauth_account)
        invalid_entries = []
        for f in sorted(glob.glob(os.path.join(BANK_DIR, "*.json"))):
            # (r8 #3) BANK_DIR IS the v2 accounts/ control plane: once a home is seeded it
            # holds registry.json / sessions.json / archiver.status.json / attestation.json /
            # quotabar.runtime.json. `*.json` matches them (they are not dotfiles), and
            # load_bank_record would render each as a malformed "account" error card while
            # the real account is omitted. Skip the known control-plane files by basename.
            if os.path.basename(f) in _V2_CONTROL_JSON:
                continue
            br = bank_common.load_bank_record(f)
            if not br.ok:
                em = os.path.basename(f)[:-5]
                invalid_entries.append(bank_common.error_account_entry(em, br.reason))
                continue
            rec = br.record
            em = rec.get("email") or os.path.basename(f)[:-5]
            claude_accts[em] = (br.oauth or {}, f, br.status,
                                rec.get("oauthAccount") if isinstance(rec.get("oauthAccount"), dict) else {})
        if identity_resolved:
            bp = claude_accts.get(act, (None, None, "ok", None))[1]
            claude_accts[act] = (kc, bp, "ok", active_oauth_account())   # bound + verified live/ok
        elif kc:
            # (r5 #4) a live keychain is present but its identity is UNRESOLVED (or
            # metadata is missing): do NOT bind it to `act`'s bank record and do NOT
            # mark that record ok — that would attribute the keychain's real (possibly
            # different) account's quota to the wrong entry and could flip a stale
            # account to ok from another account's request. Surface it under a distinct,
            # NON-mutating key with bank_path=None so set_bank_status() is a no-op for
            # it. We deliberately do NOT drop to read-only here (unlike the unstable-
            # identity case): the keychain is STABLE, just unbound, so parked-account
            # refreshes (which use their OWN banked tokens, independent of the live
            # keychain) and the always-persist cache write (finding #32) stay enabled.
            claude_accts["(active/unresolved)"] = (kc, None, "ok", active_oauth_account())

        # (r11 #8) DISCOVER v2 READY homes from the registry. v2-seeded homes have no legacy
        # <email>.json, so the glob above misses them entirely — leaving each unmonitored and
        # absent from auto-pick's inputs. Read each READY home's OWN .credentials.json (the
        # authoritative per-home grant) for identity, plus <home>/.claude.json oauthAccount
        # for plan; bank_path=None (no legacy file to mutate). Registry WINS on conflict with
        # a legacy record — in v2 the home credential is the source of truth.
        try:
            import registry as _reg_mod
            _reg_map = _reg_mod.load(BANK_DIR)
        except Exception:
            _reg_map = {}
        V2_HOME_EMAILS.clear()   # (r13 #7) rebuild the monitor-only set fresh each run
        V2_HOME_PATHS.clear()
        for _em, _ent in (_reg_map.items() if isinstance(_reg_map, dict) else []):
            if not (isinstance(_ent, dict) and _ent.get("ready") is True):
                continue
            _home = _ent.get("home")
            if not (isinstance(_home, str) and os.path.isdir(_home)):
                continue
            # (seat) read the home's credential SEAT — file OR the migrated per-config-dir slot
            # — through the ONE shared implementation (seedflow.seat_read), replacing the earlier
            # tactical inline G5c slot fallback. Read-only here; the home CLI/archiver own rotation.
            try:
                import seedflow as _seedflow
                _sb, _sr, _sstatus, _skind = _seedflow.seat_read(_home)
                _hoauth = (_sb.get("claudeAiOauth") if (_sstatus == "present" and isinstance(_sb, dict)) else {})
                if not isinstance(_hoauth, dict):
                    _hoauth = {}
            except Exception:
                _hoauth = {}
            try:
                _hj = json.load(open(os.path.join(_home, ".claude.json")))
                _hoa = _hj.get("oauthAccount") if isinstance(_hj.get("oauthAccount"), dict) else {}
            except Exception:
                _hoa = {}
            # (shadow-day fix, 2026-07-23) registry wins on conflict — EXCEPT when this
            # account is ALSO the live ACTIVE keychain account under v1/shadow. The active
            # slot's token is continuously 401-refreshed by real sessions, while a parked
            # v2 home's seeded token expires overnight and is monitor-only by design —
            # letting the registry replace the active record made the ACTIVE card go
            # stale/error while a fresh credential sat in the keychain. Keychain wins for
            # the active account; the home stays registry-known for launch/repoint.
            if _em == active_email() and _em in claude_accts:
                continue
            claude_accts[_em] = (_hoauth, None, "ok", _hoa)   # registry wins on conflict
            V2_HOME_EMAILS.add(_em)                            # (r13 #7) monitor-only for refresh
            V2_HOME_PATHS[_em] = _home

        results = []
        claude_attempts = claude_real_fails = 0
        codex_attempts = codex_real_fails = 0

        # --- claude accounts, tiered polling ---
        for email, (oauth, bank_path, status, oauth_account) in claude_accts.items():
            is_active = (identity_resolved and email == act) or email == "(active/unresolved)"
            key = f"claude|{email}"
            reuse = prev_by_key.get(key)
            # (#33) ONLY mode: fresh-poll ONLY the target; EVERY other account is
            # served from cache or an explicit placeholder — never polled/refreshed
            # (so a one-account confirmation can't launch a 60-120s parked refresh).
            if ONLY and email != ONLY:
                if reuse:
                    r2 = dict(reuse); r2["active"] = is_active; results.append(r2)
                else:
                    results.append({"provider": "claude", "email": email, "active": is_active,
                                    "status": status, "error": "skipped (ONLY mode)",
                                    "worst_limit": None, "fetched_at": now(),
                                    "plan": _norm_plan((oauth_account or {}).get("organizationType"))
                                            or _norm_plan((oauth or {}).get("subscriptionType"))})
                continue
            # per-provider backoff: serve claude from cache without touching network
            if claude_backed_off and not _force_fresh(email):
                if reuse:
                    r2 = dict(reuse); r2["active"] = is_active; r2["stale_entry"] = True
                    results.append(r2)
                else:
                    results.append({"provider": "claude", "email": email, "active": is_active,
                                    "status": status, "error": "claude backoff (serving cache)",
                                    "worst_limit": None, "fetched_at": now()})
                continue
            # burst guard: even the active account reuses a <60s-old reading —
            # QuotaBar refreshes + hooks + manual runs must not trip endpoint 429s.
            if is_active and status == "ok" and reuse and not _force_fresh(email):
                age = now() - float(reuse.get("fetched_at", 0) or 0)
                cooloff = 120 if str(reuse.get("error", "")).startswith("HTTP 429") else 60
                if age < cooloff:
                    r2 = dict(reuse); r2["active"] = True; results.append(r2); continue
            if (not is_active) and status == "ok" and reuse and not reuse.get("error") and not _force_fresh(email):
                age = now() - float(reuse.get("fetched_at", 0) or 0)
                if age < PARKED_MAX_AGE:
                    r2 = dict(reuse); r2["active"] = False; results.append(r2); continue
            # (#16) total-run deadline: past it, reuse cache or emit a skip note
            if now() > deadline and not is_active:
                if reuse:
                    r2 = dict(reuse); r2["stale_entry"] = True; results.append(r2)
                else:
                    results.append({"provider": "claude", "email": email, "active": False,
                                    "error": "skipped (run deadline)", "fetched_at": now()})
                continue
            claude_attempts += 1
            try:
                r, netfail = process_claude(email, oauth, is_active, bank_path, status, oauth_account)
            except Exception as e:
                r, netfail = ({"provider": "claude", "email": email, "active": is_active,
                               "error": f"unhandled: {type(e).__name__}", "fetched_at": now()}, False)
            if _real_netfail(r):
                claude_real_fails += 1
            if netfail:
                good = prev_good(prev.get("accounts", []), "claude", email)
                if good:
                    good = dict(good); good["stale_entry"] = True
                    # (r5 #3) a quarantine / recovery path discovered THIS run must
                    # SURVIVE into the served entry — never let a healthy cached figure
                    # silently mask a rotated token stranded in quarantine. Carry the
                    # quarantine path forward and surface it as a distinct status +
                    # recovery hint (the cached figure still shows, but flagged).
                    if r.get("quarantine"):
                        good["quarantine"] = r["quarantine"]
                        good["status"] = "needs-recovery"
                        good["error"] = r.get("error")
                        good["recovery_hint"] = ("a rotated credential is preserved in "
                            "quarantine; recover it -> " + str(r.get("quarantine")))
                    results.append(good); continue
                # (r5 #3) no healthy cache to fall back on: surface THIS run's real
                # result (carrying any quarantine/error), never drop it silently.
            results.append(r)

        # --- codex (always polled, unless ONLY / past the deadline / backed off) ---
        if ONLY or codex_backed_off:
            good = prev_good(prev.get("accounts", []), "codex", None)
            if good:
                g = dict(good)
                if codex_backed_off:
                    g["stale_entry"] = True
                results.append(g)
        elif now() <= deadline:
            cx, cx_netfail = process_codex()
            if cx is not None:
                codex_attempts += 1
                if _real_netfail(cx):
                    codex_real_fails += 1
                if cx_netfail:
                    good = prev_good(prev.get("accounts", []), "codex", cx.get("email"))
                    if good:
                        good = dict(good); good["stale_entry"] = True
                        results.append(good)
                    else:
                        results.append(cx)
                else:
                    results.append(cx)
        else:
            good = prev_good(prev.get("accounts", []), "codex", None)
            if good:
                good = dict(good); good["stale_entry"] = True
                results.append(good)

        # surface invalid bank records as explicit, visible errors (finding #35)
        results.extend(invalid_entries)

        # normalize active flags: exactly the keychain account is active,
        # regardless of what any cached/stale entry claims
        for i, r in enumerate(results):
            if r.get("provider") == "claude":
                r2 = dict(r)
                # (r8 #8) active flag keys off the DISPLAY-active account (pointer under v2).
                r2["active"] = (r2.get("email") == disp_act) if disp_act else False
                results[i] = r2

        # UI contract for the synthetic unresolved entry (never render the sentinel
        # string raw): structured fields so the app can present a designed card —
        # metadata_email (the ~/.claude.json identity of the unbound login, best
        # effort) + unresolved flag. It IS the active account by construction; the
        # normalize loop above can never match its synthetic email (the r6 review's
        # constructed-active-then-normalized-inactive regression).
        _meta_email = (active_oauth_account() or {}).get("emailAddress", "") or ""
        for i, r in enumerate(results):
            if r.get("provider") == "claude" and r.get("email") == "(active/unresolved)":
                r2 = dict(r)
                # (r8 #8) the synthetic unresolved-keychain entry is "active" only when the
                # keychain IS the display-active rail (v1/shadow). Under v2 the pointer names
                # the active home, so an unresolved keychain leftover must not claim ACTIVE.
                r2["active"] = (disp_act == act)
                r2["unresolved"] = True
                r2["metadata_email"] = _meta_email
                results[i] = r2

        # (r12 #13) v2-home Ping-cooldown pass: stamp the live Ping cooldown on every v2
        # READY-home row, whether polled fresh or served from cache. Reading the marker here
        # (not in process_claude) keeps cooldown_until fresh on cache-reuse rows and
        # independent of process_claude's early returns. Absolute epoch seconds, so a value
        # riding a cached row on a later poll is still correct. monitor_only is NOT touched
        # here — process_claude owns it (and correctly leaves the shadow active-keychain
        # account out of V2_HOME_EMAILS, so an active row is never demoted to monitor-only).
        for i, r in enumerate(results):
            if r.get("provider") != "claude" or r.get("email") not in V2_HOME_EMAILS:
                continue
            home = V2_HOME_PATHS.get(r.get("email"))
            cu = _v2_ping_cooldown_until(home) if home else None
            r2 = dict(r)
            if cu is not None:
                r2["cooldown_until"] = cu
            else:
                r2.pop("cooldown_until", None)   # never carry a stale cooldown from cache
            results[i] = r2

        # auto-ping (only when we may mutate): fire detached pings for opted-in
        # accounts whose 5h window has lapsed. Non-blocking; debounced by cooldown.
        bank_paths = {em: bp for em, (_o, bp, _s, _oa) in claude_accts.items() if bp}
        try:
            fired = maybe_autoping(results, bank_paths)
        except Exception:
            fired = []

        # per-provider backoff accounting (finding #31): a provider backs off only
        # when EVERY one of ITS attempted live polls was a REAL network failure.
        if claude_attempts > 0 and claude_real_fails >= claude_attempts:
            claude_fs += 1
            if claude_fs >= BACKOFF_FAILS:
                claude_bo = now() + BACKOFF_SECS
        elif claude_attempts > 0:
            claude_fs = 0; claude_bo = 0
        if codex_attempts > 0 and codex_real_fails >= codex_attempts:
            codex_fs += 1
            if codex_fs >= BACKOFF_FAILS:
                codex_bo = now() + BACKOFF_SECS
        elif codex_attempts > 0:
            codex_fs = 0; codex_bo = 0

        stale_flag = (not identity_stable) or unresolved_swap \
            or (claude_backed_off and claude_attempts == 0)
        stale_reason = None
        if unresolved_swap:
            stale_reason = "unresolved torn swap; read-only until reconciled"
        elif not identity_stable:
            stale_reason = "active identity changed during poll; not attributed"
        elif claude_backed_off:
            stale_reason = f"claude backoff; retry after {epoch_to_iso(claude_bo)}"

        doc = {"generated_at": iso(), "active_email": disp_act, "accounts": results,
               "stale": stale_flag, "stale_reason": stale_reason,
               "fail_streak": claude_fs, "backoff_until": claude_bo,       # legacy = claude
               "claude_fail_streak": claude_fs, "claude_backoff_until": claude_bo,
               "codex_fail_streak": codex_fs, "codex_backoff_until": codex_bo,
               "autoping_fired": fired,
               # (v2 wiring) the single routing/health pipe for QuotaBar — see epoch_state()
               # and _health_surface(). Both fail-soft; `health` is {} when nothing is anomalous
               # or discoverable, so the app renders no health chrome in the healthy state.
               "epoch": epoch_state(), "health": _health_surface()}
        # (#32) ALWAYS persist the current validated document, including explicit
        # error/stale state — never leave an old healthy cache in place when this
        # run errored. write_cache no-ops in read-only mode (no lock / unstable).
        write_cache(doc)
        print(json.dumps(doc, indent=2))
    finally:
        if HOLD_LOCK:
            release_lock()


if __name__ == "__main__":
    main()
