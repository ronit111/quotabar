#!/usr/bin/env bash
# bank-account.sh [email] — snapshot the CURRENTLY logged-in Claude Code account into
# the bank ($HOME/.claude/accounts/<email>.json). Idempotent. Never touches keychain.
#
# The optional `email` names the CARD the request came from (QuotaBar's Re-bank button
# passes it). With no argument the behaviour is exactly what it always was: bank whoever
# is active — that is the SessionStart auto-bank / "Link account" path and it is
# unchanged. With an argument it becomes answerable about WHICH account was asked for,
# which is what lets a dead card recover in one click instead of a manual ceremony.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ensure_bank

# --- Re-bank routing (before the lock: the relogin flow waits on a human) -----
# When the named account IS the active login there is a live credential to capture and
# the normal ceremony below does it. When it is NOT, there is nothing capturable for it
# in any seat, so a "re-bank" that proceeded would silently snapshot a DIFFERENT account
# — which is what this used to do. A record that is needs-relogin (or missing/malformed)
# has exactly one real recovery, a fresh browser OAuth, so route there and let
# relogin-account.sh do the whole thing. Anything else refuses honestly.
TARGET_EMAIL="${1:-}"
if [ -n "$TARGET_EMAIL" ]; then
  bank_file_for "$TARGET_EMAIL" >/dev/null || exit 1
  _active="$(active_email)"
  if [ "$TARGET_EMAIL" != "$_active" ]; then
    _tf="$(bank_file_for "$TARGET_EMAIL")"
    _status="$(ACCOUNT_BANK_HERE="$HERE" python3 - "$_tf" <<'PY'
import sys, os
sys.path.insert(0, os.environ["ACCOUNT_BANK_HERE"])
import bank_common
p = sys.argv[1]
if not os.path.exists(p):
    print("missing")
else:
    br = bank_common.load_bank_record(p)
    print(br.record.get("status", "ok") if br.ok else "malformed")
PY
)"
    case "$_status" in
      needs-relogin|missing|malformed)
        echo "Re-bank: $TARGET_EMAIL is not the active account and its record is $_status —"
        echo "the only recovery is a fresh login. Handing off to relogin-account.sh."
        export BANK_DIR          # the child must resolve the SAME bank we just read
        exec /bin/bash "$HERE/relogin-account.sh" "$TARGET_EMAIL"
        ;;
      *)
        err "Re-bank: $TARGET_EMAIL is not the active account (${_active:-none}) and its record"
        err "is '$_status' — there is no credential for it to capture, so nothing was written."
        err "To refresh it anyway: bash $HERE/relogin-account.sh $TARGET_EMAIL"
        exit 1
        ;;
    esac
  fi
fi

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
