#!/usr/bin/env python3
"""bank_common.py — shared, dependency-free helpers for the account bank.

This module is the SINGLE source of truth for three cross-cutting concerns the
2026-07-21 hardening sweep found scattered and inconsistently applied:

  1. VALIDATED LOAD (findings 35/39/53/54 and the "malformed record destroys
     credentials" class): load_bank_record() schema-validates a bank record on
     the way in. Every reader/mutator routes through it. A malformed record
     becomes an explicit, visible error — it is NEVER silently dropped and NEVER
     partially overwritten (a mutation that would erase credentials because the
     record failed to parse is refused).

  2. CREDENTIAL FINGERPRINT (findings 11/21 and the swap torn-commit class):
     cred_fingerprint() hashes the FULL canonical OAuth object (not just the
     accessToken), so rotation / external-login / torn-swap detection compares
     the whole credential, not one field.

  3. EMAIL -> PATH SAFETY (critical finding 1): safe_email() / bank_file_for()
     reject path traversal and separators so an attacker- or typo-supplied
     "email" can never resolve a file outside the bank directory.

stdlib only. Token/secret values are NEVER printed by anything here.
"""
import glob
import hashlib
import json
import math
import os
import tempfile
import time

# Bank record status values we understand. Anything else is coerced to a visible
# error rather than trusted.
KNOWN_STATUSES = ("ok", "needs-relogin")

# (r8 #3 / r13 #12) v2 control-plane JSON files that live under accounts/ (== BANK_DIR) and
# must NEVER be parsed as bank records. They are not dotfiles, so a `*.json` glob matches
# them; every account lister/poller must skip these by basename. Shared so usage.py and
# list-accounts.sh apply the identical set.
V2_CONTROL_JSON = frozenset({
    "registry.json", "sessions.json", "archiver.status.json",
    "attestation.json", "quotabar.runtime.json",
})


def resolve_bank_dir(env=None):
    """(r15 #4) THE bank-directory resolution rule, in one place: BANK_DIR (test/explicit)
    -> ACCOUNT_BANK_DIR (the convention the shim, claude-acct and hooks export) ->
    ~/.claude/accounts. Byte-identical to lib.sh:22 and README's Configuration table.

    Before this, the shell mutators honoured ACCOUNT_BANK_DIR while usage.py, reconcile.py
    and the app silently ignored it and used the default — so a user who set only the
    DOCUMENTED variable had the swap scripts operating on one bank while the poller and
    reconciler read (and recovered) a different one. Every Python entry point resolves here;
    the app resolves the same order and exports the RESULT to its children so no child can
    re-resolve differently."""
    env = os.environ if env is None else env
    return (env.get("BANK_DIR") or env.get("ACCOUNT_BANK_DIR")
            or os.path.join(os.path.expanduser("~"), ".claude", "accounts"))


# --------------------------------------------------------------------------- #
# email / path safety (critical finding 1)
# --------------------------------------------------------------------------- #
def safe_email(email):
    """Return the email unchanged iff it is safe to use as a `<email>.json`
    filename component, else None.

    Rejects: empty, non-str, path separators ("/" or "\\"), NUL, the "."/".."
    directory names, any ".." substring (parent traversal), a leading "." (hidden
    / dotfile collision with .lock/.config.json/etc.), whitespace/control chars,
    and anything without an "@" (not an email identity). Deliberately strict:
    real Claude account emails are ordinary addresses with none of these."""
    if not isinstance(email, str) or not email:
        return None
    if email in (".", ".."):
        return None
    if email.startswith("."):
        return None
    if ".." in email:
        return None
    if "/" in email or "\\" in email or "\x00" in email:
        return None
    if "@" not in email:
        return None
    for ch in email:
        # control chars and whitespace have no place in an address we file by
        if ord(ch) < 0x20 or ch.isspace():
            return None
    # basename round-trip: the filename must have no directory component
    fname = email + ".json"
    if os.path.basename(fname) != fname:
        return None
    return email


def bank_file_for(bank_dir, email):
    """Absolute path to <bank_dir>/<email>.json, or None if the email is unsafe
    OR the resolved path escapes bank_dir. Both checks matter: safe_email blocks
    the obvious cases, the realpath containment check is defense in depth."""
    e = safe_email(email)
    if e is None:
        return None
    path = os.path.join(bank_dir, e + ".json")
    # containment: the real parent must be the real bank dir
    try:
        parent = os.path.realpath(os.path.dirname(path))
        if parent != os.path.realpath(bank_dir):
            return None
    except OSError:
        return None
    return path


# --------------------------------------------------------------------------- #
# credential validation + fingerprint (findings 11/21)
# --------------------------------------------------------------------------- #
def valid_oauth(oauth):
    """True iff `oauth` is a well-formed claudeAiOauth dict: non-empty string
    accessToken + refreshToken and a FINITE numeric expiresAt. Matches
    validate_blob.py and lib.sh kc_write so every gate agrees on what 'valid
    credentials' means."""
    if not (isinstance(oauth, dict)
            and isinstance(oauth.get("accessToken"), str) and bool(oauth.get("accessToken"))
            and isinstance(oauth.get("refreshToken"), str) and bool(oauth.get("refreshToken"))
            and isinstance(oauth.get("expiresAt"), (int, float))
            and not isinstance(oauth.get("expiresAt"), bool)):
        return False
    # (r3 #13) reject non-finite expiresAt (NaN / Infinity). Python's json module
    # round-trips these as bare `NaN`/`Infinity` tokens, which Claude Code's
    # stricter JSON parser rejects — installing such a blob bricks the credential
    # file, yet every offline gate here (validation, fingerprint) would otherwise
    # accept it and let swap clear the recovery journal.
    if not math.isfinite(oauth.get("expiresAt")):
        return False
    # refreshTokenExpiresAt is optional, but if present it must also be a finite
    # number (runtime death-checks compare it numerically); a non-finite value is
    # the same non-standard-JSON hazard.
    rexp = oauth.get("refreshTokenExpiresAt")
    if rexp is not None:
        if isinstance(rexp, bool) or not isinstance(rexp, (int, float)) or not math.isfinite(rexp):
            return False
    return True


# The ONLY fields that make a credential a credential. The fingerprint hashes
# EXACTLY these (re-review issue 7): benign presentation/plan metadata such as
# subscriptionType must NOT change the fingerprint, or a plan-only change would
# falsely abort a swap or indefinitely block reconciliation.
CRED_FIELDS = ("accessToken", "refreshToken", "expiresAt")
# refreshTokenExpiresAt is credential-generation-bearing (r3 #14): runtime code
# (isolated_refresh, ping) uses it to declare a credential DEAD. Two creds that
# differ ONLY in this field are therefore NOT the same credential — a recovery
# journal carrying a refreshed refreshTokenExpiresAt must not compare equal to a
# stale bank record and be silently dropped. Included in the fingerprint when
# present; absent stays distinct from present (JSON null vs a value).
CRED_OPTIONAL_FIELDS = ("refreshTokenExpiresAt",)


def canonical_oauth(oauth):
    """Deterministic JSON of the CREDENTIAL-BEARING fields only (sorted, compact),
    or None if `oauth` is not a valid credential. Presentation/plan metadata is
    excluded on purpose (issue 7); refreshTokenExpiresAt is included when present
    (r3 #14)."""
    if not valid_oauth(oauth):
        return None
    d = {k: oauth[k] for k in CRED_FIELDS}
    for k in CRED_OPTIONAL_FIELDS:
        if k in oauth:
            d[k] = oauth[k]
    return json.dumps(d, sort_keys=True, separators=(",", ":"))


def cred_fingerprint(blob_or_oauth):
    """SHA-256 (hex) of the credential-bearing fields, or "" when the input is not
    a VALID credential (re-review issue 6: `{}` / a malformed object must yield an
    empty fingerprint, never a hash of `{}`). Accepts a full keychain blob, a bare
    oauth dict, or a JSON string of either. Comparing accessToken+refreshToken+
    expiresAt catches a rotation of ONLY the refreshToken or expiresAt (finding 21)
    while ignoring plan changes (issue 7)."""
    o = blob_or_oauth
    if isinstance(o, str):
        try:
            o = json.loads(o)
        except Exception:
            return ""
    if isinstance(o, dict) and "claudeAiOauth" in o:
        o = o.get("claudeAiOauth")
    c = canonical_oauth(o)          # None unless valid_oauth(o)
    if c is None:
        return ""
    return hashlib.sha256(c.encode("utf-8")).hexdigest()


def same_credentials(a, b):
    """True iff two blobs/oauth objects carry the same credential (full-object
    compare, finding 21). Empty/invalid fingerprints never compare equal."""
    fa, fb = cred_fingerprint(a), cred_fingerprint(b)
    return bool(fa) and fa == fb


def plan_tier(raw):
    """Normalize a plan string from EITHER oauthAccount.organizationType ("claude_max",
    "claude_max_20x") OR claudeAiOauth.subscriptionType ("max") to the max|pro|free tier
    strings autopick matches EXACTLY, else None. Prefix-based so tier variants ($100 Max 5x /
    $200 Max 20x) both collapse to "max" — a naive "claude_"-strip would yield "max_20x" and
    break is_max()'s `== "max"`. THE tier rule; usage._norm_plan is this function."""
    if not isinstance(raw, str) or not raw:
        return None
    r = raw.lower()
    if r.startswith("claude_"):
        r = r[len("claude_"):]
    for tier in ("max", "pro", "free"):
        if r.startswith(tier):
            return tier
    return None


def hook_rebank_refusal(kc, rec):
    """(v101-confirm) Why the SessionStart hook must NOT re-bank this credential drift by
    itself, or "" when the drift is provably the banked account's own credential and a
    re-bank is safe with no network call. Phrased as a refusal: anything unknown, unreadable
    or merely uncontradicted returns a reason. `kc` is the live keychain oauth object, `rec`
    the banked record's. Never raises.

    THE PROBLEM. The hook runs inside a 5s budget on a path where a network call is the
    historical false-death hazard, so it has no identity oracle available. Offline, one
    account's credential carries nothing that binds it to an email — which made "the keychain
    changed" indistinguishable from "the keychain now belongs to someone else". The hook
    re-banked on any drift its offline checks did not contradict, so a keychain-first /login
    from A to a SAME-PLAN B (keychain already holds B, ~/.claude.json still names A, both
    stable across repeated reads) wrote B's tokens into A.json and destroyed A's copy.
    Selecting A afterwards authenticates as B. The oracle-gated poll heal in usage.py cannot
    repair that if the hook won the bank lock first.

    THE ONE PROVABLE CASE. An access token is issued to exactly one account, so a live
    credential whose accessToken is BYTE-IDENTICAL to the one already banked under this email
    IS that account's credential — no oracle required. Its refreshToken or expiresAt having
    rotated (finding #45's drift class) changes the fingerprint but not the attribution. That
    is the only offline identity PROOF available here; a changed accessToken is a new token
    that could equally be A's rotation or B's login, and only the poll's live G9 lookup can
    tell those apart. Everything else defers there.

    A plan-tier change defers too, even with a matching access token, because a tier change is
    a distinct event with its own reporting and it is also write_bank_record's positive tell
    for crossed identities — this function refuses on it rather than deciding it."""
    if not valid_oauth(kc):
        return "the live credential is incomplete"
    if not isinstance(rec, dict):
        return "the banked record has no credential to compare against"
    if same_credentials(kc, rec):
        return "no drift to re-bank"
    live_at, banked_at = kc.get("accessToken"), rec.get("accessToken")
    if not isinstance(live_at, str) or not live_at or live_at != banked_at:
        return ("the access token changed, which is offline-indistinguishable from a "
                "different account's /login")
    kt, rt = plan_tier(kc.get("subscriptionType")), plan_tier(rec.get("subscriptionType"))
    if kt and rt and kt != rt:
        return "the plan tier changed"
    return ""


# --------------------------------------------------------------------------- #
# validated bank-record load (findings 35/39/53/54)
# --------------------------------------------------------------------------- #
class BankRecord(object):
    """Result of load_bank_record.

    ok        : True iff the record parsed AND passed schema validation.
    record    : the parsed dict (present even when ok is False but the file
                parsed as a dict — so a mutator can preserve unrelated keys
                instead of destroying them); None if unparseable/not a dict.
    email     : validated identity (== filename stem) when ok; else None.
    oauth     : claudeAiOauth dict when ok; else None.
    status    : record status string when ok; else None.
    plan      : oauthAccount.organizationType (or None).
    reason    : human reason string when ok is False; else "".
    path      : the path we loaded from.
    """
    __slots__ = ("ok", "record", "email", "oauth", "status", "plan", "reason", "path")

    def __init__(self, ok, record, email, oauth, status, plan, reason, path):
        self.ok = ok
        self.record = record
        self.email = email
        self.oauth = oauth
        self.status = status
        self.plan = plan
        self.reason = reason
        self.path = path


def _filename_email(path):
    base = os.path.basename(path)
    return base[:-5] if base.endswith(".json") else base


def validate_bank_record(rec, expected_email):
    """(ok, reason). Schema per the stated invariant: dict; email is a string
    equal to the filename stem; status is a known string; claudeAiOauth is a
    valid credential object; oauthAccount is a dict; plan (organizationType /
    subscriptionType) is a string or absent. A needs-relogin record is VALID
    (it is a legitimate, expected steady state) even though its token may be
    unusable — validity here means "well-formed and safe to reason about", not
    "swappable"."""
    if not isinstance(rec, dict):
        return False, "record is not a JSON object"
    email = rec.get("email")
    if not isinstance(email, str) or not email:
        return False, "email missing or not a string"
    if expected_email is not None and email != expected_email:
        return False, f"email '{email}' does not match filename '{expected_email}'"
    if safe_email(email) is None:
        return False, "email fails path-safety validation"
    status = rec.get("status", "ok")
    if not isinstance(status, str) or status not in KNOWN_STATUSES:
        return False, f"unknown status {status!r}"
    oa = rec.get("oauthAccount")
    if oa is not None and not isinstance(oa, dict):
        return False, "oauthAccount is not an object"
    for pk in ("organizationType",):
        pv = (oa or {}).get(pk)
        if pv is not None and not isinstance(pv, str):
            return False, f"oauthAccount.{pk} is not a string"
    oauth = rec.get("claudeAiOauth")
    sub = (oauth or {}).get("subscriptionType") if isinstance(oauth, dict) else None
    if sub is not None and not isinstance(sub, str):
        return False, "subscriptionType is not a string"
    # A needs-relogin record is allowed to carry a dead/absent token, but the
    # object it does carry must still be shaped correctly if present.
    if status == "needs-relogin":
        if oauth is not None and not isinstance(oauth, dict):
            return False, "claudeAiOauth is not an object"
        return True, ""
    if not valid_oauth(oauth):
        return False, "claudeAiOauth missing/invalid (need accessToken+refreshToken+numeric expiresAt)"
    return True, ""


def load_bank_record(path, expected_email="__from_filename__"):
    """Load + validate a bank record. NEVER raises. On any problem returns a
    BankRecord with ok=False and a reason; if the file at least parsed as a dict
    the .record is preserved so a caller can safely rewrite it WITHOUT losing the
    unrelated keys it already holds (this is what stops a malformed record from
    being silently destroyed — findings 39/54).

    expected_email defaults to the filename stem; pass None to skip the identity
    check, or an explicit address to require it."""
    if expected_email == "__from_filename__":
        expected_email = _filename_email(path)
    try:
        with open(path) as f:
            rec = json.load(f)
    except FileNotFoundError:
        return BankRecord(False, None, None, None, None, None, "file not found", path)
    except Exception as e:
        return BankRecord(False, None, None, None, None, None,
                          f"unparseable ({type(e).__name__})", path)
    if not isinstance(rec, dict):
        return BankRecord(False, None, None, None, None, None, "not a JSON object", path)
    ok, reason = validate_bank_record(rec, expected_email)
    if not ok:
        return BankRecord(False, rec, None, None, None, None, reason, path)
    oauth = rec.get("claudeAiOauth") if isinstance(rec.get("claudeAiOauth"), dict) else None
    plan = (rec.get("oauthAccount") or {}).get("organizationType")
    return BankRecord(True, rec, rec.get("email"), oauth, rec.get("status", "ok"), plan, "", path)


def error_account_entry(email, reason, provider="claude"):
    """A non-eligible, explicitly-errored usage entry for a record that failed
    validation. Surfaced so a malformed record CHANGES nothing silently — it is
    visible, and autopick.eligible() rejects it (has an error, no worst_limit)."""
    return {"provider": provider, "email": email, "active": False,
            "five_hour": None, "seven_day": None, "worst_limit": None, "model_cap": None,
            "status": "error", "error": f"invalid bank record: {reason}",
            "plan": None}


# --------------------------------------------------------------------------- #
# SINGLE fail-closed identity primitive (r5 #1/#4/#6)
# --------------------------------------------------------------------------- #
# The three round-5 blockers (#1 empty-fingerprint kc_write bypass, #4 ping/usage
# stamping/attributing the wrong account, #6 same-plan bank overwrite) are one
# disease: mutating consumers established credential identity ad-hoc, and each
# gap failed OPEN. resolve_identity() is the ONE primitive every mutating consumer
# now routes through. It answers exactly one question — "which banked account does
# the credential CURRENTLY live in the keychain belong to?" — and answers it only
# when the answer is unambiguous. Every other state is UNRESOLVED, and the contract
# for callers is: UNRESOLVED => fail closed (do not attribute quota, stamp a
# cooldown, mark a status ok, or overwrite a credential).
def _current_fp_matches(bank_dir, live_fp):
    """Emails of the banked accounts whose CURRENT stored credential fingerprint
    equals live_fp. Only VALID bank records participate (a malformed record has no
    trustworthy identity and its fingerprint "" can never match). Deterministic
    order. Never raises."""
    out = []
    if not live_fp:
        return out
    try:
        files = sorted(glob.glob(os.path.join(bank_dir, "*.json")))
    except Exception:
        return out
    for f in files:
        br = load_bank_record(f)
        if not br.ok:
            continue
        fp = cred_fingerprint(br.oauth)
        if fp and fp == live_fp:
            out.append(br.email)
    return out


def fp_owner(bank_dir, blob_or_oauth):
    """The single banked account whose CURRENT credential fingerprint equals the
    given blob's, or None. None when the blob is not a valid credential, matches
    NO current bank record (unknown / drifted / stale-vs-newer token), or matches
    MORE THAN ONE account (ambiguous). This is the fingerprint half of
    resolve_identity, exposed on its own for archive labelling (who owns the
    credential we are about to overwrite) — it does NOT consult metadata."""
    matches = _current_fp_matches(bank_dir, cred_fingerprint(blob_or_oauth))
    return matches[0] if len(matches) == 1 else None


def resolve_identity(bank_dir, live_blob_or_oauth, active_meta_email):
    """Return the owner email of the LIVE keychain credential, or None
    (UNRESOLVED). Fail-closed: returns an email ONLY when ALL hold —
      (a) live_blob_or_oauth is a VALID credential (non-empty fingerprint);
      (b) that fingerprint equals the CURRENT banked credential fingerprint of
          EXACTLY ONE account; and
      (c) active_meta_email (the ~/.claude.json identity) names that same account.
    Everything else is UNRESOLVED: empty/unreadable/invalid keychain, a fingerprint
    that matches no current bank record (an unknown token, OR the active account's
    own token having rotated ahead of / behind its bank record — benign drift is
    still UNRESOLVED by design, because it is offline-indistinguishable from a
    keychain-first /login installing an unbanked account), a fingerprint matching
    more than one account, or metadata that names a different account than the
    fingerprint does. Callers MUST treat None as "do not mutate / do not attribute"."""
    owner = fp_owner(bank_dir, live_blob_or_oauth)
    if owner is None:
        return None
    if not isinstance(active_meta_email, str) or active_meta_email != owner:
        return None
    return owner


# --------------------------------------------------------------------------- #
# never-destroy invariant: archive a credential blob before it is overwritten
# (r5 PRINCIPLE 2)
# --------------------------------------------------------------------------- #
def archive_blob(bank_dir, email, blob, keep=10):
    """Preserve a credential blob about to be overwritten/destroyed to
    <bank_dir>/archive/<email-or-unknown>.<utc-timestamp>.json (0600, fsync'd),
    then prune to the newest `keep` archives for that account. This is the ONE
    shared helper behind PRINCIPLE 2: every path that REPLACES a credential blob
    (bank-record overwrite, keychain overwrite, reconcile restore) archives the
    predecessor here FIRST, so even an unwinnable /login race is recoverable
    instead of fatal.

    `blob` may be a dict/list (JSON-encoded) or a string (written verbatim). A
    blank/None blob is a no-op (returns None — nothing to preserve). `email` is
    sanitized via safe_email; anything unsafe/empty files under "unknown".

    Returns the archive path, or None when nothing was archived. RAISES on a hard
    IO failure (dir uncreatable, write/fsync/rename failed) so a caller can fail
    CLOSED and refuse the overwrite rather than destroy an unarchived predecessor."""
    if blob is None:
        return None
    if isinstance(blob, (dict, list)):
        text = json.dumps(blob, separators=(",", ":"))
    else:
        text = str(blob)
    if not text.strip():
        return None
    label = safe_email(email) if email else None
    if label is None:
        label = "unknown"
    adir = os.path.join(bank_dir, "archive")
    # (r9 #2) whether archive/ already existed decides if we must also fsync bank_dir:
    # on the FIRST archive we create archive/, and fsyncing only that child leaves its
    # DIRENT in bank_dir non-durable. A crash after the caller overwrites the credential
    # (which happens right after this returns) but before bank_dir is synced would lose
    # archive/ entirely — the pre-archive predecessor copy PRINCIPLE 2 promises, gone.
    _adir_created = not os.path.isdir(adir)
    os.makedirs(adir, exist_ok=True)
    try:
        os.chmod(adir, 0o700)
    except OSError:
        pass
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    base = os.path.join(adir, f"{label}.{ts}")
    path = base + ".json"
    n = 0
    while os.path.exists(path):
        n += 1
        path = f"{base}.{n}.json"
    fd, tmp = tempfile.mkstemp(dir=adir, prefix=".arch.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        d = os.open(adir, os.O_RDONLY)
        try:
            os.fsync(d)
        finally:
            os.close(d)
        # (r9 #2) if we just created archive/, its dirent under bank_dir must be durable
        # before the caller overwrites the credential — fsync the parent too.
        if _adir_created:
            pd = os.open(bank_dir, os.O_RDONLY)
            try:
                os.fsync(pd)
            finally:
                os.close(pd)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    # prune: keep the newest `keep` archives for THIS account label only.
    try:
        entries = sorted(
            glob.glob(os.path.join(adir, glob.escape(label) + ".*.json")),
            key=lambda p: os.stat(p).st_mtime, reverse=True)
        for old in entries[keep:]:
            try:
                os.remove(old)
            except OSError:
                pass
    except Exception:
        pass
    return path


if __name__ == "__main__":
    # tiny self-check used by the test harness
    import sys
    if len(sys.argv) >= 2 and sys.argv[1] == "--fingerprint":
        # Read a keychain blob or oauth object on STDIN, print its full-credential
        # fingerprint (findings 11/21). Empty line if it can't be computed. Never
        # echoes the secret. Used by lib.sh kc_write's post-write verification and
        # by swap/reconcile torn-commit detection.
        data = sys.stdin.read()
        sys.stdout.write(cred_fingerprint(data))
        sys.exit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "--resolve-identity":
        # args: <bank_dir> <active_meta_email> ; live keychain blob on STDIN. Prints
        # the RESOLVED owner email + exit 0, else nothing + exit 1 (UNRESOLVED). The
        # single fail-closed identity primitive (r5 #1/#4/#6). Never echoes the secret.
        bank_dir = sys.argv[2]
        meta = sys.argv[3] if len(sys.argv) > 3 else ""
        owner = resolve_identity(bank_dir, sys.stdin.read(), meta)
        if owner is None:
            sys.exit(1)
        sys.stdout.write(owner)
        sys.exit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "--fp-owner":
        # args: <bank_dir> ; blob on STDIN. Prints the single owning account email
        # + exit 0, else nothing + exit 0 (ambiguous/unknown is not an error here —
        # it just means "label the archive 'unknown'"). Never echoes the secret.
        owner = fp_owner(sys.argv[2], sys.stdin.read())
        if owner:
            sys.stdout.write(owner)
        sys.exit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "--archive-blob":
        # args: <bank_dir> <email-or-empty> ; blob on STDIN. Archives the blob before
        # it is overwritten (r5 PRINCIPLE 2). Prints the archive path (empty on no-op).
        # Exit 1 on a hard IO failure so a shell caller can fail closed. Never echoes
        # the secret.
        bank_dir = sys.argv[2]
        email = sys.argv[3] if len(sys.argv) > 3 else ""
        try:
            p = archive_blob(bank_dir, email, sys.stdin.read())
        except Exception as e:
            sys.stderr.write(f"archive_blob: {type(e).__name__}: {e}\n")
            sys.exit(1)
        if p:
            sys.stdout.write(p)
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--selfcheck":
        assert safe_email("a@b.com") == "a@b.com"
        assert safe_email("../etc/passwd") is None
        assert safe_email("a/b@c.com") is None
        assert safe_email(".hidden@x.com") is None
        assert safe_email("a..b@x.com") is None
        assert safe_email("no-at-sign") is None
        assert valid_oauth({"accessToken": "a", "refreshToken": "r", "expiresAt": 1})
        assert not valid_oauth({"accessToken": "a", "refreshToken": "", "expiresAt": 1})
        assert not valid_oauth({"accessToken": "a", "refreshToken": "r", "expiresAt": True})
        # (r3 #13) non-finite expiresAt / refreshTokenExpiresAt rejected
        assert not valid_oauth({"accessToken": "a", "refreshToken": "r", "expiresAt": float("nan")})
        assert not valid_oauth({"accessToken": "a", "refreshToken": "r", "expiresAt": float("inf")})
        assert not valid_oauth({"accessToken": "a", "refreshToken": "r", "expiresAt": 1,
                                "refreshTokenExpiresAt": float("inf")})
        # (r3 #14) a rotation of ONLY refreshTokenExpiresAt changes the fingerprint
        fa = cred_fingerprint({"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "refreshTokenExpiresAt": 10})
        fb = cred_fingerprint({"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "refreshTokenExpiresAt": 20})
        assert fa and fb and fa != fb, "refreshTokenExpiresAt must affect the fingerprint"
        assert not same_credentials(
            {"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "refreshTokenExpiresAt": 10},
            {"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "refreshTokenExpiresAt": 20})
        f1 = cred_fingerprint({"claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 1}})
        f2 = cred_fingerprint({"accessToken": "a", "refreshToken": "r", "expiresAt": 1})
        assert f1 == f2 and f1 != ""
        # rotation of only refreshToken changes the fingerprint
        f3 = cred_fingerprint({"accessToken": "a", "refreshToken": "r2", "expiresAt": 1})
        assert f3 != f1
        # (r5 #1/#4/#6) resolve_identity fail-closed contract, in a temp bank.
        import tempfile as _tf, shutil as _sh
        _bd = _tf.mkdtemp(prefix="bc-selfcheck-")
        try:
            _cred = {"accessToken": "AA", "refreshToken": "rAA", "expiresAt": 1}
            _rec = {"email": "a@x.com", "status": "ok", "banked_at": "x",
                    "claudeAiOauth": _cred, "oauthAccount": {"emailAddress": "a@x.com"}}
            with open(os.path.join(_bd, "a@x.com.json"), "w") as _f:
                json.dump(_rec, _f)
            # (a)+(b)+(c) all hold -> resolves
            assert resolve_identity(_bd, {"claudeAiOauth": _cred}, "a@x.com") == "a@x.com"
            assert fp_owner(_bd, _cred) == "a@x.com"
            # empty/invalid keychain -> UNRESOLVED (this is finding #1's core)
            assert resolve_identity(_bd, "", "a@x.com") is None
            assert resolve_identity(_bd, {}, "a@x.com") is None
            assert fp_owner(_bd, {}) is None
            # metadata names a different account than the fingerprint -> UNRESOLVED (#4)
            assert resolve_identity(_bd, {"claudeAiOauth": _cred}, "b@x.com") is None
            # a drifted / unknown live token matches no current record -> UNRESOLVED (#4/#6)
            _drift = {"accessToken": "AA2", "refreshToken": "rAA", "expiresAt": 1}
            assert fp_owner(_bd, _drift) is None
            assert resolve_identity(_bd, _drift, "a@x.com") is None
            # archive_blob preserves + returns a path; blank blob is a no-op
            _p = archive_blob(_bd, "a@x.com", _cred)
            assert _p and os.path.exists(_p)
            assert archive_blob(_bd, "a@x.com", "") is None
            assert archive_blob(_bd, "a@x.com", None) is None
            # unsafe/empty email files under "unknown"
            _pu = archive_blob(_bd, "", _cred)
            assert _pu and os.path.basename(_pu).startswith("unknown.")
        finally:
            _sh.rmtree(_bd, ignore_errors=True)
        print("bank_common selfcheck OK")
        sys.exit(0)
    sys.exit(0)
