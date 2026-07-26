#!/bin/bash
# (r15) Fixes with no natural home in an existing suite: swap-journal durability (#2),
# the installer's reachable bank-lock handler (#9), verified Cask stamping (#10), and the
# Keychain-authorization command matching what it claims to do (#6).
# Hermetic: temp dirs only. Nothing here runs the installer or the release publisher.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
REPO="$(cd "$AB_DIR/.." && pwd)"

# ---- (r15 #2) the swap journal is cleared through a CHECKED, DURABLE unlink ----
new_env r15_journal >/dev/null
source "$AB_DIR/lib.sh"; ensure_bank

clear_swap_journal; assert_eq 0 "$?" "(r15 #2) clearing an absent journal is a clean no-op"

printf '{"type":"swap"}' > "$SWAP_JOURNAL"
clear_swap_journal; rc=$?
assert_eq 0 "$rc" "(r15 #2) clearing an existing journal succeeds"
assert_file_absent "$SWAP_JOURNAL" "(r15 #2) the journal is actually gone afterwards"

# An unlink that CANNOT succeed must be reported, not swallowed. `rm -f` alone exits 0 here
# and the caller would print "swapped" while a recovery record still sat on disk.
RO="$BANK_DIR/ro"; mkdir -p "$RO"
SWAP_JOURNAL="$RO/.swap-journal.json"
printf '{"type":"swap"}' > "$SWAP_JOURNAL"
chmod 500 "$RO"
out="$(clear_swap_journal 2>&1)"; rc=$?
chmod 700 "$RO"
assert_ne 0 "$rc" "(r15 #2) an unlink that fails returns nonzero (never a silent success)"
assert_file_present "$SWAP_JOURNAL" "(r15 #2) the journal survives so reconcile can still use it"
assert_contains "FAILED to clear the swap journal" "$out" "(r15 #2) the failure is reported"
rm -f "$SWAP_JOURNAL"

# _fsync_dir is best-effort: a directory it cannot open must never abort a completed mutation.
_fsync_dir "$BANK_DIR"; assert_eq 0 "$?" "(r15 #2) _fsync_dir succeeds on a real directory"
_fsync_dir "$BANK_DIR/does-not-exist"; assert_eq 0 "$?" "(r15 #2) _fsync_dir on a missing dir is a no-op, not an error"

# The metadata rename is the step that was left un-synced; it must now fsync its parent.
# (The durability itself is only observable across a power loss, so assert the ordering
# is present in the transaction rather than pretending to test the crash.)
python3 - "$AB_DIR/swap-account.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = src[src.index('d["oauthAccount"] = meta'):]
block = block[:block.index('\nPY')]
assert "os.replace(tmp, claude_json)" in block, "metadata commit is no longer a rename"
after = block[block.index("os.replace(tmp, claude_json)"):]
assert "os.fsync(dfd)" in after and "os.open(dirn" in after, \
    "the metadata rename does not fsync its parent directory"
PY
assert_eq 0 "$?" "(r15 #2) swap-account.sh fsyncs the parent after the metadata rename"

# A real swap still ends with no journal (the fix must not strand one).
new_env r15_swap_end >/dev/null
set_active a@x.com A
bank_record a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" max claude_max
/bin/bash "$AB_DIR/swap-account.sh" b@x.com >/dev/null 2>&1
assert_file_absent "$BANK_DIR/.swap-journal.json" "(r15 #2) a completed swap leaves no journal behind"

# ---- (r15 #9) the installer's bank-lock failure handler is REACHABLE under set -e ----
# install.sh runs `set -euo pipefail`, which killed the shell the moment the merge exited 3
# — so the `_merge_rc` capture and the "shim NOT staged" warning below it never ran.
python3 - "$REPO/install.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
assert "set -euo pipefail" in src, "install.sh no longer uses errexit; revisit this test"
i = src.index("_merge_rc=$?")
before, after = src[:i], src[i:]
assert "set +e" in before.rsplit("if [ -n \"$REAL_CLAUDE\" ]", 1)[-1], \
    "errexit is not suspended around the merge, so _merge_rc=$? is unreachable"
assert after.split("\n", 2)[1].strip() == "set -e", "errexit is not restored right after the capture"
PY
assert_eq 0 "$?" "(r15 #9) install.sh suspends errexit around the merge and restores it"

# Behavioural proof of the same bug class: capturing $? after a failing command under
# errexit only works when errexit is suspended for it.
rc_seen="$(bash -c 'set -e; set +e; python3 -c "import sys; sys.exit(3)"; rc=$?; set -e; echo "$rc"' 2>/dev/null)"
assert_eq 3 "$rc_seen" "(r15 #9) the rescued construct actually observes rc 3 instead of dying"
rc_seen="$(bash -c 'set -e; python3 -c "import sys; sys.exit(3)"; rc=$?; echo "$rc"' 2>/dev/null)"
assert_eq "" "$rc_seen" "(r15 #9) without the fix the handler is unreachable (nothing printed)"

# ---- (r15 #10) Cask stamping verifies BOTH substitutions ----
# A cask whose fields the patterns cannot match must FAIL loudly. This bit us in production:
# a non-hex sha256 placeholder survived the stamp and the published cask disagreed with the zip.
T="$(mktemp -d)"
# Extract release.sh's stamping block verbatim into a runnable fixture, so the test exercises
# the SHIPPED code (patterns and all) rather than a paraphrase of it that could drift.
{ echo 'set -euo pipefail'
  python3 - "$REPO/release.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index('if [ -n "$CASK_FILE" ]; then')
end = src.index("\nfi\n", start) + 4
sys.stdout.write(src[start:end])
PY
} > "$T/stamp.sh"
assert_contains "cask stamping FAILED" "$(cat "$T/stamp.sh")" "(r15 #10) extracted the real stamping block from release.sh"
SHA64="$(printf 'd%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)"
stamp_only() { # <cask-file> — run just release.sh's stamping block against a fixture
  VERSION="9.9.9" SHA="$SHA64" ZIP="QuotaBar-9.9.9.zip" CASK_FILE="$1" bash "$T/stamp.sh"
}
cat > "$T/good.rb" <<'RB'
cask "quotabar" do
  version "0.0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
end
RB
out="$(stamp_only "$T/good.rb" 2>&1)"; rc=$?
assert_eq 0 "$rc" "(r15 #10) a well-formed cask stamps successfully"
assert_contains "both fields verified" "$out" "(r15 #10) success is claimed only after verification"
grep -q '^  version "9.9.9"$' "$T/good.rb"; assert_eq 0 "$?" "(r15 #10) the version field was actually rewritten"

# the exact production failure: a NON-HEX placeholder the old pattern could not match
cat > "$T/placeholder.rb" <<'RB'
cask "quotabar" do
  version "0.0.1"
  sha256 "REPLACE_ME_WITH_THE_RELEASE_SHA"
end
RB
out="$(stamp_only "$T/placeholder.rb" 2>&1)"; rc=$?
assert_eq 0 "$rc" "(r15 #10) a non-hex sha256 placeholder is now replaced, not skipped"

# a reformatted cask the patterns genuinely cannot match must FAIL, not report success
cat > "$T/reformatted.rb" <<'RB'
cask "quotabar" do
    version "0.0.1"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
end
RB
out="$(stamp_only "$T/reformatted.rb" 2>&1)"; rc=$?
assert_ne 0 "$rc" "(r15 #10) a cask whose fields do not match FAILS the stamp"
assert_contains "cask stamping FAILED" "$out" "(r15 #10) the failure is loud and names the problem"
grep -q '0000000000000000' "$T/reformatted.rb"; assert_eq 0 "$?" "(r15 #10) the unstamped cask is left visibly unstamped"

# duplicate fields are ambiguous — we cannot say which one Homebrew reads
cat > "$T/dupe.rb" <<'RB'
cask "quotabar" do
  version "0.0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  version "0.0.2"
end
RB
out="$(stamp_only "$T/dupe.rb" 2>&1)"; rc=$?
assert_ne 0 "$rc" "(r15 #10) duplicate version fields FAIL the stamp (ambiguous)"

# ---- (r15 #6) the documented Keychain command matches what it actually does ----
for f in "$REPO/README.md" "$REPO/install.sh"; do
  n="$(basename "$f")"
  grep -q 'set-generic-password-partition-list' "$f"; assert_eq 0 "$?" "(r15 #6) $n documents the authorization command"
  # Check the INVOCATION (the command plus its backslash-continued lines), not prose that
  # merely mentions -k — the README now explains why the old flag was wrong.
  python3 - "$f" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
found = False
for i, line in enumerate(lines):
    if "set-generic-password-partition-list" not in line:
        continue
    found = True
    cmd, j = line, i
    while cmd.rstrip().endswith("\\") and j + 1 < len(lines):
        j += 1
        cmd += " " + lines[j]
    assert " -k " not in cmd, f"line {i+1}: the documented command still passes -k: {cmd.strip()}"
assert found, "no invocation found"
PY
  assert_eq 0 "$?" "(r15 #6) $n's actual command passes no -k (deprecated; omitting it prompts)"
done
grep -q 'login.keychain-db' "$REPO/README.md"; assert_eq 0 "$?" "(r15 #6) README targets the login keychain explicitly"
grep -qi 'prompt' "$REPO/README.md"; assert_eq 0 "$?" "(r15 #6) README says the command prompts"
grep -qi 'Apple-signed' "$REPO/README.md"; assert_eq 0 "$?" "(r15 #6) README states what the partition list actually grants"

# ---- (r15 #5) the release bundle ships ONLY runtime scripts ----
# `make check-scripts-dir` is the gate release.sh runs (via verify -> verify-bundle). Point it
# at planted fixtures to prove it actually discriminates — an artifact check that cannot fail
# is worth nothing, and this is the check that would have caught the absolute path leaked
# inside the shipped v1.0.0 zip (tests/__pycache__/test_g10.cpython-314.pyc).
B="$T/bundlefix"; mkdir -p "$B"
cp "$AB_DIR/usage.py" "$AB_DIR/lib.sh" "$B/"
make -C "$REPO/app" --no-print-directory check-scripts-dir DIR="$B" >/dev/null 2>&1
assert_eq 0 "$?" "(r15 #5) a clean runtime-only directory passes the bundle gate"

mkdir -p "$B/tests/__pycache__"
printf 'x' > "$B/tests/__pycache__/test_g10.cpython-314.pyc"
make -C "$REPO/app" --no-print-directory check-scripts-dir DIR="$B" >/dev/null 2>&1
assert_ne 0 "$?" "(r15 #5) a bundled tests/__pycache__/*.pyc FAILS the gate (the v1.0.0 leak)"
rm -rf "$B/tests"

printf 'p = "/Users/someone/src/quotabar"\n' > "$B/leaky.py"
make -C "$REPO/app" --no-print-directory check-scripts-dir DIR="$B" >/dev/null 2>&1
assert_ne 0 "$?" "(r15 #5) an embedded absolute /Users path FAILS the gate"
rm -f "$B/leaky.py"

printf 'x' > "$B/.env"
make -C "$REPO/app" --no-print-directory check-scripts-dir DIR="$B" >/dev/null 2>&1
assert_ne 0 "$?" "(r15 #5) a stray dotfile FAILS the gate (untracked scratch cannot ship)"
rm -f "$B/.env"

printf 'x' > "$B/._resourcefork"
make -C "$REPO/app" --no-print-directory check-scripts-dir DIR="$B" >/dev/null 2>&1
assert_ne 0 "$?" "(r15 #5) an AppleDouble ._ sidecar FAILS the gate"

rm -rf "$T"
finish "r15"
