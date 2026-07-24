#!/usr/bin/env python3
"""homewrite.py — THE tier-1 write helper (ISOLATION-DESIGN.md rev 5 §5).

Every tooling write to a home's credential file goes through write_credential() —
no other tooling code path may write one (suite-enforced). The guarantee:

    synchronous fsync'd pre-archive of the predecessor
    → temp + rename + fsync commit (file and directory)
    → post-commit readback equals what we wrote

Archive layout: <home>/archive/<utc>-<reason>.json (0600), pruned to ARCHIVE_KEEP
newest AFTER a successful commit only — a failed write never prunes, so forensic
material survives every failure path. Pre-archive failure ABORTS the write
(never-destroy is a precondition, not a best effort). stdlib only.
"""
import json
import os
import re
import tempfile
import time

import bank_common

ARCHIVE_KEEP = 20
_REASON_RE = re.compile(r"[^a-zA-Z0-9._-]+")


class HomeWriteError(Exception):
    """Any violated guarantee. The home is left in its pre-call state (or with an
    extra archive entry — never with a lost predecessor)."""


def _utc():
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def archive_predecessor(home, reason):
    """Durably archive the CURRENT credential file (if any). Returns the archive
    path or None when no predecessor exists. Raises HomeWriteError on any failure —
    callers must treat that as 'do not proceed with the write'."""
    cred = os.path.join(home, ".credentials.json")
    if not os.path.exists(cred):
        return None
    adir = os.path.join(home, "archive")
    try:
        os.makedirs(adir, exist_ok=True)
        os.chmod(adir, 0o700)
        with open(cred, "rb") as f:
            raw = f.read()
        tag = _REASON_RE.sub("-", reason)[:40] or "write"
        # monotonic-ns suffix: same-second successive writes must never collide
        dest = os.path.join(adir, f"{_utc()}-{os.getpid()}-{time.monotonic_ns():016x}-{tag}.json")
        fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        _fsync_dir(adir)
        # (finding 20) also fsync the HOME dir: if archive/ was just created, its
        # directory entry must be durable before the credential replacement lands —
        # otherwise a power loss could keep the replacement but lose the archive.
        _fsync_dir(home)
        return dest
    except Exception as e:
        raise HomeWriteError(f"pre-archive failed ({type(e).__name__}); write refused")


def _prune(adir):
    """Keep the ARCHIVE_KEEP newest entries. Called only after a successful commit;
    prune errors are non-fatal (an over-full archive is safe, a lost one is not)."""
    try:
        entries = sorted(
            (e for e in os.listdir(adir) if e.endswith(".json")),
            reverse=True,
        )
        for stale in entries[ARCHIVE_KEEP:]:
            try:
                os.remove(os.path.join(adir, stale))
            except OSError:
                pass
    except OSError:
        pass


def write_credential(home, oauth, reason, expected_email=None, identity_check=None):
    """Commit {"claudeAiOauth": oauth} to <home>/.credentials.json under the tier-1
    guarantee. `oauth` must be schema-valid (bank_common.valid_oauth). When
    `expected_email` is given, `identity_check(accessToken)` -> (bool_or_None, detail)
    gates the commit: True required; False = foreign credential (refused); None =
    INDETERMINATE (refused — fail-closed). Default identity_check is identity.verify_owner.

    Caller MUST hold the home lock (banklock on the home dir); this helper does not
    lock so that lock ordering stays in the callers (one place per §8)."""
    if not bank_common.valid_oauth(oauth):
        raise HomeWriteError("refusing to write a schema-invalid credential")
    if expected_email is not None:
        if identity_check is None:
            import identity
            identity_check = lambda tok: identity.verify_owner(tok, expected_email)  # noqa: E731
        owned, detail = identity_check(oauth.get("accessToken", ""))
        if owned is None:
            raise HomeWriteError(f"identity INDETERMINATE ({getattr(detail, 'detail', detail)}); write refused")
        if owned is False:
            raise HomeWriteError("credential belongs to a DIFFERENT account; write refused")

    archive_predecessor(home, reason)   # raises on failure => abort

    cred = os.path.join(home, ".credentials.json")
    payload = json.dumps({"claudeAiOauth": oauth})
    fd, tmp = tempfile.mkstemp(dir=home, prefix=".cred.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, cred)
    except Exception as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise HomeWriteError(f"commit failed ({type(e).__name__}); predecessor archived + intact")
    _fsync_dir(home)

    # post-commit readback: what landed must be what we wrote
    try:
        with open(cred) as f:
            back = json.load(f)
    except Exception as e:
        raise HomeWriteError(f"post-commit readback failed ({type(e).__name__})")
    if back.get("claudeAiOauth") != oauth:
        raise HomeWriteError("post-commit readback differs from written payload")

    # (finding 19) §5 mandates a POST-COMMIT G9 identity check, not just a byte
    # readback: a credential revoked or identity-changed between the pre-check and the
    # commit must be caught. The predecessor is already archived, so raising here is
    # never-destroy-safe (the caller treats it as a failed write + operator recovery).
    if expected_email is not None:
        owned2, detail2 = identity_check(oauth.get("accessToken", ""))
        if owned2 is None:
            raise HomeWriteError(
                f"post-commit identity INDETERMINATE ({getattr(detail2, 'detail', detail2)}); "
                "committed credential unverifiable (predecessor archived)")
        if owned2 is False:
            raise HomeWriteError(
                "post-commit identity says the committed credential is FOREIGN "
                "(revoked/identity-changed since pre-check; predecessor archived)")

    _prune(os.path.join(home, "archive"))
    return cred
