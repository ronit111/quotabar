#!/usr/bin/env python3
"""Tests for seedflow.py — freeze/fence integration, skeleton matrix, phase
journal, stale recovery rules. No keychain access: recovery paths that read the
slot are exercised only where the phase rules do not consult it, plus a stubbed
LOGIN_STARTED check via monkeypatching."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import epoch  # noqa: E402
import seedflow  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    acc = tempfile.mkdtemp(prefix="seed-acc-")
    # never touch the real keychain from tests (and never archive a real blob)
    fake = os.path.join(acc, "fake-keychain.json")
    with open(fake, "w") as f:
        f.write('{"claudeAiOauth": {"accessToken": "at-F0", "refreshToken": "rt-F0", "expiresAt": 9999999999999}}')
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fake
    os.makedirs(os.path.join(acc, "homes"))
    epoch.write_epoch(acc, "shadow", 10)

    # freeze: journal appears, generation bumped
    rec = seedflow.freeze(acc, "a@x.com")
    ok(rec["phase"] == "QUIESCED" and rec["email"] == "a@x.com", "freeze -> QUIESCED journal")
    ok(epoch.read_epoch(acc)["generation"] == 11, "freeze bumps generation")

    # a v1 mutator that snapshotted gen 10 now trips its fence
    fenced = False
    try:
        epoch.fence(acc, {"state": "shadow", "generation": 10}, ("v1", "shadow"))
    except epoch.EpochFenced:
        fenced = True
    ok(fenced, "pre-freeze v1 snapshot fenced after freeze")

    # double-freeze refused
    raised = False
    try:
        seedflow.freeze(acc, "b@x.com")
    except RuntimeError:
        raised = True
    ok(raised, "second concurrent SEEDING refused")

    # (r2) freeze records NO pgid — protects against a caller-shell PGID that lives on.
    ok("pgid" not in rec, "freeze does NOT record the caller pgid (r2 caller-pgid fix)")

    # phase transitions persist
    seedflow._set_phase(acc, rec, "LOGIN_STARTED")   # fp_F0 already journaled at freeze (r8)
    ok(seedflow._journal_read(acc)["phase"] == "LOGIN_STARTED", "phase persisted")

    # (r2 finding 3) `extra` may NOT override a protected field (txn/seq/phase/...)
    raised = False
    try:
        seedflow._set_phase(acc, dict(seedflow._journal_read(acc)), "HOME_WRITTEN", txn="forged")
    except RuntimeError as e:
        raised = "protected" in str(e)
    ok(raised, "_set_phase refuses to override protected fields via extra (finding 3)")

    # (r3 MAJOR1) amend_leader is the LOCKED + txn-checked path the setsid child uses —
    # a wrong txn is refused; a correct one sets pgid/leader and bumps the sequence.
    jj = seedflow._journal_read(acc)
    seq0 = jj["seq"]
    raised = False
    try:
        seedflow.amend_leader(acc, "wrong-txn", 111, 222, "start-token")
    except RuntimeError as e:
        raised = "txn mismatch" in str(e)
    ok(raised, "amend_leader refuses a wrong txn (r3 MAJOR1)")
    seedflow.amend_leader(acc, jj["txn"], 111, 222, "start-token")
    jj2 = seedflow._journal_read(acc)
    ok(jj2["pgid"] == 111 and jj2["leader_pid"] == 222 and jj2["leader_start"] == "start-token"
       and jj2["seq"] == seq0 + 1,
       "amend_leader sets pgid/leader + bumps seq under the lock (r3 MAJOR1)")
    # reset the leader fields so the recovery cases below start clean
    jj2.pop("pgid", None); jj2.pop("leader_pid", None); jj2.pop("leader_start", None)
    seedflow._journal_write(acc, jj2)

    # recovery: the dedicated child armed a LIVE pgid -> leave the live holder alone
    j = seedflow._journal_read(acc)
    j["pgid"] = os.getpgid(0)
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)
    ok(v.startswith("holder-alive"), "recovery leaves a live holder alone")

    # (r2 new blocker) LOGIN_STARTED with NO armed pgid (child never wrote one) ->
    # RETAINED (never cleared): the caller pgid is deliberately not recorded.
    j = seedflow._journal_read(acc)
    j.pop("pgid", None); j.pop("leader_pid", None); j.pop("leader_start", None)
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)
    ok(v.startswith("RETAINED") and "no dedicated pgid" in v,
       "LOGIN_STARTED with no armed pgid -> RETAINED (r2 caller-pgid fix)")

    # (finding 1) recovery: dead ARMED pgid, LOGIN_STARTED, but NO leader identity yet
    # (the setsid child never finished amending) -> RETAINED, NEVER cleared.
    j = seedflow._journal_read(acc)
    j["pgid"] = 999999999          # provably dead pgid (armed then died)
    j.pop("leader_pid", None)
    j.pop("leader_start", None)
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)
    ok(v.startswith("RETAINED") and "leader identity" in v,
       "LOGIN_STARTED without leader identity -> RETAINED (finding 1)")
    ok(seedflow._journal_read(acc) is not None, "journal kept (login child may be live)")

    # (finding 1) LOGIN_STARTED with a DEAD leader recorded + slot == F0 -> now the
    # child provably never landed, so a clear is safe.
    j = seedflow._journal_read(acc)
    j.update({"pgid": 999999999, "leader_pid": 999999998, "leader_start": "long gone"})
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)   # fake slot still == journaled F0 (same fake file)
    ok(v.startswith("cleared"), f"LOGIN_STARTED + dead leader + slot==F0 -> cleared ({v})")
    ok(seedflow._journal_read(acc) is None, "journal removed on clear")
    gen_after = epoch.read_epoch(acc)["generation"]
    ok(gen_after == 12, "clear bumps generation again")

    # dead ARMED identity used by the SAFE-phase cases below (pgid + leader, dead)
    DEADID = {"pgid": 999999999, "leader_pid": 999999998, "leader_start": "long gone"}

    # recovery: dead holder, HOME_WRITTEN -> RETAINED (unproven keychain phase)
    rec2 = seedflow.freeze(acc, "c@x.com")
    j = seedflow._journal_read(acc)
    j.update(dict(DEADID, phase="HOME_WRITTEN"))
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)
    ok(v.startswith("RETAINED"), "HOME_WRITTEN + dead holder -> freeze RETAINED")
    ok(seedflow._journal_read(acc) is not None, "journal kept on RETAINED")

    # (r3 IB1) a SAFE phase (VERIFIED) with a dead pgid but MISSING leader identity
    # must RETAIN — a dead pgid + F0 is NOT sufficient without matched-dead leader.
    j = seedflow._journal_read(acc)
    j.update({"pgid": 999999999, "phase": "VERIFIED"})
    j.pop("leader_pid", None); j.pop("leader_start", None)
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)
    ok(v.startswith("RETAINED") and "leader identity missing" in v,
       "VERIFIED + dead pgid but NO leader identity -> RETAINED (r3 IB1)")

    # recovery: VERIFIED + leader dead + slot==F0 -> cleared
    j = seedflow._journal_read(acc)
    j.update(dict(DEADID, phase="VERIFIED"))
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)
    ok(v.startswith("cleared") and "VERIFIED" in v, f"VERIFIED + leader dead + slot==F0 -> cleared ({v})")

    # (rev 9) VERIFIED but slot changed -> RETAINED even in a 'safe' phase
    rec3 = seedflow.freeze(acc, "d@x.com")
    j = seedflow._journal_read(acc)
    j.update(dict(DEADID, phase="VERIFIED", fp_F0="something-else"))
    seedflow._journal_write(acc, j)
    v = seedflow.recover(acc)
    ok(v.startswith("RETAINED") and "slot != journaled F0" in v,
       "VERIFIED + slot mismatch -> RETAINED (rev 9 universal fp==F0)")
    # clean up for any later assertions
    seedflow._journal_write(acc, dict(j, phase="ABORTED-test"))
    os.remove(os.path.join(acc, seedflow.MARKER))

    # (r3 IB2) restore_action decision table — non-interactive, keyed on JOURNALED fp_F0:
    ok(seedflow.restore_action("<empty>", False) == "delete",
       "restore_action: empty original slot -> delete the harvest (IB2)")
    ok(seedflow.restore_action("<empty>", True) == "delete",
       "restore_action: empty original slot -> delete even if an archive exists (IB2)")
    ok(seedflow.restore_action("fp-abc", True) == "restore",
       "restore_action: nonempty F0 + archive present -> restore (IB2)")
    ok(seedflow.restore_action("fp-abc", False) == "fail-closed",
       "restore_action: nonempty F0 + archive MISSING -> FAIL CLOSED, never delete (IB2)")

    # (r3 credibility) _locked=True lets a caller that ALREADY holds the bank lock advance
    # a phase WITHOUT re-acquiring it (the publication self-deadlock fix). Simulate by
    # holding the bank lock and advancing with _locked=True; a NON-locked call would block.
    recL = seedflow.freeze(acc, "L@x.com")
    seedflow._set_phase(acc, seedflow._journal_read(acc), "LOGIN_STARTED")
    import banklock as _bl
    _held = _bl.BankLock(acc)
    ok(_held.acquire(timeout=5), "held the bank lock for the _locked publication test")
    try:
        seedflow._set_phase(acc, seedflow._journal_read(acc), "HOME_WRITTEN", _locked=True)
        ok(seedflow._journal_read(acc)["phase"] == "HOME_WRITTEN",
           "_locked=True advances a phase while the caller holds the bank lock (no deadlock)")
    finally:
        _held.release()
    # clean up this transaction
    os.remove(os.path.join(acc, seedflow.MARKER))

    # (r2 new blocker) no-pgid QUIESCED + slot==F0 -> the only safe no-pgid clear
    recq = seedflow.freeze(acc, "q@x.com")
    ok(seedflow.recover(acc).startswith("cleared"),
       "no-pgid QUIESCED + slot==F0 -> cleared (nothing ever started)")

    # (r2 new blocker) unfreeze REQUIRES phase PUBLISHED — refuses mid-seed
    recu = seedflow.freeze(acc, "u@x.com")
    raised = False
    try:
        seedflow.unfreeze(acc)
    except RuntimeError as e:
        raised = "PUBLISHED" in str(e)
    ok(raised, "unfreeze refused when phase != PUBLISHED (r2 new blocker)")
    ok(seedflow._journal_read(acc) is not None, "freeze retained on refused unfreeze")
    # advance to PUBLISHED the legal way, then unfreeze succeeds (slot still F0)
    for ph in ("LOGIN_STARTED", "HOME_WRITTEN", "VERIFIED", "PUBLISHED"):
        seedflow._set_phase(acc, seedflow._journal_read(acc), ph)
    seedflow.unfreeze(acc)
    ok(seedflow._journal_read(acc) is None, "unfreeze clears from PUBLISHED (slot==F0)")

    # (r2 new blocker) freeze REFUSES outside shadow (v1/v2)
    epoch.write_epoch(acc, "v2", 40)
    raised = False
    try:
        seedflow.freeze(acc, "z@x.com")
    except RuntimeError as e:
        raised = "shadow" in str(e)
    ok(raised, "freeze refused when epoch state != shadow (r2 new blocker)")
    epoch.write_epoch(acc, "shadow", 41)   # restore for the skeleton section

    # skeleton: per-home real dirs, control plane reserved, everything else linked
    claude_root = tempfile.mkdtemp(prefix="seed-root-")
    for d in ("projects", "skills", "accounts", "memory"):
        os.makedirs(os.path.join(claude_root, d))
    for f in ("CLAUDE.md", "settings.json", ".credentials.json"):
        open(os.path.join(claude_root, f), "w").write("x")
    staged = os.path.join(acc, "homes", ".staging", "d-at-x.com")
    audit = os.path.join(acc, "seed-audit.jsonl")
    linked = seedflow.build_skeleton(staged, claude_root, audit)
    ok(os.path.isdir(os.path.join(staged, "backups"))
       and os.path.isdir(os.path.join(staged, "archive")), "per-home dirs are real")
    ok(not os.path.lexists(os.path.join(staged, "accounts")), "control plane NOT projected")
    ok(not os.path.lexists(os.path.join(staged, ".credentials.json")),
       "per-home credential never symlinked")
    ok(os.path.islink(os.path.join(staged, "projects"))
       and os.path.islink(os.path.join(staged, "CLAUDE.md")), "shared entries symlinked")
    ok("memory" in linked and "settings.json" in linked, "audit lists the links")
    ok(os.path.exists(audit), "seed audit log written")

    # (r8 #1) three-valued keychain read: present / absent / error are DISTINCT.
    blob, raw, st = seedflow._sh_keychain_read()   # fake file present
    ok(st == "present" and blob and blob["claudeAiOauth"]["accessToken"] == "at-F0",
       "keychain read: present slot -> ('present', blob)")
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN_MODE"] = "error"
    _b, _r, st_err = seedflow._sh_keychain_read()
    ok(st_err == "error" and _b is None, "keychain read: locked/denied -> ('error', None) (r8 #1)")
    del os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN_MODE"]
    missing_fake = os.path.join(acc, "no-such-keychain.json")
    _bm, _rm, st_abs = (lambda: (os.environ.__setitem__("ACCOUNT_BANK_FAKE_KEYCHAIN", missing_fake),
                                 seedflow._sh_keychain_read())[1])()
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fake   # restore
    ok(st_abs == "absent" and _bm is None, "keychain read: no file -> ('absent', None), distinct from error (r8 #1)")

    # (r8 #1) freeze ABORTS fail-closed on an unreadable slot — never journals F0="<empty>".
    acc1 = tempfile.mkdtemp(prefix="seed-kcerr-")
    os.makedirs(os.path.join(acc1, "homes"))
    epoch.write_epoch(acc1, "shadow", 1)
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN_MODE"] = "error"
    raised = False
    try:
        seedflow.freeze(acc1, "err@x.com")
    except RuntimeError as e:
        raised = "unreadable" in str(e)
    del os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN_MODE"]
    ok(raised, "freeze ABORTS on unreadable keychain (never journals F0 from a failed read) (r8 #1)")
    ok(seedflow._journal_read(acc1) is None, "no SEEDING journal left behind after aborted freeze")

    # (r8 #1) unfreeze REFUSES to clear when the slot is unreadable at clear time.
    acc1b = tempfile.mkdtemp(prefix="seed-unf-")
    os.makedirs(os.path.join(acc1b, "homes"))
    epoch.write_epoch(acc1b, "shadow", 1)
    rk = seedflow.freeze(acc1b, "u@x.com")
    for ph in ("LOGIN_STARTED", "HOME_WRITTEN", "VERIFIED", "PUBLISHED"):
        seedflow._set_phase(acc1b, seedflow._journal_read(acc1b), ph)
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN_MODE"] = "error"
    raised = False
    try:
        seedflow.unfreeze(acc1b)
    except RuntimeError as e:
        raised = "unreadable at clear time" in str(e)
    del os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN_MODE"]
    ok(raised and seedflow._journal_read(acc1b) is not None,
       "unfreeze REFUSES + RETAINS freeze on unreadable slot at clear time (r8 #1)")

    # (r8 #5) crash between the final rename and the READY registry commit: the FINAL home
    # dir exists but is NOT READY-registered. recover() must RETAIN (never auto-clear the
    # freeze abandoning a published-but-unusable home), even in the SAFE phase VERIFIED.
    import registry  # noqa: E402
    acc5 = tempfile.mkdtemp(prefix="seed-halfpub-")
    os.makedirs(os.path.join(acc5, "homes"))
    epoch.write_epoch(acc5, "shadow", 1)
    seedflow.freeze(acc5, "hp@x.com")
    final5 = os.path.join(acc5, "homes", seedflow.safe_email("hp@x.com"))
    os.makedirs(final5)                                   # renamed into place, READY not committed
    j5 = seedflow._journal_read(acc5)
    j5.update({"pgid": 999999999, "leader_pid": 999999998, "leader_start": "long gone",
               "phase": "VERIFIED"})
    seedflow._journal_write(acc5, j5)
    v5 = seedflow.recover(acc5)   # slot still == F0 (same fake file)
    ok(v5.startswith("RETAINED") and "NOT READY-registered" in v5,
       f"VERIFIED + FINAL exists but unregistered -> RETAINED, not cleared (r8 #5): {v5}")
    ok(seedflow._journal_read(acc5) is not None, "freeze RETAINED for the half-published home (r8 #5)")
    # once the READY entry is committed, the same recovery may clear (home is usable).
    registry.publish_ready(acc5, "hp@x.com", final5, "uuid-hp")
    v5b = seedflow.recover(acc5)
    ok(v5b.startswith("cleared"), f"VERIFIED + FINAL READY-registered -> clears normally (r8 #5): {v5b}")

    # (r8 #15) initial_archive durably snapshots the home credential (C1).
    home15 = tempfile.mkdtemp(prefix="seed-init-")
    with open(os.path.join(home15, ".credentials.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"C1"}}')
    dest = seedflow.initial_archive(home15)
    ok(dest and os.path.exists(dest) and "seed-initial" in dest, "initial_archive writes a snapshot (r8 #15)")
    ok(json.load(open(dest))["claudeAiOauth"]["accessToken"] == "C1", "initial archive holds C1 verbatim (r8 #15)")
    ok(seedflow.initial_archive(tempfile.mkdtemp(prefix="seed-nocred-")) is None,
       "initial_archive is a no-op when there is no credential (r8 #15)")

    # (r9 #1) the seed-time archive runs on the STAGED home BEFORE the READY rename, so
    # C1 is captured while the home is still unreachable and travels with the atomic
    # rename — it can never be a post-READY C2 written by a launched session.
    stage1 = tempfile.mkdtemp(prefix="seed-stage-")
    os.makedirs(os.path.join(stage1, "archive"))
    with open(os.path.join(stage1, ".credentials.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"C1"}}')
    seedflow.initial_archive(stage1)                 # archive C1 while STAGED
    final1 = tempfile.mkdtemp(prefix="seed-final-"); os.rmdir(final1)
    os.rename(stage1, final1)                         # the atomic publication move
    arch1 = os.path.join(final1, "archive")
    snaps = [json.load(open(os.path.join(arch1, e)))["claudeAiOauth"]["accessToken"]
             for e in os.listdir(arch1) if e.endswith(".json")]
    ok("C1" in snaps, "C1 archived while STAGED survives the rename into the final home (r9 #1)")

    # (r10 #10) a PRESENT-but-malformed slot must NOT fingerprint to "<empty>" (which
    # makes restore_action DELETE it). freeze must record a non-empty "raw:" fingerprint,
    # archive the raw bytes, and select "restore" — for both an empty-dict `{}` and
    # non-JSON bytes. Also #11: the F0 archive dir is created + populated on first seed.
    for label, content in (("empty-dict", "{}"), ("non-json", "not-json-bytes")):
        accm = tempfile.mkdtemp(prefix=f"seed-mal-{label}-")
        os.makedirs(os.path.join(accm, "homes"))
        epoch.write_epoch(accm, "shadow", 1)
        fkm = os.path.join(accm, "malformed-kc.json")
        with open(fkm, "w") as f:
            f.write(content)
        os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fkm
        recm = seedflow.freeze(accm, f"{label}@x.com")
        os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fake   # restore for later cases
        ok(recm["fp_F0"] != "<empty>" and recm["fp_F0"].startswith("raw:"),
           f"present-but-{label} slot -> non-empty 'raw:' F0, never '<empty>' (r10 #10)")
        ok(recm["f0_archive"] and os.path.exists(recm["f0_archive"]),
           f"present-but-{label} slot -> raw bytes archived (r10 #10/#11)")
        ok(seedflow.restore_action(recm["fp_F0"], True) == "restore",
           f"restore_action for a present-but-{label} slot -> RESTORE, never delete (r10 #10)")
        ok(os.path.isdir(os.path.join(accm, "archive")),
           f"first seed creates accounts/archive ({label}) (r10 #11)")
    # _slot_fingerprint contract: absent stays "<empty>"; present-valid == _fp(blob)
    ok(seedflow._slot_fingerprint(None, None, "absent") == "<empty>",
       "_slot_fingerprint: absent slot -> '<empty>' (r10 #10)")
    _valid = {"claudeAiOauth": {"accessToken": "x"}}
    ok(seedflow._slot_fingerprint(_valid, "{}", "present") == seedflow._fp(_valid),
       "_slot_fingerprint: present valid blob -> normal credential fingerprint (r10 #10)")

    # (r13 #2) recovery judges liveness by the ORCHESTRATOR (add-account.sh parent), not the
    # dead /login child. A journal with a LIVE orchestrator must NOT be cleared mid-publication,
    # even at a SAFE phase (VERIFIED) with the login child dead + slot==F0.
    acc2 = tempfile.mkdtemp(prefix="seed-orch-")
    os.makedirs(os.path.join(acc2, "homes"))
    epoch.write_epoch(acc2, "shadow", 1)
    seedflow.freeze(acc2, "orch@x.com")
    # record THIS live test process as the orchestrator, then simulate the dead login child at VERIFIED
    seedflow.amend_orchestrator(acc2, seedflow._journal_read(acc2)["txn"], os.getpid())
    j2 = seedflow._journal_read(acc2)
    j2.update({"pgid": 999999999, "leader_pid": 999999998, "leader_start": "long gone",
               "phase": "VERIFIED"})
    seedflow._journal_write(acc2, j2)
    v2 = seedflow.recover(acc2)   # login child dead, slot==F0, BUT orchestrator (us) is alive
    ok(v2.startswith("holder-alive") and "orchestrator" in v2,
       f"recover leaves a LIVE-orchestrator transaction alone, not cleared (r13 #2): {v2}")
    ok(seedflow._journal_read(acc2) is not None, "freeze RETAINED while orchestrator alive (r13 #2)")
    # a DEAD orchestrator (+ dead child + slot==F0) at VERIFIED -> clears normally
    j2b = seedflow._journal_read(acc2)
    j2b["orch_pid"] = 999999997; j2b["orch_start"] = "also long gone"
    seedflow._journal_write(acc2, j2b)
    v2b = seedflow.recover(acc2)
    ok(v2b.startswith("cleared"), f"dead orchestrator + dead child + slot==F0 -> clears (r13 #2): {v2b}")

    # (seat) the credential-SEAT abstraction: file seat, slot seat (post-migration), migration
    # precedence, seat_write to the correct seat, never-destroy pre-archive, seat_fingerprint.
    # Uses the fake keychain (per-service files) — NEVER the real keychain.
    sh = tempfile.mkdtemp(prefix="seat-home-")
    VALID = {"accessToken": "S1", "refreshToken": "r1", "expiresAt": 9999999999999}
    # none: no file, no slot
    _b, _r, st, k = seedflow.seat_read(sh)
    ok(st == "absent" and k == "none", "seat_read: no file + no slot -> absent/none (seat)")
    # FILE seat
    with open(os.path.join(sh, ".credentials.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"FILE","refreshToken":"r","expiresAt":9}}')
    _b, _r, st, k = seedflow.seat_read(sh)
    ok(st == "present" and k == "file" and _b["claudeAiOauth"]["accessToken"] == "FILE",
       "seat_read: present file -> present/file (seat)")
    # seat_write on a file seat writes the FILE (via homewrite tier-1)
    seedflow.seat_write(sh, VALID, "seat-t")
    _b, _r, st, k = seedflow.seat_read(sh)
    ok(k == "file" and _b["claudeAiOauth"]["accessToken"] == "S1", "seat_write: file seat -> writes the file (seat)")
    # MIGRATION: delete the file, populate the per-config-dir slot (fake)
    os.remove(os.path.join(sh, ".credentials.json"))
    slot_svc = seedflow.config_slot_service(sh)
    with open(seedflow._fake_slot_path(fake, slot_svc), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"SLOT","refreshToken":"r","expiresAt":9}}')
    _b, _r, st, k = seedflow.seat_read(sh)
    ok(st == "present" and k == "slot" and _b["claudeAiOauth"]["accessToken"] == "SLOT",
       "seat_read: file gone + slot present -> present/slot (migration, not a loss) (seat)")
    # seat_write on a slot seat writes the SLOT, does NOT recreate the file
    fp_before = seedflow.seat_fingerprint(sh)
    seedflow.seat_write(sh, {"accessToken": "S2", "refreshToken": "r2", "expiresAt": 9999999999999}, "seat-t2")
    ok(not os.path.exists(os.path.join(sh, ".credentials.json")), "seat_write: slot seat did NOT recreate the file (seat)")
    _b, _r, st, k = seedflow.seat_read(sh)
    ok(k == "slot" and _b["claudeAiOauth"]["accessToken"] == "S2", "seat_write: slot seat -> writes the slot (seat)")
    ok(seedflow.seat_fingerprint(sh) != fp_before, "seat_fingerprint tracks the seat content change (seat)")
    # never-destroy: the slot seat_write pre-archived the S1 predecessor
    adir = os.path.join(sh, "archive")
    ok(os.path.isdir(adir) and any(e.endswith(".json") for e in os.listdir(adir)),
       "seat_write (slot) pre-archives the predecessor (never-destroy) (seat)")

    print(f"-- seedflow: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
