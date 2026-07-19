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
try:
    import isolated_refresh
except Exception:
    isolated_refresh = None
try:
    import reconcile as _reconcile
except Exception:
    _reconcile = None

LOCKED = False          # True only while we hold the bank lock; gates all writes
TOTAL_DEADLINE = float(os.environ.get("ACCOUNT_BANK_TOTAL_DEADLINE", "45"))
LOCK_STALE_SECS = 300

HOME = os.path.expanduser("~")
_XDG_DATA = os.environ.get("XDG_DATA_HOME", os.path.join(HOME, ".local", "share"))
BANK_DIR = os.environ.get("BANK_DIR", os.path.join(_XDG_DATA, "quotabar"))
CLAUDE_JSON = os.environ.get("CLAUDE_JSON", os.path.join(HOME, ".claude.json"))
CACHE_FILE = os.path.join(BANK_DIR, ".usage-cache.json")
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


# ---------- lock (token-owned; matches lib.sh protocol) ----------
_LOCK_TOKEN = None


def acquire_lock(timeout=10):
    """Token-owned mkdir lock. release_lock() only removes it if we still own it;
    stale reclaim requires age>5min AND holder pid dead, via rename-away."""
    global _LOCK_TOKEN
    os.makedirs(BANK_DIR, exist_ok=True)
    owner = os.path.join(LOCK_DIR, "owner")
    tok = f"{os.getpid()}-{os.urandom(8).hex()}"
    waited = 0
    while True:
        try:
            os.mkdir(LOCK_DIR)
            fd, tmp = tempfile.mkstemp(dir=LOCK_DIR, prefix=".own.")
            with os.fdopen(fd, "w") as f:
                f.write(f"{os.getpid()} {tok}")
            os.replace(tmp, owner)
            _LOCK_TOKEN = tok
            return True
        except FileExistsError:
            try:
                age = time.time() - os.path.getmtime(LOCK_DIR)
            except OSError:
                age = 0
            opid = None
            try:
                opid = int(open(owner).read().split()[0])
            except Exception:
                opid = None
            dead = True
            if opid is not None:
                try:
                    os.kill(opid, 0); dead = False
                except ProcessLookupError:
                    dead = True
                except PermissionError:
                    dead = False
            if age > LOCK_STALE_SECS and dead:
                stolen = f"{LOCK_DIR}.stale.{os.getpid()}.{os.urandom(4).hex()}"
                try:
                    os.rename(LOCK_DIR, stolen)
                    import shutil as _sh2; _sh2.rmtree(stolen, ignore_errors=True)
                    continue
                except OSError:
                    pass
            if waited >= timeout:
                return False
            time.sleep(1); waited += 1


def release_lock():
    global _LOCK_TOKEN
    if not _LOCK_TOKEN:
        return
    owner = os.path.join(LOCK_DIR, "owner")
    try:
        cur = open(owner).read().split()
        cur_tok = cur[1] if len(cur) > 1 else None
    except Exception:
        cur_tok = None
    if cur_tok == _LOCK_TOKEN:
        import shutil as _sh2
        _sh2.rmtree(LOCK_DIR, ignore_errors=True)
        _LOCK_TOKEN = None


# ---------- sources ----------
def read_keychain_blob():
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
                              "-a", KEYCHAIN_ACCOUNT, "-w"],
                             capture_output=True, text=True, timeout=5)
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
    five_hour = {"utilization": fh.get("utilization"), "resets_at": fh.get("resets_at")}
    seven_day = {"utilization": sd.get("utilization"), "resets_at": sd.get("resets_at")}
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
    # model_cap: the highest model-scoped weekly limit (e.g. Fable/Opus), exposed
    # as its own field so the card shows it CONSISTENTLY regardless of whether it
    # is the current worst — its label carries a "(Model)" suffix from _limit_label.
    scoped = [c for c in cands if c["kind"] not in ("five_hour", "seven_day")]
    model_cap = max(scoped, key=lambda c: c["percent"]) if scoped else None
    return five_hour, seven_day, worst, model_cap


def poll_claude(token):
    return http_json_retry(USAGE_URL, {"Authorization": f"Bearer {token}", "anthropic-beta": OAUTH_BETA})


# ---------- bank status write ----------
def set_bank_status(bank_path, status):
    if not LOCKED:      # read-only mode: never write bank state without the lock
        return
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
def process_claude(email, oauth, is_active, bank_path, status):
    res = {"provider": "claude", "email": email, "active": is_active,
           "five_hour": None, "seven_day": None, "worst_limit": None, "model_cap": None,
           "status": status, "fetched_at": now(),
           "plan": (oauth or {}).get("subscriptionType")}  # max|pro, drives auto-pick
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
        if not LOCKED:      # never refresh/rotate without the lock
            res["error"] = "parked token expired; refresh skipped (no lock)"
            return res, False
        if not REFRESH_ENABLED or isolated_refresh is None:
            res["error"] = "parked token expired; refresh disabled"
            return res, False
        rexp = oauth.get("refreshTokenExpiresAt")
        if rexp is not None and rexp <= now_ms():
            set_bank_status(bank_path, "needs-relogin")
            res["status"] = "needs-relogin"; res["error"] = "needs-relogin"
            return res, False
        try:
            # email -> refresh writes a crash-recovery journal before cleanup.
            # For polling we only care about getting a valid, non-expired token;
            # cli_ok (turn success) is irrelevant here.
            rr = isolated_refresh.refresh_via_config_dir(oauth, email=email)
            new, rotated = rr.creds, rr.rotated
            if rr.err:
                # changed-but-malformed readback: keep the old record, skip this
                # poll rather than commit a partial blob (finding #7).
                res["error"] = f"refresh invalid: {rr.err}"
                return res, False
            still_expired = (new.get("expiresAt") or 0) <= now_ms()
            if not rotated and still_expired:
                set_bank_status(bank_path, "needs-relogin")
                res["status"] = "needs-relogin"; res["error"] = "needs-relogin"
                return res, False
            if bank_path and os.path.exists(bank_path):
                rec = json.load(open(bank_path))
                if isinstance(rec, dict):
                    rec["claudeAiOauth"] = new; rec["status"] = "ok"; rec["last_verified"] = iso()
                    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(bank_path), prefix=".acct.")
                    with os.fdopen(fd, "w") as f: json.dump(rec, f, indent=2)
                    os.chmod(tmp, 0o600); os.replace(tmp, bank_path)
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
        if e.code in (401, 403) and not is_active:
            set_bank_status(bank_path, "needs-relogin")
            res["status"] = "needs-relogin"; res["error"] = "needs-relogin"
            return res, False
        res["error"] = f"HTTP {e.code}"
        # 429/5xx are transient: report as netfail so the caller serves the
        # cached last-good entry (stale_entry) instead of a blank card
        return res, e.code == 429 or e.code >= 500
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
                subprocess.run(["codex", "exec", "reply ok", "--skip-git-repo-check"],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
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
    """Fire ping-account.sh fully DETACHED (own session, output to a 0600 log),
    so the poll never blocks on it. The ping takes the bank lock itself."""
    try:
        if os.path.exists(AUTOPING_LOG) and os.path.getsize(AUTOPING_LOG) > 50 * 1024:
            open(AUTOPING_LOG, "w").close()
    except OSError:
        pass
    try:
        lf = open(AUTOPING_LOG, "a")
        os.chmod(AUTOPING_LOG, 0o600)
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ping-account.sh")
        lf.write(f"[{iso()}] auto-ping firing for {email}\n"); lf.flush()
        subprocess.Popen(["bash", script, email], stdin=subprocess.DEVNULL,
                         stdout=lf, stderr=lf, start_new_session=True, close_fds=True)
    except Exception:
        pass


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
    if not chosen_r.get("active") and _stagger_hold(email, results, bp):
        if not AUTOPING_DRYRUN:
            _mark_stagger_hold(bp)
        return ["stagger-hold:" + email]
    if AUTOPING_DRYRUN:
        return [email + " (dry-run)"]
    _clear_stagger_hold(bp)   # firing -> clear any prior hold marker
    _spawn_autoping(email)
    return [email]


def main():
    global LOCKED
    os.makedirs(BANK_DIR, exist_ok=True)

    # (#1) acquire the lock BEFORE reading identity/keychain/bank, so active vs
    # parked can't change under us. Lock failure -> read-only mode (no writes,
    # no refresh), still poll + print.
    LOCKED = acquire_lock(timeout=8)
    deadline = now() + TOTAL_DEADLINE
    try:
        if LOCKED and _reconcile is not None:
            try: _reconcile.reconcile_journals()
            except Exception: pass

        prev = load_cache()
        prev_by_key = {f"{a.get('provider')}|{a.get('email')}": a for a in prev.get("accounts", [])}
        fail_streak = int(prev.get("fail_streak", 0) or 0)
        backoff_until = float(prev.get("backoff_until", 0) or 0)

        # backoff window: serve stale without touching the network
        if backoff_until and now() < backoff_until and prev.get("accounts"):
            serve_stale(prev, f"backoff active ({fail_streak} consecutive failures); "
                              f"retrying after {epoch_to_iso(backoff_until)}", fail_streak, backoff_until)
            return

        act = active_email()
        kc = read_keychain_blob()

        # assemble claude accounts: bank files + active keychain (live token wins)
        claude_accts = {}   # email -> (oauth, bank_path, status)
        for f in sorted(glob.glob(os.path.join(BANK_DIR, "*.json"))):
            try:
                rec = json.load(open(f))
                if not isinstance(rec, dict):   # (#18) skip non-object bank files
                    continue
            except Exception:
                continue
            em = rec.get("email") or os.path.basename(f)[:-5]
            oauth = rec.get("claudeAiOauth")
            claude_accts[em] = (oauth if isinstance(oauth, dict) else {}, f,
                                rec.get("status", "ok"))
        if act and kc:
            bp = claude_accts.get(act, (None, None, "ok"))[1]
            claude_accts[act] = (kc, bp, "ok")   # active is always live/ok
        elif kc and not act:
            claude_accts["(active/unknown)"] = (kc, None, "ok")

        results = []
        net_failures = 0
        attempted = 0

        # --- claude accounts, tiered polling ---
        for email, (oauth, bank_path, status) in claude_accts.items():
            is_active = (email == act) or email == "(active/unknown)"
            key = f"claude|{email}"
            reuse = prev_by_key.get(key)
            # burst guard: even the active account reuses a <60s-old reading —
            # QuotaBar refreshes + hooks + manual runs must not trip endpoint 429s.
            # Error entries count too (a 429 must cool down, not be re-hit).
            if ONLY and email != ONLY and reuse:
                r2 = dict(reuse); r2["active"] = is_active; results.append(r2); continue
            if is_active and status == "ok" and reuse and not _force_fresh(email):
                age = now() - float(reuse.get("fetched_at", 0) or 0)
                cooloff = 120 if str(reuse.get("error", "")).startswith("HTTP 429") else 60
                if age < cooloff:
                    r2 = dict(reuse)
                    r2["active"] = True
                    results.append(r2)
                    continue
            if (not is_active) and status == "ok" and reuse and not reuse.get("error") and not _force_fresh(email):
                age = now() - float(reuse.get("fetched_at", 0) or 0)
                if age < PARKED_MAX_AGE:
                    r2 = dict(reuse)
                    r2["active"] = False   # never trust a cached active flag
                    results.append(r2)     # fresh enough; skip the poll
                    continue
            # (#16) total-run deadline: past it, reuse cache or emit a skip note
            if now() > deadline and not is_active:
                if reuse:
                    r2 = dict(reuse); r2["stale_entry"] = True
                    results.append(r2)
                else:
                    results.append({"provider": "claude", "email": email, "active": False,
                                    "error": "skipped (run deadline)", "fetched_at": now()})
                continue
            attempted += 1
            try:
                r, netfail = process_claude(email, oauth, is_active, bank_path, status)
            except Exception as e:
                r, netfail = ({"provider": "claude", "email": email, "active": is_active,
                               "error": f"unhandled: {type(e).__name__}", "fetched_at": now()}, False)
            if netfail:
                net_failures += 1
                good = prev_good(prev.get("accounts", []), "claude", email)
                if good:
                    good = dict(good); good["stale_entry"] = True
                    results.append(good); continue
            results.append(r)

        # --- codex (always polled, unless past the deadline) ---
        if ONLY:
            good = prev_good(prev.get("accounts", []), "codex", None)
            if good:
                results.append(dict(good))
            cx = None
        elif now() <= deadline:
            cx, cx_netfail = process_codex()
            if cx is not None:
                attempted += 1
                if cx_netfail:
                    net_failures += 1
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

        # normalize active flags: exactly the keychain account is active,
        # regardless of what any cached/stale entry claims
        for i, r in enumerate(results):
            if r.get("provider") == "claude":
                r2 = dict(r)
                r2["active"] = (r2.get("email") == act) if act else False
                results[i] = r2

        # auto-ping (still under the lock): fire detached pings for opted-in
        # accounts whose 5h window has lapsed. Non-blocking; debounced by cooldown.
        bank_paths = {em: bp for em, (_o, bp, _s) in claude_accts.items() if bp}
        try:
            fired = maybe_autoping(results, bank_paths)
        except Exception:
            fired = []

        # backoff accounting (still under the lock): a run where every attempted
        # live poll hit the network counts toward backoff.
        total_network_failure = attempted > 0 and net_failures >= attempted
        if total_network_failure:
            fail_streak += 1
            if fail_streak >= BACKOFF_FAILS:
                backoff_until = now() + BACKOFF_SECS
            if prev.get("accounts"):
                reason = "live poll failed (network); showing last-good cache"
                serve_stale(prev, reason, fail_streak, backoff_until)
                # Persist the stale flag/reason INTO the cache, not just to stdout
                # (finding #3). The write refreshes cache mtime, so a consumer that
                # keys freshness off mtime (account-warn.sh) would otherwise treat
                # a failed poll as fresh and auto-swap on it. With stale=True in the
                # cache, autopick + the hook's defense both refuse to swap.
                p = dict(prev)
                p["stale"] = True
                p["stale_reason"] = reason
                p["fail_streak"] = fail_streak
                p["backoff_until"] = backoff_until
                write_cache(p)
                return
        else:
            fail_streak = 0
            backoff_until = 0

        doc = {"generated_at": iso(), "active_email": act, "accounts": results,
               "stale": False, "fail_streak": fail_streak, "backoff_until": backoff_until,
               "autoping_fired": fired}
        if any(r.get("worst_limit") for r in results):
            write_cache(doc)
        print(json.dumps(doc, indent=2))
    finally:
        if LOCKED:
            release_lock()


if __name__ == "__main__":
    main()
