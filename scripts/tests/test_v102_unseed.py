#!/usr/bin/env python3
"""(v102) ITEM 3 — un-seeding a v2 READY home.

Seeding had no inverse: a home seeded by mistake, or for an account the owner stopped using,
stayed registered forever with a live OAuth grant in a keychain slot nobody could name.
unseed.py is that inverse, and the two things it must never do are destroy an unarchived
credential and remove a home something is still using.

Asserted here:
  * happy path — the credential is archived OUTSIDE the home first, the home's own archive/
    history is moved out, the keychain SLOT is deleted, the home tree and the registry entry
    are gone, and the summary says so;
  * refuse while the pointer targets the home under shadow|v2 (and, deliberately, proceed
    under v1 where the pointer is inert and repoint refuses to move it);
  * refuse while a session is live on the home, or a restart lease is held on one; UNKNOWN
    liveness counts as live;
  * refuse during a SEEDING freeze;
  * every destructive step is behind --yes: without it, the plan prints and nothing changes;
  * an absent home is a clean no-op, and a half-finished removal resumes;
  * the archived copies survive the deletion — that is what makes un-seeding recoverable.

(v102-r2) and the four ways the first cut could still have destroyed the wrong thing:
  * the delete target must agree three ways — registry entry, canonical path, seat abstraction —
    so a stale/duplicate/foreign/symlinked mapping refuses instead of deleting B for A;
  * a launch admitted by claude-acct blocks the removal, and the registry entry goes not-READY
    BEFORE anything is destroyed, so a launch admitted mid-removal refuses instead;
  * BOTH credential seats are archived before either is deleted (a home interrupted mid-migration
    holds a different credential in each, and seat_delete removes both);
  * a present-but-corrupt session store REFUSES — an unknown session set is never an empty one.

The keychain is ALWAYS the fake one (ACCOUNT_BANK_FAKE_KEYCHAIN); no test here can reach the
real login keychain or the real accounts dir.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)

_pass = _fail = 0


def ok(cond, name):
    global _pass, _fail
    if cond:
        _pass += 1; print(f"  ok   {name}")
    else:
        _fail += 1; print(f"  FAIL {name}")


CRED = '{"claudeAiOauth":{"accessToken":"at-home","refreshToken":"rt-home",' \
       '"expiresAt":9999999999999,"subscriptionType":"max"}}'


def new_acc(tag):
    """A fresh accounts dir with a stub keychain, a shadow epoch and an empty homes tree."""
    base = tempfile.mkdtemp(prefix=f"v102-unseed-{tag}-")
    acc = os.path.join(base, "accounts")
    os.makedirs(os.path.join(acc, "homes"))
    fake = os.path.join(base, "fake-keychain.json")
    open(fake, "w").write("{}")
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fake
    os.environ.pop("ACCOUNT_BANK_FAKE_KEYCHAIN_MODE", None)
    import epoch
    epoch.write_epoch(acc, "shadow", 5)
    return acc, fake


def seed_home(acc, email, seat="slot", history=2):
    """A published-looking READY home: registry entry + a credential in the given seat +
    some archiver history inside the home."""
    import bank_common
    import registry
    import seedflow
    # the production layout: add-account.sh publishes to homes/<safe_email> verbatim
    home = os.path.join(acc, "homes", bank_common.safe_email(email))
    os.makedirs(os.path.join(home, "archive"), exist_ok=True)
    os.makedirs(os.path.join(home, "backups"), exist_ok=True)
    if seat == "slot":
        seedflow._sh_keychain_write(seedflow.config_slot_service(home), CRED)
    elif seat == "file":
        open(os.path.join(home, ".credentials.json"), "w").write(CRED)
    for i in range(history):
        open(os.path.join(home, "archive", f"2026010{i}T000000Z-1-0-observed.json"),
             "w").write(CRED)
    registry.publish_ready(acc, email, home, f"uuid-{email}")
    return home


def slot_file(fake, home):
    import seedflow
    return seedflow._fake_slot_path(fake, seedflow.config_slot_service(home))


def register_session(acc, sid, home, pid, tombstone=False):
    store = os.path.join(acc, "sessions.json")
    d = json.load(open(store)) if os.path.exists(store) else {}
    d[sid] = {"home": home, "pid": pid, "proc_start": "", "state": "IDLE",
              "tombstone": tombstone}
    json.dump(d, open(store, "w"))


def run_cli(acc, email, *flags):
    p = subprocess.run([sys.executable, os.path.join(AB, "unseed.py"), acc, email] + list(flags),
                       capture_output=True, text=True, env=dict(os.environ))
    return p.returncode, p.stdout, p.stderr


def main():
    import registry
    import seedflow
    import unseed

    SID = "11111111-2222-3333-4444-555555555555"

    # ---- happy path ------------------------------------------------------------
    acc, fake = new_acc("happy")
    home = seed_home(acc, "a@x.com")
    slot = slot_file(fake, home)
    ok(os.path.exists(slot), "premise: the home's credential is in its per-config-dir SLOT")

    rc, out, err = run_cli(acc, "a@x.com", "--yes", "--json")
    d = json.loads(out)
    ok(rc == 0, f"un-seed --yes exits 0 (got {rc}: {err.strip()})")
    ok(d["home_removed"] is True and not os.path.exists(home), "the home directory is GONE")
    ok(d["registry_entry_removed"] is True and "a@x.com" not in registry.load(acc),
       "the registry entry is GONE (nothing can resolve the email to a home)")
    ok(d["keychain_slot_deleted"] is True and not os.path.exists(slot),
       "the per-config-dir keychain SLOT is deleted (no orphaned credential left behind)")
    ok(d["keychain_slot"] == seedflow.config_slot_service(home),
       "the slot name came from the seat abstraction, not a hand-rolled hash")

    kept = d["archived_credential"]
    ok(kept and os.path.exists(kept) and open(kept).read().strip() == CRED.strip(),
       "the credential is ARCHIVED, byte-intact, OUTSIDE the home — un-seeding is recoverable")
    ok(os.path.realpath(kept).startswith(os.path.realpath(os.path.join(acc, "archive"))),
       "...in the bank archive, which is exactly why it survived the home's deletion")
    hist = d["archived_home_history"]
    ok(hist and os.path.isdir(hist) and len(os.listdir(hist)) == 2,
       "the home's OWN archive/ history was moved out too (the archiver's copies are kept)")

    rc2, out2, _ = run_cli(acc, "a@x.com", "--yes", "--json")
    ok(rc2 == 0 and json.loads(out2).get("would_remove") is False,
       "re-running on an already-removed account is a clean no-op, not an error")

    # ---- --yes is required for every destructive step --------------------------
    acc, fake = new_acc("confirm")
    home = seed_home(acc, "b@x.com")
    rc, out, err = run_cli(acc, "b@x.com", "--json")
    ok(rc == 73, f"without --yes the exit code is 73 confirmation-required (got {rc})")
    p = json.loads(out)
    ok(p["would_remove"] is True and p["home"] == home and p["seat_kind"] == "slot",
       "...and the plan describes exactly what WOULD go")
    ok(os.path.isdir(home) and "b@x.com" in registry.load(acc)
       and os.path.exists(slot_file(fake, home)),
       "...while home, registry entry and keychain slot are all still there")

    # ---- refuse: the pointer targets this home ---------------------------------
    acc, fake = new_acc("pointer")
    home = seed_home(acc, "c@x.com")
    import repoint
    repoint.repoint(acc, home, "test", registry_check=lambda h: registry.is_ready_home(acc, h))
    rc, out, err = run_cli(acc, "c@x.com", "--yes")
    ok(rc == 74, f"a home the pointer targets under shadow REFUSES with 74 (got {rc})")
    ok("Repoint first" in err or "repoint" in err.lower(), "...and names the fix")
    ok(os.path.isdir(home) and "c@x.com" in registry.load(acc), "...and nothing was removed")

    # under v1 the pointer is inert AND repoint refuses to move it, so refusing here would
    # strand the home forever. Proceed, and SAY the pointer is left dangling.
    import epoch
    epoch.write_epoch(acc, "v1", 9)
    rc, out, err = run_cli(acc, "c@x.com", "--yes", "--json")
    d = json.loads(out)
    ok(rc == 0 and d["home_removed"] is True,
       "under v1 the same home un-seeds (repoint cannot move an inert pointer)")
    ok(any("dangling" in w for w in d["warnings"]),
       "...and the dangling pointer is reported, not hidden")
    ok(registry.ready_home(acc, "c@x.com") is None,
       "...and the dangling pointer can never resolve: the READY gate needs an existing home")

    # ---- refuse: a live session is pinned to the home --------------------------
    acc, fake = new_acc("session")
    home = seed_home(acc, "d@x.com")
    register_session(acc, SID, home, os.getpid())          # this process: definitely alive
    rc, out, err = run_cli(acc, "d@x.com", "--yes")
    ok(rc == 74, f"a live session on the home REFUSES with 74 (got {rc})")
    ok("ALIVE" in err or "live" in err.lower(), "...and says which session and why")
    ok(os.path.isdir(home), "...and the home is untouched")

    # an UNKNOWN liveness probe must be treated as live, never as death
    register_session(acc, SID, home, 1)                    # pid 1: alive, EPERM on probe
    rc, out, err = run_cli(acc, "d@x.com", "--yes")
    ok(rc == 74, "an unprobeable session counts as LIVE (UNKNOWN is never death)")

    # a tombstoned session is not a session
    register_session(acc, SID, home, os.getpid(), tombstone=True)
    rc, out, err = run_cli(acc, "d@x.com", "--yes", "--json")
    ok(rc == 0 and json.loads(out)["home_removed"] is True,
       "a tombstoned record does not block the removal")

    # ---- refuse: a restart lease is held on a session of this home -------------
    acc, fake = new_acc("lease")
    home = seed_home(acc, "e@x.com")
    register_session(acc, SID, home, os.getpid(), tombstone=True)   # dead, but leased
    os.makedirs(os.path.join(acc, "sessions", f"{SID}.lease"))
    rc, out, err = run_cli(acc, "e@x.com", "--yes")
    ok(rc == 74, f"a HELD restart lease REFUSES with 74 even for a tombstoned session (got {rc})")
    ok("lease" in err.lower(), "...and names the lease as the reason")
    shutil.rmtree(os.path.join(acc, "sessions", f"{SID}.lease"))
    rc, _, _ = run_cli(acc, "e@x.com", "--yes")
    ok(rc == 0, "once the lease is released the same home un-seeds")

    # ---- refuse: a SEEDING transaction is in flight ----------------------------
    acc, fake = new_acc("freeze")
    home = seed_home(acc, "f@x.com")
    open(os.path.join(acc, ".seeding.json"), "w").write('{"phase":"QUIESCED"}')
    rc, out, err = run_cli(acc, "f@x.com", "--yes")
    ok(rc == 78, f"a SEEDING freeze fences the removal with 78 (got {rc})")
    ok(os.path.isdir(home), "...and the frozen homes tree is untouched")
    os.remove(os.path.join(acc, ".seeding.json"))
    ok(run_cli(acc, "f@x.com", "--yes")[0] == 0, "once the freeze lifts the removal proceeds")

    # ---- fail closed: an unreadable seat is never deleted ----------------------
    acc, fake = new_acc("kcerror")
    home = seed_home(acc, "g@x.com")
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN_MODE"] = "error"
    rc, out, err = run_cli(acc, "g@x.com", "--yes")
    ok(rc == 75, f"an UNREADABLE credential seat refuses with 75 (got {rc})")
    ok(os.path.isdir(home) and "g@x.com" in registry.load(acc),
       "...and nothing is destroyed: we never delete what we could not archive")
    os.environ.pop("ACCOUNT_BANK_FAKE_KEYCHAIN_MODE")
    ok(run_cli(acc, "g@x.com", "--yes")[0] == 0, "a readable keychain lets the same home go")

    # ---- absent / orphaned states ---------------------------------------------
    acc, fake = new_acc("absent")
    rc, out, err = run_cli(acc, "nobody@x.com", "--yes", "--json")
    ok(rc == 0 and json.loads(out) == {"email": "nobody@x.com", "would_remove": False,
                                       "reason": "absent"},
       "un-seeding an account that was never seeded is a clean no-op (exit 0)")

    # a crash between "home removed" and "registry entry removed": the entry survives,
    # pointing at nothing. It is inert, and a re-run must finish the job.
    acc, fake = new_acc("resume_entry")
    home = seed_home(acc, "h@x.com")
    shutil.rmtree(home)
    ok(registry.ready_home(acc, "h@x.com") is None,
       "premise: a registry entry whose home is gone is already inert (READY needs isdir)")
    rc, out, err = run_cli(acc, "h@x.com", "--yes", "--json")
    ok(rc == 0 and json.loads(out)["registry_entry_removed"] is True
       and "h@x.com" not in registry.load(acc),
       "a re-run finishes a half-done removal (the entry goes, no home to touch)")

    # the inverse orphan: a home directory with no registry entry still gets cleaned up
    acc, fake = new_acc("resume_home")
    home = seed_home(acc, "i@x.com")
    reg = registry.load(acc); reg.pop("i@x.com"); registry.save(acc, reg)
    rc, out, err = run_cli(acc, "i@x.com", "--yes", "--json")
    d = json.loads(out)
    ok(rc == 0 and d["home_removed"] is True and not os.path.exists(home),
       "an ORPHANED home (no registry entry) is still removed")
    ok(d["archived_credential"] and os.path.exists(d["archived_credential"]),
       "...and its credential is archived first, like any other")

    # ---- the file seat (a home that has never been launched) -------------------
    acc, fake = new_acc("fileseat")
    home = seed_home(acc, "j@x.com", seat="file")
    rc, out, err = run_cli(acc, "j@x.com", "--yes", "--json")
    d = json.loads(out)
    ok(rc == 0 and d["credential_file_removed"] is True and d["home_removed"] is True,
       "a never-launched home (FILE seat) un-seeds through the same path")
    ok(d["archived_credential"] and open(d["archived_credential"]).read().strip() == CRED.strip(),
       "...and its file credential is archived byte-intact before the home goes")

    # ---- an unsafe email cannot become a delete target -------------------------
    acc, fake = new_acc("unsafe")
    rc, out, err = run_cli(acc, "../../etc/passwd", "--yes")
    ok(rc == 64 and "unsafe" in err.lower(),
       "an unsafe email is rejected as usage (64), never resolved to a path")

    # ---- the claude-acct front door ---------------------------------------------
    acc, fake = new_acc("cli")
    home = seed_home(acc, "k@x.com")
    env = dict(os.environ, BANK_DIR=acc, ACCOUNT_BANK_SCRIPTS_DIR=AB)
    p = subprocess.run(["/bin/bash", os.path.join(AB, "claude-acct"), "--un-seed", "k@x.com"],
                       capture_output=True, text=True, env=env)
    ok(p.returncode == 73 and os.path.isdir(home),
       "claude-acct --un-seed without --yes prints the plan and changes nothing (73)")
    p = subprocess.run(["/bin/bash", os.path.join(AB, "claude-acct"), "--un-seed", "k@x.com",
                        "--yes", "--json"], capture_output=True, text=True, env=env)
    ok(p.returncode == 0 and json.loads(p.stdout)["home_removed"] is True,
       "claude-acct --un-seed <email> --yes removes the home")
    ok(not os.path.isdir(home), "...for real")

    # BANK_DIR must outrank ACCOUNT_BANK_DIR in the launcher too (THE bank-directory rule)
    acc, fake = new_acc("cli_bankdir")
    home = seed_home(acc, "l@x.com")
    decoy = tempfile.mkdtemp(prefix="v102-unseed-decoy-")
    p = subprocess.run(["/bin/bash", os.path.join(AB, "claude-acct"), "--un-seed", "l@x.com",
                        "--yes", "--json"], capture_output=True, text=True,
                       env=dict(os.environ, BANK_DIR=acc, ACCOUNT_BANK_DIR=decoy,
                                ACCOUNT_BANK_SCRIPTS_DIR=AB))
    ok(p.returncode == 0 and not os.path.isdir(home),
       "claude-acct resolves BANK_DIR over ACCOUNT_BANK_DIR (the destructive command cannot "
       "act on the wrong bank)")

    # ================= (v102-r2) review findings 1-4 =============================

    # ---- finding 1: the delete target must agree three ways --------------------
    # A stale mapping a@ -> homes/b-at-x.com deleted B's home and B's keychain slot while
    # removing only A's registry entry. The registry is still the only mapping consulted, but
    # its answer is now cross-verified against the canonical path and the seat abstraction.
    acc, fake = new_acc("crossverify")
    victim = seed_home(acc, "b@x.com")
    seed_home(acc, "a@x.com")
    reg = registry.load(acc)
    reg["a@x.com"]["home"] = victim                     # the stale/hostile mapping
    registry.save(acc, reg)
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75, f"a registry entry pointing at ANOTHER account's home refuses (got {rc})")
    ok(os.path.isdir(victim) and os.path.exists(slot_file(fake, victim)),
       "...and the other account's home AND keychain slot are untouched")
    ok("b@x.com" in registry.load(acc) and "a@x.com" in registry.load(acc),
       "...and no registry entry was removed either")

    # an absolute path outside the bank cannot become a delete target
    acc, fake = new_acc("escape")
    seed_home(acc, "a@x.com")
    outside = tempfile.mkdtemp(prefix="v102-unseed-outside-")
    open(os.path.join(outside, "precious.txt"), "w").write("do not delete me")
    reg = registry.load(acc); reg["a@x.com"]["home"] = outside; registry.save(acc, reg)
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75 and os.path.exists(os.path.join(outside, "precious.txt")),
       f"a home path OUTSIDE the bank refuses and is untouched (got {rc})")

    # a SYMLINK wearing the canonical name is not a home: un-seeding would delete its target
    acc, fake = new_acc("symlink")
    real_target = tempfile.mkdtemp(prefix="v102-unseed-target-")
    open(os.path.join(real_target, "precious.txt"), "w").write("do not delete me")
    import bank_common as _bc
    link = os.path.join(acc, "homes", _bc.safe_email("a@x.com"))
    os.symlink(real_target, link)
    registry.publish_ready(acc, "a@x.com", link, "uuid-a")
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75 and "SYMLINK" in err,
       f"a symlinked home refuses rather than deleting what it points at (got {rc})")
    ok(os.path.exists(os.path.join(real_target, "precious.txt")), "...and the target survives")

    # two entries claiming the same directory: one of them is stale, and removing either would
    # destroy the other's credential. Refuse and say so.
    acc, fake = new_acc("dup")
    home = seed_home(acc, "a@x.com")
    reg = registry.load(acc)
    reg["dup@x.com"] = dict(reg["a@x.com"])
    registry.save(acc, reg)
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75 and "dup@x.com" in err,
       f"two registry entries mapping to one home refuses and names both (got {rc})")
    ok(os.path.isdir(home), "...and nothing was removed")

    # a NOT-READY entry with no un-seed mark is an unfinished seeding, not a removal target
    acc, fake = new_acc("notready")
    home = seed_home(acc, "a@x.com")
    reg = registry.load(acc); reg["a@x.com"]["ready"] = False; registry.save(acc, reg)
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75 and "NOT READY" in err,
       f"a not-READY entry with no un-seed mark refuses (got {rc})")
    ok(os.path.isdir(home), "...and the half-published home is left for seedflow recover")

    # ---- finding 2: the launch-admission fence ---------------------------------
    import launchadmit
    acc, fake = new_acc("admission")
    home = seed_home(acc, "a@x.com")
    lk = launchadmit.lock(acc)
    ok(lk.acquire(timeout=5) is True, "premise: a launcher can take the admission lock")
    launchadmit.admit(acc, "a@x.com", home, os.getpid())     # this process: definitely alive
    lk.release()
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 74, f"a LIVE launch admission on the home refuses with 74 (got {rc})")
    ok("pinned launch" in err, "...and says a launch, not a session, is holding it")
    ok(os.path.isdir(home) and registry.load(acc)["a@x.com"]["ready"] is True,
       "...and the home is untouched and still READY (the refusal is before the mark)")

    # a DEAD launcher's admission is swept, not honoured forever
    d = os.path.join(acc, ".admissions")
    dead = json.load(open(os.path.join(d, f"{os.getpid()}.json")))
    os.remove(os.path.join(d, f"{os.getpid()}.json"))
    dead["pid"] = 999_999                                     # a pid that cannot exist
    dead["proc_start"] = ""
    json.dump(dead, open(os.path.join(d, "999999.json"), "w"))
    rc, out, err = run_cli(acc, "a@x.com", "--yes", "--json")
    ok(rc == 0 and json.loads(out)["home_removed"] is True,
       "a DEAD launcher's admission is swept and does not block the removal")
    ok(not os.path.exists(os.path.join(d, "999999.json")), "...and its marker is gone")

    # an admission we cannot PARSE is an unknown launch: refuse, never ignore
    acc, fake = new_acc("admission_corrupt")
    home = seed_home(acc, "a@x.com")
    os.makedirs(os.path.join(acc, ".admissions"))
    open(os.path.join(acc, ".admissions", "12.json"), "w").write("{not json")
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75 and os.path.isdir(home),
       f"an unreadable launch admission refuses (unknown launch, fail closed) (got {rc})")

    # (v102-r3) and neither is one that PARSES but cannot say which home it pinned. A marker
    # holding only a live pid used to pass liveness and then match no home, so the removal read
    # a launch it could not place as a launch that did not concern it — and deleted the home
    # that process was running on. Valid JSON is not an understood admission.
    acc, fake = new_acc("admission_homeless")
    home = seed_home(acc, "a@x.com")
    os.makedirs(os.path.join(acc, ".admissions"))
    json.dump({"pid": os.getpid()},                       # this process: definitely alive
              open(os.path.join(acc, ".admissions", f"{os.getpid()}.json"), "w"))
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75, f"a LIVE admission that names no home refuses (got {rc})")
    ok(os.path.isdir(home) and os.path.exists(slot_file(fake, home)),
       "...and the home a launch we cannot place might be using survives")
    ok(registry.load(acc)["a@x.com"].get("ready") is True,
       "...and it is still READY, because the refusal landed before anything was touched")

    # THE RACE ITSELF: the registry entry goes NOT-READY before anything is destroyed, so a
    # launcher arriving mid-removal refuses instead of pinning a home that is being deleted.
    acc, fake = new_acc("marked")
    home = seed_home(acc, "a@x.com")
    reg = registry.load(acc)
    reg["a@x.com"]["ready"] = False
    reg["a@x.com"][registry.UNSEEDING] = True                 # as the un-seeder marks it
    registry.save(acc, reg)
    ok(registry.ready_home(acc, "a@x.com") is None,
       "a marked entry stops resolving: claude-acct/launchadmit refuse the launch")
    ok(registry.is_ready_home(acc, home) is False,
       "...and the shim's by-path READY gate refuses it too")
    rc, out, err = run_cli(acc, "a@x.com", "--yes", "--json")
    ok(rc == 0 and json.loads(out)["home_removed"] is True,
       "...while a re-run of the un-seed itself finishes the job (that is what the mark is for)")

    # a refusal BEFORE any destruction puts the home back in service
    acc, fake = new_acc("rollback")
    home = seed_home(acc, "a@x.com")
    open(os.path.join(acc, "archive"), "w").write("not a directory")   # archive_blob will raise
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    os.remove(os.path.join(acc, "archive"))
    ok(rc == 75, f"an unarchivable credential refuses (got {rc}: {err.strip()[:80]})")
    ent = registry.load(acc)["a@x.com"]
    ok(ent.get("ready") is True and not ent.get(registry.UNSEEDING),
       "...and the intact home is READY again — a refusal must not strand it unlaunchable")
    ok(registry.ready_home(acc, "a@x.com") == home, "...so it can be launched again")

    # (v102-r3) A FAILURE BEFORE ANY EFFECT MUST NOT STRAND THE HOME. The un-seeding mark takes
    # a home out of service so nothing can launch into a removal in progress, and a refusal that
    # destroyed nothing has to give it back — that is what makes "nothing was touched" true. The
    # flag deciding this was set immediately BEFORE each destructive call, so it recorded what
    # the code had attempted rather than what had happened: a seat_delete or a move that failed
    # without changing anything left an intact, launchable home marked permanently unlaunchable.
    # It is now decided by observing the postcondition. These cases drive the failures directly,
    # because the ordering they exercise cannot be produced from the outside.
    def _rollback_case(tag, patch, seat="slot", history=2):
        """Run a real un-seed with one operation forced to fail, and report (Refused, entry).
        The seat cases seed NO archive history on purpose: with history present the move above
        them has already destroyed something by the time the seat is touched, and keeping the
        mark would then be right for a reason that has nothing to do with the seat."""
        _acc, _fake = new_acc(tag)
        _home = seed_home(_acc, "a@x.com", seat=seat, history=history)
        undo = patch(_home)
        try:
            unseed.unseed(_acc, "a@x.com")
            refused = None
        except unseed.Refused as e:
            refused = e
        finally:
            undo()
        return _acc, _fake, _home, refused, registry.load(_acc).get("a@x.com", {})

    def _seat_delete_raising(_home):
        original = seedflow.seat_delete

        def boom(*a, **k):
            raise OSError("the keychain went away between the read and the delete")
        seedflow.seat_delete = boom
        return lambda: setattr(seedflow, "seat_delete", original)

    acc, fake, home, refused, ent = _rollback_case("preeffect_seat", _seat_delete_raising, history=0)
    ok(refused is not None and refused.code == 75,
       f"a seat_delete that fails outright refuses with 75 (got {refused})")
    ok(os.path.isdir(home) and os.path.exists(slot_file(fake, home)),
       "...and the credential it never cleared is still there")
    ok(ent.get("ready") is True and not ent.get(registry.UNSEEDING),
       "...so the home goes back INTO service: attempting is not destroying")
    ok(registry.ready_home(acc, "a@x.com") == home, "...and it can be launched again")
    ok(run_cli(acc, "a@x.com", "--yes")[0] == 0, "...and un-seeded for real on a clean re-run")

    def _seat_delete_half(_home):
        original = seedflow.seat_delete

        def half(h, expect_slot=None):
            os.remove(os.path.join(h, ".credentials.json"))     # one form is already gone
            raise OSError("the keychain went away half way through")
        seedflow.seat_delete = half
        return lambda: setattr(seedflow, "seat_delete", original)

    acc, fake, home, refused, ent = _rollback_case("halfeffect_seat", _seat_delete_half,
                                                   seat="file", history=0)
    ok(refused is not None and refused.code == 75, "a HALF-completed seat_delete also refuses")
    ok(ent.get("ready") is False and ent.get(registry.UNSEEDING) is True,
       "...but the mark STAYS: a home with a cleared seat is one to finish removing, not launch")

    def _move_raising(_home):
        original = unseed.shutil

        def boom(src, dst):
            raise OSError("no space left on device")
        unseed.shutil = types.SimpleNamespace(move=boom, rmtree=shutil.rmtree)
        return lambda: setattr(unseed, "shutil", original)

    acc, fake, home, refused, ent = _rollback_case("preeffect_move", _move_raising)
    ok(refused is not None and refused.code == 75,
       "a history move that fails before touching the filesystem refuses with 75")
    ok(sorted(os.listdir(os.path.join(home, "archive"))) and os.path.isdir(home),
       "...with the home's archive/ history still whole inside the home")
    ok(ent.get("ready") is True and not ent.get(registry.UNSEEDING),
       "...and the home back in service — the first destructive step never ran")

    def _move_partial(_home):
        original = unseed.shutil

        def partial(src, dst):
            os.makedirs(dst)                       # a cross-device copy that died part way
            raise OSError("no space left on device")
        unseed.shutil = types.SimpleNamespace(move=partial, rmtree=shutil.rmtree)
        return lambda: setattr(unseed, "shutil", original)

    acc, fake, home, refused, ent = _rollback_case("halfeffect_move", _move_partial)
    ok(refused is not None and refused.code == 75, "a PARTIAL history move refuses too")
    ok(ent.get("ready") is False and ent.get(registry.UNSEEDING) is True,
       "...and keeps the mark: something moved, so the removal is the thing to finish")

    # ---- finding 3: BOTH seats are archived before either is deleted -----------
    # A home interrupted mid file->slot migration has a credential in each seat, and the slot's
    # is the NEWER one. seat_read names only the file (precedence), so archiving through it and
    # then calling seat_delete destroyed the newer credential unarchived.
    acc, fake = new_acc("dualseat")
    home = seed_home(acc, "a@x.com", seat="slot")             # slot holds CRED
    NEWER = CRED.replace("at-home", "at-newer-in-slot")
    import seedflow as _sf
    _sf._sh_keychain_write(_sf.config_slot_service(home), NEWER)
    open(os.path.join(home, ".credentials.json"), "w").write(CRED)   # stale file alongside it
    rc, out, err = run_cli(acc, "a@x.com", "--yes", "--json")
    d = json.loads(out)
    ok(rc == 0 and d["home_removed"] is True, f"a dual-seat home un-seeds (got {rc})")
    kept = [open(a["path"]).read().strip() for a in d["archived_credentials"]]
    ok(len(d["archived_credentials"]) == 2, "BOTH seats were archived, not just the precedence one")
    ok(NEWER.strip() in kept,
       "the SLOT's newer credential survives — the one the old code deleted unarchived")
    ok(CRED.strip() in kept, "...and so does the file seat's")
    ok(d["archived_credential"] == d["archived_credentials"][0]["path"]
       and d["archived_credentials"][0]["seat"] == "file",
       "the headline field still names the precedence seat (the app's caption is unchanged)")
    ok(d["credential_file_removed"] is True and d["keychain_slot_deleted"] is True,
       "...and both seats are actually cleared")

    # ---- finding 4: a corrupt session store fails CLOSED -----------------------
    acc, fake = new_acc("tornstore")
    home = seed_home(acc, "a@x.com")
    open(os.path.join(acc, "sessions.json"), "w").write('{"11111111-2222-3333-4444-5')
    rc, out, err = run_cli(acc, "a@x.com", "--yes")
    ok(rc == 75, f"a present-but-torn session store REFUSES (got {rc})")
    ok("unreadable" in err.lower(), "...and says the session set is unknown, not empty")
    ok(os.path.isdir(home) and "a@x.com" in registry.load(acc), "...and nothing was removed")
    import sessions as _sess
    ok(_sess._load(acc) == {},
       "premise: the DISPLAY reader still returns {} for a torn store (that is its job)")
    try:
        _sess.load_strict(acc)
        _strict_raised = False
    except _sess.StoreUnreadable:
        _strict_raised = True
    ok(_strict_raised, "...while the destructive-gate reader raises on the same store")
    os.remove(os.path.join(acc, "sessions.json"))
    ok(run_cli(acc, "a@x.com", "--yes")[0] == 0,
       "an ABSENT store is still a clean no-sessions answer (nothing ever registered)")

    print(f"  -- v102_unseed: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
