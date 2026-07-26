#!/usr/bin/env python3
"""seedflow.py — home seeding transaction with durable phase journal (rev 6 §7).

Interactive (owner present): claude-acct --add is a thin wrapper over
    seedflow.py add <email>
The transaction (per the design):
  1. quiesce checklist (owner confirms each item) + SEEDING freeze published under
     the FULL ordered barrier with an EPOCH generation increment
  2. stage the home skeleton under homes/.staging/<safe-email>/ (state matrix,
     seed audit log)
  3. keychain snapshot -> durable archive -> fingerprint F0
  4. CLAUDE_CONFIG_DIR=<staged home> claude /login   (browser dance, owner)
  5. G5 branch: home-file (preferred; harvest branch deleted if G5 proves it) or
     keychain-harvest under CAS discipline
  6. verification turn + G9 identity -> atomic publication (fsync tree -> rename ->
     parent fsync -> READY registry commit LAST) -> unfreeze (generation increment)

Phase journal (tier-1 writes to accounts/.seeding.json):
  QUIESCED -> LOGIN_STARTED -> [HOME_WRITTEN | HARVEST_READ -> HOME_WRITTEN ->
  RESTORE_STARTED -> RESTORED] -> VERIFIED -> PUBLISHED
with {txn, email, pgid, fp_F0, fp_L, phase, ts}. Stale recovery (recover cmd):
full barrier, entire pgid provably dead, then per-phase rules; retains the freeze
+ operator card whenever keychain state is unproven. stdlib only.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import uuid as uuidlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
import banklock
import epoch
import homewrite
import identity
import registry

MARKER = ".seeding.json"
RESERVED = {"accounts"}          # the control plane is NEVER projected (§6)
PER_HOME = {".credentials.json", ".claude.json", "backups", "archive"}
SAFE_PHASES_FOR_CLEAR = {"RESTORED", "VERIFIED", "PUBLISHED"}


def restore_action(fp_f0, f0_archive_exists):
    """(r3 IB2) Decide how the harvest branch restores the shared keychain slot, keyed on
    the JOURNALED F0 fingerprint — NOT on whether the archive file happens to exist:
      * fp_F0 == "<empty>"                 -> "delete"      (original slot was empty)
      * nonempty fp_F0 + archive present   -> "restore"     (write F0 back from archive)
      * nonempty fp_F0 + archive MISSING   -> "fail-closed" (NEVER delete a real harvested
                                              credential to "restore" a slot we can't produce)
    Pure + non-interactive so the decision is unit-testable without the keychain."""
    if fp_f0 == "<empty>":
        return "delete"
    if f0_archive_exists:
        return "restore"
    return "fail-closed"

# (finding 3) the ONLY legal phase transitions. _set_phase refuses anything else,
# so a stale/concurrent `phase` command can never overwrite newer state with an
# out-of-order write, and the two G5 arms are the only accepted shapes.
TRANSITIONS = {
    "QUIESCED": {"LOGIN_STARTED"},
    "LOGIN_STARTED": {"HOME_WRITTEN", "HARVEST_READ"},
    "HARVEST_READ": {"HOME_WRITTEN"},
    "HOME_WRITTEN": {"RESTORE_STARTED", "VERIFIED"},
    "RESTORE_STARTED": {"RESTORED"},
    "RESTORED": {"VERIFIED"},
    "VERIFIED": {"PUBLISHED"},
    "PUBLISHED": set(),
}


def safe_email(email):
    return bank_common.safe_email(email)


def config_slot_service(config_dir):
    """(G5c, verified live 2026-07-22 on CLI 2.1.217) The CLI keychains per-config-dir
    credentials under service 'Claude Code-credentials-<sha256(config_dir)[:8]>' — the
    bare 'Claude Code-credentials' default slot is only the no-CONFIG_DIR world's. A
    staged-home /login therefore lands in the STAGED PATH's slot, not the default one."""
    import hashlib
    return "Claude Code-credentials-" + hashlib.sha256(
        str(config_dir).encode()).hexdigest()[:8]


def _fake_slot_path(fake, service):
    """Per-service fake-keychain file for tests: '<fake>.svc-<suffix>'."""
    return fake + ".svc-" + service.rsplit("-", 1)[-1]


def _sh_keychain_delete(service):
    """Delete a keychain slot (G5c staging-slot hygiene). rc 44 (not found) is success.
    Fake-keychain aware; absolute security binary per (r14 #2)."""
    fake = os.environ.get("ACCOUNT_BANK_FAKE_KEYCHAIN")
    if fake:
        try:
            os.remove(_fake_slot_path(fake, service))
        except FileNotFoundError:
            pass
        return True
    _sec = os.environ.get("ACCOUNT_BANK_SECURITY_BIN", "/usr/bin/security")
    r = subprocess.run([_sec, "delete-generic-password", "-s", service],
                       capture_output=True, text=True)
    return r.returncode in (0, 44)


def _sh_keychain_read(service=None):
    """Read a keychain slot (the shared default slot, or `service` — e.g. a per-config-dir
    G5c slot); returns (blob-dict-or-None, raw-or-None, status).

    status is three-valued and NEVER conflates "slot genuinely empty" with "read
    failed" (r8 #1 — fail-closed, the same disease as the ps-probe empty sentinel):
      * "present" — the slot holds a credential (blob parsed, or raw for non-JSON).
      * "absent"  — the slot is provably empty (`security` rc 44 == errSecItemNotFound,
                    or, in tests, the fake keychain file simply does not exist).
      * "error"   — the read could not be performed (keychain locked/denied/other
                    nonzero rc, or the fake file was unreadable). Callers must treat
                    this as UNKNOWN: freeze ABORTS, unfreeze REFUSES, recovery RETAINS.
                    It must NEVER collapse to fp_F0="<empty>" (that later drives a
                    restore→delete of a real harvested credential, or a false clear).

    Tests set ACCOUNT_BANK_FAKE_KEYCHAIN=<file> so no test ever touches the real
    slot; ACCOUNT_BANK_FAKE_KEYCHAIN_MODE=error deterministically simulates a locked/
    denied read without needing the real keychain."""
    fake = os.environ.get("ACCOUNT_BANK_FAKE_KEYCHAIN")
    if fake:
        if os.environ.get("ACCOUNT_BANK_FAKE_KEYCHAIN_MODE") == "error":
            return None, None, "error"          # simulated locked/denied read
        if service is not None:
            fake = _fake_slot_path(fake, service)
        if not os.path.exists(fake):
            return None, None, "absent"         # no file == empty slot
        try:
            raw = open(fake).read()
        except Exception:
            return None, None, "error"          # present but unreadable == read failure
        if raw == "":
            return None, None, "absent"
        try:
            return json.loads(raw), raw, "present"
        except ValueError:
            return None, raw, "present"         # non-JSON blob is still a present credential
    # (r14 #2) ABSOLUTE /usr/bin/security — NEVER resolve `security` via PATH on the
    # credential path: a PATH-prepended proxy named `security` would exfiltrate the F0
    # OAuth blob. The ACCOUNT_BANK_SECURITY_BIN override is owner-set (tests), not a PATH
    # hijack; default is the absolute system path.
    _sec = os.environ.get("ACCOUNT_BANK_SECURITY_BIN", "/usr/bin/security")
    _svc = service if service is not None else "Claude Code-credentials"
    _cmd = [_sec, "find-generic-password", "-s", _svc]
    if service is None:
        _cmd += ["-a", os.environ.get("USER", "")]   # per-dir slots use no account attr
    r = subprocess.run(_cmd + ["-w"], capture_output=True, text=True)
    if r.returncode == 0:
        try:
            return json.loads(r.stdout), r.stdout, "present"
        except ValueError:
            return None, r.stdout, "present"
    if r.returncode == 44:                       # errSecItemNotFound: provably empty slot
        return None, None, "absent"
    return None, None, "error"                    # locked / denied / other: UNKNOWN, fail-closed


def _fp(blob):
    """Credential fingerprint via bank_common (same primitive the fence uses)."""
    if not isinstance(blob, dict):
        return ""
    o = blob.get("claudeAiOauth", blob)
    return bank_common.cred_fingerprint(o) if hasattr(bank_common, "cred_fingerprint") \
        else json.dumps({k: o.get(k) for k in
                         ("accessToken", "refreshToken", "expiresAt")}, sort_keys=True)


def _slot_fingerprint(blob, raw, status):
    """(r10 #10) The canonical F0 / live-slot fingerprint. A PRESENT slot is NEVER
    collapsed to "<empty>" just because it is malformed/falsy:
      * absent                          -> "<empty>"  (provably empty slot only)
      * present + valid non-empty blob  -> _fp(blob)  (the normal credential fingerprint)
      * present + unparseable/empty-dict -> "raw:"+sha256(raw) (a stable non-empty id)
    "error" is never passed here (callers abort/retain on it). This is what stops a
    present-but-`{}`/non-JSON slot from being fingerprinted "<empty>", which would make
    restore_action DELETE it instead of restoring the archived original bytes."""
    if status != "present":
        return "<empty>"
    if isinstance(blob, dict) and blob:
        return _fp(blob)
    import hashlib
    return "raw:" + hashlib.sha256((raw or "").encode()).hexdigest()


# ---- credential SEAT abstraction (G5c) --------------------------------------
# A home's credential lives in ONE of two SEATS:
#   * "file" — <home>/.credentials.json (pre-launch / never-migrated seeding state), or
#   * "slot" — the per-config-dir keychain slot config_slot_service(home), which the CLI
#              MIGRATES the file into (and DELETES the file) on the home's first pinned launch.
# From then on the SLOT is the seat. This module is the ONE source of truth every consumer
# (usage, archiver, homerec, gate-g8) uses so file-vs-slot is decided in exactly one place.

def _sh_keychain_write(service, raw):
    """(seat) Write a raw credential blob into keychain slot `service`. Fake-aware; ABSOLUTE
    security binary (r14 #2); the blob travels through `security -i` STDIN (never argv, so it is
    not visible to same-user `ps`). `raw` must be compact (no whitespace). Returns True on ok."""
    fake = os.environ.get("ACCOUNT_BANK_FAKE_KEYCHAIN")
    if fake:
        try:
            with open(_fake_slot_path(fake, service), "w") as f:
                f.write(raw)
            return True
        except Exception:
            return False
    _sec = os.environ.get("ACCOUNT_BANK_SECURITY_BIN", "/usr/bin/security")
    # (seat live-fix) `security -i` requirements found at the first REAL slot write (the
    # fake keychain could not catch this): -a is REQUIRED by add-generic-password, and a
    # raw JSON blob's quotes break -i tokenization — the value must be a double-quoted
    # token with backslash-escaped backslashes/quotes. Validated live: -U updates in
    # place and reads back byte-identical. (Matches the CLI's own items: acct=$USER.)
    _esc = raw.strip().replace("\\", "\\\\").replace('"', '\\"')
    cmd = 'add-generic-password -U -a "%s" -s "%s" -w "%s"\n' % (
        os.environ.get("USER", ""), service, _esc)
    r = subprocess.run([_sec, "-i"], input=cmd, capture_output=True, text=True)
    return r.returncode == 0


def seat_read(home):
    """(seat) Read a home's credential SEAT. Returns (blob-dict|None, raw|None, status, kind):
    status is 'present'|'absent'|'error'; kind is 'file'|'slot'|'none'. Precedence: a present,
    non-empty FILE is the seat; else the per-config-dir SLOT; else none. This makes a
    file->slot MIGRATION a seat CHANGE (kind flips file->slot), never a lost credential."""
    cred = os.path.join(home, ".credentials.json")
    if os.path.exists(cred):
        try:
            raw = open(cred).read()
        except Exception:
            return None, None, "error", "file"
        if raw.strip() != "":
            try:
                return json.loads(raw), raw, "present", "file"
            except ValueError:
                return None, raw, "present", "file"
        # empty file is not a usable seat -> fall through to the slot
    blob, raw, status = _sh_keychain_read(service=config_slot_service(home))
    if status == "present":
        return blob, raw, "present", "slot"
    if status == "error":
        return None, None, "error", "slot"
    return None, None, "absent", "none"


def seat_read_forms(home):
    """(v102-r2, seat) Read BOTH seat forms INDEPENDENTLY: {"file": (blob, raw, status),
    "slot": (blob, raw, status)}.

    seat_read answers "which credential does this home use?" and returns exactly one seat, by
    precedence. Un-seeding asks the other question — "what will be destroyed?" — and
    seat_delete's answer is BOTH forms, unconditionally, because a home interrupted mid-
    migration legitimately has a file the CLI has not yet removed alongside the slot it has
    already written. Archiving through seat_read therefore preserved the FILE (precedence) and
    then destroyed a SLOT that, in exactly that interrupted state, holds the NEWER credential.

    Two reads, two archives, no precedence: the never-destroy rule applies per seat, not per
    home. `status` is the same three-valued one everywhere else — an "error" on either form is
    UNKNOWN and its caller fails closed."""
    cred = os.path.join(home, ".credentials.json")
    file_seat = (None, None, "absent")
    if os.path.exists(cred):
        try:
            raw = open(cred).read()
        except Exception:
            file_seat = (None, None, "error")
        else:
            if raw.strip() == "":
                file_seat = (None, None, "absent")      # an empty file is not a credential
            else:
                try:
                    file_seat = (json.loads(raw), raw, "present")
                except ValueError:
                    file_seat = (None, raw, "present")  # non-JSON is still a present credential
    return {"file": file_seat, "slot": _sh_keychain_read(service=config_slot_service(home))}


def seat_fingerprint(home):
    """(seat) Stable fingerprint of the home's current seat content, or None when the seat read
    ERRORED (UNKNOWN — callers fail-closed). '<empty>' for a provably-absent seat."""
    blob, raw, status, _kind = seat_read(home)
    if status == "error":
        return None
    return _slot_fingerprint(blob, raw, status)


def _seat_archive_current(home, reason):
    """(seat) Never-destroy: durably archive the home's CURRENT seat content into <home>/archive/
    before it is overwritten (the slot-seat analogue of homewrite.archive_predecessor). No-op when
    the seat is absent. Raises on a hard IO failure so the caller can fail closed."""
    _blob, raw, status, _kind = seat_read(home)
    if status != "present" or not raw:
        return None
    rawb = raw.encode() if isinstance(raw, str) else raw
    adir = os.path.join(home, "archive")
    os.makedirs(adir, exist_ok=True)
    os.chmod(adir, 0o700)
    dest = os.path.join(
        adir, f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{os.getpid()}-"
              f"{time.monotonic_ns():016x}-seat-{reason}.json")
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(rawb)
        f.flush()
        os.fsync(f.fileno())
    dfd = os.open(adir, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return dest


def seat_write(home, oauth, reason, expected_email=None, identity_check=None):
    """(seat) Write `oauth` (the claudeAiOauth dict) to the home's EXISTING seat: the keychain
    SLOT if the seat is a slot, the FILE otherwise (file seat OR neither — matching pre-launch
    seeding state; the CLI migrates it to the slot on first launch). Same never-destroy +
    identity discipline as homewrite: schema-valid required; expected_email/identity_check gate
    the commit (True required; False=foreign refused; None=INDETERMINATE refused); the current
    seat content is pre-archived first. Returns the seat kind written ('file'|'slot')."""
    _b, _r, _st, kind = seat_read(home)
    if kind == "slot":
        if not bank_common.valid_oauth(oauth):
            raise RuntimeError("seat_write: refusing a schema-invalid credential")
        if expected_email is not None:
            ic = identity_check
            if ic is None:
                ic = lambda tok: identity.verify_owner(tok, expected_email)  # noqa: E731
            owned, detail = ic(oauth.get("accessToken", ""))
            if owned is None:
                raise RuntimeError(f"seat_write: identity INDETERMINATE ({getattr(detail,'detail',detail)}); refused")
            if owned is False:
                raise RuntimeError("seat_write: credential belongs to a DIFFERENT account; refused")
        _seat_archive_current(home, reason)   # never-destroy the predecessor first
        raw = json.dumps({"claudeAiOauth": oauth}, separators=(",", ":"))
        if not _sh_keychain_write(config_slot_service(home), raw):
            raise RuntimeError("seat_write: slot write failed")
        return "slot"
    # file seat (or none): tier-1 file writer (pre-archive + identity gate live inside it)
    homewrite.write_credential(home, oauth, reason, expected_email=expected_email,
                               identity_check=identity_check)
    return "file"


def seat_delete(home, expect_slot=None):
    """(v102, seat) Remove a home's credential from BOTH possible seats — the counterpart of
    seat_write, used by un-seeding. Returns {"file_removed": bool, "slot_deleted": bool}.

    (v102-r2) `expect_slot` is the caller's independently-derived slot service name, and a
    mismatch RAISES. The slot is keyed on the home path STRING, so a caller that verified one
    spelling of the home and then handed us another would silently delete a different account's
    grant — un-seed cross-checks its verified target against this module's derivation here
    rather than trusting that the two agree.

    Deliberately NOT seat_read-precedence-driven. seat_read names the ONE authoritative seat;
    un-seeding needs the opposite guarantee — that no copy of this home's credential is left
    behind anywhere — and a home mid-migration can legitimately have a file the CLI has not
    yet removed alongside a slot it has already written. So: delete the file if present, and
    clear the per-config-dir slot unconditionally (the keychain delete treats "not found" as
    success, so clearing an already-empty slot is a clean no-op).

    Archiving is the CALLER's responsibility and must happen first — this destroys.
    Raises on a file unlink that fails, so a caller can fail closed; a failed SLOT delete is
    reported as slot_deleted=False rather than raised (the keychain can be locked, and the
    caller decides whether that blocks the rest of the operation)."""
    slot = config_slot_service(home)
    if expect_slot is not None and expect_slot != slot:
        raise RuntimeError(f"seat_delete: the caller's verified slot ({expect_slot}) is not the "
                           f"one this home derives ({slot}); refusing to delete a slot nobody "
                           f"verified")
    out = {"file_removed": False, "slot_deleted": False}
    cred = os.path.join(home, ".credentials.json")
    if os.path.exists(cred):
        os.remove(cred)
        out["file_removed"] = True
    out["slot_deleted"] = bool(_sh_keychain_delete(slot))
    return out


# ---- barrier + journal ------------------------------------------------------
def _ordered_locks(acc):
    """bank -> pointer -> homes lexicographic (§8 total order). Returns acquired
    lock objects in order; caller releases in reverse."""
    locks = []
    bank = banklock.BankLock(acc)
    if not bank.acquire(timeout=15):
        raise RuntimeError("bank lock contended")
    locks.append(bank)
    ptr = banklock.BankLock(acc)
    ptr.lock_dir = os.path.join(acc, ".pointer.lock")
    ptr.owner = os.path.join(ptr.lock_dir, "owner")
    ptr.reclaim_dir = os.path.join(acc, ".pointer.lock.reclaim")
    if not ptr.acquire(timeout=15):
        bank.release()
        raise RuntimeError("pointer lock contended")
    locks.append(ptr)
    homes_root = os.path.join(acc, "homes")
    if os.path.isdir(homes_root):
        for name in sorted(os.listdir(homes_root)):
            h = os.path.join(homes_root, name)
            if not os.path.isdir(h) or name == ".staging":
                continue
            hl = banklock.BankLock(h)
            if not hl.acquire(timeout=15):
                for l in reversed(locks):
                    l.release()
                raise RuntimeError(f"home lock contended: {name}")
            locks.append(hl)
    return locks


def _release(locks):
    for l in reversed(locks):
        try:
            l.release()
        except Exception:
            pass


def _journal_write(acc, rec):
    fd, tmp = tempfile.mkstemp(dir=acc, prefix=".seedj.")
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(acc, MARKER))
    dfd = os.open(acc, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def _journal_read(acc):
    p = os.path.join(acc, MARKER)
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {"phase": "UNREADABLE"}


def _bank_lock(acc):
    """The bank lock — serializes phase read-modify-writes (finding 3). Distinct
    from the full barrier freeze/recover take; _set_phase runs OUTSIDE the barrier."""
    return banklock.BankLock(acc)


# (r2 finding 3) fields _set_phase controls itself — a CLI/`extra` writer may NEVER
# override them (that is how a stale caller would rewrite txn/seq/phase and defeat the
# transition + txn validation).
_PHASE_PROTECTED = frozenset({"txn", "seq", "phase", "ts", "pid", "pgid",
                              "leader_pid", "leader_start", "fp_F0", "f0_archive", "email"})


def _set_phase(acc, rec, phase, expected_txn=None, _locked=False, **extra):
    """Advance the SEEDING journal by exactly one legal transition, serialized under
    the bank lock (finding 3). Refuses if: no journal exists (recovered/cleared);
    the caller's expected txn does not match the live record (stale writer); the
    transition current->phase is not in TRANSITIONS; or `extra` tries to overwrite a
    protected field. The monotonic sequence is incremented on the LIVE record, so two
    writers can never both turn N into N+1. On success `rec` is updated in place.

    (r2 finding 6) `_locked=True` skips the bank-lock acquire for a caller that
    ALREADY holds it (e.g. publication) — the banklock is a non-reentrant mkdir, so
    re-acquiring it would self-deadlock and strand a freshly-READY home frozen."""
    bad = _PHASE_PROTECTED & set(extra)
    if bad:
        raise RuntimeError(f"seeding phase: refusing to override protected fields {sorted(bad)}")
    lk = None
    if not _locked:
        lk = _bank_lock(acc)
        if not lk.acquire(timeout=15):
            raise RuntimeError("seeding phase: bank lock contended")
    try:
        cur = _journal_read(acc)
        if cur is None:
            raise RuntimeError("seeding phase: no journal (recovered/cleared) — refusing")
        want_txn = expected_txn if expected_txn is not None else rec.get("txn")
        if want_txn is not None and cur.get("txn") != want_txn:
            raise RuntimeError("seeding phase: txn mismatch (stale/concurrent writer) — refusing")
        cur_phase = cur.get("phase")
        if phase not in TRANSITIONS.get(cur_phase, set()):
            raise RuntimeError(f"seeding phase: illegal transition {cur_phase!r} -> {phase!r}")
        cur.update(extra)                       # (protected keys already rejected above)
        cur["phase"] = phase                    # controlled fields set LAST — always win
        cur["seq"] = cur.get("seq", 0) + 1      # monotonic sequence on the LIVE record
        cur["ts"] = int(time.time())
        _journal_write(acc, cur)
        rec.clear()
        rec.update(cur)
        return cur
    finally:
        if lk is not None:
            lk.release()


def amend_leader(acc, expected_txn, pgid, leader_pid, leader_start):
    """(r3 MAJOR1) The dedicated setsid child's write-ahead identity amendment, done
    through the SAME locked + txn-checked path as phase writes — not a raw journal
    rewrite. Under the bank lock: verify the live journal's txn matches, then set the
    pgid/leader fields and bump the monotonic sequence. Refuses if the journal is gone
    or belongs to a different transaction."""
    lk = _bank_lock(acc)
    if not lk.acquire(timeout=15):
        raise RuntimeError("amend_leader: bank lock contended")
    try:
        cur = _journal_read(acc)
        if cur is None:
            raise RuntimeError("amend_leader: no journal (recovered/cleared)")
        if cur.get("txn") != expected_txn:
            raise RuntimeError("amend_leader: txn mismatch (stale/concurrent writer)")
        cur["pgid"] = pgid
        cur["leader_pid"] = leader_pid
        cur["leader_start"] = leader_start
        cur["seq"] = cur.get("seq", 0) + 1
        cur["ts"] = int(time.time())
        _journal_write(acc, cur)
        return cur
    finally:
        lk.release()


def amend_orchestrator(acc, expected_txn, orch_pid):
    """(r13 #2) Record the ORCHESTRATOR (the add-account.sh parent process) identity in the
    journal, through the same locked + txn-checked path as amend_leader. The journal otherwise
    tracks only the /login CHILD's pgid/leader; that child DIES when /login exits, while the
    parent keeps running through verification/publication. Recovery must judge liveness by the
    orchestrator, else it clears a LIVE transaction's freeze mid-publication. The start-time is
    read with retries (r8 #2 discipline: an empty start-time is UNKNOWN, never authoritative)."""
    import sessions as _sessions
    ostart = ""
    for _ in range(4):
        ostart = _sessions._proc_start(orch_pid)
        if ostart:
            break
        time.sleep(0.05)
    lk = _bank_lock(acc)
    if not lk.acquire(timeout=15):
        raise RuntimeError("amend_orchestrator: bank lock contended")
    try:
        cur = _journal_read(acc)
        if cur is None:
            raise RuntimeError("amend_orchestrator: no journal (recovered/cleared)")
        if cur.get("txn") != expected_txn:
            raise RuntimeError("amend_orchestrator: txn mismatch (stale/concurrent writer)")
        cur["orch_pid"] = orch_pid
        cur["orch_start"] = ostart
        cur["seq"] = cur.get("seq", 0) + 1
        cur["ts"] = int(time.time())
        _journal_write(acc, cur)
        return cur
    finally:
        lk.release()


def freeze(acc, email):
    """Publish the SEEDING freeze under the full barrier + generation bump.

    r8 ordering: WHILE HOLDING the barrier — snapshot the keychain slot, durably
    archive it (F0 blob), bump the generation, and only then publish the journal
    as one ALREADY-COMPLETE record carrying fp(F0) + the archive path. The pgid /
    leader fields are the single permitted later amendment (armed write-ahead
    before the login spawn); a record missing them recovers as RETAIN."""
    locks = _ordered_locks(acc)
    try:
        if _journal_read(acc) is not None:
            raise RuntimeError("another SEEDING transaction exists; recover first")
        # (r2 new blocker) seeding is `shadow`-ONLY (§8 tool×state matrix): a keychain-
        # touching overlap with v1 mutators or with v2 auto-pick is impossible only if
        # freeze refuses to run outside shadow. Checked inside the barrier.
        st = epoch.read_epoch(acc)
        if st["state"] != "shadow":
            raise RuntimeError(f"seeding requires epoch state 'shadow'; current is {st['state']!r}")
        blob, raw, status = _sh_keychain_read()
        # (r8 #1) a FAILED slot read (locked/denied) must NEVER be journaled as F0.
        # "<empty>" is reserved for a PROVABLY empty slot (status "absent"); an "error"
        # aborts the freeze fail-closed — otherwise restoration later reads "<empty>"
        # and DELETES the harvested credential to "restore" a slot it never actually read.
        if status == "error":
            raise RuntimeError(
                "seeding aborted: keychain slot unreadable (locked/denied) — cannot "
                "snapshot F0 fail-closed; unlock the login keychain and retry")
        # (r10 #10) a PRESENT-but-malformed slot must keep a non-"<empty>" fingerprint so
        # restoration RESTORES the archived raw bytes instead of DELETING them.
        fp_f0 = _slot_fingerprint(blob, raw, status)
        f0_archive = ""
        if raw:
            adir = os.path.join(acc, "archive")
            # (r10 #11) first-seed creates accounts/archive; fsyncing only the child leaves
            # its dirent under `acc` non-durable, so a crash after the journal is published
            # could point it at a lost archive. Track creation and fsync the parent too.
            _adir_created = not os.path.isdir(adir)
            os.makedirs(adir, exist_ok=True)
            os.chmod(adir, 0o700)
            f0_archive = os.path.join(
                adir, f"seed-F0-{int(time.time())}-{os.getpid()}-{time.monotonic_ns():016x}.json")
            fd = os.open(f0_archive, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            dfd = os.open(adir, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
            if _adir_created:                    # (r10 #11) durably root archive/ under acc
                pfd = os.open(acc, os.O_RDONLY)
                try:
                    os.fsync(pfd)
                finally:
                    os.close(pfd)
        epoch.bump(acc)
        # (r2 new blocker) DO NOT record the caller's process group here. The freeze
        # runs in the owner's interactive shell whose PGID may live for hours after an
        # abandoned seed — recording it would make recovery report "holder alive"
        # forever. The ONLY authoritative pgid is the dedicated setsid child's, which
        # it write-ahead journals just before exec (add-account.sh). A record with no
        # pgid therefore means "no child ever armed" and recovers as RETAIN unless it
        # is still QUIESCED with slot == F0 (nothing started).
        rec = {"txn": str(uuidlib.uuid4()), "seq": 1, "email": email,
               "pid": os.getpid(),
               "fp_F0": fp_f0, "f0_archive": f0_archive,
               "phase": "QUIESCED", "ts": int(time.time())}
        _journal_write(acc, rec)
        return rec
    finally:
        _release(locks)


def unfreeze(acc):
    """Normal end-of-seed clear. (finding 2) The universal fp==F0 rule applies to
    EVERY clear, recovery OR normal: re-read the live slot AT CLEAR TIME and refuse
    to remove the marker unless it still equals the journaled F0 (an external
    keychain write after PUBLISHED but before unfreeze must land on an operator, not
    be silently accepted). Removal errors are NOT swallowed, and the parent dir is
    fsync'd so the removal is durable."""
    locks = _ordered_locks(acc)
    try:
        rec = _journal_read(acc)
        if rec is not None:
            # (r2 new blocker) the normal clear is legal ONLY from the terminal phase
            # PUBLISHED. Without this, `unfreeze` could clear during LOGIN_STARTED (F0
            # unchanged) and re-admit v1 while the login child still runs.
            if rec.get("phase") != "PUBLISHED":
                raise RuntimeError(
                    f"unfreeze refused: phase is {rec.get('phase')!r}, not PUBLISHED "
                    "(a normal clear may only happen after successful publication)")
            f0 = rec.get("fp_F0")
            live, live_raw, live_status = _sh_keychain_read()
            # (r8 #1) an unreadable slot at clear time is UNKNOWN, never "<empty>": refuse
            # to clear (a read failure must not falsely satisfy the fp==F0 gate when F0 is
            # itself "<empty>"). Only a proven present/absent read may be compared.
            if live_status == "error":
                raise RuntimeError(
                    "unfreeze refused: keychain unreadable at clear time (locked/denied); "
                    "freeze RETAINED, operator card")
            live_fp = _slot_fingerprint(live, live_raw, live_status)   # (r10 #10)
            if not (isinstance(f0, str) and f0 and live_fp == f0):
                raise RuntimeError(
                    "unfreeze refused: live keychain fingerprint != journaled F0 "
                    "(external slot change during seeding); freeze RETAINED, operator card")
        epoch.bump(acc)
        p = os.path.join(acc, MARKER)
        try:
            os.remove(p)
        except FileNotFoundError:
            pass
        # (finding 2) do not swallow other removal errors — a marker we could not
        # remove is a live freeze, not a silent success.
        dfd = os.open(acc, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        _release(locks)


# ---- skeleton ----------------------------------------------------------------
def build_skeleton(staged, claude_root, audit_path):
    """Symlink every ~/.claude entry per the state matrix; per-home entries are
    real; control plane reserved; unknowns shared + audited."""
    os.makedirs(staged, exist_ok=True)
    os.chmod(staged, 0o700)
    os.makedirs(os.path.join(staged, "backups"), exist_ok=True)
    os.makedirs(os.path.join(staged, "archive"), exist_ok=True)
    audited = []
    for name in sorted(os.listdir(claude_root)):
        if name in RESERVED or name in PER_HOME or name in (".DS_Store",):
            continue
        src = os.path.join(claude_root, name)
        dst = os.path.join(staged, name)
        if os.path.exists(dst) or os.path.islink(dst):
            continue
        os.symlink(src, dst)
        audited.append(name)
    with open(audit_path, "a") as f:
        f.write(json.dumps({"ts": int(time.time()), "linked": audited}) + "\n")
    return audited


def initial_archive(home):
    """(r8 #15) Durably archive the home's just-published credential (C1) into
    <home>/archive/ at seed time — §5/§7 step 6's "initial durable snapshot". The
    READY-only archiver daemon may not have scanned this home yet, and the FIRST CLI
    refresh can replace C1 with C2 before it does; without a seed-time snapshot the
    original grant is lost. G5a (/login wrote the file directly) never went through
    homewrite's pre-archive, so this is the only guaranteed snapshot of C1. Tier-1
    discipline: O_EXCL create + fsync file + fsync dir. Returns the archive path, or
    None if there is no credential to snapshot. Idempotent-safe (unique filename)."""
    cred = os.path.join(home, ".credentials.json")
    if not os.path.exists(cred):
        return None
    with open(cred, "rb") as f:
        raw = f.read()
    adir = os.path.join(home, "archive")
    os.makedirs(adir, exist_ok=True)
    os.chmod(adir, 0o700)
    dest = os.path.join(
        adir, f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{os.getpid()}-"
              f"{time.monotonic_ns():016x}-seed-initial.json")
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
        f.flush()
        os.fsync(f.fileno())
    dfd = os.open(adir, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return dest


# ---- recovery ----------------------------------------------------------------
def _pgid_dead(pgid):
    try:
        os.killpg(pgid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    except Exception:
        return False


def recover(acc):
    """Stale-SEEDING recovery per rev 6 §7. Returns a verdict string; retains the
    freeze whenever keychain state is unproven."""
    if _journal_read(acc) is None:          # cheap early-out, no barrier
        return "no-seeding-transaction"
    locks = _ordered_locks(acc)
    try:
        # (r2 new blocker) RE-READ the journal INSIDE the barrier — it is the
        # authoritative snapshot. Reading before the barrier could clear a stale
        # QUIESCED view after the live record already advanced to LOGIN_STARTED.
        rec = _journal_read(acc)
        if rec is None:
            return "no-seeding-transaction (cleared concurrently)"
        # (r13 #2) ORCHESTRATOR liveness FIRST: the add-account.sh parent runs through
        # verification/publication AFTER the /login child dies. If the orchestrator is ALIVE the
        # transaction is live — leave the freeze alone, regardless of the (dead) login child.
        # Only when the orchestrator is provably DEAD (or was never recorded — old journal) do we
        # fall through to the login-child pgid/phase rules. Empty start-time -> existence probe
        # (r8 #2); UNKNOWN -> fail-closed RETAIN.
        _orch_pid = rec.get("orch_pid")
        if _orch_pid:
            import sessions as _sessions
            _ostart = rec.get("orch_start", "")
            _ostate = _sessions._proc_state(_orch_pid, _ostart if _ostart else None)
            if _ostate == "ALIVE":
                return "holder-alive: seeding orchestrator (add-account.sh) still running"
            if _ostate != "DEAD":
                return ("RETAINED: orchestrator liveness UNKNOWN (ps probe failed); "
                        "operator card (fail-closed)")
            # orchestrator provably DEAD -> proceed to the login-child rules below.
        # (r2 new blocker) pgid liveness applies ONLY when a dedicated child actually
        # recorded its group. A record with no pgid means the setsid child never armed.
        pgid = rec.get("pgid")
        phase = rec.get("phase", "UNREADABLE")

        def _slot_is_f0_early():
            live, live_raw, st = _sh_keychain_read()
            if st == "error":
                return False                     # (r8 #1) unreadable slot never proves F0
            f0 = rec.get("fp_F0")
            live_fp = _slot_fingerprint(live, live_raw, st)   # (r10 #10)
            return isinstance(f0, str) and f0 and live_fp == f0

        if pgid is None:
            # only a truly-not-started transaction is safe to clear.
            if phase == "QUIESCED" and _slot_is_f0_early():
                epoch.bump(acc)
                os.remove(os.path.join(acc, MARKER))
                dfd = os.open(acc, os.O_RDONLY)      # (r3 MINOR2) durable removal
                try:
                    os.fsync(dfd)
                finally:
                    os.close(dfd)
                return "cleared (no child ever armed; QUIESCED + slot == F0)"
            return ("RETAINED: no dedicated pgid recorded (login child never armed / "
                    "phase advanced); operator card")
        if not _pgid_dead(pgid):
            return "holder-alive: leave it alone"
        # (r3 IB1) LEADER IDENTITY IS MANDATORY for EVERY clear, in EVERY phase. The
        # dedicated child writes {pgid, leader_pid, leader_start} atomically before it
        # execs /login, so a record that HAS a pgid but is MISSING leader identity is a
        # torn/ambiguous journal — rev 9 requires ambiguity to RETAIN, full stop. This
        # covers RESTORED/VERIFIED/PUBLISHED too (a dead pgid + matching F0 is NOT
        # sufficient to clear without a matched-dead leader).
        lp, ls = rec.get("leader_pid"), rec.get("leader_start", "")
        if not (lp and ls):
            return ("RETAINED: pgid recorded but leader identity missing "
                    "(torn/ambiguous journal); operator card")
        import sessions as _sessions
        # (r6 b5) three-valued leader liveness: the old `_proc_start(lp) == ls` read a
        # FAILED start-time probe (which returns "") as death — ""!=ls cleared the freeze
        # on a transient ps failure. Require POSITIVE death; ALIVE or UNKNOWN both RETAIN
        # (fail-closed: never clear a SEEDING freeze on an unproven leader).
        _lstate = _sessions._proc_state(lp, ls)
        if _lstate != "DEAD":
            if _lstate == "ALIVE":
                return "holder-alive: leader process still running"
            return ("RETAINED: leader liveness UNKNOWN (start-time probe failed); "
                    "operator card")
        # leader present AND proven dead: only now may a phase-specific clear proceed.
        # (rev 9) EVERY clear additionally requires the live slot fingerprint, re-read
        # AT CLEAR TIME, to equal the journaled F0 — whatever the phase.
        def _slot_is_f0():
            live, live_raw, st = _sh_keychain_read()
            if st == "error":
                return False                     # (r8 #1) unreadable slot never proves F0
            f0 = rec.get("fp_F0")
            live_fp = _slot_fingerprint(live, live_raw, st)   # (r10 #10)
            return isinstance(f0, str) and f0 and live_fp == f0
        def _clear(why):
            epoch.bump(acc)
            os.remove(os.path.join(acc, MARKER))
            # (r3 MINOR2) durably commit the marker removal, like normal unfreeze does.
            dfd = os.open(acc, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
            return f"cleared ({why})"
        # (r8 #5) DISK-STATE gate, phase-independent: publication renames the staged
        # tree into homes/<safe-email>/ and only THEN commits the READY registry entry.
        # A crash in that window leaves a reachable-but-UNREGISTERED final home. The
        # phase is still VERIFIED, so the SAFE_PHASES clear below would silently bump the
        # epoch and drop the freeze — abandoning a published-but-unusable home that
        # launchers reject AND that blocks a retry (add-account refuses an existing dir).
        # Per §7 ("recovery re-verifies then publishes or re-stages — never auto-READY"),
        # never auto-clear this: RETAIN + operator card so the home is completed or removed.
        email = rec.get("email", "")
        se = safe_email(email) if email else None
        if se:
            final = os.path.join(acc, "homes", se)
            if os.path.isdir(final) and not registry.ready_home(acc, email):
                return ("RETAINED: home published to " + final + " but NOT READY-registered "
                        "(crash between final rename and READY commit); operator card — "
                        "re-verify + registry.publish_ready, or remove the dir and retry")
        if phase in SAFE_PHASES_FOR_CLEAR:
            if _slot_is_f0():
                return _clear(f"phase {phase} + leader dead + slot re-verified == F0")
            return (f"RETAINED: phase {phase} but live slot != journaled F0 "
                    "(external change while stale); operator card")
        if phase == "QUIESCED":
            if _slot_is_f0():
                return _clear("nothing had started; slot == F0")
            return "RETAINED: QUIESCED but slot != F0; operator card"
        if phase == "LOGIN_STARTED":
            # leader fields present and proven dead above: a slot==F0 clear is safe.
            if _slot_is_f0():
                return _clear("slot still F0; login never landed; leader dead")
            return ("RETAINED: slot changed during LOGIN_STARTED; operator must "
                    "inspect (journal + archives hold F0)")
        # HARVEST_READ / HOME_WRITTEN / RESTORE_STARTED / UNREADABLE / unknown
        return (f"RETAINED: phase {phase} leaves the keychain unproven; operator "
                "recovery required (F0/L fingerprints in journal, F0 blob archived)")
    finally:
        _release(locks)


def _cli():
    cmd = sys.argv[1]
    acc = os.environ.get("ACCOUNT_BANK_DIR", os.path.expanduser("~/.claude/accounts"))
    if cmd == "recover":
        print(recover(acc))
        return 0
    if cmd == "status":
        rec = _journal_read(acc)
        print(json.dumps(rec) if rec else "no seeding transaction")
        return 0
    if cmd == "freeze":       # exposed for the interactive add flow + tests
        print(json.dumps(freeze(acc, sys.argv[2])))
        return 0
    if cmd == "unfreeze":
        unfreeze(acc)
        return 0
    if cmd == "record-orchestrator":   # (r13 #2) seedflow.py record-orchestrator <pid>
        rec = _journal_read(acc)
        if rec is None:
            print("no seeding transaction", file=sys.stderr)
            return 1
        amend_orchestrator(acc, rec.get("txn"), int(sys.argv[2]))
        return 0
    if cmd == "phase":        # seedflow.py phase <PHASE> [k=v ...] (add-flow steps)
        rec = _journal_read(acc)
        if rec is None:
            print("no seeding transaction", file=sys.stderr)
            return 1
        extra = dict(kv.split("=", 1) for kv in sys.argv[3:])
        _set_phase(acc, rec, sys.argv[2], **extra)
        return 0
    print(f"seedflow.py: unknown command {cmd!r}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(_cli())
