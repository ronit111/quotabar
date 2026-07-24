#!/bin/bash
# kc_write return-code contract (finding 10): a failed/indeterminate write is
# NEVER reported as "unchanged success".
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
new_env kcwrite >/dev/null
source "$AB_DIR/lib.sh"; ensure_bank
# (r6 b9) kc_write now REQUIRES a HELD lock (LOCK_TOKEN) as well as its epoch snapshot
# (EPOCH_SNAP) — both set by acquire_lock, never hand-set (an inherited EPOCH_SNAP with no
# held lock must not fake proof-of-lock). Acquire the real lock the way production does;
# the sandbox has no EPOCH file (pre-v2 world = "v1 0") so acquire_lock snapshots "v1 0".
acquire_lock || { echo "FAIL: could not acquire the bank lock in kcwrite test"; exit 1; }
trap 'release_lock' EXIT

A='{"claudeAiOauth":{"accessToken":"A","refreshToken":"rA","expiresAt":111}}'
B='{"claudeAiOauth":{"accessToken":"B","refreshToken":"rB","expiresAt":222}}'

rm -f "$STUB_KC_FILE"
printf '%s' "$B" | kc_write >/dev/null 2>&1; assert_eq 10 "$?" "no item + no bootstrap -> rc 10 (definitely unchanged)"
printf '%s' "$A" | ACCOUNT_BANK_BOOTSTRAP=1 kc_write >/dev/null 2>&1; assert_eq 0 "$?" "bootstrap create -> rc 0"
assert_eq "$A" "$(kc_read)" "readback == A"
printf '%s' "$B" | kc_write >/dev/null 2>&1; assert_eq 0 "$?" "update existing -> rc 0 verified"
assert_eq "$B" "$(kc_read)" "store now == B"
# (r5 PRINCIPLE 2) overwriting A with B must have archived A first.
_arch="$(ls "$BANK_DIR"/archive/*.json 2>/dev/null | head -1)"
assert_ne "" "$_arch" "kc_write archived the pre-overwrite credential to archive/ (r5 P2)"
assert_contains '"accessToken":"A"' "$(cat "$_arch" 2>/dev/null)" "archive holds the overwritten outgoing creds (r5 P2)"
printf '' | kc_write >/dev/null 2>&1; assert_eq 10 "$?" "empty blob -> rc 10"
printf '%s' "$A" | STUB_KC_MODE=writeignore kc_write >/dev/null 2>&1; assert_eq 1 "$?" "write reported success but did not land -> rc 1 (indeterminate)"
assert_eq "$B" "$(kc_read)" "store unchanged after ignored write"
printf '%s' "$A" | STUB_KC_MODE=writefail kc_write >/dev/null 2>&1; assert_eq 1 "$?" "security nonzero + not landed -> rc 1"
# malformed blob (no refreshToken) rejected pre-write
printf '{"claudeAiOauth":{"accessToken":"x","expiresAt":1}}' | kc_write >/dev/null 2>&1; assert_eq 10 "$?" "incomplete blob rejected -> rc 10"

# (r4 #1) KC_LAST_SNAPSHOT must reach the PARENT shell. Write B via PROCESS
# SUBSTITUTION (runs kc_write in THIS shell) and confirm the variable holds a
# snapshot path whose bytes are the OVERWRITTEN A. Pre-fix, callers piped into
# kc_write (a subshell) and KC_LAST_SNAPSHOT stayed empty here — the whole outgoing
# re-bank recovery block was dead.
printf '%s' "$A" | W "$STUB_KC_FILE"; rm -f "$STUB_KC_FILE.rdcount"
KC_LAST_SNAPSHOT=""
kc_write < <(printf '%s' "$B") >/dev/null 2>&1; assert_eq 0 "$?" "process-sub write -> rc 0"
assert_ne "" "$KC_LAST_SNAPSHOT" "KC_LAST_SNAPSHOT reaches the parent shell (r4 #1)"
assert_eq "$A" "$(cat "$KC_LAST_SNAPSHOT" 2>/dev/null)" "snapshot holds the overwritten outgoing creds (r4 #1)"

# (r4 #1) even a PIPE (subshell) caller can recover the path via KC_LAST_SNAPSHOT_FILE.
printf '%s' "$B" | W "$STUB_KC_FILE"
rm -f "$KC_LAST_SNAPSHOT_FILE"
printf '%s' "$A" | kc_write >/dev/null 2>&1; assert_eq 0 "$?" "pipe write -> rc 0"
assert_file_present "$KC_LAST_SNAPSHOT_FILE" "snapshot path file written even from a pipe (r4 #1)"
_snap="$(cat "$KC_LAST_SNAPSHOT_FILE" 2>/dev/null)"
assert_eq "$B" "$(cat "$_snap" 2>/dev/null)" "file-fallback snapshot holds overwritten creds (r4 #1)"

# (r4 #2) a rotation between kc_write's snapshot and its write syscall -> rc 11,
# keychain UNCHANGED, and KC_LAST_SNAPSHOT refreshed to the newest live bytes so the
# caller re-banks the true-latest outgoing credential instead of parking a spent one.
printf '%s' "$A" | W "$STUB_KC_FILE"; rm -f "$STUB_KC_FILE.rdcount"
KC_LAST_SNAPSHOT=""
STUB_KC_MODE=rotate_recheck kc_write < <(printf '%s' "$B") >/dev/null 2>&1; assert_eq 11 "$?" "rotation between snapshot and write -> rc 11 (r4 #2)"
assert_eq "$A" "$(cat "$STUB_KC_FILE")" "keychain UNCHANGED on rc 11 (r4 #2)"
assert_contains "ROTATED" "$(cat "$KC_LAST_SNAPSHOT" 2>/dev/null)" "KC_LAST_SNAPSHOT refreshed to newest outgoing bytes (r4 #2)"

# (r5 #1) an EMPTY/UNREADABLE final re-read must NOT bypass the mismatch gate and
# overwrite blind. Store holds A; the recheck read returns empty -> kc_write REFUSES
# (rc 11), keychain UNCHANGED. PRE-FIX (recheck gated on `[ -n "$recheck_fp" ]`) the
# empty fingerprint skipped the gate and the write LANDED (rc 0, store -> B): this
# assertion fails on pre-fix code.
printf '%s' "$A" | W "$STUB_KC_FILE"; rm -f "$STUB_KC_FILE.rdcount"
KC_LAST_SNAPSHOT=""
STUB_KC_MODE=empty_recheck kc_write < <(printf '%s' "$B") >/dev/null 2>&1; assert_eq 11 "$?" "empty/unreadable recheck -> rc 11, no fail-open overwrite (r5 #1)"
assert_eq "$A" "$(cat "$STUB_KC_FILE")" "keychain UNCHANGED on empty recheck (r5 #1)"

# (finding 22) kc_write WITHOUT a snapshot (caller skipped acquire_lock) is refused
# fail-closed (rc 78), keychain UNCHANGED — it can no longer slip a write past the fence.
printf '%s' "$A" | W "$STUB_KC_FILE"
_saved_snap="$EPOCH_SNAP"; EPOCH_SNAP=""
printf '%s' "$B" | kc_write >/dev/null 2>&1; assert_eq 78 "$?" "kc_write without EPOCH_SNAP -> rc 78 (finding 22)"
assert_eq "$A" "$(kc_read)" "keychain UNCHANGED when snapshot missing (finding 22)"
EPOCH_SNAP="$_saved_snap"

finish "kc_write"
