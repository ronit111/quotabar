#!/usr/bin/env bash
# bank-account.sh — snapshot the CURRENTLY logged-in Claude Code account into the
# bank ($HOME/.claude/accounts/<email>.json). Idempotent. Never touches keychain.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ensure_bank
acquire_lock || { err "bank-account: could not acquire lock; aborting."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE

# reconcile any crash-recovery journals into the bank before we read anything.
# An UNRESOLVED torn swap (exit 10) blocks banking too (finding #13).
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/reconcile.py"; rcrc=$?
if [ "$rcrc" -ne 0 ]; then
  err "bank-account: reconcile did not complete cleanly (rc $rcrc); refusing to bank."
  err "Inspect list-accounts.sh / .swap-journal.json / .swap-unresolved and resolve first."
  exit 1
fi

# --- (finding #5) capture a STABLE keychain+identity snapshot ---
# Read the keychain blob AND the active identity, then re-read both and require
# they are unchanged. If a /login rotates the keychain or switches the account
# between the two reads, the snapshot is torn — abort rather than bind one
# account's tokens to another's identity. write_bank_record.py enforces the
# metadata==email match as a second, independent gate.
raw="$(cred_read)"
[ -n "$raw" ] || { err "No Claude Code credentials found (checked ~/.claude/.credentials.json and the keychain slot). Are you logged in?"; exit 1; }
email="$(active_email)"
if [ -z "$email" ]; then
  err "Could not determine active account email from $CLAUDE_JSON (oauthAccount.emailAddress)."
  err "Refusing to bank an account with no email identity."
  exit 1
fi
fp1="$(printf '%s' "$raw" | _cred_fp)"
raw2="$(cred_read)"; email2="$(active_email)"
fp2="$(printf '%s' "$raw2" | _cred_fp)"
if [ -z "$fp1" ] || [ "$fp1" != "$fp2" ] || [ "$email" != "$email2" ]; then
  err "bank-account: the active account changed while capturing it (a /login raced the"
  err "read). No record written; re-run bank-account.sh once the login settles."
  exit 1
fi

out="$(bank_file_for "$email")" || { err "bank-account: unsafe active email '$email'; refusing."; exit 1; }

# blob via STDIN (never argv); helper writes the bank record atomically (0600),
# independently re-checks the metadata==email identity match (findings #5/#6), and
# re-verifies the credential fingerprint we captured (fp1) still matches the blob
# (re-review issue 11) so a raced /login can't misattribute a credential.
if ! printf '%s' "$raw" | ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/write_bank_record.py" \
      "$CLAUDE_JSON" "$email" "$out" "$(now_iso)" "$(now_epoch)" "$fp1"; then
  err "bank-account: failed to write bank record."; exit 1
fi

echo "Banked $email -> $out"
