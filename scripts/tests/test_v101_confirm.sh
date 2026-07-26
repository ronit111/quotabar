#!/bin/bash
# (v101-confirm) Shell-side fixes from the confirmation review.
#
#   #1  account-warn.sh (SessionStart) re-banks ONLY drift it can attribute offline and
#       ANNOUNCES everything it defers to the oracle-gated poll heal.
#   #3  release.sh refuses to label an artifact with a version the built bundle disagrees with.
#   #4  account-warn.sh and session-hook.sh use THE bank-directory rule (BANK_DIR ->
#       ACCOUNT_BANK_DIR -> default), the same one lib.sh and bank_common already share.
#   #7  a failed journal clear after a COMMITTED swap is its own outcome, never a silent 0.
#
# Hermetic: temp banks, stub keychain, no real login, no installer, no publisher.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
REPO="$(cd "$AB_DIR/.." && pwd)"

# hook_out — run the SessionStart hook and print its stdout (the one JSON object it emits).
hook_out() { /bin/bash "$AB_DIR/account-warn.sh" 2>/dev/null; }

# fresh_cache — a usage cache the hook accepts as fresh, with the active account cold enough
# that autopick decides "none". Keeps every test below on the login-sync path only.
fresh_cache() {
  python3 - "$BANK_DIR/.usage-cache.json" "$1" <<'PY'
import json, sys
json.dump({"accounts": [{"provider": "claude", "email": sys.argv[2], "active": True,
                         "status": "ok",
                         "worst_limit": {"percent": 5, "kind": "five_hour",
                                         "resets_at": "2026-01-01T00:00:00Z"}}]},
          open(sys.argv[1], "w"))
PY
}

record_field() { # <email> <top-level-or-oauth-field>
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
o = d.get("claudeAiOauth") or {}
print(o.get(sys.argv[2], d.get(sys.argv[2], "")))' "$BANK_DIR/$1.json" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# (#1) the hook re-banks ONLY what it can prove offline
# ---------------------------------------------------------------------------
# THE provable case: the access token is unchanged and only the refresh token rotated. An
# access token is issued to one account, so this is provably that account's own credential.
new_env v101_hook_refresh >/dev/null
set_active a@x.com AT-1 RT-2 "$FUT" max claude_max      # keychain: rotated refresh token
bank_record a@x.com AT-1 RT-1 "$FUT" max claude_max     # bank: the older refresh token
fresh_cache a@x.com
out="$(hook_out)"
assert_eq "RT-2" "$(record_field a@x.com refreshToken)" \
  "(#1) an unchanged access token with a rotated refresh token IS re-banked by the hook"
assert_eq "" "$out" "(#1) a routine rotation stays silent — it is not news"

# THE critical case the review found: a keychain-first /login to a SAME-PLAN account. Offline
# this is byte-identical to a rotation, so the hook must leave the bank record ALONE.
new_env v101_hook_sameplan >/dev/null
set_active a@x.com AT-B RT-B "$FUT" max claude_max      # keychain: a DIFFERENT credential
bank_record a@x.com AT-A RT-A "$FUT" max claude_max     # same plan, so plan checks pass
fresh_cache a@x.com
before="$(cat "$BANK_DIR/a@x.com.json")"
out="$(hook_out)"
assert_eq "$before" "$(cat "$BANK_DIR/a@x.com.json")" \
  "(#1) a same-plan keychain-first /login leaves the bank record BYTE-IDENTICAL"
assert_eq "AT-A" "$(record_field a@x.com accessToken)" \
  "(#1) account A's banked credential is NOT overwritten with B's tokens"
assert_contains "deferred" "$out" "(#1) the hook ANNOUNCES what it deferred"
assert_contains "identity-verified poll" "$out" "(#1) ...and names where it was deferred to"
assert_file_absent "$BANK_DIR/archive" \
  "(#1) nothing was overwritten, so no predecessor archival happened either"

# a plan change defers too — with its own message, because it IS news.
new_env v101_hook_planchange >/dev/null
set_active a@x.com AT-1 RT-2 "$FUT" pro claude_pro      # same access token, new plan
bank_record a@x.com AT-1 RT-1 "$FUT" max claude_max
fresh_cache a@x.com
before="$(cat "$BANK_DIR/a@x.com.json")"
out="$(hook_out)"
assert_eq "$before" "$(cat "$BANK_DIR/a@x.com.json")" \
  "(#1) a plan change leaves the bank record untouched"
assert_contains "plan change detected (max -> pro)" "$out" \
  "(#1) the plan change is announced with both tiers"
assert_contains "bank-account.sh" "$out" "(#1) ...and names the one-line manual fix"

# no drift at all: nothing to say, nothing to do.
new_env v101_hook_nodrift >/dev/null
set_active a@x.com AT-1 RT-1 "$FUT" max claude_max
bank_record a@x.com AT-1 RT-1 "$FUT" max claude_max
fresh_cache a@x.com
out="$(hook_out)"
assert_eq "" "$out" "(#1) an unchanged credential produces no message"

# ---------------------------------------------------------------------------
# (#4) THE bank-directory rule, in the two entry points that skipped a rung
# ---------------------------------------------------------------------------
# account-warn.sh used to read BANK_DIR only, so an ACCOUNT_BANK_DIR-only setup had the hook
# reading the DEFAULT bank while the children it spawns mutated the custom one.
new_env v101_bankdir_hook >/dev/null
set_active a@x.com AT-1 RT-1 "$FUT" max claude_max
CUSTOM="$BANK_DIR/custom"; mkdir -p "$CUSTOM"; chmod 700 "$CUSTOM"
( unset BANK_DIR; ACCOUNT_BANK_DIR="$CUSTOM" /bin/bash "$AB_DIR/account-warn.sh" >/dev/null 2>&1 )
assert_file_present "$CUSTOM/a@x.com.json" \
  "(#4) with ACCOUNT_BANK_DIR only, the hook auto-banks into THAT bank"
assert_file_absent "$BANK_DIR/a@x.com.json" \
  "(#4) ...and not into the default bank it used to read"

# BANK_DIR must still outrank ACCOUNT_BANK_DIR, in the same entry point.
new_env v101_bankdir_hook_prec >/dev/null
set_active a@x.com AT-1 RT-1 "$FUT" max claude_max
WINNER="$BANK_DIR/winner"; LOSER="$BANK_DIR/loser"
mkdir -p "$WINNER" "$LOSER"; chmod 700 "$WINNER" "$LOSER"
BANK_DIR="$WINNER" ACCOUNT_BANK_DIR="$LOSER" /bin/bash "$AB_DIR/account-warn.sh" >/dev/null 2>&1
assert_file_present "$WINNER/a@x.com.json" "(#4) BANK_DIR outranks ACCOUNT_BANK_DIR in the hook"
assert_file_absent "$LOSER/a@x.com.json" "(#4) ...and the lower rung is not touched"

# session-hook.sh used to start at ACCOUNT_BANK_DIR, so a BANK_DIR-only setup tracked sessions
# in a different bank than the one the swap/poll rails lock.
SH_T="$(mktemp -d)"; SH_ACC="$SH_T/accounts"; mkdir -p "$SH_ACC/homes/a-at-x.com"
SH_SID="99999999-2222-3333-4444-555555555555"
printf '{"session_id":"%s","cwd":"/tmp","transcript_path":"/tp.jsonl"}' "$SH_SID" \
  | env -u ACCOUNT_BANK_DIR BANK_DIR="$SH_ACC" ACCOUNT_BANK_SCRIPTS_DIR="$AB_DIR" \
        ACCOUNT_BANK_HOOK_PID="$$" CLAUDE_CONFIG_DIR="$SH_ACC/homes/a-at-x.com" \
        bash "$AB_DIR/session-hook.sh" start >/dev/null 2>&1
assert_file_present "$SH_ACC/sessions.json" \
  "(#4) session-hook.sh honours BANK_DIR (it used to see only ACCOUNT_BANK_DIR)"

SH_WIN="$SH_T/win"; SH_LOSE="$SH_T/lose"
mkdir -p "$SH_WIN/homes/a-at-x.com" "$SH_LOSE/homes/a-at-x.com"
printf '{"session_id":"%s","cwd":"/tmp","transcript_path":"/tp.jsonl"}' "$SH_SID" \
  | env BANK_DIR="$SH_WIN" ACCOUNT_BANK_DIR="$SH_LOSE" ACCOUNT_BANK_SCRIPTS_DIR="$AB_DIR" \
        ACCOUNT_BANK_HOOK_PID="$$" CLAUDE_CONFIG_DIR="$SH_WIN/homes/a-at-x.com" \
        bash "$AB_DIR/session-hook.sh" start >/dev/null 2>&1
assert_file_present "$SH_WIN/sessions.json" "(#4) session-hook.sh gives BANK_DIR precedence"
assert_file_absent "$SH_LOSE/sessions.json" "(#4) ...and leaves the lower rung alone"
rm -rf "$SH_T"

# archiverd resolves through the same shared rule rather than its own partial one.
python3 - "$AB_DIR" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import bank_common
src = open(os.path.join(sys.argv[1], "archiverd.py")).read()
assert "bank_common.resolve_bank_dir()" in src, "archiverd must use the shared resolver"
assert 'os.environ.get("ACCOUNT_BANK_DIR", os.path.expanduser' not in src, \
    "archiverd must not carry its own partial precedence"
os.environ.pop("BANK_DIR", None)
os.environ["ACCOUNT_BANK_DIR"] = "/tmp/v101-ab"
assert bank_common.resolve_bank_dir() == "/tmp/v101-ab"
os.environ["BANK_DIR"] = "/tmp/v101-b"
assert bank_common.resolve_bank_dir() == "/tmp/v101-b"
print("PYOK")
PY
assert_eq 0 "$?" "(#4) archiverd routes through bank_common.resolve_bank_dir (BANK_DIR first)"

# ---------------------------------------------------------------------------
# (#7) a failed journal clear after a COMMITTED swap
# ---------------------------------------------------------------------------
# clear_swap_journal distinguishes "still on disk" (rc 1) from "removed but not proven
# durable" (rc 2). The old code ended on a best-effort fsync whose `|| true` made rc 2 read
# as clean success.
new_env v101_journal_rc >/dev/null
source "$AB_DIR/lib.sh"; ensure_bank
printf '{"type":"swap"}' > "$SWAP_JOURNAL"
( _fsync_dir_checked() { return 1; }
  clear_swap_journal >/dev/null 2>&1; exit $? )
assert_eq 2 "$?" "(#7) an unsyncable directory yields the distinct rc 2, never 0"
assert_file_absent "$SWAP_JOURNAL" "(#7) ...the unlink itself still happened"
_fsync_dir_checked "$BANK_DIR"; assert_eq 0 "$?" "(#7) the checked fsync succeeds on a real directory"
_fsync_dir_checked "$BANK_DIR/does-not-exist"
assert_ne 0 "$?" "(#7) ...and REPORTS a directory it cannot open (the best-effort one swallows it)"

# End to end: a swap that COMMITS but cannot clear its journal must exit 6 — not 0 (a lie),
# and not a generic failure (also a lie: the switch really happened). Injected by overriding
# clear_swap_journal in a COPY of the scripts, so the real commit path runs untouched.
new_env v101_swap_rc6 >/dev/null
COPY="$(mktemp -d)/scripts"; /bin/cp -R "$AB_DIR/." "$COPY"
cat >> "$COPY/lib.sh" <<'EOS'
clear_swap_journal() { err "account-bank: FAILED to clear the swap journal (injected)."; return 1; }
EOS
set_active a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" pro claude_pro
out="$(/bin/bash "$COPY/swap-account.sh" b@x.com 2>&1)"; rc=$?
assert_eq 6 "$rc" "(#7) commit-landed/cleanup-failed exits 6 — a distinct outcome, never 0"
assert_contains "Active account is now: b@x.com" "$out" \
  "(#7) the committed switch is still reported — it really did happen"
assert_contains "COMMITTED, but its recovery journal could not be cleared" "$out" \
  "(#7) ...and the cleanup failure is stated plainly"
assert_contains '"accessToken":"B"' "$(kc_now)" "(#7) the keychain really holds the target"
assert_eq "b@x.com" "$(claude_json_email)" "(#7) the metadata really names the target"
rm -rf "$(dirname "$COPY")"

# the hook maps rc 6 to "swapped, but clean up" rather than "the swap did not complete".
assert_contains "rc == 6" "$(cat "$AB_DIR/account-warn.sh")" \
  "(#7) the SessionStart hook has a dedicated branch for rc 6"

# ---------------------------------------------------------------------------
# (#3) release.sh cannot label an artifact with a version the bundle disagrees with
# ---------------------------------------------------------------------------
V_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/app/Info.plist")"
V_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$REPO/app/Info.plist")"
assert_eq "1.0.1" "$V_SHORT" "(#3) the shipped Info.plist reports 1.0.1"
assert_ne "1" "$V_BUILD" "(#3) CFBundleVersion was bumped too (upgrades need a higher build)"

# Extract release.sh's version-guard block verbatim so the test exercises the SHIPPED code.
T="$(mktemp -d)"
{ echo 'set -euo pipefail'
  python3 - "$REPO/release.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index('if [ "$VERSION" != "$PLIST_VERSION" ]; then')
end = src.index("\nfi\n", start) + 4
sys.stdout.write(src[start:end])
PY
} > "$T/guard.sh"
assert_contains "REFUSING" "$(cat "$T/guard.sh")" "(#3) extracted the real guard from release.sh"
guard() { VERSION="$1" PLIST_VERSION="$2" DIST="/dist" bash "$T/guard.sh"; }
guard 1.0.1 1.0.1 >/dev/null 2>&1
assert_eq 0 "$?" "(#3) a requested version matching the built bundle passes"
out="$(guard 1.0.1 1.0.0 2>&1)"; rc=$?
assert_ne 0 "$rc" "(#3) 'release.sh 1.0.1' against a 1.0.0 bundle FAILS (the reported bug)"
assert_contains "does not match the BUILT bundle" "$out" "(#3) ...and says exactly why"
guard 0.9.0 1.0.1 >/dev/null 2>&1
assert_ne 0 "$?" "(#3) a DOWNGRADE label is refused too"
rm -rf "$T"

finish v101_confirm
