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
  verify-banked <config_dir> <bank_record> [snapshot]
      Prove the record that was just written carries the credential we CAPTURED, and
      restore the pre-bank snapshot if it does not. See "the banked-credential
      assertion" below.
  journal-claim / journal-update / journal-release / journal-sweep / journal-kill
      The pending-relogin journal. See "the pending journal" below.

THE BANKED-CREDENTIAL ASSERTION (r2 finding 1). `bank-account.sh` does not take the
credential from us — it re-reads "the live credential" through `cred_read`, and cred_read
accepts a config dir's `.credentials.json` only when the raw text contains
"claudeAiOauth" or "oauth". A FLAT blob ({"accessToken":...} at top level) — a shape the
capture path deliberately tolerates — matches neither, so cred_read falls through to the
BARE default slot: the ACTIVE account. Every downstream check still passes (the email
comes from the target's own .claude.json, so write_bank_record's metadata gate agrees,
and the fp1/fp2 stability check compares that wrong blob with itself), and the flow would
report success with another account's tokens under the target's name. Loosening cred_read
is not the fix — its shape gate and kc_write's ceremony are load-bearing elsewhere.
Instead we assert, after the fact and independently of shape: the fingerprint of the blob
we captured must equal the fingerprint of the credential now in the record. Any
mismatch — or any fingerprint we cannot compute — is a hard failure, and the pre-bank
record is restored so a wrong credential is never left banked under that email.

THE PENDING JOURNAL (r2 finding 2). The login happens in a Terminal we do not control and
a human we cannot hurry. If the flow dies first — timeout, mismatch, reboot, kill — and
the owner completes the OAuth afterwards, the CLI writes a LIVE credential into the slot
`Claude Code-credentials-<sha256(config_dir)[:8]>` for a config dir that no longer exists:
nothing can recompute that service name, so the credential is stranded in the keychain
forever. `<bank_dir>/.relogin-journal.json` records the config dir BEFORE the Terminal is
opened and is cleared only after a completed cleanup, so every slot spelling stays
recomputable no matter how the run dies. It doubles as the double-invocation guard: a
second Re-bank while one is pending is refused rather than opening a second window
(QuotaBar's busy-guard clears the moment the flow detaches, so the guard has to live
here).

Doctrine this file must not weaken:
  * A seat read of status "error" means UNKNOWN (locked/headless keychain). It is NEVER
    a negative verdict — the watcher keeps waiting and, at timeout, reports "unknown",
    not "no credential".
  * Identity is proven POSITIVELY before anything is banked. INVALID (the server
    rejected it) and INDETERMINATE (offline/timeout/WAF) are both refusals; only
    RESOLVED-and-equal proceeds. If the owner picked the wrong account in the browser we
    abort and clean up rather than banking a mismatched credential.
  * Raw credential material is never printed, logged, or put in an error string.

Exit codes: 0 ok · 4 timeout · 5 identity mismatch/rejected (CONFIRMED, the owner picked
the wrong account) · 6 transient (identity unconfirmed, unreadable seat, malformed
capture) · 8 banked credential is NOT the one captured · 9 another re-login is already
pending for this account · 2 usage.
"""
import json
import os
import shutil
import signal
import subprocess
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


def _sweep_config_dir(config_dir):
    """Delete every per-config-dir slot this path could have produced, then the dir."""
    deleted = 0
    for svc in sorted(_slot_services(config_dir)):
        # never let a computed name reach `security delete` unless it is unmistakably a
        # PER-DIR slot: the bare default slot is the live login and must never be touched.
        if not svc.startswith("Claude Code-credentials-") or len(svc) <= 24:
            continue
        if seedflow._sh_keychain_delete(svc):
            deleted += 1
    shutil.rmtree(config_dir, ignore_errors=True)
    return deleted


def cmd_cleanup(config_dir):
    deleted = _sweep_config_dir(config_dir)
    print("cleaned: %d slot spellings swept, %s removed"
          % (deleted, "dir" if not os.path.exists(config_dir) else "dir REMAINS"))
    return 0 if not os.path.exists(config_dir) else 1


# ---------- the banked-credential assertion (r2 finding 1) --------------------

def cmd_verify_banked(config_dir, bank_record, snapshot=""):
    """Prove the record now holds the credential we captured; restore and fail if not.

    Deliberately shape-agnostic: both sides go through bank_common.cred_fingerprint,
    which canonicalizes a full keychain blob and a bare oauth object identically and
    returns "" for anything it cannot validate. An empty fingerprint never compares
    equal, so "I could not verify this" fails exactly like "these differ" — the whole
    point of the check is that it cannot be talked into a yes."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import bank_common
    except Exception:
        print("unverifiable: bank_common unavailable")
        return 8

    try:
        with open(os.path.join(config_dir, ".credentials.json")) as f:
            captured = f.read()
    except Exception:
        print("unverifiable: the captured credential could not be re-read")
        return 8
    try:
        with open(bank_record) as f:
            rec = json.load(f)
        banked = rec.get("claudeAiOauth")
    except Exception:
        print("unverifiable: the bank record could not be read back")
        return 8

    if bank_common.same_credentials(captured, banked):
        print("verified: the banked credential is the one captured")
        return 0

    # The record holds something other than what this login produced — on the known
    # mechanism, the ACTIVE account's tokens under the target's email. Leaving that in
    # place is worse than the dead record we started with (a swap would later hand a
    # session the wrong account), so put the pre-bank state back.
    restored = _restore_record(bank_record, snapshot)
    print("MISMATCH: the banked credential is not the one this login captured "
          "(%s)" % restored)
    return 8


def _restore_record(bank_record, snapshot):
    """Put the pre-bank record back, byte for byte. `snapshot` is a file holding the
    previous bytes, or "" when there was no record before (in which case the correct
    restoration is to remove the one we just wrote — that returns the bank to its
    actual prior state, it does not destroy anything that existed)."""
    try:
        if snapshot and os.path.exists(snapshot):
            with open(snapshot) as f:
                prev = f.read()
            dirn = os.path.dirname(os.path.abspath(bank_record))
            fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
            with os.fdopen(fd, "w") as f:
                f.write(prev)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, bank_record)
            return "previous record restored"
        os.remove(bank_record)
        return "the record this run created was removed"
    except FileNotFoundError:
        return "nothing to restore"
    except Exception as e:
        return "RESTORE FAILED (%s) — inspect this record by hand" % type(e).__name__


# ---------- the pending journal (r2 finding 2) --------------------------------

JOURNAL_NAME = ".relogin-journal.json"
LOCK_NAME = ".relogin-journal.lock"
LOCK_WAIT_S = 5


def _journal_path(bank_dir):
    return os.path.join(bank_dir, JOURNAL_NAME)


class _JournalLock:
    """mkdir lock, the same primitive lib.sh's bank lock uses. Short-lived by
    construction: every critical section here is a read-modify-write of one small JSON
    file, never anything that waits on a human or the network."""

    def __init__(self, bank_dir):
        self.path = os.path.join(bank_dir, LOCK_NAME)

    def __enter__(self):
        deadline = time.time() + LOCK_WAIT_S
        while True:
            try:
                os.mkdir(self.path)
                return self
            except FileExistsError:
                # a lock older than the wait budget is a crash residue, not a holder
                try:
                    if time.time() - os.path.getmtime(self.path) > LOCK_WAIT_S * 2:
                        os.rmdir(self.path)
                        continue
                except Exception:
                    pass
                if time.time() >= deadline:
                    raise TimeoutError("journal lock busy")
                time.sleep(0.1)

    def __exit__(self, *exc):
        try:
            os.rmdir(self.path)
        except Exception:
            pass
        return False


def _journal_load(bank_dir):
    try:
        d = json.load(open(_journal_path(bank_dir)))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _journal_store(bank_dir, d):
    fd, tmp = tempfile.mkstemp(dir=bank_dir, prefix=".reljrnl.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, _journal_path(bank_dir))
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        return False


def _alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True          # exists, owned by someone else
    except Exception:
        return False


def _login_pid(entry):
    """The pid of the `claude` the login window is running. The launcher records it INSIDE
    the config dir rather than in the journal, so it survives a crash between opening the
    window and any journal update — the file is written before the exec, the journal only
    has to point at the directory."""
    cfg = entry.get("config_dir") or ""
    if not cfg:
        return None
    try:
        with open(os.path.join(cfg, "login.pid")) as f:
            return int(f.read().strip())
    except Exception:
        return None


def _entry_pending(entry, max_age):
    """An entry is PENDING while something of it is still running and it is not older
    than the flow could possibly be. The age cap is what keeps a recycled pid from
    pinning a dead entry as live forever."""
    try:
        age = time.time() - float(entry.get("started_at", 0) or 0)
    except (TypeError, ValueError):
        age = max_age + 1
    if age > max_age:
        return False
    return _alive(entry.get("owner_pid")) or _alive(_login_pid(entry))


def cmd_journal_claim(bank_dir, email, owner_pid, max_age):
    """Claim the right to run a re-login for `email`, atomically. Exit 9 if one is
    already pending — a second Terminal window for the same account is never right, and
    QuotaBar cannot enforce that itself (its per-card busy guard clears as soon as the
    flow detaches, about a second in)."""
    try:
        with _JournalLock(bank_dir):
            d = _journal_load(bank_dir)
            cur = d.get(email)
            if isinstance(cur, dict) and _entry_pending(cur, max_age):
                print("pending: a re-login for %s is already running (pid %s)"
                      % (email, cur.get("owner_pid")))
                return 9
            d[email] = {"config_dir": "", "started_at": int(time.time()),
                        "owner_pid": int(owner_pid), "term_window": ""}
            _journal_store(bank_dir, d)
    except TimeoutError:
        print("pending: the re-login journal is busy")
        return 9
    print("claimed")
    return 0


def cmd_journal_update(bank_dir, email, key, value):
    if key not in ("config_dir", "owner_pid", "term_window"):
        sys.stderr.write("journal-update: refusing unknown key %r\n" % key)
        return 2
    try:
        with _JournalLock(bank_dir):
            d = _journal_load(bank_dir)
            if not isinstance(d.get(email), dict):
                # Re-create rather than skip. The config dir IS the recoverability
                # property — an update that quietly did nothing because a sweep had just
                # dropped the entry would leave a live login with no journal pointing at
                # its slot, which is the exact failure this journal exists to prevent.
                d[email] = {"config_dir": "", "started_at": int(time.time()),
                            "owner_pid": 0, "term_window": ""}
            d[email][key] = int(value) if key == "owner_pid" else value
            _journal_store(bank_dir, d)
    except TimeoutError:
        return 0
    return 0


def cmd_journal_release(bank_dir, email):
    try:
        with _JournalLock(bank_dir):
            d = _journal_load(bank_dir)
            if email in d:
                d.pop(email, None)
                _journal_store(bank_dir, d)
    except TimeoutError:
        return 0
    return 0


def _close_terminal_window(window_id):
    """Best effort. `saving no` matters: the window is closed after its process is
    already dead, and a prompt nobody answers would leave it open anyway."""
    if not window_id:
        return
    osa = os.environ.get("ACCOUNT_BANK_OSASCRIPT_BIN", "/usr/bin/osascript")
    if not (os.path.isfile(osa) and os.access(osa, os.X_OK)):
        return
    script = ('on run argv\n'
              '  tell application "Terminal"\n'
              '    close (every window whose id is (item 1 of argv) as integer) saving no\n'
              '  end tell\n'
              'end run\n')
    try:
        subprocess.run([osa, "-", str(window_id)], input=script,
                       capture_output=True, text=True, timeout=5)
    except Exception:
        pass


def _terminate_login(entry):
    """Stop the login this entry started: the `claude` process first, then its window.
    Called on every path that abandons a flow — otherwise a login completed after we
    gave up writes a live credential into a slot whose config dir we already deleted."""
    pid = _login_pid(entry)
    killed = False
    if pid and _alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
            killed = True
            for _ in range(20):
                time.sleep(0.1)
                if not _alive(pid):
                    break
            if _alive(pid):
                os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    _close_terminal_window(entry.get("term_window"))
    return killed


def cmd_journal_kill(bank_dir, email):
    entry = _journal_load(bank_dir).get(email)
    if not isinstance(entry, dict):
        print("no pending login")
        return 0
    print("login terminated" if _terminate_login(entry) else "no live login to terminate")
    return 0


def cmd_journal_sweep(bank_dir, max_age):
    """Reap every entry whose flow is over: kill anything still running, sweep the slot
    for every spelling of its config dir, delete the dir, drop the entry. This is what
    makes a reboot or a SIGKILL mid-login recoverable instead of permanent."""
    reaped = []
    try:
        with _JournalLock(bank_dir):
            d = _journal_load(bank_dir)
            for email in list(d.keys()):
                entry = d.get(email)
                if not isinstance(entry, dict):
                    d.pop(email, None)
                    continue
                if _entry_pending(entry, max_age):
                    continue
                _terminate_login(entry)
                cfg = entry.get("config_dir") or ""
                if cfg and os.path.basename(cfg).startswith(".relogin."):
                    _sweep_config_dir(cfg)
                d.pop(email, None)
                reaped.append(email)
            if reaped:
                _journal_store(bank_dir, d)
    except TimeoutError:
        print("swept: journal busy, skipped")
        return 0
    print("swept: %s" % (", ".join(reaped) if reaped else "nothing stale"))
    return 0


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
        if cmd == "verify-banked" and len(argv) in (4, 5):
            return cmd_verify_banked(argv[2], argv[3], argv[4] if len(argv) > 4 else "")
        if cmd == "journal-claim" and len(argv) == 6:
            return cmd_journal_claim(argv[2], argv[3], argv[4], float(argv[5]))
        if cmd == "journal-update" and len(argv) == 6:
            return cmd_journal_update(argv[2], argv[3], argv[4], argv[5])
        if cmd == "journal-release" and len(argv) == 4:
            return cmd_journal_release(argv[2], argv[3])
        if cmd == "journal-kill" and len(argv) == 4:
            return cmd_journal_kill(argv[2], argv[3])
        if cmd == "journal-sweep" and len(argv) == 4:
            return cmd_journal_sweep(argv[2], float(argv[3]))
    except ValueError:
        pass
    sys.stderr.write(
        "usage: relogin_capture.py watch <dir> <email> <timeout>\n"
        "     | cleanup <dir> | clear-breaker <bank_dir> <email>\n"
        "     | verify-banked <dir> <bank_record> [snapshot]\n"
        "     | journal-claim <bank_dir> <email> <owner_pid> <max_age>\n"
        "     | journal-update <bank_dir> <email> <key> <value>\n"
        "     | journal-release|journal-kill <bank_dir> <email>\n"
        "     | journal-sweep <bank_dir> <max_age>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
