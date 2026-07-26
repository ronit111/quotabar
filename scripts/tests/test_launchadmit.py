#!/usr/bin/env python3
"""(v102-r2) The LAUNCH ADMISSION fence — review finding 2, at the module level.

un-seed already refused while a SESSION was live on a home. A session only exists once the
launched CLI runs its SessionStart hook, so between `claude-acct` resolving a READY home and
that hook firing, the launch was invisible to every check un-seed makes. launchadmit is the
record that closes that window, and the properties it has to hold are:

  * an admission survives exactly as long as the process it names — a DEAD launcher blocks
    nothing, an alive one blocks everything, and UNKNOWN counts as alive;
  * a marker that cannot be read is an unknown launch, so it RAISES rather than being ignored
    (the whole failure this fence exists to prevent is treating an unknown launch as no launch);
  * (v102-r3) so is one that reads fine but does not say what it has to say: a LIVE admission
    must satisfy the whole schema, because a launch we cannot place on a home is exactly the
    unknown launch above wearing valid JSON;
  * (v102-r3) resolving the home and recording the admission are ONE lock-held operation, and
    a launcher that resolved earlier must have its answer revalidated inside the lock — that
    gap is the race, not the recording;
  * the lock is genuinely mutual, and it is NOT the bank lock — a pinned launch must not queue
    behind a poll holding the bank lock across a network call;
  * the CLI refuses a not-READY entry, and records nothing when it refuses.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)

_pass = _fail = 0
_ABSENT = object()      # "this key is missing entirely", as distinct from a bad value


def ok(cond, name):
    global _pass, _fail
    if cond:
        _pass += 1; print(f"  ok   {name}")
    else:
        _fail += 1; print(f"  FAIL {name}")


def new_acc(tag):
    base = tempfile.mkdtemp(prefix=f"v102-admit-{tag}-")
    acc = os.path.join(base, "accounts")
    os.makedirs(os.path.join(acc, "homes"))
    return acc


def main():
    import launchadmit
    import registry

    acc = new_acc("basic")
    home = os.path.join(acc, "homes", "a-at-x.com")
    os.makedirs(home)
    registry.publish_ready(acc, "a@x.com", home, "uuid-a")

    ok(launchadmit.live_admissions(acc) == [],
       "no admissions directory at all is an empty answer, not an error")

    p = launchadmit.admit(acc, "a@x.com", home, os.getpid())
    ok(os.path.exists(p) and os.stat(p).st_mode & 0o777 == 0o600, "an admission is 0600")
    ok(os.stat(os.path.dirname(p)).st_mode & 0o777 == 0o700, "...in a 0700 directory")
    live = launchadmit.live_admissions(acc)
    ok(len(live) == 1 and live[0]["home"] == home and live[0]["email"] == "a@x.com",
       "this process's admission is LIVE and names the home it launched on")

    # a dead pid's claim is swept on sight
    rec = json.load(open(p))
    os.remove(p)
    rec["pid"] = 999_999
    rec["proc_start"] = ""
    dead = os.path.join(acc, ".admissions", "999999.json")
    json.dump(rec, open(dead, "w"))
    ok(launchadmit.live_admissions(acc) == [], "a provably DEAD launcher's admission is ignored")
    ok(not os.path.exists(dead), "...and swept, so the directory cannot grow without bound")

    # pid 1 with no recorded start-time: liveness falls back to bare existence, and a live pid
    # we cannot prove anything else about counts as LIVE — the fail-closed direction.
    rec["pid"] = 1
    rec["proc_start"] = ""
    json.dump(rec, open(os.path.join(acc, ".admissions", "1.json"), "w"))
    ok(len(launchadmit.live_admissions(acc)) == 1,
       "a live launcher with no recorded start-time still counts as LIVE")
    # a start-time MISMATCH is the one case where an existing pid is provably not our launcher
    # (the pid was reused), and only then is the claim dropped.
    rec["proc_start"] = "a start time this process never had"
    json.dump(rec, open(os.path.join(acc, ".admissions", "1.json"), "w"))
    ok(launchadmit.live_admissions(acc) == [],
       "a REUSED pid is not the launcher we admitted — proven gone, so swept")

    # an unreadable marker is an unknown launch: raise, never skip
    open(os.path.join(acc, ".admissions", "77.json"), "w").write("{not json")
    try:
        launchadmit.live_admissions(acc)
        raised = False
    except launchadmit.AdmissionError:
        raised = True
    ok(raised, "a corrupt admission RAISES — an unreadable launch is not an absent one")
    open(os.path.join(acc, ".admissions", "77.json"), "w").write('{"email": "a@x.com"}')
    try:
        launchadmit.live_admissions(acc)
        raised = False
    except launchadmit.AdmissionError:
        raised = True
    ok(raised, "...and so does one with no usable pid")
    os.remove(os.path.join(acc, ".admissions", "77.json"))

    # ---- (v102-r3) a LIVE admission must satisfy the WHOLE schema ---------------
    # `{"pid": <a live pid>}` is valid JSON and passes liveness, and that was enough to be
    # returned as a live admission. Un-seed then compared its home against the target, found
    # nothing to compare, and passed it over as somebody else's launch — deleting the home the
    # process it could not place was actually running on. A live launch we cannot place is the
    # same unknown launch a corrupt marker is, so it raises the same way.
    good = json.load(open(launchadmit.admit(acc, "a@x.com", home, os.getpid())))
    ok(len(launchadmit.live_admissions(acc)) == 1, "premise: one well-formed LIVE admission")

    def marker(**over):
        rec = dict(good)
        for k, v in over.items():
            if v is _ABSENT:
                rec.pop(k, None)
            else:
                rec[k] = v
        p = os.path.join(acc, ".admissions", "88.json")
        json.dump(rec, open(p, "w"))
        try:
            launchadmit.live_admissions(acc)
            return False
        except launchadmit.AdmissionError:
            return True
        finally:
            os.remove(p)

    ok(marker(home=_ABSENT), "a LIVE admission that names NO home raises — it cannot be placed")
    ok(marker(home=""), "...an empty home is not a home either")
    ok(marker(home=None), "...nor a null one")
    ok(marker(home="homes/a-at-x.com"),
       "...nor a relative path (the un-seeder compares canonical absolute homes)")
    ok(marker(home=home + "/."),
       "...nor an un-normalized one, which would compare unequal to the same directory")
    ok(marker(email=_ABSENT) and marker(email="../../etc/passwd"),
       "a missing or path-unsafe email raises — the marker names an account or it names nothing")
    ok(marker(ts=_ABSENT) and marker(ts="yesterday") and marker(ts=0),
       "a missing, non-numeric or non-positive timestamp raises")
    ok(marker(proc_start=_ABSENT) and marker(proc_start=17),
       "a malformed start-time raises — liveness cannot be judged the way it was recorded")
    ok(marker(pid=0) and marker(pid=-1) and marker(pid="123") and marker(pid=True),
       "a non-positive, non-integer or boolean pid raises (it did not even have to be positive)")

    # ...but a marker whose process is provably DEAD is still swept whatever else it says: a
    # claim nobody is holding blocks nothing, so garbage cannot wedge every removal forever.
    junk = os.path.join(acc, ".admissions", "999999.json")
    json.dump({"pid": 999_999, "proc_start": "", "junk": True}, open(junk, "w"))
    try:
        swept = launchadmit.live_admissions(acc)
        raised = False
    except launchadmit.AdmissionError:
        swept, raised = None, True
    ok(not raised and len(swept) == 1 and not os.path.exists(junk),
       "a DEAD launcher's malformed marker is swept, not raised on (pid is checked first)")

    # ---- the lock -------------------------------------------------------------
    import banklock
    lk = launchadmit.lock(acc)
    ok(lk.acquire(timeout=5) is True, "the admission lock can be taken")
    other = launchadmit.lock(acc)
    ok(other.acquire(timeout=1) is False, "...and it is genuinely mutual")
    bank = banklock.BankLock(acc)
    ok(bank.acquire(timeout=1) is True,
       "the BANK lock is still free — a pinned launch never waits on the poll's lock")
    bank.release()
    lk.release()

    # ---- (v102-r3) admit_ready: resolving and recording are ONE lock hold -------
    # G8 resolved its home, THEN took the lock and recorded that pre-lock answer with the
    # low-level admit(). An un-seed fitting entirely inside that gap — take the lock, see no
    # admission, mark the entry not-READY, release, delete — left the gate launching into a
    # deleted config dir, with a marker that arrived after the only check that would have read
    # it. The lock-held re-resolve is what closes it, and both launchers now go through it.
    acc = new_acc("ready")
    home = os.path.join(acc, "homes", "a-at-x.com")
    os.makedirs(home)
    registry.publish_ready(acc, "a@x.com", home, "uuid-a")

    ok(launchadmit.admit_ready(acc, "a@x.com", os.getpid()) == home,
       "admit_ready resolves the READY home and returns it")
    ok(len(launchadmit.live_admissions(acc)) == 1, "...recording exactly one admission for it")

    # the pre-resolved path is revalidated, not trusted
    ok(launchadmit.admit_ready(acc, "a@x.com", os.getpid(), expect_home=home) == home,
       "a launcher's own pre-resolved home is accepted when it still agrees")
    try:
        launchadmit.admit_ready(acc, "a@x.com", os.getpid(),
                                expect_home=os.path.join(acc, "homes", "somewhere-else"))
        refused = False
    except launchadmit.AdmissionRefused:
        refused = True
    ok(refused, "a home that MOVED under the launcher is refused, never launched into")

    # THE RACE, in the order it happens: the launcher resolves, the un-seeder marks the entry
    # out of service, and only then does the launcher reach the lock.
    resolved = registry.ready_home(acc, "a@x.com")
    registry.mark_unseeding(acc, "a@x.com")                 # as un-seed does, under this lock
    before = len(launchadmit.live_admissions(acc))
    try:
        launchadmit.admit_ready(acc, "a@x.com", os.getpid(), expect_home=resolved)
        refused = False
    except launchadmit.AdmissionRefused:
        refused = True
    ok(refused, "a home marked out of service AFTER the launcher resolved it is refused")
    ok(len(launchadmit.live_admissions(acc)) == before,
       "...and nothing is recorded — the fence cannot be entered once the door is shut")
    registry.clear_unseeding(acc, "a@x.com")

    # a contended lock is its own answer: the un-seeder is mid-fence, so refusing is correct
    blocker = launchadmit.lock(acc)
    ok(blocker.acquire(timeout=5) is True, "premise: an un-seed holds the admission lock")
    before = len(launchadmit.live_admissions(acc))
    try:
        launchadmit.admit_ready(acc, "a@x.com", os.getpid(), timeout=1)
        contended = False
    except launchadmit.AdmissionContended:
        contended = True
    ok(contended, "admit_ready reports a contended lock distinctly from a refusal")
    ok(len(launchadmit.live_admissions(acc)) == before,
       "...and records nothing, so a launch that never happened blocks no removal")
    blocker.release()

    # ---- the CLI --------------------------------------------------------------
    def cli(email, pid=None):
        return subprocess.run(
            [sys.executable, os.path.join(AB, "launchadmit.py"), "admit", acc, email,
             str(pid if pid is not None else os.getpid())],
            capture_output=True, text=True)

    r = cli("a@x.com")
    ok(r.returncode == 0 and r.stdout.strip() == home,
       f"admit prints the READY home (rc {r.returncode}: {r.stderr.strip()})")
    ok(len(launchadmit.live_admissions(acc)) == 1, "...and records exactly one admission")

    r = cli("nobody@x.com")
    ok(r.returncode == 1 and "no READY home" in r.stderr,
       f"an unknown account is refused with rc 1 (got {r.returncode})")
    ok(len(launchadmit.live_admissions(acc)) == 1, "...and records nothing")

    registry.mark_unseeding(acc, "a@x.com")
    r = cli("a@x.com")
    ok(r.returncode == 1, "a home being un-seeded is refused — the mid-un-seed launch race")
    ok(len(launchadmit.live_admissions(acc)) == 1, "...and records nothing for it either")
    registry.clear_unseeding(acc, "a@x.com")

    held = launchadmit.lock(acc)
    ok(held.acquire(timeout=5) is True, "premise: something else holds the admission lock")
    env = dict(os.environ, ACCOUNT_BANK_LOCK_WAIT="1")
    r = subprocess.run([sys.executable, os.path.join(AB, "launchadmit.py"), "admit", acc,
                        "a@x.com", str(os.getpid())], capture_output=True, text=True, env=env)
    ok(r.returncode == 3,
       f"a contended lock exits 3 — distinct from 1 (not READY) and from python's own 2 "
       f"(got {r.returncode})")
    held.release()

    print(f"  -- launchadmit: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
