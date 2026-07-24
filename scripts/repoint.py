#!/usr/bin/env python3
"""repoint.py — the pointer transaction (ISOLATION-DESIGN.md rev 5 §4).

`accounts/current` is a symlink to a READY home. It is bookkeeping, not a live rail:
read only at shim launch resolution and for display; NEVER handed to a process as
CLAUDE_CONFIG_DIR (sessions are pinned to real home paths).

Transaction (sole legal writer path):
  pointer lock (banklock at accounts/.pointer.lock)
    -> fsync'd INTENT {txn, from, to, why, pid, ts}
    -> unique temp symlink -> rename() over `current` -> parent-dir fsync
    -> fsync'd COMMIT {txn}
Recovery (also only under the pointer lock): physically delimit a partial tail
(truncate to last newline + fsync), then append a fsync'd SYNTHETIC-COMMIT bound to
the target observed from the live symlink (ground truth). `--back` follows
commit/synthetic-commit records only.

stdlib only. Callers: QuotaBar Switch, shim auto-pick, claude-acct --back.
"""
import json
import os
import sys
import time
import uuid as uuidlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import banklock
import epoch as _epoch

POINTER_NAME = "current"
LOG_NAME = "pointer.log"
LOCK_DIRNAME = ".pointer.lock"


class RepointError(Exception):
    pass


class EpochRefused(RepointError):
    """(r9 #7) The pointer transaction is a shadow|v2 operation (§4/§8). A subclass of
    RepointError so existing `except RepointError` callers (autopick_v2) still fail
    safe (pointer untouched); claude-acct catches it distinctly to exit rc 78."""


def _epoch_gate(accounts_dir):
    """(r9 #7) Refuse a NEW pointer transaction unless EPOCH permits it. A PRESENT EPOCH
    in a state other than shadow|v2 (i.e. a rollback to v1) refuses — `--back`/repoint
    must not mutate pointer state the flipped-back world forbids. An ABSENT EPOCH is the
    pre-v2 world (repoint is inert bookkeeping there, and the shim never auto-picks
    without v2), so it stays permissive to avoid breaking v1-default installs. A
    present-but-broken EPOCH fails closed."""
    if not os.path.exists(os.path.join(accounts_dir, "EPOCH")):
        return
    try:
        st = _epoch.read_epoch(accounts_dir)["state"]
    except _epoch.EpochError:
        raise EpochRefused("EPOCH unreadable; refusing pointer transaction (fail-closed)")
    if st not in ("shadow", "v2"):
        raise EpochRefused(f"epoch state {st!r} forbids repoint (shadow|v2 only)")


def _paths(accounts_dir):
    return (os.path.join(accounts_dir, POINTER_NAME),
            os.path.join(accounts_dir, LOG_NAME))


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _append_record(logpath, rec):
    """Append one fsync'd JSON line. The line is written whole + flushed + fsynced
    before return, so a later reader can only ever see it complete or absent —
    except for a crash mid-write, which the tail-delimit rule repairs."""
    with open(logpath, "a") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        f.flush()
        os.fsync(f.fileno())


def _delimit_tail(logpath):
    """Physically truncate a partial trailing line (no final newline) — rev 5 §4.
    Runs only under the pointer lock."""
    if not os.path.exists(logpath):
        return
    with open(logpath, "rb+") as f:
        data = f.read()
        if not data or data.endswith(b"\n"):
            return
        cut = data.rfind(b"\n") + 1   # 0 when no newline at all
        f.truncate(cut)
        f.flush()
        os.fsync(f.fileno())


def read_current(accounts_dir):
    """The live pointer target (real home path) or None. Read-only, no lock —
    the symlink is atomic ground truth."""
    ptr, _ = _paths(accounts_dir)
    try:
        target = os.readlink(ptr)
    except OSError:
        return None
    return target if os.path.isabs(target) else os.path.join(accounts_dir, target)


def _recover_locked(accounts_dir, registry_check):
    """Under the held pointer lock: delimit tail; if the last record is an INTENT
    without its COMMIT, append a SYNTHETIC-COMMIT bound to the OBSERVED target —
    but ONLY after validating (finding 16) that BOTH the crashed intent's target AND
    the observed live target are READY-registered homes. An observed NON-home target
    is itself an incident: raise (freeze the pointer path + surface) rather than
    launder an invalid target into normal history."""
    ptr, logpath = _paths(accounts_dir)
    _delimit_tail(logpath)
    if not os.path.exists(logpath):
        return
    last = None
    with open(logpath) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    last = json.loads(line)
                except ValueError:
                    last = None   # unreachable post-delimit, but fail-safe
    if last and last.get("kind") == "intent":
        observed = read_current(accounts_dir)
        intent_target = last.get("to")
        if observed is None or not registry_check(observed):
            raise RepointError(
                f"pointer recovery: observed target {observed!r} is NOT a READY home — "
                "incident: pointer frozen, refusing to synthesize normality (finding 16)")
        # (r2 finding 16) a MISSING/empty intent `to` must NOT bypass validation — it
        # is itself an incident (a torn record whose target we cannot confirm READY).
        if not intent_target or not registry_check(intent_target):
            raise RepointError(
                f"pointer recovery: crashed intent target {intent_target!r} is missing/NOT READY — "
                "surfacing incident, not synthesizing (finding 16)")
        _append_record(logpath, {
            "kind": "synthetic-commit", "txn": last.get("txn"),
            "observed_target": observed, "ts": int(time.time()),
        })


def _pointer_lock(accounts_dir):
    lk = banklock.BankLock(accounts_dir)
    lk.lock_dir = os.path.join(accounts_dir, LOCK_DIRNAME)
    lk.owner = os.path.join(lk.lock_dir, "owner")
    lk.reclaim_dir = os.path.join(accounts_dir, LOCK_DIRNAME + ".reclaim")
    return lk


def _repoint_locked(accounts_dir, target_home, why, registry_check):
    """The pointer write, assuming the pointer lock is HELD and recovery already ran."""
    ptr, logpath = _paths(accounts_dir)
    # (finding 17) never write a self-referential pointer: a target whose path IS the
    # pointer (`accounts/current`) would produce `current -> current`. Reject it —
    # realpath aliasing to a READY home does not make the pointer path a valid target.
    if os.path.abspath(target_home.rstrip("/")) == os.path.abspath(ptr):
        raise RepointError("refusing a self-referential pointer (target IS accounts/current)")
    # (r2 finding 17) the target MUST be a real home directory, never a symlink/alias.
    if os.path.islink(target_home):
        raise RepointError(
            f"pointer target must be a real home directory, not a symlink/alias: {target_home}")
    # (r3 #17) reject a spelling that EMBEDS the pointer or uses `..`. A path like
    # `accounts/current/../homes/b` realpath-resolves to a READY home (so registry_check
    # and isdir both pass) yet contains `current` as a component, so writing it as the
    # symlink target would create an indirect current -> …/current/… cycle. A legitimate
    # home target never contains the pointer name or a `..` component.
    _parts = target_home.split(os.sep)
    if POINTER_NAME in _parts:
        raise RepointError(
            f"pointer target must not contain the pointer name {POINTER_NAME!r} as a path "
            f"component (indirect cycle): {target_home}")
    if ".." in _parts:
        raise RepointError(f"pointer target must not contain '..' components: {target_home}")
    prev = read_current(accounts_dir)
    txn = str(uuidlib.uuid4())
    _append_record(logpath, {
        "kind": "intent", "txn": txn, "from": prev, "to": target_home,
        "why": why, "pid": os.getpid(), "ts": int(time.time()),
    })
    tmp = os.path.join(accounts_dir, f".current.{txn[:8]}.{os.getpid()}")
    os.symlink(target_home, tmp)
    try:
        os.rename(tmp, ptr)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    _fsync_dir(accounts_dir)
    _append_record(logpath, {"kind": "commit", "txn": txn, "ts": int(time.time())})
    return {"txn": txn, "from": prev, "to": target_home}


def repoint(accounts_dir, target_home, why, registry_check=None, lock_timeout=10):
    """Atomically point `current` at target_home. `registry_check(home)` must return
    True (READY) — pass the registry gate in; refusing is the default when absent
    (fail-closed: no check, no repoint)."""
    if registry_check is None:
        raise RepointError("no registry_check supplied; refusing (READY gate is mandatory)")
    _epoch_gate(accounts_dir)   # (r9 #7) fast pre-lock reject
    if not registry_check(target_home):
        raise RepointError(f"target home not READY: {target_home}")
    if not os.path.isdir(target_home):
        raise RepointError(f"target home missing: {target_home}")
    lk = _pointer_lock(accounts_dir)
    if not lk.acquire(timeout=lock_timeout):
        raise RepointError("pointer lock contended")
    try:
        # (r11 #5) RE-CHECK epoch UNDER the pointer lock — the pre-lock check races a
        # concurrent shadow->v1 flip. The flip holds the pointer lock (seedflow._ordered_locks:
        # bank->pointer->homes) while it writes EPOCH, so an epoch change is IMPOSSIBLE while
        # we hold this lock; the authoritative gate must be here, not the check-then-lock above.
        _epoch_gate(accounts_dir)
        _recover_locked(accounts_dir, registry_check)   # heal any prior crash first
        return _repoint_locked(accounts_dir, target_home, why, registry_check)
    finally:
        lk.release()


def back(accounts_dir, registry_check=None, lock_timeout=10):
    """Undo the last committed repoint: find the most recent commit/synthetic-commit,
    take its transaction's `from`, and repoint there (as a NEW forward transaction —
    history only ever appends). (finding 35) Selection AND the write happen inside a
    single held pointer lock, so a concurrent repoint cannot commit between the two
    and make `--back` undo a stale commit."""
    if registry_check is None:
        raise RepointError("no registry_check supplied; refusing (READY gate is mandatory)")
    _epoch_gate(accounts_dir)   # (r9 #7) fast pre-lock reject
    _, logpath = _paths(accounts_dir)
    lk = _pointer_lock(accounts_dir)
    if not lk.acquire(timeout=lock_timeout):
        raise RepointError("pointer lock contended")
    try:
        # (r11 #5) authoritative epoch re-check UNDER the pointer lock (see repoint()).
        _epoch_gate(accounts_dir)
        _recover_locked(accounts_dir, registry_check)   # heal first (also under lock)
        if not os.path.exists(logpath):
            raise RepointError("no pointer history")
        intents, commits = {}, []
        with open(logpath) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("kind") == "intent":
                    intents[rec.get("txn")] = rec
                elif rec.get("kind") in ("commit", "synthetic-commit"):
                    commits.append(rec)
        if not commits:
            raise RepointError("no committed repoint to undo")
        last = intents.get(commits[-1].get("txn"))
        if not last or not last.get("from"):
            raise RepointError("last committed transaction has no usable 'from'")
        target = last["from"]
        if not registry_check(target):
            raise RepointError(f"--back target not READY: {target}")
        return _repoint_locked(accounts_dir, target, "back", registry_check)
    finally:
        lk.release()
