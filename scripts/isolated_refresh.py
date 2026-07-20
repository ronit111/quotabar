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
import json, os, sys, tempfile, shutil, subprocess, time, shutil as _sh
from collections import namedtuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import reconcile as _rec
except Exception:
    _rec = None

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
#             "launch_error" | "timeout" | "nonzero" | "malformed". Lets callers
#             surface a distinct transient error without conflating it with death.
RefreshResult = namedtuple("RefreshResult", "creds rotated cli_ok err auth_failed reason")

# A parked turn's stderr matching any of these (case-insensitive) means the server
# genuinely rejected the credentials — the ONLY confirmed-revocation signal. The
# confirmed real-death signature observed in the wild is
# "Failed to authenticate: OAuth session expired and could not be refreshed".
# Kept deliberately auth-specific so a transient/network/launch failure is never
# misread as revocation (finding #1). A bare 401/403 in a claude turn's stderr is
# an auth status; transient failures report "network"/timeout, not 401/403.
AUTH_FAIL_SIGNATURES = (
    "failed to authenticate",
    "oauth session expired",
    "could not be refreshed",
    "invalid_grant",
    "invalid_token",
    "401",
    "403",
)


def _valid_blob(o):
    """Full credential schema: accessToken/refreshToken non-empty strings and a
    numeric expiresAt (matches validate_blob.py / lib.sh kc_write, finding #7)."""
    return (isinstance(o, dict)
            and isinstance(o.get("accessToken"), str) and bool(o.get("accessToken"))
            and isinstance(o.get("refreshToken"), str) and bool(o.get("refreshToken"))
            and isinstance(o.get("expiresAt"), (int, float)))


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
    override = os.environ.get("ACCOUNT_BANK_CLAUDE_BIN")
    if override:
        return override if (os.path.isfile(override) and os.access(override, os.X_OK)) else ""
    c = _sh.which("claude")
    if c and os.path.isfile(c) and os.access(c, os.X_OK):
        return c
    for cand in (os.path.expanduser("~/.local/bin/claude"),
                 "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return ""


def refresh_via_config_dir(creds, email=None, model="haiku", timeout=60):
    """creds: the claudeAiOauth dict. Returns a RefreshResult.

    We only journal / return NEW creds when the CLI produced a schema-valid blob
    (finding #7); a changed-but-malformed readback keeps the OLD creds and reports
    err. cli_ok reflects whether a claude turn genuinely exited 0 (finding #8) —
    the caller needs this separately from token-expiry to avoid reporting a failed
    ping as a success. auth_failed/reason let the caller distinguish a CONFIRMED
    auth rejection (mark dead) from a transient failure (retry later, finding #1)."""
    old_at = creds.get("accessToken")
    cli_ok = False
    # (#3/#4/#5) resolve the binary up front. Unresolved => transient, not death.
    cbin = resolve_claude_bin()
    if not cbin:
        return RefreshResult(creds, False, False, None, False, "resolver_error")
    stderr_accum = ""      # accumulated across attempts; inspected only if !cli_ok
    launch_error = False   # subprocess could not start (FileNotFound / OSError)
    timed_out = False      # a turn was killed by the timeout
    d = tempfile.mkdtemp(prefix="acctbank-cfg-")
    os.chmod(d, 0o700)
    try:
        credpath = os.path.join(d, ".credentials.json")
        fd = os.open(credpath, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"claudeAiOauth": creds}, f)
        env = dict(os.environ, CLAUDE_CONFIG_DIR=d)
        # minimal turn; try requested model, fall back to default on failure
        for m in ([model] if model else []) + [None]:
            cmd = [cbin, "-p", "reply with just: ok"]
            if m:
                cmd += ["--model", m]
            try:
                # stdin=DEVNULL: claude -p reads the prompt from argv, but in a
                # non-tty context (GUI app/hook) an inherited stdin can hang it.
                # start_new_session (finding #2): the child leads its own process
                # group, so a timeout-kill isolates it from us and grandchildren
                # are orphaned rather than left attached to the caller.
                r = subprocess.run(cmd, env=env, capture_output=True, text=True,
                                   timeout=timeout, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
                stderr_accum += (r.stderr or "")
                if r.returncode == 0:
                    cli_ok = True
                    break
            except subprocess.TimeoutExpired as e:
                # creds may still have rotated before the hang; read back below.
                timed_out = True
                partial = getattr(e, "stderr", None)
                if partial:
                    stderr_accum += partial if isinstance(partial, str) else partial.decode("utf-8", "replace")
                break
            except (FileNotFoundError, PermissionError, OSError):
                launch_error = True
                break
            except Exception:
                launch_error = True
                break
        # Read back BEFORE cleanup so a rotation that landed just before a
        # timeout-kill is still captured + journaled (finding #2 defense-in-depth).
        try:
            new = json.load(open(credpath)).get("claudeAiOauth", creds)
        except Exception:
            new = creds
        changed = bool(new.get("accessToken")) and new.get("accessToken") != old_at
        rotated_valid = changed and _valid_blob(new)

        if not _valid_blob(new):
            # A malformed readback must NEVER overwrite a good bank record. Keep
            # the old creds; surface an error only if the CLI *appeared* to rotate
            # (a changed but invalid blob is the dangerous case worth reporting).
            return RefreshResult(creds, False, cli_ok,
                                 "rotated blob failed schema validation" if changed else None,
                                 False, "malformed" if changed else "nonzero")

        if rotated_valid:
            # A live, schema-valid rotation trumps any stderr noise: the token
            # clearly works, so this is never a death even if the turn exited
            # nonzero for an unrelated reason.
            if email and _rec is not None:
                try:
                    _rec.write_journal(email, new)
                except Exception:
                    pass
            return RefreshResult(new, True, cli_ok, None, False, "ok")

        # No rotation. Classify the outcome so the caller can tell a confirmed
        # auth rejection (dead) from a transient failure (retry).
        if cli_ok:
            # Turn ran fine and the token did not need rotating — healthy.
            return RefreshResult(new, False, True, None, False, "ok")
        low = stderr_accum.lower()
        if any(sig in low for sig in AUTH_FAIL_SIGNATURES):
            return RefreshResult(new, False, False, None, True, "auth_rejected")
        if timed_out:
            return RefreshResult(new, False, False, None, False, "timeout")
        if launch_error:
            return RefreshResult(new, False, False, None, False, "launch_error")
        return RefreshResult(new, False, False, None, False, "nonzero")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _cli():
    """CLI: refresh the parked account in <bankfile>, rewrite it under no lock
    (caller must hold the lock). Prints rotated/failed to stderr."""
    bankfile = sys.argv[1]
    rec = json.load(open(bankfile))
    if not isinstance(rec, dict):
        print("bank file is not an object", file=sys.stderr); sys.exit(2)
    email = rec.get("email")
    creds = rec.get("claudeAiOauth", {})
    rr = refresh_via_config_dir(creds, email=email)
    new, rotated = rr.creds, rr.rotated
    # Exit-code contract (only exit 3 makes ping-account.sh mark needs-relogin):
    #   3 = CONFIRMED dead token (auth rejection OR refresh-token provably expired)
    #   4 = changed-but-malformed readback (finding #7; record left untouched)
    #   5 = turn did not confirm the 5h window (finding #8; token may be alive)
    #   6 = TRANSIENT refresh failure (resolver/launch/timeout/non-auth nonzero) —
    #       token unchanged, retry next cycle, DO NOT mark dead (finding #1)
    # A changed-but-malformed readback: keep the existing bank record untouched.
    if rr.err:
        print(f"ping FAILED ({rr.err}); keeping existing bank record", file=sys.stderr)
        sys.exit(4)
    now_ms = time.time() * 1000
    still_expired = (new.get("expiresAt") or 0) <= now_ms
    rexp = creds.get("refreshTokenExpiresAt")
    refresh_tok_expired = isinstance(rexp, (int, float)) and rexp <= now_ms
    # CONFIRMED death only: the server rejected the credentials (auth_failed) or
    # the refresh token is provably past its expiry. Nothing else is death.
    if rr.auth_failed or refresh_tok_expired:
        why = "auth rejected by server" if rr.auth_failed else "refresh token expired"
        print(f"refresh FAILED (confirmed dead token: {why})", file=sys.stderr)
        sys.exit(3)
    # Transient failure, token unchanged and still expired: keep the account
    # retriable rather than marking it dead (finding #1).
    if not rotated and still_expired:
        print(f"refresh deferred (transient: {rr.reason}); token unchanged, will retry",
              file=sys.stderr)
        sys.exit(6)
    # The turn must have genuinely run (finding #8). If the CLI never exited 0,
    # the window was NOT started even though the token may be alive/rotated — do
    # not report a ping success. Exit 5 = turn failed (distinct from dead token).
    if not rr.cli_ok:
        print("ping FAILED (claude CLI did not exit 0; 5h window not confirmed)", file=sys.stderr)
        sys.exit(5)
    rec["claudeAiOauth"] = new
    rec["status"] = "ok"
    rec["last_verified"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    dirn = os.path.dirname(bankfile) or "."
    fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, bankfile)
    # bank committed -> journal (if any) is now redundant; drop it
    if _rec is not None and email:
        try: os.remove(_rec.journal_path(email))
        except OSError: pass
    print("rotated" if rotated else "refreshed-not-rotated", file=sys.stderr)


if __name__ == "__main__":
    _cli()
