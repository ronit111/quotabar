#!/usr/bin/env python3
"""reconcile.py — recover crash-torn state from journals before any account is
read or mutated. Two journal kinds:

  swap journal (.swap-journal.json): written by swap-account.sh BEFORE the
    keychain write and cleared AFTER the ~/.claude.json metadata commit. If a
    swap is interrupted in between, the keychain may hold the target creds while
    the metadata still names the source (or vice versa). We resolve this to a
    consistent state by comparing the LIVE keychain fingerprint against the
    journal's target_fp / pre_fp (findings #12/#14/#15) — and we NEVER roll back
    on top of a newer external /login we don't recognize.

  refresh journals (.refresh-journal-<email>.json): written by a parked-account
    refresh BEFORE it commits rotated creds to the bank file. If the process dies
    in between we merge the (newer) rotated credential into the bank record. We
    compare the FULL credential (finding #17), not just expiresAt, and we
    QUARANTINE (never silently delete) a journal we can't safely interpret
    (finding #18).

FAIL-CLOSED CONTRACT (finding #13): if a swap journal cannot be resolved to a
known-consistent state, reconcile_journals() reports it UNRESOLVED and the CLI
exits EXIT_UNRESOLVED_SWAP. Every mutator aborts while a swap journal is
unresolved — proceeding would read/write inconsistent credential state.

MUST hold the bank lock. The importable reconcile_journals() assumes the caller
holds it; the standalone CLI acquires it itself (finding #19). Never prints
secrets.
"""
import json, os, glob, tempfile, time, sys, subprocess, pwd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common

HOME = os.path.expanduser("~")
BANK_DIR = bank_common.resolve_bank_dir()   # (r15 #4) the ONE rule: BANK_DIR -> ACCOUNT_BANK_DIR -> default
CLAUDE_JSON = os.environ.get("CLAUDE_JSON", os.path.join(HOME, ".claude.json"))
SWAP_JOURNAL = os.path.join(BANK_DIR, ".swap-journal.json")
# DURABLE unresolved-blocker (re-review issue 3): once a torn swap is detected and
# NOT cleanly resolved, this marker persists across runs so mutation stays blocked
# even after the journal itself is quarantined/removed. Cleared ONLY on a positive
# resolution (or a clean "no torn state"). A stuck marker requires operator review
# — safer than silently allowing mutation on an unknown keychain/metadata pairing.
SWAP_UNRESOLVED = os.path.join(BANK_DIR, ".swap-unresolved")
LOCK_DIR = os.path.join(BANK_DIR, ".lock")
LOCK_STALE_SECS = 300
KEYCHAIN_SERVICE = "Claude Code-credentials"
KEYCHAIN_ACCOUNT = os.environ.get("KEYCHAIN_ACCOUNT") or pwd.getpwuid(os.getuid()).pw_name

EXIT_OK = 0
EXIT_UNRESOLVED_SWAP = 10   # a swap journal remains torn/ambiguous -> block mutators


def _security_bin():
    override = os.environ.get("ACCOUNT_BANK_SECURITY_BIN")
    if override:
        return override if (os.path.isfile(override) and os.access(override, os.X_OK)) else None
    if os.path.isfile("/usr/bin/security") and os.access("/usr/bin/security", os.X_OK):
        return "/usr/bin/security"
    # (r14 #2) NO PATH fallback for a credential-bearing tool — a `security` proxy on PATH
    # could exfiltrate the OAuth blob. If the absolute binary is gone, fail (return None).
    return None


def _atomic_write_json(path, obj):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".acct.")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2)
        f.flush(); os.fsync(f.fileno())          # durability (finding #4)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    d = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
    try:
        os.fsync(d)
    finally:
        os.close(d)


def _fsync_dir(dirpath):
    """(v101-confirm) Make a rename/unlink inside `dirpath` durable. Returns True only when
    the directory was opened AND fsync'd — a failure here is REPORTED, never absorbed, because
    the caller uses it to decide whether a journal removal actually happened on disk.
    Tests substitute this attribute to simulate a directory that cannot be synced."""
    try:
        fd = os.open(dirpath, os.O_RDONLY)
    except OSError:
        return False
    try:
        os.fsync(fd)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def _quarantine(path, why):
    """Move a journal we cannot safely interpret out of the active name, so it is
    neither trusted nor destroyed (finding #18). Returns the quarantine path."""
    q = f"{path}.corrupt.{int(time.time())}.{os.getpid()}"
    try:
        os.rename(path, q)
        sys.stderr.write(f"reconcile: quarantined journal ({why}) -> {os.path.basename(q)}\n")
    except OSError:
        q = None
    return q


def _set_unresolved_marker(why):
    """Durably write the unresolved marker. Returns True on a VERIFIED durable
    write, False otherwise (r3 #12): callers must NOT free/quarantine the journal
    that is the fallback blocker unless this returns True, or a disk-full/marker-
    creation failure could leave the NEXT run with neither journal nor marker
    (fail-open)."""
    try:
        with open(SWAP_UNRESOLVED, "w") as f:
            f.write(f"{time.time()} {why}\n")
            f.flush(); os.fsync(f.fileno())
        os.chmod(SWAP_UNRESOLVED, 0o600)
        d = os.open(os.path.dirname(SWAP_UNRESOLVED) or ".", os.O_RDONLY)
        try: os.fsync(d)
        finally: os.close(d)
        return True
    except Exception:
        sys.stderr.write("reconcile: FAILED to durably write the unresolved marker "
                         "(fail-closed: keeping the journal in place as the blocker).\n")
        return False


def _banked_fp(email):
    """Fingerprint of the BANKED credential for `email`, or "" when the record is
    absent/unreadable/invalid. Used to positively verify keychain<->bank agreement
    before declaring a torn swap resolved (r3 #9/#11)."""
    if not email:
        return ""
    path = bank_common.bank_file_for(BANK_DIR, email)
    if not path:
        return ""
    br = bank_common.load_bank_record(path)
    if not br.ok or not br.oauth:
        return ""
    return bank_common.cred_fingerprint(br.oauth)


def _clear_unresolved_marker():
    try:
        os.remove(SWAP_UNRESOLVED)
    except OSError:
        pass


def journal_path(email):
    """Path for a refresh journal, or None if the email is UNSAFE as a filename
    (re-review issue 4). No sanitizing-and-continuing — an unsafe identity is
    rejected outright so a forged journal can't address a file outside BANK_DIR."""
    safe = bank_common.safe_email(email)
    if safe is None:
        return None
    return os.path.join(BANK_DIR, f".refresh-journal-{safe}.json")


def write_journal(email, oauth):
    jp = journal_path(email)
    if jp is None:
        raise ValueError(f"refuse to write refresh journal for unsafe email {email!r}")
    _atomic_write_json(jp, {"email": email, "claudeAiOauth": oauth, "ts": time.time()})


def _active_email():
    try:
        return (json.load(open(CLAUDE_JSON)).get("oauthAccount") or {}).get("emailAddress", "") or ""
    except Exception:
        return ""


# --- (v108) SEAT-AWARE credential access -------------------------------------
# Current Claude Code keeps the active credential in $CLAUDE_CONFIG_DIR/.credentials.json
# and no longer writes the bare keychain slot this tool was built against. Reconcile
# restores the OUTGOING credential after a torn swap, so it must read and write the same
# seat swap-account.sh does, or it "restores" into a place the CLI never reads.
# Mirrors lib.sh cred_read/_seat_is_file exactly, including the isolation rule: when
# credential reads are redirected (tests/stubs) the SLOT is always the seat, so a
# hermetic run can never read or overwrite the owner's real credential file.
def _seat_file_path():
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or
                        os.path.join(os.path.expanduser("~"), ".claude"),
                        ".credentials.json")


def _seat_is_file():
    if (os.environ.get("ACCOUNT_BANK_FAKE_KEYCHAIN") or os.environ.get("STUB_KC_FILE")
            or os.environ.get("ACCOUNT_BANK_SECURITY_BIN")):
        return False
    try:
        return os.path.getsize(_seat_file_path()) > 0
    except OSError:
        return False


def _seat_read():
    """The live credential: file seat when that is where the CLI keeps it, else slot."""
    if _seat_is_file():
        try:
            raw = open(_seat_file_path()).read().strip()
        except OSError:
            return None
        if raw:
            try:
                d = json.loads(raw)
            except ValueError:
                return None
            if isinstance(d, dict) and (d.get("claudeAiOauth") or d.get("oauth")):
                return raw
        return None
    return _live_keychain_blob()


def _seat_write(compact_blob):
    """Write the live credential seat atomically (0600). True on a landed write."""
    if not _seat_is_file():
        sec = _security_bin()
        if not sec:
            return False
        # (v112) The blob is a QUOTED, escaped token, matching lib.sh kc_write. It used
        # to be bare, relying on the blob containing no whitespace — an invariant CLI
        # 2.1.235 ended by moving mcpOAuth (whose OAuth `scope` is space-delimited) into
        # this same item. Measured against the real `security -i`: a bare token with a
        # space either errors (rc 2) or, when the trailing text parses as arguments, is
        # SILENTLY TRUNCATED at the space with rc 0 — the caller's verify is the only
        # thing that would catch the second case.
        _esc = compact_blob.replace("\\", "\\\\").replace('"', '\\"')
        cmd = 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' % (
            KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, _esc)
        try:
            subprocess.run([sec, "-i"], input=cmd, text=True, capture_output=True, timeout=8)
        except Exception:
            pass   # rc ignored — the caller VERIFIES instead of trusting it
        return True
    path = _seat_file_path()
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".cred.")
        with os.fdopen(fd, "w") as f:
            f.write(compact_blob); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, 0o600); os.replace(tmp, path)
        return True
    except OSError:
        return False


def _live_keychain_blob():
    """Raw keychain blob (string) for the exact service+account, or None. Bounded;
    secret never logged."""
    sec = _security_bin()
    if not sec:
        return None
    try:
        p = subprocess.run([sec, "find-generic-password", "-s", KEYCHAIN_SERVICE,
                            "-a", KEYCHAIN_ACCOUNT, "-w"],
                           capture_output=True, text=True, timeout=8, stdin=subprocess.DEVNULL)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip()
    except Exception:
        pass
    return None


def _live_fp():
    # (v108) the fingerprint of the live SEAT — the same thing _seat_write just wrote,
    # so the post-write verify below actually proves the write landed where the CLI reads.
    return bank_common.cred_fingerprint(_seat_read() or "")


def _stable_live_fp(retries=3):
    """Repeatedly read the live keychain fingerprint; return (fp, stable). stable
    is True only if two consecutive reads agree — so we never act on a keychain
    that is moving under us (re-review issue 8)."""
    f1 = _live_fp()
    for _ in range(max(1, retries - 1)):
        f2 = _live_fp()
        if f1 == f2:
            return f1, True
        f1 = f2
    return f1, False


def _restore_keychain(compact_blob, expected_live_fp):
    """Verification-aware keychain restore (finding #16 + re-review issue 8): before
    overwriting, require the LIVE keychain to STILL equal `expected_live_fp` (a
    stable repeated read). A concurrent /login that installed a different
    credential (C) changes the live fp, so we ABORT rather than clobber the newer
    login. Then snapshot the current item, refuse to CREATE, write via `security
    -i`, and VERIFY the result. Honors ACCOUNT_BANK_RECONCILE_DRYRUN=1. Returns
    True only on VERIFIED success."""
    if not isinstance(compact_blob, str) or not compact_blob.strip():
        return False
    # (v112) FORMATTING whitespace only. This was a scan over every character, which
    # under CLI 2.1.235 rejects any journalled blob carrying mcpOAuth — i.e. it would
    # have refused to restore a torn swap, turning a recoverable interruption into a
    # permanent one. Mirrors validate_blob.py's string-aware check.
    if bank_common.formatting_whitespace(compact_blob.strip()):
        return False   # security -i needs one token; a compact blob is required
    want_fp = bank_common.cred_fingerprint(compact_blob)
    try:
        o = json.loads(compact_blob)
        oa = o.get("claudeAiOauth") if isinstance(o, dict) else None
        if not bank_common.valid_oauth(oa):
            # (v112) Same distinction the swap capture gate now draws: a journalled blob
            # that parses and HAS a claudeAiOauth but fails validation is a schema change,
            # not a corrupt journal, and it is worth saying which — a torn swap left
            # unrestored is the most expensive state this system has.
            if isinstance(o, dict) and "claudeAiOauth" in o:
                sys.stderr.write(
                    "reconcile: credential blob shape not recognized (CLI schema may have "
                    "changed; validation rejected a READABLE journalled credential). "
                    "Journal KEPT; the keychain was not touched.\n")
            return False
    except Exception:
        return False
    if not want_fp:
        return False
    # PRECONDITION (issue 8): the live keychain must still be exactly what we
    # expected to overwrite, and stable. Otherwise a newer writer intervened.
    live_fp, stable = _stable_live_fp()
    if not stable or not expected_live_fp or live_fp != expected_live_fp:
        sys.stderr.write("reconcile: live keychain changed/moved before restore "
                         "(expected != live); refusing to overwrite. Journal kept.\n")
        return False
    if os.environ.get("ACCOUNT_BANK_RECONCILE_DRYRUN") == "1":
        sys.stderr.write("reconcile(dry-run): WOULD restore pre-swap keychain blob\n")
        return True
    # (v2 rev6 §8) reconcile's keychain restore is a v1 mutation: gate it.
    try:
        import epoch as _epoch_mod
        _epoch_mod.v1_gate(BANK_DIR)
    except Exception as _eg:
        sys.stderr.write(f"reconcile: epoch gate refused the restore ({_eg}); "
                         "keychain UNCHANGED, journal kept.\n")
        return False
    sec = _security_bin()
    if not sec:
        return False
    # fail-closed: refuse to CREATE — the item must already exist.
    if _seat_read() is None:
        sys.stderr.write("reconcile: no existing credential seat to restore into; refusing to create.\n")
        return False
    # snapshot the current item before overwriting it
    snap_dir = os.path.join(BANK_DIR, ".keychain-snapshots")
    try:
        os.makedirs(snap_dir, exist_ok=True); os.chmod(snap_dir, 0o700)
        cur = _seat_read()
        if cur:
            sp = os.path.join(snap_dir, f"{int(time.time())}-{os.getpid()}.json")
            fd, tmp = tempfile.mkstemp(dir=snap_dir, prefix=".snap.")
            with os.fdopen(fd, "w") as f:
                f.write(cur)
            os.chmod(tmp, 0o600); os.replace(tmp, sp)
            # (r5 PRINCIPLE 2) this restore OVERWRITES the live keychain credential
            # `cur`; archive it to the unified <bank_dir>/archive/ dir FIRST (labelled
            # with its owning account, or "unknown"), so a restore that turns out to
            # clobber a credential we care about is still recoverable. Fail CLOSED: if
            # the predecessor cannot be archived, refuse the restore.
            bank_common.archive_blob(BANK_DIR, bank_common.fp_owner(BANK_DIR, cur), cur)
    except Exception:
        return False   # snapshot / archive failure -> fail closed
    if not _seat_write(compact_blob):
        return False
    return _live_fp() == want_fp


def reconcile_swap_journal():
    """Resolve a torn swap. Returns (status, target):
        status in {"none", "resolved", "unresolved"}.
    A swap journal that cannot be resolved to a known-consistent state leaves the
    journal in place, SETS the durable unresolved marker, and returns "unresolved"
    so callers block mutation on this AND every future run (re-review issue 3)."""
    marker_present = os.path.exists(SWAP_UNRESOLVED)
    if not os.path.exists(SWAP_JOURNAL):
        if marker_present:
            # a prior torn state was flagged and never cleanly resolved; stay
            # blocked until an operator inspects and clears .swap-unresolved.
            sys.stderr.write("reconcile: durable unresolved-swap marker present (no journal); "
                             "mutation stays blocked until manually cleared.\n")
            return ("unresolved", None)
        return ("none", None)
    try:
        j = json.load(open(SWAP_JOURNAL))
    except Exception:
        # (r3 #12) durable marker FIRST; only free the active journal name once the
        # marker is verifiably on disk. If the marker cannot be written, leave the
        # journal in place — it stays the blocker for the next run (never fail-open).
        if _set_unresolved_marker("unparseable swap journal"):
            _quarantine(SWAP_JOURNAL, "unparseable")   # rename frees the active name
        else:
            sys.stderr.write("reconcile: keeping unparseable journal in place (marker not durable).\n")
        return ("unresolved", None)
    if not isinstance(j, dict) or j.get("type") != "swap":
        if _set_unresolved_marker("swap journal wrong type"):
            _quarantine(SWAP_JOURNAL, "not a swap journal")
        else:
            sys.stderr.write("reconcile: keeping wrong-type journal in place (marker not durable).\n")
        return ("unresolved", None)

    target = j.get("target")
    current = j.get("current")
    target_fp = j.get("target_fp") or ""
    pre_fp = j.get("pre_fp") or ""
    pre_blob = j.get("pre_swap_blob")
    active = _active_email()
    live_fp = _live_fp()

    def resolved():
        """(v101-confirm) "resolved" is a claim about DISK, so prove it on disk before making
        it. The old body swallowed the unlink's OSError and never synced the directory, so a
        read-only bank (or any errno at all) produced "resolved" with the secret-bearing
        journal still sitting there — and the very next mutator would rediscover it as a torn
        swap. Both a surviving journal and an unproven-durable removal now fall through to
        unresolved(), which durably records WHY and keeps blocking."""
        try:
            os.remove(SWAP_JOURNAL)
        except FileNotFoundError:
            pass
        except OSError as e:
            sys.stderr.write(f"reconcile: could not remove the resolved swap journal "
                             f"({type(e).__name__}); keeping it as the blocker.\n")
            return unresolved("journal removal failed")
        if os.path.exists(SWAP_JOURNAL):
            sys.stderr.write("reconcile: the swap journal is still present after removal; "
                             "keeping it as the blocker.\n")
            return unresolved("journal still present after removal")
        if not _fsync_dir(os.path.dirname(SWAP_JOURNAL) or "."):
            sys.stderr.write("reconcile: the journal was removed but its directory could not be "
                             "synced; the removal is not proven durable.\n")
            return unresolved("journal removal not durable")
        _clear_unresolved_marker()
        return ("resolved", target)

    def unresolved(why):
        _set_unresolved_marker(why)
        return ("unresolved", target)

    # Case A — metadata committed to the target. Only "resolved" if the LIVE
    # keychain POSITIVELY equals the target credential (r3 #9). The old code
    # accepted a journal with NO target_fp as resolved on the metadata name alone,
    # even with an unreadable keychain or a different credential installed. Now we
    # require a positive fingerprint match: target_fp from the journal, or, when
    # absent, the banked credential fingerprint for the target. An unreadable or
    # diverged keychain is unresolved, not resolved.
    if active and target and active == target:
        want = target_fp or _banked_fp(target)
        if not live_fp:
            sys.stderr.write("reconcile: swap metadata==target but keychain unreadable; keeping journal.\n")
            return unresolved("metadata==target, keychain unreadable")
        if want and live_fp == want:
            return resolved()
        sys.stderr.write("reconcile: swap metadata==target but keychain != banked target creds "
                         "(or no fingerprint to verify against); keeping journal.\n")
        return unresolved("metadata==target, keychain unverified/diverged")

    # Case B — keychain still holds the pre-swap creds: the keychain write never
    # landed (or was already rolled back). Consistent ONLY if the active metadata
    # ALSO still names the pre-swap source (r3 #10). With keychain==pre-swap but
    # metadata naming a DIFFERENT account, the two stores disagree — keep blocking.
    if pre_fp and live_fp == pre_fp:
        if current and active and active == current:
            return resolved()
        if not active:
            sys.stderr.write("reconcile: keychain==pre-swap but active metadata unreadable; keeping journal.\n")
            return unresolved("keychain==pre-swap, active metadata unreadable")
        sys.stderr.write("reconcile: keychain==pre-swap but metadata names a different account; keeping journal.\n")
        return unresolved("keychain==pre-swap, metadata diverged")

    # Case C — TORN: keychain holds the target creds but metadata never moved off
    # the source. Roll the keychain back to the pre-swap blob so it matches
    # ~/.claude.json again (findings #10/#12). The restore itself re-checks, under a
    # stable read, that the live keychain STILL equals target_fp immediately before
    # overwriting (issue 8) — so a concurrent /login that installed C is never
    # clobbered. Keep the journal on any failure/mismatch.
    #
    # (r4 #7) require the FULL torn-evidence set: metadata must STILL name the swap
    # SOURCE (active == current), not merely "not the target". The old condition
    # `active != target` also matched metadata naming a THIRD account C (or an
    # unreadable metadata): rolling the keychain back to the pre-swap source A would
    # then leave the keychain on A while metadata says C — a fresh divergence, and
    # it wrongly reported "resolved" and cleared recovery. If metadata is neither the
    # source nor the target, this is not our clean torn state; fall through and keep
    # the journal (unresolved) instead of restoring.
    if target_fp and live_fp == target_fp and current and active == current:
        if _restore_keychain(pre_blob, expected_live_fp=target_fp):
            return resolved()
        sys.stderr.write("reconcile: torn-swap keychain rollback not performed; journal kept for retry\n")
        return unresolved("torn-swap rollback failed or preconditions changed")

    # Case D — the live keychain is neither our pre-swap nor our target credential,
    # and the active account is a DIFFERENT third account: an external /login
    # superseded the torn swap and wrote BOTH stores together, so they already
    # agree. Rolling back would clobber that newer login (finding #14) — treat the
    # journal as obsolete and drop it WITHOUT touching the keychain.
    if live_fp and live_fp != pre_fp and live_fp != target_fp \
            and active and active != current and active != target:
        # (r3 #11) positively verify the two stores agree before trusting this: the
        # LIVE keychain must match the BANKED credential for the now-active account.
        # The old branch assumed any third email + any third fingerprint belonged
        # together, so an overlapping/torn login (keychain X, metadata names Y) was
        # wrongly declared resolved. If the active account is unbanked or its banked
        # credential does not match the live keychain, we CANNOT confirm agreement —
        # keep the journal + marker (fail-closed).
        if _banked_fp(active) == live_fp:
            sys.stderr.write("reconcile: torn swap superseded by external login (verified "
                             "keychain==banked cred for active); dropping stale journal.\n")
            return resolved()
        sys.stderr.write("reconcile: apparent external login but live keychain does NOT match the "
                         "banked credential for the active account; keeping journal (unresolved).\n")
        return unresolved("third-account keychain unverified against its banked credential")

    # Anything else (keychain unreadable, or diverged while active still == source)
    # is ambiguous. Keep the journal and report unresolved so mutators block.
    sys.stderr.write("reconcile: swap journal ambiguous (live_fp/active unrecognized); keeping journal.\n")
    return unresolved("ambiguous live_fp/active")


def reconcile_journals():
    """Reconcile swap + refresh journals. Returns a dict:
        {"swap": <status>, "recovered": [emails], "unresolved": bool}
    'unresolved' True => a swap journal remains torn/ambiguous; callers MUST NOT
    mutate credential state this run (finding #13)."""
    try:
        swap_status, _ = reconcile_swap_journal()
    except Exception as e:
        sys.stderr.write(f"reconcile: swap reconcile error ({type(e).__name__}); treating as unresolved\n")
        swap_status = "unresolved"
    unresolved = (swap_status == "unresolved")

    # If the swap is unresolved, do NOT merge refresh journals — we must not mutate
    # bank records while the keychain/metadata pairing is in an unknown state.
    recovered = []
    if unresolved:
        return {"swap": swap_status, "recovered": recovered, "unresolved": True}

    # (finding 23) merging a refresh journal REWRITES a v1 bank credential — a v1
    # mutation. Gate it exactly like every other v1 mutator: refuse under v2 or while
    # a SEEDING freeze is active. Without this, refresh-journal merges kept mutating
    # bank credentials (and consuming journals) after the cutover.
    import epoch as _epoch_mod
    try:
        _epoch_mod.v1_gate(BANK_DIR)
        _recon_snap = _epoch_mod.read_epoch(BANK_DIR)   # (r2 finding 23) exact snapshot
    except Exception as _eg:
        sys.stderr.write(f"reconcile: epoch gate refused refresh-journal merges ({_eg}); "
                         "leaving journals intact.\n")
        return {"swap": swap_status, "recovered": recovered, "unresolved": False}

    def _fenced():
        # (r2 finding 23) exact generation fence immediately before a merge write /
        # journal consumption: refuse if the epoch moved at all since entry (ABA-proof).
        try:
            _epoch_mod.fence(BANK_DIR, _recon_snap, ("v1", "shadow"))
            return False
        except _epoch_mod.EpochFenced as _e:
            sys.stderr.write(f"reconcile: epoch moved mid-merge ({_e}); stopping, journals intact.\n")
            return True

    for jp in glob.glob(os.path.join(BANK_DIR, ".refresh-journal-*.json")):
        if _fenced():
            break
        try:
            j = json.load(open(jp))
        except Exception:
            _quarantine(jp, "unparseable refresh journal")   # never silently delete (finding #18)
            continue
        if not isinstance(j, dict):
            _quarantine(jp, "refresh journal not an object")
            continue
        email = j.get("email")
        joauth = j.get("claudeAiOauth")
        if not email or not bank_common.valid_oauth(joauth):
            _quarantine(jp, "refresh journal invalid credential")
            continue
        # (issue 4) resolve the bank path SAFELY: a forged journal with a "../../x"
        # email must never address a file outside BANK_DIR. Reject unsafe identity.
        bank_path = bank_common.bank_file_for(BANK_DIR, email)
        if bank_path is None:
            _quarantine(jp, f"unsafe email in refresh journal: {email!r}")
            continue
        br = bank_common.load_bank_record(bank_path)
        if br.reason == "file not found":
            # nothing to merge into; the journal is orphaned but NOT obviously
            # corrupt — quarantine rather than delete so a briefly-renamed bank
            # file can be recovered from it (finding #18).
            _quarantine(jp, f"no bank file for {email}")
            continue
        # (issue 4) ONLY mutate a VALID bank record. A parseable-but-invalid record
        # (schema failure, email mismatch) is quarantined, never rewritten.
        if not br.ok:
            _quarantine(jp, f"bank file for {email} invalid ({br.reason})")
            continue
        rec = br.record
        bank_oauth = rec.get("claudeAiOauth") if isinstance(rec.get("claudeAiOauth"), dict) else {}
        # Merge when the journal credential DIFFERS from the bank's (full-object
        # compare, finding #17) and is at least as new. A rotation can change only
        # the refreshToken/expiresAt with an equal expiresAt, so expiresAt alone is
        # not a sufficient generation test.
        if not bank_common.same_credentials(joauth, bank_oauth):
            j_exp = joauth.get("expiresAt") or 0
            b_exp = (bank_oauth or {}).get("expiresAt") or 0
            newer_or_equal = j_exp >= b_exp
            if newer_or_equal:
                rec["claudeAiOauth"] = joauth
                rec["status"] = "ok"
                rec["last_verified"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                _atomic_write_json(br.path, rec)
                recovered.append(email)
            else:
                # bank is newer than the journal -> journal is stale; safe to drop.
                try: os.remove(jp); continue
                except OSError: pass
                continue
        try:
            os.remove(jp)   # merged or identical -> consumed
        except OSError:
            pass
    return {"swap": swap_status, "recovered": recovered, "unresolved": False}


if __name__ == "__main__":
    # Standalone: acquire the shared lock ourselves (finding #19) unless told the
    # caller already holds it (ACCOUNT_BANK_HOLDS_LOCK=1, used when a locked shell
    # op shells out to us — though callers normally import the function instead).
    import banklock
    # (r12 #11) honor HOLDS_LOCK only when ownership is PROVEN (token match); else self-acquire.
    held = (os.environ.get("ACCOUNT_BANK_HOLDS_LOCK") == "1"
            and banklock.verify_caller_holds(BANK_DIR))
    _lk = None
    if not held:
        _lk = banklock.BankLock(BANK_DIR)
        if not _lk.acquire(timeout=int(os.environ.get("ACCOUNT_BANK_LOCK_WAIT", "10") or "10")):
            sys.stderr.write("reconcile: could not acquire lock; not reconciling.\n")
            sys.exit(0)   # not a torn-state signal; just contention
    try:
        try:
            r = reconcile_journals()
        except Exception as e:
            # (re-review issue 3) ANY unexpected reconciliation failure is
            # mutation-blocking, not fail-open. Set the durable marker and exit
            # with the blocking code so every caller aborts.
            sys.stderr.write(f"reconcile: unexpected failure ({type(e).__name__}); "
                             f"treating as UNRESOLVED and blocking mutation.\n")
            _set_unresolved_marker(f"reconcile exception: {type(e).__name__}")
            sys.exit(EXIT_UNRESOLVED_SWAP)
    finally:
        if _lk is not None:
            _lk.release()
    if r.get("recovered"):
        sys.stderr.write("reconciled rotated tokens for: " + ", ".join(r["recovered"]) + "\n")
    if r.get("unresolved"):
        sys.stderr.write("reconcile: UNRESOLVED swap journal present; mutators must abort.\n")
        sys.exit(EXIT_UNRESOLVED_SWAP)
    sys.exit(EXIT_OK)
