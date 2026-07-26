#!/usr/bin/env python3
"""registry.py — the READY-home registry (ISOLATION-DESIGN.md rev 5 §7).

`accounts/registry.json` maps email -> {home, uuid, ready, seeded_at}. An email is
ALWAYS mapped through here — never through raw path construction. Shim, repoint,
and claude-acct refuse homes without a READY entry.

Writes are tier-1-style (temp+rename+fsync) under the BANK lock (caller holds it —
this module doesn't lock, same single-place-ordering rule as epoch.py). stdlib only.
"""
import json
import os
import tempfile
import time

REG_NAME = "registry.json"
# (v102-r2) set on an entry whose home un-seeding is in the middle of removing. See
# mark_unseeding: it is the ONE reason a not-READY entry is still a legal delete target.
UNSEEDING = "unseeding"


class RegistryError(Exception):
    pass


def _path(accounts_dir):
    return os.path.join(accounts_dir, REG_NAME)


def load(accounts_dir):
    """{} when absent. A PRESENT-but-broken registry raises (fail closed — guessing
    home paths defeats the READY gate)."""
    p = _path(accounts_dir)
    if not os.path.exists(p):
        return {}
    try:
        with open(p) as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("not an object")
        return d
    except Exception as e:
        raise RegistryError(f"registry unreadable: {e}")


def save(accounts_dir, reg):
    fd, tmp = tempfile.mkstemp(dir=accounts_dir, prefix=".registry.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(reg, f, indent=1, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, _path(accounts_dir))
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(accounts_dir, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def publish_ready(accounts_dir, email, home, account_uuid):
    """Mark a home READY (called only after §7 step 6 verification). Caller holds
    the bank lock and has already atomically moved the staged home into place."""
    if not (email and os.path.isdir(home) and account_uuid):
        raise RegistryError("publish_ready: email/home/uuid required")
    reg = load(accounts_dir)
    reg[email] = {"home": home, "uuid": account_uuid, "ready": True,
                  "seeded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    save(accounts_dir, reg)
    return reg[email]


def mark_unseeding(accounts_dir, email):
    """(v102-r2) Take an entry OUT of service before un-seeding destroys its home, and mark
    WHY. Caller holds the bank lock (writes here always do) and the admission lock, so this is
    the moment new launches stop being possible: every consumer of a READY entry — ready_home,
    is_ready_home, usage.py's v2 discovery, launchadmit — requires `ready is True`, so a
    launcher that arrives after this write refuses instead of pinning a home that is about to
    be deleted.

    `unseeding` is what keeps that fail-closed marking from being a one-way trap: un-seed's own
    resolver accepts a not-READY entry ONLY when this flag is on it (a re-run finishes an
    interrupted removal), while a not-READY entry with no flag stays refused — that one is a
    half-published seeding, not our own in-flight work. Returns the updated entry, or None when
    there is no entry to mark."""
    reg = load(accounts_dir)
    ent = reg.get(email)
    if not isinstance(ent, dict):
        return None
    ent["ready"] = False
    ent[UNSEEDING] = True
    reg[email] = ent
    save(accounts_dir, reg)
    return ent


def clear_unseeding(accounts_dir, email):
    """Undo mark_unseeding — used only when the removal refused BEFORE destroying anything, so
    a refusal (a locked keychain, an unarchivable credential) does not leave a perfectly intact
    home permanently unlaunchable. Once anything has been destroyed the mark STAYS: that home
    is no longer something to launch, it is something to finish removing."""
    reg = load(accounts_dir)
    ent = reg.get(email)
    if not isinstance(ent, dict) or not ent.get(UNSEEDING):
        return None
    ent.pop(UNSEEDING, None)
    ent["ready"] = True
    reg[email] = ent
    save(accounts_dir, reg)
    return ent


def ready_home(accounts_dir, email):
    """Real home path for a READY email, else None. Never constructs paths."""
    try:
        ent = load(accounts_dir).get(email)
    except RegistryError:
        return None   # broken registry -> nothing is READY (fail closed)
    if not isinstance(ent, dict) or ent.get("ready") is not True:
        return None
    home = ent.get("home")
    return home if isinstance(home, str) and os.path.isdir(home) else None


def is_ready_home(accounts_dir, home_path):
    """READY-gate by PATH (used by repoint's registry_check and the shim): the
    canonicalized path must equal a READY entry's canonicalized home."""
    try:
        reg = load(accounts_dir)
    except RegistryError:
        return False
    want = os.path.realpath(home_path)
    for ent in reg.values():
        if (isinstance(ent, dict) and ent.get("ready") is True
                and isinstance(ent.get("home"), str)
                and os.path.realpath(ent["home"]) == want
                and os.path.isdir(ent["home"])):
            return True
    return False


def _cli():
    """CLI for shell callers:
       registry.py ready-home <accounts_dir> <email>   -> prints path, exit 0 | exit 1
       registry.py is-ready <accounts_dir> <home_path> -> exit 0 | exit 1"""
    import sys
    cmd = sys.argv[1]
    if cmd == "ready-home":
        h = ready_home(sys.argv[2], sys.argv[3])
        if h:
            print(h)
            return 0
        return 1
    if cmd == "is-ready":
        return 0 if is_ready_home(sys.argv[2], sys.argv[3]) else 1
    print(f"registry.py: unknown command {cmd!r}", file=os.sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
