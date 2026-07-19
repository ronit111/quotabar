#!/usr/bin/env bash
# swap-account.sh <email> — switch the active Claude Code account to <email>.
#
# Hardened ordering (cross-vendor review 2026-07-19):
#   1. acquire lock FIRST
#   2. reconcile crash-recovery journals
#   3. load + FULLY validate the target UNDER the lock (existence, status,
#      metadata identity, blob schema) before touching the keychain
#   4. re-derive the current active account under the lock
#   5. current == target  -> no-op: only re-bank live creds, never write keychain
#   6. snapshot the live keychain (fail-closed), re-bank current, write target
#   7. update ~/.claude.json; on failure, ROLL BACK the keychain to the snapshot
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

target="${1:-}"
if [ -z "$target" ] || [ "${target:0:2}" = "--" ]; then
  err "Usage: swap-account.sh <email> [--expect-active <email>]"
  err "Banked accounts:"; list_bank_emails | sed 's/^/  - /' >&2
  exit 2
fi
shift
# --expect-active <email> (finding #11): the caller's snapshot of the active
# account. Under the lock we abort (exit 3) if the live active account no longer
# matches, so a SessionStart auto-pick can't overwrite a newer manual/QuotaBar
# switch that happened between the caller's read and our lock acquisition.
expect_active=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-active) expect_active="${2:-}"; shift 2 ;;
    *) err "swap: unknown argument '$1'"; exit 2 ;;
  esac
done

ensure_bank
acquire_lock || { err "swap: could not acquire lock; another bank/swap/usage op is running. Aborting."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE

python3 "$HERE/reconcile.py" 2>/dev/null || true

tf="$(bank_file_for "$target")"
[ -f "$tf" ] || {
  err "Account '$target' is not in the bank ($BANK_DIR)."
  err "Banked accounts:"; list_bank_emails | sed 's/^/  - /' >&2
  err "Bank it first: run /login in Claude Code, pick the account, then bank-account.sh"
  exit 1
}

# --- validate the target fully, under the lock, before any keychain write ---
# Emits the compact keychain blob on stdout if valid; non-zero + reason otherwise.
target_blob="$(python3 - "$tf" "$target" <<'PY'
import sys, json
tf, target = sys.argv[1], sys.argv[2]
try:
    rec = json.load(open(tf))
except Exception as e:
    sys.stderr.write(f"bank file unreadable: {e}\n"); sys.exit(1)
if not isinstance(rec, dict):
    sys.stderr.write("bank file is not an object\n"); sys.exit(1)
if rec.get("status") == "needs-relogin":
    sys.stderr.write("needs-relogin\n"); sys.exit(2)
oauth = rec.get("claudeAiOauth")
if not isinstance(oauth, dict) or not oauth.get("accessToken") or not oauth.get("refreshToken"):
    sys.stderr.write("bank creds incomplete (need access+refresh token)\n"); sys.exit(1)
meta = rec.get("oauthAccount") or {}
if not meta or meta.get("emailAddress") != target:
    sys.stderr.write("bank oauthAccount metadata missing or email mismatch; refusing swap\n"); sys.exit(3)
sys.stdout.write(json.dumps({"claudeAiOauth": oauth}, separators=(",", ":")))
PY
)"
vrc=$?
if [ $vrc -ne 0 ]; then
  case $vrc in
    2) err "Account '$target' needs re-login (parked token revoked/expired)."
       err "Recover: run /login in Claude Code, pick $target (browser usually still"
       err "authorized — two clicks), then: bash $HERE/bank-account.sh — then swap again." ;;
    3) err "Account '$target' has no valid identity metadata in the bank. Re-bank it:"
       err "  /login as $target, then bash $HERE/bank-account.sh" ;;
    *) err "Account '$target' failed validation; not swapping." ;;
  esac
  exit 1
fi

# --- re-derive current active account under the lock ---
current="$(active_email)"
raw_current="$(kc_read)"   # live blob, for re-bank AND rollback

# --- (finding #11) expected-active guard: bail if the world moved under us ---
if [ -n "$expect_active" ] && [ "$current" != "$expect_active" ]; then
  err "Aborting swap: expected active account '$expect_active' but it is now '$current'"
  err "(a newer manual/QuotaBar switch happened under the lock). No change made."
  exit 3
fi

# --- (5) no-op when target is already active: refresh the bank, never keychain ---
if [ -n "$current" ] && [ "$current" = "$target" ]; then
  if [ -n "$raw_current" ]; then
    cf="$(bank_file_for "$current")"
    printf '%s' "$raw_current" | python3 "$HERE/write_bank_record.py" \
      "$CLAUDE_JSON" "$current" "$cf" "$(now_iso)" "$(now_epoch)" || true
  fi
  echo "$target is already the active account. Refreshed its bank copy; keychain untouched."
  exit 0
fi

# --- (6a) re-bank the current active account (freshest tokens) ---
if [ -n "$current" ] && [ -n "$raw_current" ]; then
  cf="$(bank_file_for "$current")"
  printf '%s' "$raw_current" | python3 "$HERE/write_bank_record.py" \
    "$CLAUDE_JSON" "$current" "$cf" "$(now_iso)" "$(now_epoch)" || true
  echo "Re-banked current active account: $current (freshest tokens saved)"
fi

# === COMMIT SECTION (finding #1) ============================================
# The keychain write and the ~/.claude.json metadata write must land together or
# not at all. Two protections:
#   (a) A phase journal (pre-swap blob + from/to emails, 0600) is written BEFORE
#       the keychain write and cleared AFTER the metadata commit. reconcile.py
#       rolls the keychain back from it if we are interrupted in between.
#   (b) We ignore INT/TERM/HUP/PIPE across the commit so account-warn.sh's timeout
#       SIGTERM (its only bound; it no longer SIGKILLs here) cannot tear the
#       commit. The commit is sub-second, so the signal is simply deferred; the
#       EXIT trap still releases the lock. Even a hard SIGKILL is survivable
#       because (a) makes the torn state self-healing.
if [ -n "$raw_current" ]; then
  precompact="$(printf '%s' "$raw_current" | compact_blob 2>/dev/null)" || precompact=""
else
  precompact=""
fi
trap '' INT TERM HUP PIPE            # (b) defer signals across the commit
if [ -n "$precompact" ]; then
  printf '%s' "$precompact" | write_swap_journal "$target" "$current" || true
fi

# --- (6b) write target creds into the keychain (kc_write snapshots first) ---
if ! printf '%s' "$target_blob" | kc_write; then
  clear_swap_journal                 # keychain unchanged (kc_write fail-closed)
  trap 'release_lock; exit 130' INT TERM HUP PIPE
  err "FAILED to write target credentials to keychain (kc_write). Keychain unchanged."
  exit 1
fi

# --- (7) update ~/.claude.json; roll back the keychain on failure ---
if ! python3 - "$CLAUDE_JSON" "$tf" <<'PY'; then
import sys, json, os, tempfile
claude_json, tf = sys.argv[1], sys.argv[2]
meta = (json.load(open(tf)).get("oauthAccount") or {})
if not meta or not meta.get("emailAddress"):
    sys.stderr.write("bank metadata empty at write time\n"); sys.exit(1)
try:
    d = json.load(open(claude_json))
    if not isinstance(d, dict): raise ValueError("claude.json not an object")
except Exception as e:
    sys.stderr.write(f"claude.json unreadable: {e}\n"); sys.exit(1)
d["oauthAccount"] = meta
dirn = os.path.dirname(claude_json) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".claude.json.")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, claude_json)
PY
  err "Metadata update FAILED. Rolling back keychain to the pre-swap account…"
  if [ -n "$precompact" ]; then
    if printf '%s' "$precompact" | kc_write; then
      clear_swap_journal   # keychain and metadata both back to pre-swap: consistent
      err "Rollback complete: keychain restored to $current. No change applied."
    else
      # leave the journal so reconcile.py retries the rollback on the next op
      err "ROLLBACK FAILED. Journal kept for reconcile; snapshot also in $SNAP_DIR."
    fi
  else
    err "No pre-swap blob captured; latest snapshot is in $SNAP_DIR."
  fi
  trap 'release_lock; exit 130' INT TERM HUP PIPE
  exit 1
fi

# metadata committed: keychain and ~/.claude.json now both point at the target.
clear_swap_journal
trap 'release_lock; exit 130' INT TERM HUP PIPE
# === END COMMIT SECTION =====================================================

# --- report ---
sub="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("claudeAiOauth") or {}).get("subscriptionType","?"))' "$tf")"
banked_at="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("banked_at","?"))' "$tf")"
echo ""
echo "Active account is now: $target  (subscription: $sub)"
echo "  banked_at: $banked_at"

procs="$(pgrep -fl 'claude' 2>/dev/null | grep -v 'swap-account' | grep -vi 'grep' || true)"
if [ -n "$procs" ]; then
  echo ""
  echo "NOTE: All running Claude Code sessions switch to $target on their next request"
  echo "  (turn-level pickup, verified 2026-07-19). No /login needed. Session UIs may still"
  echo "  DISPLAY the old account — that is cosmetic only. Sessions that will switch:"
  echo "$procs" | sed 's/^/    /'
fi
