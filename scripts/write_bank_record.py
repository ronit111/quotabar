#!/usr/bin/env python3
"""write_bank_record.py — write/update a bank record atomically.

The keychain blob is read from STDIN (never argv). Other args are non-secret.
Preserves banked_at / last_ping / debounce markers from an existing record.

Hardening (findings #5/#6): the writer now REFUSES to persist a record unless
  - the blob is a fully valid credential (accessToken + refreshToken + numeric
    expiresAt), matching validate_blob.py / lib.sh kc_write, and
  - the active identity metadata (~/.claude.json oauthAccount.emailAddress) equals
    the <email> we are banking.
The second check is what stops one account's keychain credentials being written
under another account's identity when a /login races the capture (finding #5):
the caller captures a stable keychain+metadata snapshot, and if they disagree we
fail loudly instead of binding A's tokens to B.json.

Usage:  <blob-on-stdin> | write_bank_record.py <claude_json> <email> <out> <iso> <epoch>
"""
import sys, json, os, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
import epoch as epoch_mod   # NB: argv[5] below is also named `epoch` (pre-existing)

claude_json, email, out, iso, epoch = sys.argv[1:6]

_bank_dir = os.path.dirname(os.path.abspath(out))

# (finding 21) hold the bank lock across the whole read-modify-write. Callers that
# already hold it (bank-account.sh / swap-account.sh) pass ACCOUNT_BANK_HOLDS_LOCK=1
# so we do NOT re-acquire (mkdir banklock is non-reentrant). Standalone/test callers
# acquire it here. Without the lock, a flip could slip between the entry gate and the
# atomic replace and let a v1 credential-record mutation land in v2.
import banklock as _banklock
# (r12 #11) trust ACCOUNT_BANK_HOLDS_LOCK ONLY when lock ownership is PROVEN (the exported
# ACCOUNT_BANK_LOCK_TOKEN matches the on-disk owner). A caller that merely sets the flag
# without holding the lock fails the check and falls through to self-acquire below, so it
# can NEVER mutate a credential record without a real physical lock.
_held = (os.environ.get("ACCOUNT_BANK_HOLDS_LOCK") == "1"
         and _banklock.verify_caller_holds(_bank_dir))
_wbr_lock = None
if not _held:
    _wbr_lock = _banklock.BankLock(_bank_dir)
    if not _wbr_lock.acquire(timeout=int(os.environ.get("ACCOUNT_BANK_LOCK_WAIT", "10") or "10")):
        sys.stderr.write("write_bank_record: could not acquire bank lock; record UNCHANGED\n")
        sys.exit(1)

_wbr_released = False
def _release_wbr_lock():
    global _wbr_released
    if _wbr_lock is not None and not _wbr_released:
        _wbr_released = True
        _wbr_lock.release()
import atexit as _atexit
_atexit.register(_release_wbr_lock)   # release on EVERY exit path (all the gates below)

# (v2 rev6 §8) v1 bank-record credential writes are gated exactly like keychain
# writes: state v1|shadow AND no SEEDING freeze. rc 78, record untouched.
try:
    epoch_mod.v1_gate(_bank_dir)
    # (finding 21) capture the EXACT epoch at entry; re-fence immediately before the
    # atomic replace so an ABA generation bump (a flip + rollback) is caught too.
    _epoch_snap = epoch_mod.read_epoch(_bank_dir)
except epoch_mod.EpochFenced as e:
    sys.stderr.write(f"write_bank_record: epoch gate refused ({e}); record UNCHANGED\n")
    _release_wbr_lock()
    sys.exit(epoch_mod.EXIT_FENCED)
except epoch_mod.EpochError as e:
    sys.stderr.write(f"write_bank_record: EPOCH unreadable ({e}); record UNCHANGED\n")
    _release_wbr_lock()
    sys.exit(epoch_mod.EXIT_FENCED)
raw = sys.stdin.read()
if not raw.strip():
    sys.stderr.write("write_bank_record: empty blob on stdin\n"); sys.exit(1)
try:
    blob = json.loads(raw)
except Exception as e:
    sys.stderr.write(f"write_bank_record: blob not JSON ({e})\n"); sys.exit(1)

# path-safety: the email must be a safe filename component AND match `out`.
if bank_common.safe_email(email) is None:
    sys.stderr.write(f"write_bank_record: unsafe email '{email}'\n"); sys.exit(1)
if os.path.basename(out) != f"{email}.json":
    sys.stderr.write(f"write_bank_record: out path '{out}' does not match email '{email}'\n"); sys.exit(1)

oauth = blob.get("claudeAiOauth") if isinstance(blob, dict) else None
# FULL credential validation (finding #6): a blob with an access token but no
# refresh token / no numeric expiry must NOT be written as status ok.
if not bank_common.valid_oauth(oauth):
    sys.stderr.write("write_bank_record: blob is not a complete credential "
                     "(need accessToken+refreshToken+numeric expiresAt)\n")
    sys.exit(1)

try:
    cj = json.load(open(claude_json)); oauth_account = cj.get("oauthAccount") or {}
except Exception:
    oauth_account = {}
if not isinstance(oauth_account, dict):
    oauth_account = {}

# identity match (findings #5/#6): metadata email must equal the banked email.
meta_email = oauth_account.get("emailAddress")
if meta_email != email:
    sys.stderr.write(
        f"write_bank_record: REFUSING to write — active identity metadata "
        f"({meta_email!r}) does not match the account being banked ({email!r}). "
        f"A /login likely raced the capture; re-run.\n")
    sys.exit(2)

# (r3 #2) BEST-EFFORT identity cross-check. The keychain blob carries no offline,
# verifiable binding to the metadata email, so a /login's keychain-first transition
# (keychain already holds account B, metadata still names A, both stable across
# repeated reads) can bind B's tokens to A.json and destroy A's good bank copy.
# That cannot be fully prevented at this layer (see the residual note below), but a
# PLAN mismatch is a positive tell of crossed identities: the credential's
# subscriptionType must be consistent with the metadata's organizationType
# (max<->claude_max, pro<->claude_pro, free<->free). When they disagree we refuse,
# turning a silent cross-identity write into a loud, safe failure.
#   RESIDUAL (documented, unfixable-at-this-layer): two SAME-plan accounts racing a
#   /login cannot be distinguished by plan; the caller's stable keychain+metadata
#   snapshot (bank-account.sh) plus the expected-fingerprint gate below narrow but
#   do not eliminate that window. A JWT-subject decode was considered and rejected
#   as too fragile to make load-bearing without the ability to validate against a
#   real token's claim structure.
def _plan_tier(s):
    s = (s or "").lower()
    if "max" in s: return "max"
    if "pro" in s: return "pro"
    if "free" in s: return "free"
    return ""
_sub = oauth.get("subscriptionType") if isinstance(oauth, dict) else None
_org = oauth_account.get("organizationType")
_ts, _to = _plan_tier(_sub), _plan_tier(_org)
if _ts and _to and _ts != _to:
    sys.stderr.write(
        f"write_bank_record: REFUSING — the credential plan ({_sub!r}) is inconsistent "
        f"with the active identity's organizationType ({_org!r}). A /login likely crossed "
        f"identities (keychain-first transition). Re-run once the login settles.\n")
    sys.exit(2)

# OPTIONAL expected-fingerprint gate (re-review issue 11): callers that captured a
# stable keychain snapshot pass its credential fingerprint as argv[6]; we refuse
# unless the blob we're about to write still matches it, so a raced /login can't
# get one account's credential attributed to another's record.
expected_fp = sys.argv[6] if len(sys.argv) > 6 else ""
if expected_fp:
    if bank_common.cred_fingerprint(blob) != expected_fp:
        sys.stderr.write("write_bank_record: REFUSING — blob fingerprint does not match the "
                         "caller's captured snapshot (a /login likely raced the capture).\n")
        sys.exit(2)

# Route the existing record through the VALIDATED loader (issue 10). If a record
# already exists but is INVALID (unparseable / schema failure / email mismatch),
# REFUSE rather than silently reset it to {} and overwrite — that would mask
# corruption and could discard fields. ACCOUNT_BANK_FORCE_REBANK=1 overrides for a
# deliberate recovery overwrite.
prev = {}
if os.path.exists(out):
    br = bank_common.load_bank_record(out, expected_email=email)
    if br.ok:
        prev = br.record
    elif os.environ.get("ACCOUNT_BANK_FORCE_REBANK") == "1":
        prev = br.record if isinstance(br.record, dict) else {}
        sys.stderr.write(f"write_bank_record: existing record invalid ({br.reason}); "
                         f"FORCE_REBANK set — overwriting.\n")
    else:
        sys.stderr.write(f"write_bank_record: REFUSING — existing record is invalid "
                         f"({br.reason}). Move it aside or set ACCOUNT_BANK_FORCE_REBANK=1.\n")
        sys.exit(3)

record = {
    "email": email,
    "banked_at": prev.get("banked_at", iso),
    "banked_at_epoch": prev.get("banked_at_epoch", int(epoch)),
    "status": "ok",
    "last_verified": iso,
    "last_ping": prev.get("last_ping", 0),
    "claudeAiOauth": oauth,
    "oauthAccount": oauth_account,
}
# Preserve the auto-ping debounce state across a re-bank (finding #15): dropping
# last_autoping / last_ping_failed would re-enable an early retry right after a
# failed or in-flight detached ping. stagger_hold_since is preserved too so the
# 2.5h phase-stagger cap survives a re-bank/restart. Only carry them forward if
# they existed.
for _k in ("last_autoping", "last_ping_failed", "stagger_hold_since"):
    if _k in prev:
        record[_k] = prev[_k]
dirn = os.path.dirname(out) or "."
# (r5 #6, PRINCIPLE 2) NEVER-DESTROY: before this atomic replace overwrites an
# existing record's credential, archive the predecessor blob. The same-plan
# keychain-first /login race (documented above) cannot be fully prevented at this
# layer — but archiving A's real credential FIRST turns "B′ silently destroys A"
# into a recoverable event (A survives in <bank_dir>/archive/). Fail CLOSED: if the
# predecessor cannot be durably archived, REFUSE the overwrite rather than destroy
# it unarchived. Only archive when a DIFFERENT valid credential is being replaced
# (a no-op re-bank of the same creds needs no archive).
# (r2 finding 21) EXACT generation fence BEFORE the FIRST durable mutation — which is
# the predecessor archival, not the atomic replace. If the epoch moved at all since
# entry (a flip, even flip-and-rollback), refuse before touching anything on disk.
try:
    epoch_mod.fence(_bank_dir, _epoch_snap, ("v1", "shadow"))
except epoch_mod.EpochFenced as e:
    sys.stderr.write(f"write_bank_record: epoch moved before write ({e}); record UNCHANGED\n")
    sys.exit(epoch_mod.EXIT_FENCED)
prev_oauth = prev.get("claudeAiOauth") if isinstance(prev, dict) else None
if bank_common.valid_oauth(prev_oauth) and \
        bank_common.cred_fingerprint(prev_oauth) != bank_common.cred_fingerprint(oauth):
    try:
        bank_common.archive_blob(dirn, email, {"claudeAiOauth": prev_oauth})
    except Exception as e:
        sys.stderr.write("write_bank_record: REFUSING — could not archive the existing "
                         f"credential before overwrite ({type(e).__name__}); not destroying it.\n")
        sys.exit(4)
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
with os.fdopen(fd, "w") as f:
    json.dump(record, f, indent=2)
    f.flush(); os.fsync(f.fileno())
os.chmod(tmp, 0o600)
os.replace(tmp, out)
d = os.open(dirn, os.O_RDONLY)
try:
    os.fsync(d)
finally:
    os.close(d)
