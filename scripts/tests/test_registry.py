#!/usr/bin/env python3
"""Tests for registry.py — READY-home registry (rev 5 §7)."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import registry  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    acc = tempfile.mkdtemp(prefix="reg-acc-")
    home = os.path.join(acc, "homes", "a-at-x.com")
    os.makedirs(home)

    ok(registry.load(acc) == {}, "absent registry loads as {}")
    ok(registry.ready_home(acc, "a@x.com") is None, "unknown email -> None")
    ok(not registry.is_ready_home(acc, home), "unregistered home not READY")

    ent = registry.publish_ready(acc, "a@x.com", home, "uuid-1")
    ok(ent["ready"] is True, "publish_ready returns READY entry")
    ok(registry.ready_home(acc, "a@x.com") == home, "ready_home maps email -> home")
    ok(registry.is_ready_home(acc, home), "is_ready_home by exact path")
    # symlinked path canonicalizes to the same home
    link = os.path.join(acc, "current")
    os.symlink(home, link)
    ok(registry.is_ready_home(acc, link), "is_ready_home through a symlink")
    ok(oct(os.stat(os.path.join(acc, "registry.json")).st_mode & 0o777) == "0o600",
       "registry file 0600")

    # missing home dir -> not ready (even though entry says ready)
    home2 = os.path.join(acc, "homes", "b-at-x.com")
    os.makedirs(home2)
    registry.publish_ready(acc, "b@x.com", home2, "uuid-2")
    os.rmdir(home2)
    ok(registry.ready_home(acc, "b@x.com") is None, "vanished home dir -> None")
    ok(not registry.is_ready_home(acc, home2), "vanished home dir -> not READY")

    # broken registry: load raises; gates fail closed
    with open(os.path.join(acc, "registry.json"), "w") as f:
        f.write("{ nope")
    raised = False
    try:
        registry.load(acc)
    except registry.RegistryError:
        raised = True
    ok(raised, "broken registry raises on load")
    ok(registry.ready_home(acc, "a@x.com") is None, "broken registry -> ready_home None")
    ok(not registry.is_ready_home(acc, home), "broken registry -> is_ready False")

    # publish validation
    for bad in (("", home, "u"), ("e@x", "/nonexistent", "u"), ("e@x", home, "")):
        raised = False
        try:
            registry.publish_ready(acc, *bad)
        except registry.RegistryError:
            raised = True
        ok(raised, f"publish_ready rejects {bad[0] or '<empty>'}/{bad[2] or '<empty>'}")

    # CLI bridge
    with open(os.path.join(acc, "registry.json"), "w") as f:
        json.dump({"a@x.com": {"home": home, "uuid": "u", "ready": True}}, f)
    rp = os.path.join(HERE, "registry.py")
    r = subprocess.run([sys.executable, rp, "ready-home", acc, "a@x.com"],
                       capture_output=True, text=True)
    ok(r.returncode == 0 and r.stdout.strip() == home, "CLI ready-home prints path")
    r = subprocess.run([sys.executable, rp, "is-ready", acc, home], capture_output=True)
    ok(r.returncode == 0, "CLI is-ready exit 0")
    r = subprocess.run([sys.executable, rp, "is-ready", acc, acc], capture_output=True)
    ok(r.returncode == 1, "CLI is-ready exit 1 for non-home")

    print(f"-- registry: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
