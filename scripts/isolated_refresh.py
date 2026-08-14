#!/usr/bin/env python3
"""isolated_refresh.py — refresh a PARKED Claude account's tokens by letting the
Claude Code CLI itself do the OAuth refresh inside an isolated config dir.

Technique (verified 2026-07-19): Claude Code reads file-based credentials from
$CLAUDE_CONFIG_DIR/.credentials.json instead of the login keychain when
CLAUDE_CONFIG_DIR is set. We copy the parked account's creds into a throwaway
dir, run one minimal turn, and read the (possibly rotated) creds back out. The
login keychain is never touched — the active session is unaffected.

This is strictly for PARKED accounts. Refreshing rotates the token, which would
break a live session if applied to the active account.

Crash safety (finding #5): when the CLI rotates the token, we write the rotated
creds to a 0600 recovery journal BEFORE this function returns / cleans up. The
caller commits them to the bank file and then removes the journal. If anything
dies in between, reconcile.py recovers the journal on the next locked operation.

Importable: refresh_via_config_dir(creds, email=None) -> (new_creds, rotated)
CLI:        isolated_refresh.py <bankfile.json>   (rewrites the bank file in place)

stdlib only.
"""
import json, os, sys, tempfile, shutil, subprocess, time, signal, errno, shutil as _sh
from collections import namedtuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
try:
    import reconcile as _rec
except Exception:
    _rec = None

# Environment variables that could make the isolated "parked OAuth" turn bill a
# DIFFERENT account (or route elsewhere) than the one we think we're refreshing
# (finding #23). We build a minimal OAuth-only env by REMOVING these, plus the
# shell-injection vectors BASH_ENV/ENV/CDPATH (finding #48).
_STRIP_ENV = (
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_CUSTOM_HEADERS",
    "ANTHROPIC_DEFAULT_HEADERS", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_API_KEY_HELPER",
    "AWS_BEARER_TOKEN_BEDROCK", "CLOUD_ML_REGION", "GOOGLE_APPLICATION_CREDENTIALS",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
    "BASH_ENV", "ENV", "CDPATH",
)


def _oauth_only_env(config_dir):
    """A sanitized environment for the isolated refresh turn: the current env minus
    every alternate-auth / routing / proxy / shell-injection variable, with
    CLAUDE_CONFIG_DIR pointed at the throwaway profile so the CLI reads its
    file-based OAuth creds (finding #23)."""
    env = {k: v for k, v in os.environ.items() if k not in _STRIP_ENV}
    env["CLAUDE_CONFIG_DIR"] = config_dir
    return env


def _run_group_bounded(cmd, env, timeout):
    """Run cmd in its OWN process group and enforce `timeout` by killing the WHOLE
    group (finding #22): subprocess.run's timeout kills only the immediate child,
    orphaning a `claude` turn's descendants that may still rotate credentials after
    the reported timeout. Returns (returncode, stdout, stderr, timed_out)."""
    p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         stdin=subprocess.DEVNULL, text=True, start_new_session=True)
    # Capture the process-group id ONCE, immediately after Popen (re-review issue
    # 5). start_new_session makes the child its own group leader, so pgid == pid
    # right now. We must NOT re-resolve it after signalling: once the leader exits,
    # os.getpgid(pid) raises or (worse) could resolve a reused PID's group.
    try:
        pgid = os.getpgid(p.pid)
    except Exception:
        pgid = None
    try:
        out, errout = p.communicate(timeout=timeout)
        return p.returncode, out, errout, False
    except subprocess.TimeoutExpired:
        # kill the entire process group using the IMMUTABLE pgid captured above
        if pgid is not None:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(pgid, sig)
                except Exception:
                    pass
                if sig is signal.SIGTERM:
                    time.sleep(0.3)
        else:
            try: p.kill()
            except Exception: pass
        try:
            out, errout = p.communicate(timeout=5)
        except Exception:
            out, errout = "", ""
        return (p.returncode if p.returncode is not None else 124), out, errout, True

# creds:      the oauth dict to use going forward (new if valid+rotated, else old).
# rotated:    True iff the CLI produced a NEW, schema-valid access token.
# cli_ok:     True iff a claude turn exited 0 (the turn actually ran and billed).
# err:        non-None reason string iff the CLI returned a CHANGED but malformed
#             blob — in which case we keep the OLD creds and refuse to commit.
# auth_failed: True ONLY when a claude turn actually RAN and was rejected with an
#             authentication/OAuth signature (see AUTH_FAIL_SIGNATURES). This is
#             the *sole* refresh-side trigger for marking a token dead
#             (needs-relogin). Never set for resolver/launch/timeout/network/
#             non-auth-nonzero failures — those are transient and stay retriable
#             (finding #1).
# reason:     structured outcome tag: "ok" | "auth_rejected" | "resolver_error" |
#             "launch_error" | "timeout" | "nonzero" | "malformed" |
#             "readback_torn" (r3 #6) | "became_active" | "became_active_after"
#             (r3 #5). Lets callers surface a distinct transient error without
#             conflating it with death.
# quarantine: (r3 #6/#7) absolute path of a PRESERVED throwaway config dir whenever
#             there is ANY doubt the rotation was captured/journaled — the caller
#             must NOT treat the run as clean and must not delete it until the
#             rotation is durably committed elsewhere. None in the normal case.
RefreshResult = namedtuple("RefreshResult", "creds rotated cli_ok err auth_failed reason quarantine")
RefreshResult.__new__.__defaults__ = (None,)   # quarantine defaults to None

# A parked turn's output matching any of these (case-insensitive) means the server
# genuinely rejected the OAuth credentials — the ONLY confirmed-revocation signal.
# The confirmed real-death signature observed in the wild is
# "Failed to authenticate: OAuth session expired and could not be refreshed".
#
# Precision (finding #24): these are STRUCTURED auth signatures only. Bare "401"/
# "403" were REMOVED — an ambiguous 403 (WAF, org policy, model/endpoint scope) or
# a 401 from an unrelated proxy is NOT proof the OAuth token is dead, and marking a
# live parked account needs-relogin on that basis is the exact false-death we must
# avoid (findings #1/#37). Transient failures report network/timeout, not these.
# STRUCTURED auth-death signatures only (re-review issue 12). These are specific,
# near-complete phrases — NOT loose substrings like "oauth token" or "could not be
# refreshed", which also occur inside ambiguous messages such as
# "403 ... OAuth token not permitted for this model" (an org/scope 403 that is
# TRANSIENT, not a dead credential). The confirmed real-death message is
# "Failed to authenticate: OAuth session expired and could not be refreshed".
AUTH_FAIL_SIGNATURES = (
    "failed to authenticate",
    "oauth session expired and could not be refreshed",
    "invalid_grant",
    "invalid_token",
    "invalid refresh token",
    "refresh token has expired",
    "refresh token expired",
    "token has been revoked",
    "token is revoked",
)
# If ANY of these appears, the failure is TRANSIENT and NEVER a dead-token verdict,
# even if an auth phrase also matched (issue 12): a 403 / forbidden / not-permitted
# / rate-limit / network / timeout response is ambiguous, not credential death.
AUTH_TRANSIENT_MARKERS = (
    "403", "forbidden", "not permitted", "not allowed", "429",
    "rate limit", "rate-limit", "overloaded", "timeout", "timed out",
    "network", "connection", "temporarily",
)


def _is_auth_death(text):
    """True ONLY when the output carries a structured OAuth-rejection signature AND
    no transient/ambiguous marker (issue 12)."""
    low = (text or "").lower()
    if any(m in low for m in AUTH_TRANSIENT_MARKERS):
        return False
    return any(sig in low for sig in AUTH_FAIL_SIGNATURES)


def _valid_blob(o):
    """THE shared credential validator (re-review issue 6): delegates to
    bank_common.valid_oauth so shell and Python agree — accessToken/refreshToken
    non-empty strings and a numeric-but-NOT-boolean expiresAt."""
    return bank_common.valid_oauth(o)


def resolve_claude_bin():
    """Unified resolver contract (findings #3/#4/#5), mirrored by lib.sh claude_bin:
      - honor ACCOUNT_BANK_CLAUDE_BIN, but only if it is an actually-executable file;
      - else PATH lookup, then the known install locations;
      - every candidate must be a real, executable regular file (rejects aliases /
        function descriptions / non-executable matches);
      - NO login-shell fallback (it can hang unbounded on a slow profile and can
        return contaminated stdout) — ~/.local/bin + homebrew cover this machine.
    Returns an absolute path, or "" when unresolved. An unresolved binary is a
    TRANSIENT failure for the caller, never a dead token."""
    # (r10 #6) the resolver must return the REAL binary, never the v2 PATH shim. During
    # seeding the shim rejects the unregistered staging home (exit 65), so `which("claude")`
    # hitting accounts/bin/claude breaks /login + verification. Mirror bin/claude: prefer the
    # recorded REAL_CLAUDE_BIN, then PATH / known locations, with EVERY candidate excluded if
    # it resides under accounts/bin or is dev/inode-identical to the shim.
    acc = os.environ.get("ACCOUNT_BANK_DIR", os.path.expanduser("~/.claude/accounts"))
    override = os.environ.get("ACCOUNT_BANK_CLAUDE_BIN")
    if override:
        # (r12 #9) the shim-path/inode rejection applies to the OVERRIDE too. Setting
        # ACCOUNT_BANK_CLAUDE_BIN=accounts/bin/claude previously selected the shim, which
        # rejects the unregistered staging home during seeding and strands the transaction
        # at LOGIN_STARTED. Reject a shim override (return "" = transient-unresolved), never
        # silently hand it back.
        if os.path.isfile(override) and os.access(override, os.X_OK) and not _is_shim_path(override, acc):
            return override
        return ""
    try:
        _cfg = json.load(open(os.path.join(acc, ".config.json")))
        _rb = _cfg.get("REAL_CLAUDE_BIN") if isinstance(_cfg, dict) else None
        if _rb and os.path.isfile(_rb) and os.access(_rb, os.X_OK) and not _is_shim_path(_rb, acc):
            return _rb
    except Exception:
        pass
    c = _sh.which("claude")
    if c and os.path.isfile(c) and os.access(c, os.X_OK) and not _is_shim_path(c, acc):
        return c
    for cand in (os.path.expanduser("~/.local/bin/claude"),
                 "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK) and not _is_shim_path(cand, acc):
            return cand
    return ""


def _is_shim_path(path, accounts_dir):
    """(r10 #6) True if `path` is the v2 launch shim — resides under accounts/bin, or is
    dev/inode-identical to accounts/bin/claude. Fail-closed (treat as shim) if unstattable,
    so a candidate we cannot verify is never handed back as the 'real' binary."""
    try:
        rp = os.path.realpath(path)
    except OSError:
        return True
    binroot = os.path.realpath(os.path.join(accounts_dir, "bin"))
    if rp == binroot or rp.startswith(binroot + os.sep):
        return True
    shim = os.path.join(accounts_dir, "bin", "claude")
    try:
        if os.path.exists(shim):
            ss, cs = os.stat(os.path.realpath(shim)), os.stat(rp)
            if (ss.st_dev, ss.st_ino) == (cs.st_dev, cs.st_ino):
                return True
    except OSError:
        pass
    return False


def _active_email_from(claude_json):
    try:
        return (json.load(open(claude_json)).get("oauthAccount") or {}).get("emailAddress", "") or ""
    except Exception:
        return ""


def _fsync_file(path):
    """fsync a file's contents to disk. Raises OSError on failure."""
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _fsync_dir(path):
    """fsync a directory so its entries (a freshly-created file / subdir) are
    durable. Raises OSError on failure."""
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _quarantine_cfgdir(d, bank_dir, email, why):
    """(r3 #6/#7) Preserve a throwaway config dir (which holds .credentials.json,
    the possibly-rotated readback) instead of deleting it, whenever there is ANY
    doubt the rotation was captured or durably recorded.

    (r4 #4) NEVER returns None while the data still exists — a failed quarantine
    must not fall through to deletion. Preference order:
      1. atomic os.rename into bank_dir (fast, same-filesystem);
      2. on EXDEV (cross-filesystem), copytree into bank_dir, verify, then remove
         the original (keep BOTH if the copy is incomplete — never lose data);
      3. on any other failure, LEAVE the original dir `d` in place and return IT,
         reporting the path loudly. The caller then preserves (does not delete) it.
    """
    safe = bank_common.safe_email(email) if email else None
    tag = safe if safe else "anon"
    base = bank_dir if bank_dir and os.path.isdir(bank_dir) else os.path.dirname(d)
    q = os.path.join(base, f".refresh-quarantine-{tag}-{int(time.time())}-{os.getpid()}")
    try:
        os.rename(d, q)
    except OSError as e:
        moved = False
        if getattr(e, "errno", None) == errno.EXDEV:
            # cross-filesystem: copy the tree, then make BOTH the copied credential
            # file AND the destination directory DURABLE (fsync) before deleting the
            # source. (r5 #2) The old code checked only that the copied file EXISTED,
            # then deleted the source — a power loss after an un-fsync'd copy could
            # leave the copy's bytes unwritten AND the source gone, losing the freshly
            # rotated refresh token entirely. Now we fsync the file, its dir, and the
            # parent, and delete the source ONLY if all fsyncs succeed; otherwise we
            # keep BOTH copies and report both paths.
            try:
                shutil.copytree(d, q)
                qcred = os.path.join(q, ".credentials.json")
                if os.path.isdir(q) and os.path.exists(qcred):
                    durable = False
                    try:
                        _fsync_file(qcred)
                        _fsync_dir(q)
                        _fsync_dir(os.path.dirname(q) or ".")
                        durable = True
                    except OSError:
                        durable = False
                    if durable:
                        shutil.rmtree(d, ignore_errors=True)
                        moved = True
                    else:
                        # (r5 #2) copy landed but is NOT provably durable: do NOT delete
                        # the source. Preserve BOTH and report both paths so the rotated
                        # token is recoverable from either.
                        try: os.chmod(d, 0o700)
                        except OSError: pass
                        try: os.chmod(q, 0o700)
                        except OSError: pass
                        sys.stderr.write(
                            f"isolated_refresh: EXDEV copy could not be durably fsync'd "
                            f"({why}); kept BOTH copies (recover from either) -> "
                            f"source {d} | copy {q}\n")
                        return d
                else:
                    shutil.rmtree(q, ignore_errors=True)   # partial copy: discard it
            except Exception:
                shutil.rmtree(q, ignore_errors=True)       # partial copy: discard it
                moved = False
        if not moved:
            # (r4 #4) Could NOT relocate. DO NOT delete the original — leave it in
            # place and report it loudly so the rotated token stays recoverable.
            try: os.chmod(d, 0o700)
            except OSError: pass
            sys.stderr.write(
                f"isolated_refresh: could NOT quarantine into the bank ({why}); recovery "
                f"copy LEFT IN PLACE (do not delete) -> {d}\n")
            return d
    try: os.chmod(q, 0o700)
    except OSError: pass
    sys.stderr.write(f"isolated_refresh: QUARANTINED config dir ({why}) -> {os.path.basename(q)}\n")
    return q


def refresh_via_config_dir(creds, email=None, model="haiku", timeout=60, claude_json=None, bank_dir=None):
    """creds: the claudeAiOauth dict. Returns a RefreshResult.

    We only journal / return NEW creds when the CLI produced a schema-valid blob
    (finding #7); a changed-but-malformed readback keeps the OLD creds and reports
    err. cli_ok reflects whether a claude turn genuinely exited 0 (finding #8) —
    the caller needs this separately from token-expiry to avoid reporting a failed
    ping as a success. auth_failed/reason let the caller distinguish a CONFIRMED
    auth rejection (mark dead) from a transient failure (retry later, finding #1).

    active-guard (finding #27): if `claude_json` is given and, right before we run
    the turn, that account is the LIVE ACTIVE account, we ABORT without rotating.
    Refreshing rotates the token server-side, which would spend the refresh token
    the live session's keychain still holds — bricking the active session. Only
    parked accounts may be refreshed."""
    old_at = creds.get("accessToken")
    cli_ok = False
    # (#27) never rotate an account that is (now) the active one.
    if claude_json and email and _active_email_from(claude_json) == email:
        return RefreshResult(creds, False, False, None, False, "became_active")
    # (#3/#4/#5) resolve the binary up front. Unresolved => transient, not death.
    cbin = resolve_claude_bin()
    if not cbin:
        return RefreshResult(creds, False, False, None, False, "resolver_error")
    stderr_accum = ""      # accumulated across attempts; inspected only if !cli_ok
    launch_error = False   # subprocess could not start (FileNotFound / OSError)
    timed_out = False      # a turn was killed by the timeout
    d = tempfile.mkdtemp(prefix="acctbank-cfg-")
    os.chmod(d, 0o700)
    preserved = False   # (r3 #6/#7) set when we quarantine d instead of deleting it
    seat_slot_service = None   # (v110) set when the readback came from the per-dir SLOT
    try:
        credpath = os.path.join(d, ".credentials.json")
        fd = os.open(credpath, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"claudeAiOauth": creds}, f)
        env = _oauth_only_env(d)   # sanitized OAuth-only env (findings #23/#48)
        # minimal turn; try requested model, fall back to default on failure
        for m in ([model] if model else []) + [None]:
            cmd = [cbin, "-p", "reply with just: ok"]
            if m:
                cmd += ["--model", m]
            # classify from THIS attempt's output only, so a benign first-attempt
            # message can't poison a different second-attempt failure (finding #24).
            last_out = ""
            try:
                # own process group + whole-group timeout kill (finding #22).
                rc, out, errout, to = _run_group_bounded(cmd, env, timeout)
                # BOTH streams: the claude CLI prints the auth-failure message
                # ("Failed to authenticate: OAuth session expired and could not be
                # refreshed") to STDOUT, not stderr — stderr alone misclassified a
                # dead token as transient "nonzero" (bug 2026-07-21).
                last_out = (errout or "") + "\n" + (out or "")
                stderr_accum = last_out   # keep only the latest attempt's output
                if to:
                    timed_out = True
                    break
                if rc == 0:
                    cli_ok = True
                    break
            except (FileNotFoundError, PermissionError, OSError):
                launch_error = True
                break
            except Exception:
                launch_error = True
                break
        # Read back BEFORE cleanup so a rotation that landed just before a
        # timeout-kill is still captured + journaled (finding #22 defense-in-depth).
        #
        # (r3 #6) FAIL-CLOSED on a torn/unreadable readback. The old code turned any
        # read/parse failure into `new = creds` (unchanged), so a server-side
        # rotation followed by a torn credential-file write silently discarded the
        # replacement token and then deleted the temp dir — permanent loss. Now: if
        # the credentials file cannot be read/parsed, or does not carry an oauth
        # object, we CANNOT know whether a rotation landed. Quarantine the config
        # dir (preserving whatever bytes exist) and return a distinct error; the
        # caller exits nonzero without committing or deleting anything.
        # (r4 #3) DELETE the temp dir ONLY when the readback is PROVABLY safe:
        # either (a) a schema-valid credential IDENTICAL to what we banked (bank
        # already holds it — nothing to lose) or (b) a schema-valid ROTATION that we
        # durably preserve/journal below. EVERYTHING ELSE — an unreadable/torn file,
        # an empty dict, a missing/non-dict claudeAiOauth, or a changed-but-malformed
        # blob — leaves us unable to prove whether a real rotation landed, so we
        # QUARANTINE (preserve) and fail loud. The old code mapped {} / missing-oauth
        # to `new = creds` (silently "unchanged, ok") and a changed-but-invalid blob
        # to reason="malformed" WITHOUT preserving it, then let `finally` delete the
        # dir in all three cases — potentially destroying the rotated refresh token.
        readback_failed = False
        try:
            raw_new = json.load(open(credpath))
        except FileNotFoundError:
            # (v110, live 2026-08-14 on CLI 2.1.232) Claude Code >= 2.1.228 treats a config
            # dir's FILE credential as a migration source: it moves it into the per-config-dir
            # keychain slot and deletes the file (the G5c behavior, previously seen only on
            # pinned homes). A missing file after the turn is therefore the seat MOVING, not
            # a torn write — read the slot before declaring the readback torn. The service
            # name hashes the literal path string, so try both spellings of the temp dir.
            raw_new = None
            try:
                import seedflow as _sf
                for _p in dict.fromkeys((os.path.abspath(d), os.path.realpath(d))):
                    _svc = _sf.config_slot_service(_p)
                    _blob, _sraw, _st = _sf._sh_keychain_read(service=_svc)
                    if _st == "present" and isinstance(_blob, dict):
                        raw_new = _blob
                        seat_slot_service = _svc
                        # travels with the dir if quarantined — names where the only
                        # copy of a rotated credential may live (service name, no secret)
                        try:
                            with open(os.path.join(d, ".seat-slot-service"), "w") as _mf:
                                _mf.write(_svc + "\n")
                        except Exception:
                            pass
                        break
            except Exception:
                raw_new = None
            if raw_new is None:
                readback_failed = True
        except Exception:
            readback_failed = True
            raw_new = None
        if readback_failed:
            q = _quarantine_cfgdir(d, bank_dir, email, "credentials readback torn/unreadable")
            preserved = q is not None
            return RefreshResult(creds, False, cli_ok,
                                 "credentials readback torn/unreadable after turn",
                                 False, "readback_torn", q)

        new = raw_new.get("claudeAiOauth") if isinstance(raw_new, dict) else None
        # (v110) a BLANKED slot — parseable blob, empty accessToken AND refreshToken — is the
        # new CLI's cleared-login stamp (observed live 2026-08-14: three blanked orphan slots
        # from one poll's refresh turns, byte-shape identical to a dead pinned home's seat).
        # There is provably NO credential here to preserve (the tokens are empty strings and
        # the predecessor is still in the bank), so quarantining would only accumulate noise.
        # With a confirmed auth signature in the turn's output this is a DEAD token; without
        # one it stays a distinct transient (bank untouched, retriable) — fail-closed on the
        # verdict, exactly the v105.1 doctrine.
        if (seat_slot_service and isinstance(new, dict)
                and not str(new.get("accessToken") or "").strip()
                and not str(new.get("refreshToken") or "").strip()):
            if _is_auth_death(stderr_accum):
                return RefreshResult(creds, False, cli_ok, None, True, "auth_rejected")
            return RefreshResult(creds, False, cli_ok,
                                 "seat blanked by the CLI without a confirmed auth rejection",
                                 False, "seat_blanked", None)
        if not isinstance(new, dict) or not _valid_blob(new):
            # Torn/empty/missing/malformed readback. We wrote {"claudeAiOauth": creds}
            # and did NOT read back a schema-valid oauth object — a rotation may or
            # may not have landed. Preserve, never delete, fail loud (r4 #3).
            q = _quarantine_cfgdir(d, bank_dir, email, "credentials readback invalid/missing oauth")
            preserved = q is not None
            return RefreshResult(creds, False, cli_ok,
                                 "credentials readback invalid or missing oauth after turn",
                                 False, "readback_torn", q)

        # `new` is now a schema-valid oauth blob. (r3 #15) a ROTATION requires the
        # CREDENTIAL fields to change, not merely any field: same_credentials
        # compares the credential fingerprint only (accessToken/refreshToken/
        # expiresAt/refreshTokenExpiresAt), so a plan-only readback delta is not a
        # rotation and does not override a genuine auth failure below.
        rotated_valid = not bank_common.same_credentials(new, creds)

        if rotated_valid:
            # (r3 #5) BECAME-ACTIVE re-check AFTER the turn. The preflight guard is
            # a point-in-time check; a /login could have activated this parked
            # account DURING the turn. If it is now the active account and we just
            # rotated its token, the live keychain still holds the spent predecessor
            # — committing/journaling silently as "parked" would hide that the live
            # session is now broken. Preserve the rotated creds durably (quarantine)
            # and report a distinct became_active_after so the caller fails loud.
            if claude_json and email and _active_email_from(claude_json) == email:
                q = _quarantine_cfgdir(d, bank_dir, email,
                                       "account became active during rotation")
                preserved = q is not None
                return RefreshResult(new, True, cli_ok,
                                     "account became active during rotation",
                                     False, "became_active_after", q)
            # A live, schema-valid rotation trumps any output noise: the token
            # clearly works, so this is never a death even if the turn exited
            # nonzero for an unrelated reason. Durably journal the rotated creds
            # BEFORE returning (finding #20): reconcile.write_journal fsyncs the
            # file + its directory, so the replacement token survives a crash
            # between here and the caller's bank commit.
            #
            # (r3 #7) FAIL-CLOSED on a journal-write failure. The old code only
            # WARNED and always deleted the temp dir, so a crash before the caller's
            # synchronous commit left the bank on a SPENT refresh token with no
            # recovery record. Now: if journaling fails, PRESERVE the config dir as
            # a quarantine (durable recovery material) and flag it on the result so
            # the caller exits nonzero (distinct code) rather than reporting success.
            # (r4 #5) An UNAVAILABLE journal subsystem == journal FAILED, never a
            # silent success. The old code guarded on `_rec is not None` and, when
            # reconcile failed to import (_rec is None) or no email was known, simply
            # SKIPPED journaling and returned "ok" — a valid rotation with NO crash
            # recovery record. Now every reason the journal can't be written durably
            # (import failure, missing identity, or a write exception) sets
            # journal_failed and preserves the rotated creds as a quarantine.
            journal_failed = False
            if not email:
                journal_failed = True
                sys.stderr.write("isolated_refresh: no email for the rotated-token journal; "
                                 "preserving recovery copy (fail-closed).\n")
            elif _rec is None:
                journal_failed = True
                sys.stderr.write("isolated_refresh: reconcile/journal subsystem unavailable; "
                                 "preserving rotated token (fail-closed).\n")
            else:
                try:
                    _rec.write_journal(email, new)
                except Exception:
                    journal_failed = True
                    sys.stderr.write("isolated_refresh: rotated-token journal write FAILED; "
                                     "preserving recovery copy (fail-closed).\n")
            if journal_failed:
                q = _quarantine_cfgdir(d, bank_dir, email, "rotated-token journal unavailable/failed")
                preserved = q is not None
                return RefreshResult(new, True, cli_ok,
                                     "rotated-token journal unavailable or failed",
                                     False, "journal_failed", q)
            return RefreshResult(new, True, cli_ok, None, False, "ok")

        # No rotation. Classify the outcome so the caller can tell a confirmed
        # auth rejection (dead) from a transient failure (retry).
        if cli_ok:
            # Turn ran fine and the token did not need rotating — healthy.
            return RefreshResult(new, False, True, None, False, "ok")
        if _is_auth_death(stderr_accum):
            return RefreshResult(new, False, False, None, True, "auth_rejected")
        if timed_out:
            return RefreshResult(new, False, False, None, False, "timeout")
        if launch_error:
            return RefreshResult(new, False, False, None, False, "launch_error")
        return RefreshResult(new, False, False, None, False, "nonzero")
    finally:
        # (r3 #6/#7) never delete a config dir we deliberately quarantined.
        if not preserved:
            shutil.rmtree(d, ignore_errors=True)
            # (v110) the CLI minted a per-dir keychain slot for this now-deleted temp dir;
            # once the readback is harvested (banked/journaled by the caller's path) the
            # slot is garbage that would otherwise accumulate one orphan per refresh turn
            # (184 observed 2026-08-14). Best-effort; a survivor is only an orphan.
            # Quarantined dirs KEEP their slot — it may hold the only rotated credential —
            # and carry its service name in .seat-slot-service.
            if seat_slot_service:
                try:
                    import seedflow as _sf
                    _sf._sh_keychain_delete(seat_slot_service)
                except Exception:
                    pass


def _cli():
    """CLI: refresh the parked account in <bankfile>, rewriting it in place.

    Locking (finding #25): a direct invocation MUST hold the shared bank lock, or
    it can rotate a target after a concurrent swap loaded the old bank blob (swap
    would then install a spent token). We acquire the lock here UNLESS the caller
    already holds it (ACCOUNT_BANK_HOLDS_LOCK=1 — ping-account.sh sets this because
    it calls us while holding the lock)."""
    bankfile = sys.argv[1]
    bank_dir = os.environ.get("BANK_DIR", os.path.dirname(os.path.abspath(bankfile)))
    # (r3 #8) ALIGN the journal/recovery bank dir with the bank dir we actually
    # lock. reconcile captured its BANK_DIR at import time from $BANK_DIR / the
    # default location; a direct CLI invocation against a bankfile in a DIFFERENT
    # directory (no exported BANK_DIR) would otherwise lock dir A but write the
    # recovery journal into dir B, losing crash recovery and possibly merging the
    # credential into an unrelated same-email record in the default bank. Point
    # reconcile at the locked dir so lock, journal, and journal-removal all agree.
    if _rec is not None:
        _rec.BANK_DIR = bank_dir
        _rec.SWAP_JOURNAL = os.path.join(bank_dir, ".swap-journal.json")
        _rec.SWAP_UNRESOLVED = os.path.join(bank_dir, ".swap-unresolved")
    import banklock
    # (r12 #11) honor HOLDS_LOCK only when ownership is PROVEN (token match); else self-acquire,
    # so a caller that lies about holding the lock can never rotate a credential lock-free.
    held = (os.environ.get("ACCOUNT_BANK_HOLDS_LOCK") == "1"
            and banklock.verify_caller_holds(bank_dir))
    _lk = None
    if not held:
        _lk = banklock.BankLock(bank_dir)
        if not _lk.acquire(timeout=int(os.environ.get("ACCOUNT_BANK_LOCK_WAIT", "10") or "10")):
            print("isolated_refresh: could not acquire bank lock; aborting.", file=sys.stderr)
            sys.exit(6)   # transient: contention, token untouched
    try:
        _cli_locked(bankfile, bank_dir)
    finally:
        if _lk is not None:
            _lk.release()


def _cli_locked(bankfile, bank_dir=None):
    # validated load (finding #35 class): a malformed bank record becomes a clear
    # error, never a silent skip or partial overwrite.
    br = bank_common.load_bank_record(bankfile)
    if not br.ok:
        print(f"isolated_refresh: bank record invalid ({br.reason}); refusing to refresh",
              file=sys.stderr)
        sys.exit(2)
    rec = br.record
    email = rec.get("email")
    creds = rec.get("claudeAiOauth", {})
    if bank_dir is None:
        bank_dir = os.environ.get("BANK_DIR", os.path.dirname(os.path.abspath(bankfile)))
    # (finding 24) gate BEFORE launching claude / rotating the v1 refresh grant. In v2
    # the refresh must never fire — discovering the epoch only at bank commit (exit 78)
    # would have already spent the predecessor refresh token, stranding the bank on it.
    import epoch as _epoch_mod
    try:
        _epoch_mod.v1_gate(bank_dir)
        _ir_snap = _epoch_mod.read_epoch(bank_dir)   # (r2 finding 24) exact snapshot
    except Exception as _eg:
        print(f"isolated_refresh: epoch gate refused BEFORE refresh ({_eg}); "
              "not launching, bank UNCHANGED", file=sys.stderr)
        sys.exit(78)
    claude_json = os.environ.get("CLAUDE_JSON", os.path.join(os.path.expanduser("~"), ".claude.json"))
    rr = refresh_via_config_dir(creds, email=email, claude_json=claude_json, bank_dir=bank_dir)
    new, rotated = rr.creds, rr.rotated
    # Exit-code contract (only exit 3 makes ping-account.sh mark needs-relogin):
    #   3 = CONFIRMED dead token (auth rejection OR refresh-token provably expired)
    #   4 = changed-but-malformed readback (finding #7; record left untouched)
    #   5 = turn did not confirm the 5h window (finding #8; token may be alive) —
    #       NOTE: if a valid rotation happened it is ALREADY committed before this.
    #   6 = TRANSIENT refresh failure (resolver/launch/timeout/non-auth nonzero) —
    #       token unchanged, retry next cycle, DO NOT mark dead (finding #1)
    #   7 = (r3 #6) readback torn/unreadable: cannot tell if a rotation landed. The
    #       config dir is QUARANTINED (recovery material); bank left untouched.
    #   8 = (r3 #5) the account BECAME ACTIVE during rotation: the rotated token is
    #       quarantined, the bank is NOT written as parked; the live session may be
    #       on a spent token — a loud, distinct signal for operator/keychain sync.

    # (r3 #6) torn readback: do NOT commit; the quarantine holds whatever landed.
    if rr.reason == "readback_torn":
        print(f"ping FAILED ({rr.err}); config dir quarantined"
              + (f" at {os.path.basename(rr.quarantine)}" if rr.quarantine else "")
              + "; bank record untouched", file=sys.stderr)
        sys.exit(7)

    # (r3 #5) became active mid-rotation: fail loud, keep quarantine, do NOT commit.
    if rr.reason == "became_active_after":
        print(f"ping FAILED ({rr.err}); the parked account became ACTIVE during the "
              "rotation. Rotated creds quarantined"
              + (f" at {os.path.basename(rr.quarantine)}" if rr.quarantine else "")
              + "; NOT written to the bank as parked. The live session may hold a "
              "spent token — re-login if the active session breaks.", file=sys.stderr)
        sys.exit(8)

    if rr.err and rr.reason != "journal_failed":
        print(f"ping FAILED ({rr.err}); keeping existing bank record", file=sys.stderr)
        sys.exit(4)

    def _drop_quarantine():
        # (r3 #7) once the rotation is durably committed to the bank, the quarantine
        # recovery copy is redundant — remove it so it does not accumulate.
        if rr.quarantine and os.path.isdir(rr.quarantine):
            try: shutil.rmtree(rr.quarantine, ignore_errors=True)
            except Exception: pass

    def _commit(creds_obj):
        # (v2 rev6 §8 + r2 finding 24) v1 bank-credential commit: current-state gate
        # AND the EXACT generation fence against the snapshot captured pre-refresh, so a
        # flip that landed during the (slow) refresh is caught before the bank write.
        try:
            _epoch_mod.v1_gate(bank_dir)
            _epoch_mod.fence(bank_dir, _ir_snap, ("v1", "shadow"))
        except Exception as _eg:
            print(f"isolated_refresh: epoch gate/fence refused the commit ({_eg}); "
                  "bank record UNCHANGED", file=sys.stderr)
            sys.exit(78)
        rec["claudeAiOauth"] = creds_obj
        rec["status"] = "ok"
        rec["last_verified"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        dirn = os.path.dirname(bankfile) or "."
        fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f, indent=2)
            f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, bankfile)
        dfd = os.open(dirn, os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
        if _rec is not None and email:
            try: os.remove(_rec.journal_path(email))
            except OSError: pass

    now_ms = time.time() * 1000

    # (re-review issue 9) COMMIT any VALID rotation IMMEDIATELY — before the
    # cli_ok / window gate — so a rotated refresh token is never discarded just
    # because the turn happened to exit nonzero. The rotated token is live proof
    # the credential works.
    if rotated and _valid_blob(new):
        _commit(new)
        # (r3 #7) the rotation is now durably in the bank; a journal-failure
        # quarantine copy is no longer needed for recovery.
        _drop_quarantine()
        if rr.reason == "journal_failed":
            print("WARNING: rotated-token journal write had failed; the rotation is "
                  "now durably committed to the bank and the quarantine copy removed.",
                  file=sys.stderr)
        if not rr.cli_ok:
            # creds safely persisted, but the 5h window was not confirmed: report
            # a ping-failure exit so no success cooldown is stamped.
            print("rotated creds committed, but claude turn did not exit 0 "
                  "(5h window not confirmed)", file=sys.stderr)
            sys.exit(5)
        print("rotated", file=sys.stderr)
        sys.exit(0)

    # No valid rotation past this point.
    rexp = creds.get("refreshTokenExpiresAt")
    refresh_tok_expired = isinstance(rexp, (int, float)) and not isinstance(rexp, bool) and rexp <= now_ms
    if rr.auth_failed or refresh_tok_expired:
        why = "auth rejected by server" if rr.auth_failed else "refresh token expired"
        print(f"refresh FAILED (confirmed dead token: {why})", file=sys.stderr)
        sys.exit(3)
    still_expired = (new.get("expiresAt") or 0) <= now_ms
    if still_expired:
        # token unchanged & still expired, not auth-dead -> transient, retriable.
        print(f"refresh deferred (transient: {rr.reason}); token unchanged, will retry",
              file=sys.stderr)
        sys.exit(6)
    if not rr.cli_ok:
        print("ping FAILED (claude CLI did not exit 0; 5h window not confirmed)", file=sys.stderr)
        sys.exit(5)
    # healthy: token alive, turn ran, no rotation needed — refresh last_verified.
    _commit(new)
    print("refreshed-not-rotated", file=sys.stderr)


if __name__ == "__main__":
    _cli()
