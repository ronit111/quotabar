#!/usr/bin/env bash
# bank-account.sh — snapshot the CURRENTLY logged-in Claude Code account into the
# bank ($BANK_DIR/<email>.json). Idempotent. Never touches keychain.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ensure_bank
acquire_lock || { err "bank-account: could not acquire lock; aborting."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE

# reconcile any crash-recovery journals into the bank before we read anything
python3 "$HERE/reconcile.py" 2>/dev/null || true

raw="$(kc_read)"
[ -n "$raw" ] || { err "No Claude Code credentials found in keychain (exact match). Are you logged in?"; exit 1; }
email="$(active_email)"
if [ -z "$email" ]; then
  err "Could not determine active account email from $CLAUDE_JSON (oauthAccount.emailAddress)."
  err "Refusing to bank an account with no email identity."
  exit 1
fi

out="$(bank_file_for "$email")"

# blob via STDIN (never argv); helper writes the bank record atomically (0600).
if ! printf '%s' "$raw" | python3 "$HERE/write_bank_record.py" \
      "$CLAUDE_JSON" "$email" "$out" "$(now_iso)" "$(now_epoch)"; then
  err "bank-account: failed to write bank record."; exit 1
fi

echo "Banked $email -> $out"
