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

CLAUDE_BIN = None

# creds:   the oauth dict to use going forward (new if valid+rotated, else old).
# rotated: True iff the CLI produced a NEW, schema-valid access token.
# cli_ok:  True iff a claude turn exited 0 (the turn actually ran and billed).
# err:     non-None reason string iff the CLI returned a CHANGED but malformed
#          blob — in which case we keep the OLD creds and refuse to commit.
RefreshResult = namedtuple("RefreshResult", "creds rotated cli_ok err")


def _valid_blob(o):
    """Full credential schema: accessToken/refreshToken non-empty strings and a
    numeric expiresAt (matches validate_blob.py / lib.sh kc_write, finding #7)."""
    return (isinstance(o, dict)
            and isinstance(o.get("accessToken"), str) and bool(o.get("accessToken"))
            and isinstance(o.get("refreshToken"), str) and bool(o.get("refreshToken"))
            and isinstance(o.get("expiresAt"), (int, float)))


def _claude_bin():
    global CLAUDE_BIN
    if CLAUDE_BIN:
        return CLAUDE_BIN
    # PATH may be minimal under SwiftBar/hooks; check the known install location too
    for cand in (_sh.which("claude"),
                 os.path.expanduser("~/.local/bin/claude"),
                 "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if cand and os.path.exists(cand):
            CLAUDE_BIN = cand
            return cand
    return "claude"


def refresh_via_config_dir(creds, email=None, model="haiku", timeout=60):
    """creds: the claudeAiOauth dict. Returns a RefreshResult.

    We only journal / return NEW creds when the CLI produced a schema-valid blob
    (finding #7); a changed-but-malformed readback keeps the OLD creds and reports
    err. cli_ok reflects whether a claude turn genuinely exited 0 (finding #8) —
    the caller needs this separately from token-expiry to avoid reporting a failed
    ping as a success."""
    old_at = creds.get("accessToken")
    cli_ok = False
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
            cmd = [_claude_bin(), "-p", "reply with just: ok"]
            if m:
                cmd += ["--model", m]
            try:
                # stdin=DEVNULL: claude -p reads the prompt from argv, but in a
                # non-tty context (SwiftBar/hook) an inherited stdin can hang it.
                r = subprocess.run(cmd, env=env, capture_output=True, text=True,
                                   timeout=timeout, stdin=subprocess.DEVNULL)
                if r.returncode == 0:
                    cli_ok = True
                    break
            except subprocess.TimeoutExpired:
                break  # creds may still have rotated before the hang; read back
            except Exception:
                pass
        try:
            new = json.load(open(credpath)).get("claudeAiOauth", creds)
        except Exception:
            new = creds
        changed = bool(new.get("accessToken")) and new.get("accessToken") != old_at
        if not _valid_blob(new):
            # A malformed readback must NEVER overwrite a good bank record. Keep
            # the old creds; surface an error only if the CLI *appeared* to rotate
            # (a changed but invalid blob is the dangerous case worth reporting).
            return RefreshResult(creds, False, cli_ok,
                                 "rotated blob failed schema validation" if changed else None)
        rotated = changed
        # crash-safety journal: persist rotated creds before we delete the tmpdir
        if rotated and email and _rec is not None:
            try:
                _rec.write_journal(email, new)
            except Exception:
                pass
        return RefreshResult(new, rotated, cli_ok, None)
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
    # A changed-but-malformed readback: keep the existing bank record untouched
    # and fail non-zero (finding #7). Exit 4 = generic ping failure (not a dead
    # token), so ping-account.sh reports failure without marking needs-relogin.
    if rr.err:
        print(f"ping FAILED ({rr.err}); keeping existing bank record", file=sys.stderr)
        sys.exit(4)
    now_ms = time.time() * 1000
    still_expired = (new.get("expiresAt") or 0) <= now_ms
    # A dead token (couldn't rotate and still expired) -> needs-relogin (exit 3).
    if not rotated and still_expired:
        print("refresh FAILED (token unchanged and still expired)", file=sys.stderr)
        sys.exit(3)
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
