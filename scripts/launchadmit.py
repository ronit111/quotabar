#!/usr/bin/env python3
"""launchadmit.py — the LAUNCH ADMISSION fence (v102-r2). The missing edge between
`claude-acct <email>` and `unseed.py`.

THE RACE IT CLOSES. Un-seeding refuses while a live SESSION is pinned to the home, but a
session only exists in sessions.json once the launched CLI runs its SessionStart hook. Between
`claude-acct` resolving the READY home and that hook firing there is a window in which the home
is, as far as every check un-seed can make, unused. The seeding barrier does not help: it
serializes seeding, repointing and un-seeding against each other, and `claude-acct` takes none
of those locks — it reads the registry and execs. So:

    claude-acct        registry says READY -> exec claude -------------> SessionStart
    unseed.py                       barrier | no sessions | rmtree |
                                            ^ the launch is invisible here

and the survivor is a running Claude Code whose CLAUDE_CONFIG_DIR was deleted underneath it.

THE FENCE. One small lock, taken by both sides, around the moment the launcher commits to a
home:

  * the LAUNCHER (`admit_ready`, which is also how it resolves the home) takes the admission
    lock, re-checks the READY entry, writes an admission marker naming the home and the pid
    that is about to become the CLI, and releases. Total time held: one registry read and one
    small file write. RESOLVING AND RECORDING ARE ONE OPERATION, and that is the point:
    a launcher that resolves the home first and only records under the lock can have had its
    home marked not-READY and deleted in between, so its marker arrives after the un-seeder
    has already decided nothing was in flight. Every launcher — `claude-acct` and the G8
    gate — goes through `admit_ready`; a caller that had to resolve the home earlier for
    other reasons passes it as `expect_home` and is refused if the lock-held answer differs.
  * the UN-SEEDER, already holding the full seeding barrier, takes the same lock, refuses if any
    LIVE admission names the home, and — still holding it — marks the registry entry not-READY.
    From that moment no new launcher can resolve the home at all, so the lock can be released
    before the slow destructive work begins.

Neither side can be half-way through the other's critical section, so an admission is either
visible to the un-seeder (which then refuses) or impossible (the entry is already not-READY).

LIVENESS. An admission is live exactly as long as its pid is: `claude-acct` records its OWN pid
and then execs, so the marker names the real CLI process, and exec preserves both the pid and
its start time. Three-valued like everything else here — UNKNOWN counts as LIVE — and a
provably DEAD pid's marker is swept on sight, so a launcher that failed after admission (or a
session that has since exited) blocks nothing. A marker that cannot be parsed is not swept and
not ignored: it REFUSES, because an unreadable admission is an unknown launch.

(v102-r3) So is a marker that parses but does not say what it has to say. Validating the pid
alone was enough to call a record LIVE and not enough to say WHICH home it pinned, so
`{"pid": <a live pid>}` passed liveness, matched no home, and the un-seeder read a launch it
could not place as a launch that did not concern it — the same "unknown launch is no launch"
failure, arriving through a marker that happened to be valid JSON. A LIVE admission is now held
to the whole schema (usable pid, absolute normalized home, usable email, timestamp, start-time
shape) and any gap raises. The pid is validated FIRST and a provably dead launcher is still
swept whatever else its marker says: a claim whose process is gone blocks nothing, so a
garbage-but-dead marker cannot wedge every removal.

The lock is its own file (`.admit.lock`), NOT the bank lock: a pinned launch must not queue
behind a poll that holds the bank lock across a network call. It is taken last in the §8 total
order (bank -> pointer -> homes -> admit) by the un-seeder and alone by the launcher, so it
cannot participate in a cycle.

    launchadmit.py admit <accounts_dir> <email> <pid>   -> prints the home; 0 ok, 1 refused,
                                                          3 admission lock contended

(3, not 2: python itself exits 2 when it cannot open the script file, and the launcher must
never read "this file is missing" as "an un-seed holds the lock, retry".)

stdlib only; never prints token material.
"""
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common
import banklock
import registry
import sessions

LOCK_DIRNAME = ".admit.lock"
ADMIT_DIRNAME = ".admissions"

EX_OK, EX_REFUSED, EX_CONTENDED = 0, 1, 3


class AdmissionError(Exception):
    """An admission record exists but cannot be understood — never treated as absence."""


class AdmissionRefused(Exception):
    """The fence declined this launch: no READY home under the lock, a home that is not the one
    the caller had already resolved, or an admission we could not record."""


class AdmissionContended(Exception):
    """The admission lock is held (an un-seed is mid-fence); nothing was recorded."""


def lock(acc):
    """The admission lock. Same banklock protocol (owner file, stale reclaim) as every other
    lock here, on its own directory."""
    lk = banklock.BankLock(acc)
    lk.lock_dir = os.path.join(acc, LOCK_DIRNAME)
    lk.owner = os.path.join(lk.lock_dir, "owner")
    lk.reclaim_dir = os.path.join(acc, LOCK_DIRNAME + ".reclaim")
    return lk


def _dir(acc):
    return os.path.join(acc, ADMIT_DIRNAME)


def _lock_wait():
    """A launch must not hang on this. The hold is a registry read and one small write, so the
    only way to wait long is an un-seed mid-fence — and then refusing IS the right answer.
    ACCOUNT_BANK_LOCK_WAIT is the house override (tests use it); 10s is the default."""
    try:
        return float(os.environ.get("ACCOUNT_BANK_LOCK_WAIT", "10") or 10)
    except ValueError:
        return 10.0


def _real(p):
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def _write(acc, rec, pid):
    d = _dir(acc)
    os.makedirs(d, exist_ok=True)
    os.chmod(d, 0o700)
    path = os.path.join(d, f"{int(pid)}.json")
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".admit.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(rec, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return path


def admit(acc, email, home, pid):
    """Record that `pid` is about to become a CLI pinned to `home`. Caller holds the admission
    lock. Returns the marker path.

    The low-level half of the fence: it records a decision someone else made. Launchers call
    `admit_ready`, which makes that decision under the lock in the same hold as this write."""
    return _write(acc, {"email": email, "home": home, "pid": int(pid),
                        "proc_start": sessions._proc_start(pid), "ts": int(time.time())}, pid)


def admit_ready(acc, email, pid, expect_home=None, timeout=None):
    """(v102-r3) THE launcher operation, and the only one a launcher should use: resolve the
    READY home and record `pid` against it inside ONE hold of the admission lock. Returns the
    home. Raises AdmissionContended (the lock is held) or AdmissionRefused (no READY home, a
    home that moved, an unrecordable admission) — never launches anything itself.

    Doing both under one hold is the whole fence. The un-seeder, holding the same lock, refuses
    on a live admission and only then marks the entry not-READY, so an admission is either
    visible to it or impossible. Split the pair — resolve first, lock later — and the un-seeder
    can run its refusal check, mark, release and start deleting in the gap; the marker then
    lands against a home that is already going away, which is precisely the state this file
    exists to make unreachable.

    `expect_home` is for a launcher that had to resolve the home earlier for other reasons (the
    G8 gate stages a whole harness around it): the lock-held answer must be that same directory
    or the launch is REFUSED, rather than run against a path that moved underneath it."""
    lk = lock(acc)
    if not lk.acquire(timeout=_lock_wait() if timeout is None else timeout):
        raise AdmissionContended("the admission lock is contended (an un-seed is in flight); "
                                 "nothing was launched. Retry in a moment.")
    try:
        # Re-read the registry INSIDE the lock: the READY entry is the launch authority, and an
        # un-seeder holding this lock is either about to clear it or has just done so.
        home = registry.ready_home(acc, email)
        if not home:
            raise AdmissionRefused(f"no READY home for {email}")
        if expect_home is not None and _real(home) != _real(expect_home):
            raise AdmissionRefused(
                f"the READY home for {email} is {home}, not the {expect_home} this launch was "
                f"prepared against — it was re-pointed or taken out of service in between")
        try:
            admit(acc, email, home, pid)
        except Exception as e:
            # Fail CLOSED: an admission we could not record is one the un-seeder cannot see.
            raise AdmissionRefused(f"could not record the launch admission "
                                   f"({type(e).__name__}); refusing to launch un-fenced")
        return home
    finally:
        lk.release()


def _pid_of(path, rec):
    """The pid a marker names, or AdmissionError. Checked before anything else, because
    liveness is what decides whether the rest of the record still matters at all."""
    if not isinstance(rec, dict):
        raise AdmissionError(f"launch admission {path} is not a JSON object")
    pid = rec.get("pid")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        raise AdmissionError(f"launch admission {path} has no usable pid")
    return pid


def _validate_live(path, rec):
    """The full schema every LIVE admission must satisfy, or AdmissionError.

    A marker's whole job is to name the home a launch is pinned to, so a live record that
    cannot answer that is not a weaker claim than a well-formed one — it is a launch we cannot
    place, and the fence's rule is that an unplaceable launch stops every removal until someone
    looks. Validating only the pid let `{"pid": <a live pid>}` through as LIVE-but-homeless,
    where _refuse_if_admitted compared it against the home, found no match, and passed it over
    as somebody else's business."""
    home = rec.get("home")
    if not isinstance(home, str) or not home:
        raise AdmissionError(f"launch admission {path} names no home, so the launch it records "
                             f"cannot be placed on one")
    if not os.path.isabs(home) or home != os.path.normpath(home):
        raise AdmissionError(f"launch admission {path} names a home ({home!r}) that is not an "
                             f"absolute, normalized path")
    email = rec.get("email")
    if not isinstance(email, str) or bank_common.safe_email(email) is None:
        raise AdmissionError(f"launch admission {path} has no usable email")
    ts = rec.get("ts")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)) or ts <= 0:
        raise AdmissionError(f"launch admission {path} has no usable timestamp")
    if not isinstance(rec.get("proc_start"), str):
        raise AdmissionError(f"launch admission {path} has a malformed process start-time; its "
                             f"liveness cannot be judged the way it was recorded")
    return rec


def live_admissions(acc):
    """Every admission whose process is not provably dead, sweeping the ones that are.

    Raises AdmissionError on a marker we cannot read, cannot parse, or (when its process is not
    provably dead) cannot fully understand: an admission that exists but cannot be understood is
    an UNKNOWN launch, and the whole point of this file is that unknown launches are not treated
    as absent ones."""
    d = _dir(acc)
    try:
        names = sorted(os.listdir(d))
    except FileNotFoundError:
        return []
    except OSError as e:
        raise AdmissionError(f"the admissions directory could not be read ({e})")
    out = []
    for name in names:
        if not name.endswith(".json") or name.startswith("."):
            continue
        p = os.path.join(d, name)
        try:
            with open(p) as f:
                rec = json.load(f)
        except Exception as e:
            raise AdmissionError(f"launch admission {p} is unreadable ({type(e).__name__}: {e})")
        pid = _pid_of(p, rec)
        start = rec.get("proc_start")
        if sessions._proc_state(pid, (start if isinstance(start, str) else None) or None) == "DEAD":
            try:
                os.remove(p)          # the launcher is provably gone; its claim goes with it
            except OSError:
                pass
            continue
        _validate_live(p, rec)        # a live launch we cannot place stops every removal
        rec["_path"] = p
        out.append(rec)
    return out


def _cli():
    if len(sys.argv) != 5 or sys.argv[1] != "admit":
        sys.stderr.write("usage: launchadmit.py admit <accounts_dir> <email> <pid>\n")
        return EX_REFUSED
    acc, email, pid = sys.argv[2], sys.argv[3], sys.argv[4]
    try:
        pid = int(pid)
    except ValueError:
        sys.stderr.write("launchadmit: pid must be an integer\n")
        return EX_REFUSED
    try:
        home = admit_ready(acc, email, pid)
    except AdmissionContended as e:
        sys.stderr.write(f"launchadmit: {e}\n")
        return EX_CONTENDED
    except AdmissionRefused as e:
        sys.stderr.write(f"launchadmit: {e}\n")
        return EX_REFUSED
    print(home)
    return EX_OK


if __name__ == "__main__":
    raise SystemExit(_cli())
