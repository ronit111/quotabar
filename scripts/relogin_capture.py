#!/usr/bin/env python3
"""relogin_capture.py — the credential-side half of `relogin-account.sh`.

The shell orchestrator opens a Terminal running `CLAUDE_CONFIG_DIR=<dir> claude` and the
owner completes the browser OAuth. Everything that has to reason about the credential
itself lives here, because the seat abstraction and the identity oracle are Python:

  watch <config_dir> <email> <timeout_s>
      Poll the throwaway config dir's SEAT until the credential the login produced
      appears, prove it belongs to <email> via the G9 oracle, and materialize it as the
      dir's `.credentials.json` so `bank-account.sh` (whose cred_read follows
      CLAUDE_CONFIG_DIR for the FILE form only) can bank it.
  cleanup <config_dir>
      Delete the throwaway dir AND every per-config-dir keychain slot its path spellings
      could have produced.
  clear-breaker <bank_dir> <email>
      Clear the auto-ping circuit breaker (`needs_login_since` / `ping_fail_streak`) for
      the account's home and bank record, and re-arm the revocation notification.

Doctrine this file must not weaken:
  * A seat read of status "error" means UNKNOWN (locked/headless keychain). It is NEVER
    a negative verdict — the watcher keeps waiting and, at timeout, reports "unknown",
    not "no credential".
  * Identity is proven POSITIVELY before anything is banked. INVALID (the server
    rejected it) and INDETERMINATE (offline/timeout/WAF) are both refusals; only
    RESOLVED-and-equal proceeds. If the owner picked the wrong account in the browser we
    abort and clean up rather than banking a mismatched credential.
  * Raw credential material is never printed, logged, or put in an error string.

Exit codes (watch): 0 captured · 4 timeout · 5 identity mismatch/rejected (CONFIRMED,
the owner picked the wrong account) · 6 transient (identity unconfirmed, unreadable
seat, malformed capture) · 2 usage.
"""
import json
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import seedflow                                   # noqa: E402  (seat abstraction)

try:
    import identity as _identity                  # noqa: E402  (G9 oracle)
except Exception:
    _identity = None

POLL_S = 3
IDENTITY_TIMEOUT_S = 15
IDENTITY_RETRIES = 3            # INDETERMINATE is not a verdict — retry inside budget
METADATA_GRACE_S = 45           # how long to wait for the CLI to write .claude.json


# ---------- capture -----------------------------------------------------------

def _oauth_of(blob):
    """The OAuth sub-object of a seat blob, tolerating both shapes the CLI has used."""
    if not isinstance(blob, dict):
        return None
    inner = blob.get("claudeAiOauth")
    if isinstance(inner, dict):
        return inner
    if "accessToken" in blob or "refreshToken" in blob:
        return blob
    return None


def _usable(oauth):
    """A credential with BOTH tokens empty is the CLI's cleared-login stamp (v109), not a
    credential — the login has not completed yet."""
    if not isinstance(oauth, dict):
        return False
    return bool((oauth.get("accessToken") or "").strip()
                or (oauth.get("refreshToken") or "").strip())


def _metadata_email(config_dir):
    try:
        d = json.load(open(os.path.join(config_dir, ".claude.json")))
        acct = d.get("oauthAccount") or {}
        em = acct.get("emailAddress")
        return em if isinstance(em, str) else ""
    except Exception:
        return ""


def _resolve(token, budget):
    """One G9 lookup.

    `ACCOUNT_BANK_FAKE_PROFILE="<VERDICT> [email]"` is the hermetic-test seam — the same
    posture as ACCOUNT_BANK_FAKE_KEYCHAIN elsewhere in this tree — so the suite can drive
    every branch of the identity gate (RESOLVED-and-equal, RESOLVED-but-different,
    INVALID, INDETERMINATE) without a network call or a real credential. It is unset in
    every real run; when it is unset this is a plain call into identity.py."""
    fake = os.environ.get("ACCOUNT_BANK_FAKE_PROFILE")
    if fake:
        parts = fake.split()
        cls = getattr(_identity, "IdentityResult", None)
        verdict = parts[0] if parts else "INDETERMINATE"
        em = parts[1] if len(parts) > 1 else ""
        if cls is None:
            return type("R", (), {"verdict": verdict, "email": em, "detail": "fake"})()
        return cls(verdict, "fake-uuid", em, "", "fake")
    return _identity.resolve(token, timeout=budget)


def _verify_identity(token, email, deadline):
    """(verdict, reason) where verdict is "ok" (positively proven to be `email`),
    "confirmed-bad" (the account is provably not `email`, or the server rejected the
    credential — a real, actionable answer) or "transient" (we could not find out;
    never an accusation)."""
    if _identity is None and not os.environ.get("ACCOUNT_BANK_FAKE_PROFILE"):
        return "transient", "identity oracle unavailable"
    last = "identity unconfirmed"
    for attempt in range(IDENTITY_RETRIES):
        budget = min(IDENTITY_TIMEOUT_S, max(1.0, deadline - time.time()))
        r = _resolve(token, budget)
        if r.verdict == "RESOLVED":
            if r.email == email:
                return "ok", ""
            return "confirmed-bad", "the browser login was %s, not %s" % (r.email, email)
        if r.verdict == "INVALID":
            return "confirmed-bad", "the server rejected the captured credential (%s)" % r.detail
        last = "identity unconfirmed (%s)" % r.detail
        if attempt + 1 < IDENTITY_RETRIES and time.time() + 5 < deadline:
            time.sleep(5)
    return "transient", last


def _materialize(config_dir, raw):
    """Write the captured blob as the dir's `.credentials.json` (0600, atomic) so the
    shell's cred_read finds it. No-op-safe when the seat already IS that file."""
    dest = os.path.join(config_dir, ".credentials.json")
    fd, tmp = tempfile.mkstemp(dir=config_dir, prefix=".cred.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise
    # verify by re-reading — a materialization we cannot read back is not a capture
    with open(dest) as f:
        return f.read().strip() == raw.strip()


def cmd_watch(config_dir, email, timeout_s):
    deadline = time.time() + timeout_s
    saw_error = False
    blob = raw = None
    while time.time() < deadline:
        b, r, status, _kind = seedflow.seat_read(config_dir)
        if status == "error":
            saw_error = True            # UNKNOWN, never a verdict — keep waiting
        elif status == "present":
            oauth = _oauth_of(b)
            if _usable(oauth) and r:
                blob, raw = b, r
                break
            # a blanked or unparseable blob means the login has not landed yet
        time.sleep(POLL_S)

    if raw is None:
        if saw_error:
            print("unknown: the credential seat could not be read (keychain locked?)")
            return 6
        print("timeout: no credential appeared in the login window")
        return 4

    oauth = _oauth_of(blob)
    token = (oauth or {}).get("accessToken") or ""
    if not token:
        # refresh-only blob: nothing to prove identity with, and banking an
        # unverifiable credential is exactly what fact 4 forbids.
        print("transient: captured credential has no access token to verify")
        return 6

    verdict, why = _verify_identity(
        token, email, time.time() + IDENTITY_TIMEOUT_S * IDENTITY_RETRIES + 10)
    if verdict == "confirmed-bad":
        print("mismatch: " + why)
        return 5
    if verdict != "ok":
        print("transient: " + why)
        return 6

    meta_deadline = time.time() + METADATA_GRACE_S
    meta = _metadata_email(config_dir)
    while not meta and time.time() < meta_deadline:
        time.sleep(POLL_S)
        meta = _metadata_email(config_dir)
    if meta != email:
        print("transient: the login's own metadata names %r, not %s"
              % (meta or "(nothing yet)", email))
        return 6

    try:
        if not _materialize(config_dir, raw):
            print("transient: the captured credential did not read back intact")
            return 6
    except Exception as e:
        print("transient: could not materialize the captured credential (%s)"
              % type(e).__name__)
        return 6
    print("captured: %s verified by the profile oracle" % email)
    return 0


# ---------- cleanup -----------------------------------------------------------

def _slot_services(config_dir):
    """Every per-config-dir slot service name this dir could have produced. The CLI
    derives the service from the CLAUDE_CONFIG_DIR string it was handed, so a path that
    differs only by a trailing slash or an unresolved symlink is a DIFFERENT slot — all
    the spellings have to be swept or a live credential is left behind in the keychain."""
    spellings = set()
    for p in (config_dir, config_dir.rstrip("/")):
        if not p:
            continue
        spellings.add(p)
        spellings.add(p + "/")
        try:
            rp = os.path.realpath(p)
            spellings.add(rp)
            spellings.add(rp + "/")
        except Exception:
            pass
    return {seedflow.config_slot_service(p) for p in spellings}


def cmd_cleanup(config_dir):
    deleted = 0
    for svc in sorted(_slot_services(config_dir)):
        # never let a computed name reach `security delete` unless it is unmistakably a
        # PER-DIR slot: the bare default slot is the live login and must never be touched.
        if not svc.startswith("Claude Code-credentials-") or len(svc) <= 24:
            continue
        if seedflow._sh_keychain_delete(svc):
            deleted += 1
    shutil.rmtree(config_dir, ignore_errors=True)
    print("cleaned: %d slot spellings swept, %s removed"
          % (deleted, "dir" if not os.path.exists(config_dir) else "dir REMAINS"))
    return 0 if not os.path.exists(config_dir) else 1


# ---------- breaker -----------------------------------------------------------

_BREAKER_FIELDS = ("needs_login_since", "ping_fail_streak")


def _clear_fields(path):
    """Drop the breaker fields from a marker/record JSON. Refuses to rewrite anything it
    cannot parse — a marker-only rewrite of a malformed BANK record would destroy the
    credentials it holds (the _ping_marker.py doctrine)."""
    try:
        d = json.load(open(path))
    except Exception:
        return False
    if not isinstance(d, dict) or not any(k in d for k in _BREAKER_FIELDS):
        return False
    for k in _BREAKER_FIELDS:
        d.pop(k, None)
    dirn = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        return False


def cmd_clear_breaker(bank_dir, email):
    cleared = []
    try:
        import registry
        home = registry.ready_home(bank_dir, email)
    except Exception:
        home = None
    if home:
        if _clear_fields(os.path.join(home, ".ping-marker.json")):
            cleared.append("home marker")
    rec = os.path.join(bank_dir, email + ".json")
    if os.path.exists(rec) and _clear_fields(rec):
        cleared.append("bank record")
    try:
        import notify
        notify.clear(bank_dir, email)
    except Exception:
        pass
    print("breaker cleared: %s" % (", ".join(cleared) if cleared else "nothing armed"))
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[1]
    try:
        if cmd == "watch" and len(argv) == 5:
            return cmd_watch(argv[2], argv[3], float(argv[4]))
        if cmd == "cleanup" and len(argv) == 3:
            return cmd_cleanup(argv[2])
        if cmd == "clear-breaker" and len(argv) == 4:
            return cmd_clear_breaker(argv[2], argv[3])
    except ValueError:
        pass
    sys.stderr.write("usage: relogin_capture.py watch <dir> <email> <timeout>"
                     " | cleanup <dir> | clear-breaker <bank_dir> <email>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
