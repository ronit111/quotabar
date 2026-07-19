#!/usr/bin/env python3
"""reconcile.py — recover rotated tokens from crash-recovery journals.

A parked-account refresh writes the rotated creds to a 0600 journal
($BANK/.refresh-journal-<email>.json) BEFORE it commits them to the bank file.
If the process dies between the two, the new refresh token would be lost. On the
next locked operation we reconcile: if a journal holds a token newer than the
bank file's, merge it in atomically; then delete the journal.

MUST be called while holding the bank lock (callers do). Importable as
reconcile_journals(); also runnable as a CLI. Never prints secrets.
"""
import json, os, glob, tempfile, time, sys, subprocess, pwd

HOME = os.path.expanduser("~")
_XDG_DATA = os.environ.get("XDG_DATA_HOME", os.path.join(HOME, ".local", "share"))
BANK_DIR = os.environ.get("BANK_DIR", os.path.join(_XDG_DATA, "quotabar"))
CLAUDE_JSON = os.environ.get("CLAUDE_JSON", os.path.join(HOME, ".claude.json"))
SWAP_JOURNAL = os.path.join(BANK_DIR, ".swap-journal.json")
KEYCHAIN_SERVICE = "Claude Code-credentials"
KEYCHAIN_ACCOUNT = os.environ.get("KEYCHAIN_ACCOUNT") or pwd.getpwuid(os.getuid()).pw_name


def _atomic_write_json(path, obj):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".acct.")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def journal_path(email):
    safe = email.replace("/", "_")
    return os.path.join(BANK_DIR, f".refresh-journal-{safe}.json")


def write_journal(email, oauth):
    _atomic_write_json(journal_path(email),
                       {"email": email, "claudeAiOauth": oauth, "ts": time.time()})


def _active_email():
    try:
        return (json.load(open(CLAUDE_JSON)).get("oauthAccount") or {}).get("emailAddress", "") or ""
    except Exception:
        return ""


def _restore_keychain(compact_blob):
    """Write a compact, pre-validated credential blob back to the login keychain
    via `security -i` (secret on stdin, never argv), mirroring lib.sh kc_write.
    Honors ACCOUNT_BANK_RECONCILE_DRYRUN=1 (log-only) so the rollback path can be
    exercised without touching the live keychain. Returns True on (simulated)
    success."""
    if not isinstance(compact_blob, str) or not compact_blob.strip():
        return False
    if any(ch.isspace() for ch in compact_blob.strip()):
        return False   # security -i tokenizes on whitespace; a compact blob is required
    try:
        o = json.loads(compact_blob)
        oa = o.get("claudeAiOauth") if isinstance(o, dict) else None
        if not (isinstance(oa, dict) and oa.get("accessToken") and oa.get("refreshToken")):
            return False
    except Exception:
        return False
    if os.environ.get("ACCOUNT_BANK_RECONCILE_DRYRUN") == "1":
        sys.stderr.write("reconcile(dry-run): WOULD restore pre-swap keychain blob\n")
        return True
    cmd = 'add-generic-password -U -s "%s" -a "%s" -w %s\n' % (
        KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, compact_blob)
    try:
        p = subprocess.run(["security", "-i"], input=cmd, text=True,
                           capture_output=True, timeout=8)
        return p.returncode == 0
    except Exception:
        return False


def reconcile_swap_journal():
    """Roll back a torn swap (finding #1). A swap writes .swap-journal.json (the
    pre-swap keychain blob + from/to emails) before the keychain write and clears
    it after the metadata commit. If we find it here:
      - active email already == target  -> the metadata commit landed; the swap
        completed, just drop the stale journal.
      - otherwise -> the metadata is still the pre-swap account while the keychain
        may already hold the target creds (torn). Restore the pre-swap blob so the
        keychain matches ~/.claude.json again, then drop the journal. If the
        restore fails, KEEP the journal so a later locked op retries.
    Returns the rolled-back target email, or None."""
    if not os.path.exists(SWAP_JOURNAL):
        return None
    try:
        j = json.load(open(SWAP_JOURNAL))
    except Exception:
        os.remove(SWAP_JOURNAL); return None
    if not isinstance(j, dict) or j.get("type") != "swap":
        try: os.remove(SWAP_JOURNAL)
        except OSError: pass
        return None
    target = j.get("target")
    active = _active_email()
    if active and target and active == target:
        os.remove(SWAP_JOURNAL)   # swap committed fully; nothing to undo
        return None
    if _restore_keychain(j.get("pre_swap_blob")):
        try: os.remove(SWAP_JOURNAL)
        except OSError: pass
        return target
    # restore failed -> leave the journal for the next locked op to retry
    sys.stderr.write("reconcile: torn-swap keychain rollback FAILED; journal kept for retry\n")
    return None


def reconcile_journals():
    # torn-swap rollback first: it restores the keychain to a known-consistent
    # state before any account is read/used by the caller.
    try:
        rolled = reconcile_swap_journal()
    except Exception:
        rolled = None
    recovered = []
    for jp in glob.glob(os.path.join(BANK_DIR, ".refresh-journal-*.json")):
        try:
            j = json.load(open(jp))
        except Exception:
            os.remove(jp)   # corrupt journal is useless
            continue
        if not isinstance(j, dict):
            os.remove(jp); continue
        email = j.get("email")
        joauth = j.get("claudeAiOauth")
        if not email or not isinstance(joauth, dict) or not joauth.get("accessToken"):
            os.remove(jp); continue
        bank_path = os.path.join(BANK_DIR, f"{email}.json")
        if not os.path.exists(bank_path):
            os.remove(jp); continue   # nothing to merge into
        try:
            rec = json.load(open(bank_path))
            if not isinstance(rec, dict):
                os.remove(jp); continue
        except Exception:
            os.remove(jp); continue
        bank_exp = (rec.get("claudeAiOauth") or {}).get("expiresAt") or 0
        jrn_exp = joauth.get("expiresAt") or 0
        if jrn_exp > bank_exp:
            rec["claudeAiOauth"] = joauth
            rec["status"] = "ok"
            rec["last_verified"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            _atomic_write_json(bank_path, rec)
            recovered.append(email)
        os.remove(jp)   # journal consumed either way
    return recovered


if __name__ == "__main__":
    r = reconcile_journals()
    if r:
        sys.stderr.write("reconciled rotated tokens for: " + ", ".join(r) + "\n")
