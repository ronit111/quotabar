#!/usr/bin/env python3
"""(r10 #6) isolated_refresh.resolve_claude_bin must return the REAL Claude binary, never
the v2 PATH shim. During seeding the shim rejects the unregistered staging home (exit 65),
so resolving `claude` to accounts/bin/claude breaks /login + verification. Hermetic: all
'binaries' are stub scripts; no real claude, no network."""
import json
import os
import stat
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import isolated_refresh  # noqa: E402

_pass = _fail = 0
def ok(c, m):
    global _pass, _fail
    if c:
        _pass += 1; print(f"  ok   {m}")
    else:
        _fail += 1; print(f"  FAIL {m}")


def make_exe(path, body="#!/bin/bash\nexit 0\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def main():
    base = tempfile.mkdtemp(prefix="resolve-")
    acc = os.path.join(base, "accounts")
    shim = os.path.join(acc, "bin", "claude")          # the v2 shim
    real = os.path.join(base, "realbin", "claude")     # the real CLI at a nonstandard place
    make_exe(shim)
    make_exe(real)
    os.environ["ACCOUNT_BANK_DIR"] = acc
    os.environ.pop("ACCOUNT_BANK_CLAUDE_BIN", None)

    # _is_shim_path recognises the shim (under accounts/bin) and clears the real binary
    ok(isolated_refresh._is_shim_path(shim, acc) is True, "_is_shim_path flags accounts/bin/claude (r10 #6)")
    ok(isolated_refresh._is_shim_path(real, acc) is False, "_is_shim_path clears the real binary (r10 #6)")

    # PATH is shim-first (as at/after cutover); resolve_claude_bin must SKIP it and use the
    # recorded REAL_CLAUDE_BIN from .config.json.
    with open(os.path.join(acc, ".config.json"), "w") as f:
        json.dump({"REAL_CLAUDE_BIN": real}, f)
    os.environ["PATH"] = os.path.join(acc, "bin") + os.pathsep + os.environ.get("PATH", "")
    got = isolated_refresh.resolve_claude_bin()
    ok(got == real, f"resolve_claude_bin returns the recorded REAL binary, not the shim (r10 #6): {got}")
    ok(os.path.realpath(got) != os.path.realpath(shim), "resolved binary is NEVER the shim (r10 #6)")

    # with no recorded REAL_CLAUDE_BIN, a shim-first PATH must still not return the shim
    os.remove(os.path.join(acc, ".config.json"))
    # add a real claude at a known fallback location so resolution can succeed non-shim
    known = os.path.join(base, "localbin", "claude"); make_exe(known)
    # point HOME so ~/.local/bin resolves into our fixture is overkill; instead ensure PATH
    # still leads with the shim and a real binary exists later on PATH
    os.environ["PATH"] = os.path.join(acc, "bin") + os.pathsep + os.path.dirname(known) + os.pathsep + "/usr/bin"
    got2 = isolated_refresh.resolve_claude_bin()
    ok(got2 and os.path.realpath(got2) != os.path.realpath(shim),
       f"shim-first PATH without a recorded real binary still skips the shim (r10 #6): {got2}")

    # an explicit ACCOUNT_BANK_CLAUDE_BIN override is honored (tests/stubs rely on this)
    os.environ["ACCOUNT_BANK_CLAUDE_BIN"] = real
    ok(isolated_refresh.resolve_claude_bin() == real, "explicit override honored (r10 #6)")
    os.environ.pop("ACCOUNT_BANK_CLAUDE_BIN", None)

    # (r12 #9) the shim-path rejection applies to the OVERRIDE too: setting it to the shim
    # must NOT select the shim — return "" (transient-unresolved), never the shim.
    os.environ["ACCOUNT_BANK_CLAUDE_BIN"] = shim
    ok(isolated_refresh.resolve_claude_bin() == "",
       "ACCOUNT_BANK_CLAUDE_BIN=shim is REJECTED, not honored (r12 #9)")
    os.environ.pop("ACCOUNT_BANK_CLAUDE_BIN", None)

    print(f"  -- resolve_claude: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
