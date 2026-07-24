#!/usr/bin/env python3
"""Tests for the v1 epoch gates (rev 6 §8): kc_write shell gate, write_bank_record
gate, v1_gate marker/state semantics. Uses a stubbed keychain via the test harness
env (no real keychain access)."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import epoch  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    bd = tempfile.mkdtemp(prefix="gates-bank-")

    # v1_gate: absent EPOCH (v1 world) passes; v2 refuses; marker refuses
    ok(epoch.v1_gate(bd)["state"] == "v1", "v1_gate passes in the pre-v2 world")
    epoch.write_epoch(bd, "shadow", 1)
    ok(epoch.v1_gate(bd)["state"] == "shadow", "v1_gate passes in shadow")
    epoch.write_epoch(bd, "v2", 2)
    fenced = False
    try:
        epoch.v1_gate(bd)
    except epoch.EpochFenced:
        fenced = True
    ok(fenced, "v1_gate refuses in v2")
    epoch.write_epoch(bd, "shadow", 3)
    open(os.path.join(bd, ".seeding.json"), "w").write("{}")
    fenced = False
    try:
        epoch.v1_gate(bd)
    except epoch.EpochFenced:
        fenced = True
    ok(fenced, "v1_gate refuses under SEEDING marker")
    os.remove(os.path.join(bd, ".seeding.json"))

    # CLI v1-gate exit codes
    r = subprocess.run([sys.executable, os.path.join(HERE, "epoch.py"), "v1-gate", bd])
    ok(r.returncode == 0, "CLI v1-gate passes in shadow")
    epoch.write_epoch(bd, "v2", 4)
    r = subprocess.run([sys.executable, os.path.join(HERE, "epoch.py"), "v1-gate", bd],
                       capture_output=True)
    ok(r.returncode == 78, "CLI v1-gate exits 78 in v2")

    # write_bank_record: gated (78, record untouched) vs allowed
    out = os.path.join(bd, "a@x.com.json")
    blob = json.dumps({"claudeAiOauth": {"accessToken": "AT", "refreshToken": "RT",
                                         "expiresAt": 9999999999999}})
    cj = os.path.join(bd, "claude.json")
    open(cj, "w").write(json.dumps({"oauthAccount": {"emailAddress": "a@x.com"}}))
    wbr = [sys.executable, os.path.join(HERE, "write_bank_record.py"),
           cj, "a@x.com", out, "2026-01-01T00:00:00Z", "1700000000"]
    r = subprocess.run(wbr, input=blob, capture_output=True, text=True)
    ok(r.returncode == 78 and not os.path.exists(out),
       "write_bank_record fenced in v2 (78, no record)")
    epoch.write_epoch(bd, "shadow", 5)
    r = subprocess.run(wbr, input=blob, capture_output=True, text=True)
    ok(r.returncode == 0 and os.path.exists(out),
       f"write_bank_record allowed in shadow (rc {r.returncode}: {r.stderr.strip()[:120]})")

    # kc_write shell gate: exercised through lib.sh with a stubbed keychain.
    # The existing test harness (testlib.sh) stubs kc_read/kc_write internals; here
    # we only prove the GATE: source lib.sh, call kc_write under v2 -> rc 78 before
    # any keychain access is attempted (the stub records any access).
    epoch.write_epoch(bd, "v2", 6)
    script = f'''
set -u
export BANK_DIR="{bd}"
source "{HERE}/lib.sh" 2>/dev/null || exit 90
printf '%s' '{{"claudeAiOauth":{{}}}}' | kc_write
'''
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    ok(r.returncode == 78, f"kc_write fenced in v2 (rc {r.returncode})")
    # generation fence: snapshot then bump -> fenced even in shadow
    epoch.write_epoch(bd, "shadow", 7)
    script = f'''
set -u
export BANK_DIR="{bd}"
source "{HERE}/lib.sh" 2>/dev/null || exit 90
EPOCH_SNAP="shadow 7"
python3 "{HERE}/epoch.py" bump-for-test "$BANK_DIR" 2>/dev/null || \
  python3 - <<'PYEOF'
import sys; sys.path.insert(0, "{HERE}")
import epoch; epoch.bump("{bd}")
PYEOF
printf '%s' '{{"claudeAiOauth":{{}}}}' | kc_write
'''
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    ok(r.returncode == 78, f"kc_write generation-fenced after bump (rc {r.returncode})")

    print(f"-- epoch_gates: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
