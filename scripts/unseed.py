#!/usr/bin/env python3
"""unseed.py — remove a v2 READY home: the counterpart of add-account.sh's seeding.

    unseed.py <accounts_dir> <email> [--yes] [--json]

Seeding mints a home (add-account.sh: freeze -> /login -> harvest -> verify -> publish
READY). Until v102 nothing undid it, so a home seeded by mistake, or belonging to an account
the owner no longer uses, stayed in the registry forever — monitored by the archiver, listed
by the app, holding a live OAuth grant in a keychain slot nobody could name.

WHAT IS REMOVED (in this order, which is the recovery order):
  0. (v102-r2) the registry entry is marked NOT-READY first — see THE ADMISSION FENCE below.
  1. EVERY credential seat the home has, ARCHIVED first into <accounts_dir>/archive/ — outside
     the home, so it survives step 5. Fail closed: an unarchivable credential is never
     destroyed. Both seat FORMS are archived independently (v102-r2): seat_delete removes the
     file AND the keychain slot, and a home interrupted mid-migration can hold a different
     credential in each, so archiving only the precedence seat would have destroyed the other
     unarchived.
  2. the home's OWN archive/ directory, MOVED to <accounts_dir>/archive/unseeded-<email>.<ts>/
     — the archiver's accumulated copies live inside the home and would otherwise be deleted
     along with it. Un-seeding must be recoverable, so its history is retained too.
  3. the per-config-dir keychain SLOT (Claude Code-credentials-<sha256(home)[:8]>), via
     seedflow.seat_delete — the seat abstraction, never a hand-rolled service name.
  4. the home directory itself.
  5. the registry entry — LAST, and that ordering is the whole crash story. Every consumer of
     a READY entry (registry.ready_home, is_ready_home, usage.py's discovery) also requires
     os.path.isdir(home), so an entry left behind by a crash between 4 and 5 is inert: nothing
     can launch on it, and re-running this tool finishes the job. The inverse order would
     leave a registered home whose credential we had already destroyed.

THE ADMISSION FENCE (v102-r2). Refusing while a SESSION is live only covers sessions that have
already registered. `claude-acct` resolves a READY home and execs, and until the new CLI runs
its SessionStart hook that launch is invisible to every check here — so a launch could slip
between the liveness check and the rmtree and end up running on a deleted config dir. Both
sides now meet at launchadmit.py's admission lock: the launcher records its pid against the
home under that lock, and this tool (holding the seeding barrier) takes the same lock, refuses
if any live admission names the home, and marks the registry entry NOT-READY before releasing
it. After that mark no launcher can resolve the home at all, which is what makes it safe to do
the slow destructive work outside the admission lock. A refusal BEFORE anything is destroyed
restores the READY entry; once destruction has begun the mark stays, because the correct next
step for that home is finishing the removal, not launching it. (v102-r3) "Has begun" is decided
by OBSERVING what happened — the history is still whole and no destination exists, both seats
still hold what they held — never by having reached the line that would have destroyed it. A
step that failed before changing anything leaves a launchable home, and stranding it not-READY
would be this tool breaking an account it explicitly declined to touch.

WHAT REFUSES (fail closed; nothing is touched unless every gate passes):
  * a SEEDING transaction in flight (the .seeding.json journal)                       -> 78
  * a registry entry that is not READY and not our own in-flight un-seed mark, a home that is
    not this bank's canonical homes/<safe-email> directory, a symlinked home, or a home a
    SECOND registry entry also claims — the delete target must agree three ways (registry
    entry, canonical path, seat abstraction) or we do not touch it                    -> 75
  * a live LAUNCH ADMISSION on this home (a `claude-acct` launch in flight)           -> 74
  * a present-but-unreadable session store — an unknown session set is never an empty one -> 75
  * the pointer targets this home while the epoch can act on the pointer (shadow|v2). Under
    v1 the pointer is inert bookkeeping AND repoint refuses to move it, so refusing here too
    would make the home un-removable; we proceed and say the pointer is left dangling (it is
    registry-gated, so it can never resolve).                                          -> 74
  * a live session pinned to this home, or a held restart lease on one. Liveness is
    three-valued and UNKNOWN counts as LIVE.                                           -> 74
  * no --yes. Every destructive step is behind the flag; without it this prints the plan and
    changes nothing, so the app can show its own confirmation UI and then drive us.     -> 73

Exit codes: 0 removed / nothing to remove (un-seeding an already-absent home is a clean
no-op, not an error) · 64 usage or unsafe email · 70 barrier contended · 73 confirmation
required · 74 in use · 75 failed mid-flight · 78 fenced.

--json makes every outcome machine-readable on stdout (the result dict, the plan with
would_remove, or {"refused", "code"}); the human text goes to stderr in that mode. That is
the form QuotaBar drives.
stdlib only; never prints token material.
"""
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
import epoch as epoch_mod
import launchadmit
import registry
import seedflow

EX_OK, EX_USAGE = 0, 64
EX_CONTENDED, EX_CONFIRM, EX_INUSE, EX_FAILED, EX_FENCED = 70, 73, 74, 75, 78


class Refused(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


def _real(p):
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def _verify_home_path(homes, home):
    """The path leg of the cross-check: this must be a directory THIS bank owns, named for the
    account we were asked to remove, reachable without following a symlink. `home` is already
    known to be the canonical homes/<safe-email> string; these checks are what stop a
    same-named symlink, a bind-style redirect or a nested path from turning that string into a
    delete target somewhere else."""
    if not os.path.isabs(home) or home != os.path.normpath(home):
        raise Refused(EX_FAILED, f"the home path {home!r} is not absolute+normalized; refusing "
                                 f"to resolve a delete target through it")
    if os.path.islink(home):
        raise Refused(EX_FAILED, f"{home} is a SYMLINK, not a home directory. Un-seeding "
                                 f"deletes its target; refusing to follow it.")
    real = _real(home)
    homes_real = _real(homes)
    if os.path.dirname(real) != homes_real or real == homes_real:
        raise Refused(EX_FAILED, f"{home} really resolves to {real}, which is not a direct "
                                 f"child of this bank's {homes_real}. Refusing to delete "
                                 f"outside the homes tree.")


def _verify_sole_claim(reg, email, home):
    """The registry leg: no OTHER account may map to this same directory. A stale duplicate
    mapping is exactly how removing A deletes B's home and B's keychain slot while only A's
    entry disappears — so a shared realpath is a refusal, not a tie to break."""
    real = _real(home)
    for other, ent in (reg or {}).items():
        if other == email or not isinstance(ent, dict):
            continue
        h = ent.get("home")
        if isinstance(h, str) and h and _real(h) == real:
            raise Refused(EX_FAILED,
                          f"the registry maps BOTH {email} and {other} to {home}. One of them "
                          f"is stale, and removing this home would destroy the other account's "
                          f"credential too. Fix the registry first; nothing was touched.")


def _resolve_home(acc, email):
    """The verified delete target: {"home", "source", "slot", "resuming"}, or None when there
    is nothing to remove.

    (v102-r2) The registry is still the only mapping consulted, but its answer is no longer
    taken on trust — it is CROSS-VERIFIED against the two other things that must agree about
    what "this account's home" means, and ANY disagreement refuses:

      * the registry ENTRY: present, and either READY or carrying our own in-flight unseeding
        mark. A not-READY entry with no mark is a half-published seeding, not a removal target.
      * the canonical PATH: <accounts_dir>/homes/<safe-email>, spelled exactly, a real
        non-symlinked direct child of the homes tree, claimed by no other registry entry. A
        stale mapping to another account's home, or an absolute path outside the bank, is
        precisely what this refuses to act on.
      * the SEAT abstraction: the keychain slot is sha256 of the home path STRING, so the
        verified string is carried through to seat_delete, which re-derives it and raises on
        disagreement rather than clearing a slot nobody verified.

    When the entry is already gone (a crash between steps 4 and 5, or a hand-deleted entry) the
    same canonical path is used as an orphan delete target so the cleanup can finish — under
    every check above except the entry one, which by definition has nothing to say."""
    try:
        reg = registry.load(acc)
    except registry.RegistryError as e:
        raise Refused(EX_FAILED, f"registry unreadable ({e}); refusing to guess what to remove")
    safe = bank_common.safe_email(email)
    if not safe:
        raise Refused(EX_USAGE, f"unsafe email {email!r}")
    homes = os.path.join(acc, "homes")
    canonical = os.path.join(homes, safe)
    ent = reg.get(email)
    if isinstance(ent, dict) and isinstance(ent.get("home"), str) and ent["home"]:
        home = ent["home"]
        resuming = bool(ent.get(registry.UNSEEDING))
        if ent.get("ready") is not True and not resuming:
            raise Refused(EX_FAILED,
                          f"the registry entry for {email} is NOT READY and carries no un-seed "
                          f"mark — that is an unfinished seeding, not a home to remove. Run "
                          f"`seedflow.py recover` first; nothing was touched.")
        if home != canonical:
            if _real(home) == _real(canonical):
                raise Refused(EX_FAILED,
                              f"the registry spells this home {home!r} while this bank spells "
                              f"it {canonical!r}. They resolve to the same directory, but the "
                              f"keychain slot is keyed on the EXACT string, so the two spellings "
                              f"name different slots. Re-run against the accounts dir the "
                              f"registry was written with rather than guessing which slot holds "
                              f"the grant.")
            raise Refused(EX_FAILED,
                          f"the registry maps {email} to {home}, which is not this bank's home "
                          f"for it ({canonical}). A stale or hand-edited mapping would delete "
                          f"the wrong home and the wrong keychain slot; refusing.")
        _verify_home_path(homes, home)
        _verify_sole_claim(reg, email, home)
        return {"home": home, "source": "registry", "resuming": resuming,
                "slot": seedflow.config_slot_service(home)}
    if os.path.isdir(canonical):
        _verify_home_path(homes, canonical)
        _verify_sole_claim(reg, email, canonical)   # a home another entry claims is not orphaned
        return {"home": canonical, "source": "orphan-home", "resuming": False,
                "slot": seedflow.config_slot_service(canonical)}
    return None


def _sessions_on_home(acc, home_real):
    """Every session record — live, idle or tombstoned — whose pinned home is this one.
    Reads the store WITHOUT taking the sessions lock: we hold the seeding barrier (bank ->
    pointer -> homes) and must not introduce a second lock-order edge into it. The read is
    only ever used to REFUSE, and it is re-taken after the barrier closes the door on new
    launches, so a lock-free snapshot cannot let a live session slip through.

    (v102-r2) Through sessions.load_strict, NOT sessions._load: the display reader turns a torn
    store into {}, and this gate would have read that as "no sessions" and deleted a live
    session's home. Present-but-unreadable refuses."""
    import sessions
    out = []
    try:
        store = sessions.load_strict(acc)
    except sessions.StoreUnreadable as e:
        raise Refused(EX_FAILED, f"the session store is present but unreadable ({e}); refusing "
                                 f"to remove a home that may be in use. Nothing was touched.")
    except Exception as e:
        raise Refused(EX_FAILED, f"the session store could not be read ({type(e).__name__}); "
                                 f"refusing to remove a home that may be in use")
    for sid, rec in (store or {}).items():
        if not isinstance(rec, dict):
            continue
        h = rec.get("home")
        if isinstance(h, str) and h and _real(h) == home_real:
            out.append((sid, rec))
    return out


def _refuse_if_in_use(acc, home):
    import sessions
    home_real = _real(home)
    for sid, rec in _sessions_on_home(acc, home_real):
        if sessions.lease_held(acc, sid):
            raise Refused(EX_INUSE, f"a restart lease is HELD on session {sid} pinned to this "
                                    f"home; a restart transaction is in flight. Retry once it "
                                    f"completes.")
        if rec.get("tombstone"):
            continue
        pid = rec.get("pid")
        if not pid:
            continue
        state = sessions._proc_state(pid, rec.get("proc_start") or None)
        if state != "DEAD":
            raise Refused(EX_INUSE, f"session {sid} (pid {pid}) is {state} on this home. "
                                    f"UNKNOWN counts as live — exit that session first.")


def _refuse_if_admitted(acc, home):
    """Refuse while a `claude-acct` launch has been ADMITTED against this home and its process
    is not provably dead. This is the pre-registration half of "in use": the CLI exists (or is
    about to), but nothing has written a session record for it yet."""
    home_real = _real(home)
    try:
        admissions = launchadmit.live_admissions(acc)
    except launchadmit.AdmissionError as e:
        raise Refused(EX_FAILED, f"{e}; an admission we cannot read is a launch we cannot rule "
                                 f"out. Nothing was touched.")
    for rec in admissions:
        h = rec.get("home")
        if isinstance(h, str) and _real(h) == home_real:
            raise Refused(EX_INUSE,
                          f"a pinned launch (pid {rec.get('pid')}) was admitted on this home and "
                          f"its process is still alive. Quit that session — or let the launch "
                          f"fail — and re-run.")


def _refuse_if_pointer_target(acc, home):
    import repoint
    try:
        tgt = repoint.read_current(acc)
    except Exception:
        raise Refused(EX_FAILED, "the launch pointer could not be read; refusing to remove a "
                                 "home that may be its target.")
    if not tgt or _real(tgt) != _real(home):
        return None
    try:
        state = epoch_mod.read_epoch(acc).get("state")
    except Exception:
        state = "v2"      # an unreadable EPOCH is UNKNOWN -> assume the pointer is live
    if state in ("shadow", "v2"):
        raise Refused(EX_INUSE,
                      f"accounts/current points at this home and the epoch is {state}, so "
                      f"future launches would resolve to it. Repoint first "
                      f"(claude-acct --switch <other-email>), then un-seed.")
    # v1: the pointer is inert AND repoint refuses to move it (shadow|v2 only), so refusing
    # here would strand the home permanently. Proceed and report the dangling pointer.
    return ("pointer left dangling at a removed home; it is registry-gated, so nothing can "
            "resolve or launch through it")


def plan(acc, email):
    """What un-seeding WOULD do, and every refusal that applies — computed before the barrier
    so `--yes`-less callers get the same verdict the real run would reach."""
    if not os.path.isdir(acc):
        raise Refused(EX_USAGE, f"accounts dir does not exist: {acc}")
    if seedflow._journal_read(acc) is not None:
        raise Refused(EX_FENCED, "a SEEDING transaction is in flight (.seeding.json); the "
                                 "homes tree is frozen. Let it finish or run "
                                 "`seedflow.py recover` first.")
    target = _resolve_home(acc, email)
    if target is None:
        return None
    home, source = target["home"], target["source"]
    warnings = []
    w = _refuse_if_pointer_target(acc, home)
    if w:
        warnings.append(w)
    _refuse_if_in_use(acc, home)
    _refuse_if_admitted(acc, home)
    seats = _readable_seats(home)
    kind = "file" if seats.get("file") else ("slot" if seats.get("slot") else "none")
    return {"email": email, "home": home, "home_source": source,
            "home_present": os.path.isdir(home),
            "registered": source == "registry",
            "resuming": target["resuming"],
            "seat_kind": kind, "seat_present": bool(seats),
            "seats_present": sorted(seats),
            "keychain_slot": target["slot"],
            "warnings": warnings}


def _seat_forms_held(home):
    """The set of seat forms that currently HOLD a credential, or None when that cannot be
    established. Used only to answer "did that failure destroy anything?", and the None is why
    it is a separate function from _readable_seats: an unreadable seat there is a refusal, here
    it is an unknown — and an unknown postcondition must never be read as "nothing happened"."""
    if not os.path.isdir(home):
        return None
    try:
        forms = seedflow.seat_read_forms(home)
    except Exception:
        return None
    held = set()
    for kind, (_blob, raw, status) in forms.items():
        if status == "error":
            return None
        if status == "present" and raw:
            held.add(kind)
    return held


def _move_changed_nothing(src, entries, dest):
    """True iff a FAILED move demonstrably left the filesystem as it was: the source is still
    there with exactly the entries it had, and no destination exists. shutil.move falls back to
    copy+delete across devices, so a failure part-way through legitimately leaves a partial
    destination — and that is a change, not an unlucky no-op."""
    try:
        return (not os.path.exists(dest) and os.path.isdir(src)
                and sorted(os.listdir(src)) == entries)
    except OSError:
        return False


def _readable_seats(home):
    """{seat_kind: raw} for every seat form that HOLDS a credential — the set that must be
    archived before anything is deleted. An "error" on either form refuses: a seat we cannot
    read is one we cannot archive, and seat_delete would destroy it anyway."""
    if not os.path.isdir(home):
        return {}
    out = {}
    for kind, (_blob, raw, status) in sorted(seedflow.seat_read_forms(home).items()):
        if status == "error":
            raise Refused(EX_FAILED, f"the home's {kind} credential seat could not be READ "
                                     f"(keychain locked/denied). Refusing to delete what we "
                                     f"cannot archive.")
        if status == "present" and raw:
            out[kind] = raw
    return out


def unseed(acc, email):
    """Execute the plan under the seeding barrier. Returns a result dict. Raises Refused."""
    p = plan(acc, email)
    if p is None:
        return None
    try:
        locks = seedflow._ordered_locks(acc)
    except RuntimeError as e:
        raise Refused(EX_CONTENDED, f"could not take the seeding barrier ({e}); nothing "
                                    f"changed. Retry when the other operation finishes.")
    try:
        # Re-verify EVERYTHING under the barrier: the pre-lock plan is advisory, and a
        # /login, a launch or a seeding freeze could have landed in between.
        if seedflow._journal_read(acc) is not None:
            raise Refused(EX_FENCED, "a SEEDING transaction started while we waited for the "
                                     "barrier; nothing changed.")
        # Re-RESOLVE, not just re-check: the registry could have been rewritten while we waited
        # for the barrier, and the pre-lock plan's target is only advisory. Everything below
        # acts on the target verified under the lock.
        target = _resolve_home(acc, email)
        if target is None:
            return None
        home, slot = target["home"], target["slot"]
        _refuse_if_pointer_target(acc, home)
        _refuse_if_in_use(acc, home)

        done = {"email": email, "home": home, "archived_credential": None,
                "archived_credentials": [], "archived_home_history": None,
                "credential_file_removed": False, "keychain_slot": slot,
                "keychain_slot_deleted": False, "home_removed": False,
                "registry_entry_removed": False, "warnings": list(p["warnings"])}

        # 0. CLOSE THE DOOR. Under the admission lock: refuse if a launch is already in flight
        # on this home, then mark the entry not-READY so no further launch can resolve it. Both
        # steps have to be inside the same lock hold — checking and marking separately would
        # leave the same gap this fence exists to remove. Once the mark lands, launchers refuse
        # on their own, so the lock is released before the slow work below.
        admit_lk = launchadmit.lock(acc)
        if not admit_lk.acquire(timeout=15):
            raise Refused(EX_CONTENDED, "the launch-admission lock is contended (a pinned "
                                        "launch is resolving right now); nothing changed.")
        marked = False
        try:
            _refuse_if_admitted(acc, home)
            if target["source"] == "registry" and not target["resuming"]:
                registry.mark_unseeding(acc, email)
                marked = True
        finally:
            admit_lk.release()

        # (v102-r3) Flips at the first irreversible step, and ONLY from an observed
        # postcondition. It used to be set immediately before each destructive call, which made
        # it a record of what we had ATTEMPTED rather than of what had happened: a move that
        # failed before touching the filesystem, or a seat_delete that raised before clearing
        # either form, left a completely intact and launchable home behind a flag that said
        # otherwise — so the un-seeding mark stayed and the home became unlaunchable for a
        # failure that changed nothing. Attempting is not destroying; the handler below only
        # keeps the mark when something demonstrably went.
        destroyed = False
        try:
            # With the door closed, take the liveness snapshot that DECIDES. The earlier ones
            # could still race a launch; this one cannot, because nothing new can start.
            _refuse_if_in_use(acc, home)

            if os.path.isdir(home):
                # 1. EVERY credential seat, archived OUTSIDE the home so it outlives step 4.
                # seat_delete clears the file AND the slot, so both are archived here — a home
                # interrupted mid-migration can hold a different credential in each, and the
                # never-destroy rule is per seat.
                seats = _readable_seats(home)
                for kind in ("file", "slot"):
                    if kind not in seats:
                        continue
                    try:
                        path = bank_common.archive_blob(acc, email, seats[kind])
                    except Exception as e:
                        raise Refused(EX_FAILED, f"could not archive the home's {kind} "
                                                 f"credential ({type(e).__name__}); nothing "
                                                 f"destroyed.")
                    done["archived_credentials"].append({"seat": kind, "path": path})
                    # the precedence seat (file over slot) stays the headline field the app
                    # captions with; the list above is the complete record.
                    if done["archived_credential"] is None or kind == "file":
                        done["archived_credential"] = path

                # 2. the home's own archive/ history, MOVED out before the home goes. THE FIRST
                # DESTRUCTIVE STEP — everything above only copied.
                hist = os.path.join(home, "archive")
                if os.path.isdir(hist) and os.listdir(hist):
                    # everything up to the move only PREPARES a destination; a failure here
                    # cannot have touched the home.
                    try:
                        dest_root = os.path.join(acc, "archive")
                        os.makedirs(dest_root, exist_ok=True)
                        os.chmod(dest_root, 0o700)
                        label = bank_common.safe_email(email) or "unknown"
                        dest = os.path.join(
                            dest_root,
                            f"unseeded-{label}.{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}")
                        n = 0
                        while os.path.exists(dest):
                            n += 1
                            dest = f"{dest}.{n}"
                        before = sorted(os.listdir(hist))
                    except Exception as e:
                        raise Refused(EX_FAILED, f"could not prepare a destination for the "
                                                 f"home's archive/ history ({type(e).__name__}); "
                                                 f"nothing was destroyed.")
                    try:
                        shutil.move(hist, dest)
                    except Exception as e:
                        # THE FIRST DESTRUCTIVE STEP is only destructive if it moved something.
                        if _move_changed_nothing(hist, before, dest):
                            raise Refused(EX_FAILED, f"could not preserve the home's archive/ "
                                                     f"history ({type(e).__name__}); nothing was "
                                                     f"destroyed and the home is intact.")
                        destroyed = True
                        raise Refused(EX_FAILED, f"the home's archive/ history was PARTIALLY "
                                                 f"moved to {dest} ({type(e).__name__}); the "
                                                 f"home stays out of service — re-run to finish "
                                                 f"the removal rather than launching it.")
                    destroyed = True
                    done["archived_home_history"] = dest

                # 3. the credential seat: the file AND the per-config-dir keychain slot. The
                # slot name is the one VERIFIED above, re-derived inside seat_delete, which
                # raises rather than clear a slot the resolver never checked.
                held_before = _seat_forms_held(home)
                try:
                    seat = seedflow.seat_delete(home, expect_slot=slot)
                except Exception as e:
                    # A seat_delete that raised BEFORE removing either form leaves both
                    # credentials where they were, and that home is still perfectly launchable.
                    # Only an observed change — or an unknown, which is never "no change" —
                    # keeps it out of service.
                    if held_before is not None and _seat_forms_held(home) == held_before:
                        raise Refused(EX_FAILED, f"could not clear the home's credential seat "
                                                 f"({type(e).__name__}); the home is intact and "
                                                 f"nothing was destroyed.")
                    destroyed = True
                    raise Refused(EX_FAILED, f"could not clear the home's credential seat "
                                             f"({type(e).__name__}) and a seat may already be "
                                             f"cleared; the home stays out of service — re-run "
                                             f"to finish the removal.")
                destroyed = True
                done["credential_file_removed"] = seat["file_removed"]
                done["keychain_slot_deleted"] = seat["slot_deleted"]
                if not seat["slot_deleted"]:
                    raise Refused(EX_FAILED,
                                  "the keychain slot could not be deleted (locked/denied). The "
                                  "home is intact and still registered; unlock the keychain and "
                                  "re-run rather than leave an orphaned credential behind.")

                # 4. the home tree.
                try:
                    shutil.rmtree(home)
                except Exception as e:
                    raise Refused(EX_FAILED, f"could not remove the home directory {home} "
                                             f"({type(e).__name__}). The credential is archived "
                                             f"and the slot is cleared; re-run to finish.")
                done["home_removed"] = True

            # 5. the registry entry, LAST — the commit.
            try:
                reg = registry.load(acc)
            except registry.RegistryError as e:
                raise Refused(EX_FAILED, f"the home is gone but the registry is unreadable "
                                         f"({e}); remove the {email} entry by hand.")
            if email in reg:
                reg.pop(email, None)
                try:
                    registry.save(acc, reg)
                except Exception as e:
                    # The write is temp+rename: it either replaced the registry or it did not.
                    # A failure leaves the entry exactly as it was, so it destroys nothing on
                    # its own — but everything above it may already have, and `destroyed`
                    # already says so.
                    raise Refused(EX_FAILED, f"the registry entry for {email} could not be "
                                             f"dropped ({type(e).__name__}); re-run to finish.")
                destroyed = True
                done["registry_entry_removed"] = True
            return done
        except Refused:
            # A refusal that landed BEFORE anything was destroyed leaves a perfectly intact,
            # perfectly launchable home — putting it back in service is part of "nothing was
            # touched". After the first destructive step the mark STAYS: that home is no longer
            # something to launch, it is something to finish removing, and every consumer being
            # READY-gated is what makes the half-removed state inert rather than dangerous.
            # (v102-r3) `destroyed` is set from observed postconditions, so this asks what
            # HAPPENED, not how far the code got — and an unobservable postcondition keeps the
            # mark, since an unknown is never a proof that nothing changed.
            if marked and not destroyed:
                try:
                    registry.clear_unseeding(acc, email)
                except Exception:
                    pass
            raise
    finally:
        seedflow._release(locks)


def _print_plan(p, as_json):
    if as_json:
        print(json.dumps(dict(p, would_remove=True), indent=2))
        return
    print(f"un-seed PLAN for {p['email']} (nothing has changed — re-run with --yes):")
    print(f"  home:              {p['home']}"
          f"{'' if p['home_present'] else '  (already absent)'}")
    print(f"  registry entry:    {'present' if p['registered'] else 'absent'}")
    both = "  — BOTH forms hold a credential; both are archived" \
        if len(p.get("seats_present") or []) > 1 else ""
    print(f"  credential seat:   {p['seat_kind']}"
          f"{' (present)' if p['seat_present'] else ' (empty)'}{both}")
    print(f"  keychain slot:     {p['keychain_slot']}")
    print( "  archived first:    the credential + the home's archive/ history, into "
           "<accounts>/archive/")
    for w in p["warnings"]:
        print(f"  NOTE:              {w}")


def _print_result(d, as_json):
    if as_json:
        print(json.dumps(d, indent=2))
        return
    print(f"un-seeded {d['email']}")
    print(f"  home removed:      {d['home'] if d['home_removed'] else 'no (already absent)'}")
    print(f"  registry entry:    {'removed' if d['registry_entry_removed'] else 'none'}")
    print(f"  keychain slot:     "
          f"{'deleted (' + d['keychain_slot'] + ')' if d['keychain_slot_deleted'] else 'none'}")
    print(f"  credential kept:   {d['archived_credential'] or 'nothing to archive'}")
    for a in d.get("archived_credentials") or []:
        if a["path"] != d["archived_credential"]:
            print(f"  also kept:         {a['path']}  (the {a['seat']} seat)")
    if d["archived_home_history"]:
        print(f"  history kept:      {d['archived_home_history']}")
    for w in d["warnings"]:
        print(f"  NOTE:              {w}")
    print( "  recover:           the archived copies above are the ONLY remaining trace; "
           "re-seed with claude-acct --add.")


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = set(a for a in argv[1:] if a.startswith("--"))
    unknown = flags - {"--yes", "--json"}
    if len(args) != 2 or unknown:
        sys.stderr.write("usage: unseed.py <accounts_dir> <email> [--yes] [--json]\n")
        return EX_USAGE
    acc, email = args
    as_json = "--json" in flags
    try:
        p = plan(acc, email)
        if p is None:
            msg = f"{email}: nothing to un-seed (no registry entry, no home)."
            print(json.dumps({"email": email, "would_remove": False, "reason": "absent"})
                  if as_json else msg)
            return EX_OK
        if "--yes" not in flags:
            _print_plan(p, as_json)
            return EX_CONFIRM
        _print_result(unseed(acc, email), as_json)
        return EX_OK
    except Refused as e:
        if as_json:
            print(json.dumps({"email": email, "refused": str(e), "code": e.code}, indent=2))
        sys.stderr.write(f"un-seed: {e}\n")
        return e.code
    except Exception as e:
        # (v102-r2) A destructive command driven by an app must not answer with a traceback and
        # rc 1. Anything unforeseen exits as a mid-flight failure with a one-line reason — the
        # code the caller already knows means "safe to retry, cause varies" — and no stack.
        msg = f"unexpected {type(e).__name__}: {e}"
        if as_json:
            print(json.dumps({"email": email, "refused": msg, "code": EX_FAILED}, indent=2))
        sys.stderr.write(f"un-seed: {msg}\n")
        return EX_FAILED


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
