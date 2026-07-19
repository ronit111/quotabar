#!/usr/bin/env bash
# remove-account.sh <email> — forget a PARKED Claude account: delete its bank
# record and drop it from the auto-ping list. The live keychain is never touched.
#
# Hardened ordering (mirrors swap-account.sh's discipline):
#   1. acquire the bank lock FIRST
#   2. reconcile crash-recovery journals under the lock
#   3. re-derive the live active account under the lock and REFUSE to remove it
#      (the active account owns the live keychain item; removing its bank record
#      would strand the running session's usage tracking) — swap away first
#   4. REFUSE if <email> is not a banked account (nothing to remove)
#   5. delete the bank file atomically (rename-away, then unlink)
#   6. drop <email> from .config.json auto_ping (atomic 0600 write, fail-soft)
# Auto-pick needs no edit: it enumerates bank files, so a removed account leaves
# the pool automatically. Keychain snapshots in .keychain-snapshots are harmless
# history and are intentionally left in place.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

target="${1:-}"
if [ -z "$target" ] || [ "${target:0:2}" = "--" ]; then
  err "Usage: remove-account.sh <email>"
  err "Banked accounts:"; list_bank_emails | sed 's/^/  - /' >&2
  exit 2
fi

ensure_bank
acquire_lock || { err "remove-account: could not acquire lock; another bank/swap/usage op is running. Aborting."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE

python3 "$HERE/reconcile.py" 2>/dev/null || true

# --- (3) refuse to remove the live active account -----------------------------
current="$(active_email)"
if [ -n "$current" ] && [ "$current" = "$target" ]; then
  err "Cannot remove the active account ($target); swap to another account first."
  err "Run swap-account.sh <other-email>, then remove-account.sh $target."
  exit 1
fi

# --- (4) refuse if it is not a banked account ---------------------------------
tf="$(bank_file_for "$target")"
if [ ! -f "$tf" ]; then
  # idempotent-ish: still scrub any stray auto_ping entry, then report a clean no-op
  removed_from_cfg="$(drop_from_autoping "$target")"
  if [ "$removed_from_cfg" = "1" ]; then
    echo "'$target' was not a banked account (no bank file); removed a stray auto-ping entry."
  else
    echo "'$target' is not a banked account. Nothing to remove."
  fi
  exit 0
fi

# --- (5) delete the bank file atomically --------------------------------------
# rename-away-then-unlink so a reader mid-op sees the file present or gone, never
# a half-truncated record.
gone="$tf.removing.$$.$RANDOM"
if mv -f "$tf" "$gone" 2>/dev/null; then
  rm -f "$gone" 2>/dev/null
else
  rm -f "$tf" 2>/dev/null
fi

# --- (6) drop <email> from the auto_ping list ---------------------------------
removed_from_cfg="$(drop_from_autoping "$target")"

# --- report -------------------------------------------------------------------
echo "Removed banked account: $target"
echo "  bank file deleted:    $tf"
if [ "$removed_from_cfg" = "1" ]; then
  echo "  auto-ping entry:      removed from .config.json"
fi
echo "  keychain:             untouched (live login unaffected; snapshots kept as history)"
echo "  auto-pick pool:       $target excluded automatically (no bank file)"
