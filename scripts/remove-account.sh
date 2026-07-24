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

ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/reconcile.py"; rcrc=$?
if [ "$rcrc" -ne 0 ]; then
  err "remove-account: reconcile did not complete cleanly (rc $rcrc); refusing to remove."
  err "Inspect list-accounts.sh / .swap-journal.json / .swap-unresolved and resolve first."
  exit 1
fi

# --- (r12 #7) EPOCH-GUARD FIRST, before ANY mutation path -----------------------
# Removal mutates v1 bank state — the record delete AND drop_from_autoping's .config.json
# scrub. The no-legacy-record branch below used to `return` BEFORE the (later) epoch_guard,
# so under EPOCH v2 it could still rewrite .config.json and falsely report "nothing to
# remove" while the READY home stayed registered. Fence here so v2 refuses rc 78 with an
# honest message before drop_from_autoping or any delete runs.
if ! epoch_guard; then
  _st="$(python3 "$HERE/epoch.py" snapshot "$BANK_DIR" 2>/dev/null | awk '{print $1}')"
  if [ "$_st" = "v2" ]; then
    err "remove-account: under EPOCH v2, accounts live in per-home dirs; this v1 tool does not"
    err "remove v2 READY homes (use the QuotaBar v2 remove flow). rc 78; nothing changed."
  else
    err "remove-account: epoch gate refused the mutation (rc 78; nothing changed). Re-run after the flip/seed settles."
  fi
  exit 78
fi

# --- (3) refuse to remove the live active account -----------------------------
current="$(active_email)"
if [ -n "$current" ] && [ "$current" = "$target" ]; then
  err "Cannot remove the active account ($target); swap to another account first."
  err "Run swap-account.sh <other-email>, then remove-account.sh $target."
  exit 1
fi

# --- (4) refuse if it is not a banked account ---------------------------------
tf="$(bank_file_for "$target")" || { err "remove-account: refusing unsafe email '$target'."; exit 2; }
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

# --- (finding #51 + re-review issue 11) revalidate the active identity IMMEDIATELY
#     before deletion, by BOTH email AND credential fingerprint (stable read). A
#     /login writes the keychain BEFORE ~/.claude.json, so the email alone can
#     still read as parked while the keychain already holds this account's creds
#     (it is becoming active). Compare the live keychain fingerprint to the
#     target's banked credential too, and abort if they match. ---
current2="$(active_email)"
if [ -n "$current2" ] && [ "$current2" = "$target" ]; then
  err "Aborting removal: '$target' just became the ACTIVE account (a /login raced us)."
  err "Swap away first, then remove."
  exit 1
fi
# stable live keychain fingerprint
live1="$(active_cred_fp)"; live2="$(active_cred_fp)"
target_cred_fp="$(python3 -c 'import json,sys
sys.path.insert(0, sys.argv[1]); import bank_common
try:
    o=(json.load(open(sys.argv[2])).get("claudeAiOauth") or {})
except Exception:
    o={}
print(bank_common.cred_fingerprint(o))' "$HERE" "$tf" 2>/dev/null)"
if [ -n "$live1" ] && [ "$live1" = "$live2" ] && [ -n "$target_cred_fp" ] && [ "$live1" = "$target_cred_fp" ]; then
  err "Aborting removal: the live keychain now holds '$target's credentials (it is"
  err "becoming the active account via a /login). Swap away / let the login settle first."
  exit 1
fi

# --- (r6 b10) epoch gate the record + cache deletion — removing a bank record (and
# purging its usage-cache entry) is a v1 bank-state mutation, so it must pass the SAME
# v1-gate + generation fence every credential mutator uses. An in-flight removal that
# slept across a flip/freeze must not delete a record the new epoch may depend on.
# rc 78 = fenced, NOTHING deleted.
if ! epoch_guard; then
  err "Aborting removal: epoch gate refused the mutation (rc 78; nothing deleted). Re-run after the flip/seed settles."
  exit 78
fi

# --- (5) delete the bank file atomically, CHECKING the result (finding #50) ----
# rename-away-then-unlink so a reader mid-op sees the file present or gone, never
# a half-truncated record. Every step's result is checked; we report success ONLY
# if the record is verifiably absent (never leave a token-bearing tombstone while
# printing "Removed").
gone="$tf.removing.$$.$RANDOM"
if mv -f "$tf" "$gone" 2>/dev/null; then
  if ! rm -f "$gone" 2>/dev/null; then
    err "remove-account: renamed the record aside but could not unlink it ($gone)."
    err "A token-bearing file remains; NOT reporting success."
    exit 1
  fi
elif ! rm -f "$tf" 2>/dev/null; then
  err "remove-account: FAILED to delete the bank record ($tf). Nothing removed."
  exit 1
fi
if [ -e "$tf" ] || [ -e "$gone" ]; then
  err "remove-account: bank record still present after delete attempt; failing loud."
  exit 1
fi

# --- (6) drop <email> from the auto_ping list ---------------------------------
removed_from_cfg="$(drop_from_autoping "$target")"

# --- (finding #52) invalidate the usage-cache entry under the same lock so a
#     SessionStart hook can't auto-pick a just-removed account from a fresh cache.
python3 - "$CACHE_FILE" "$target" <<'PY' 2>/dev/null || true
import sys, json, os, tempfile
cache, email = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(cache))
    if not isinstance(d, dict):
        sys.exit(0)
except Exception:
    sys.exit(0)
accts = d.get("accounts")
if isinstance(accts, list):
    d["accounts"] = [a for a in accts
                     if not (isinstance(a, dict) and a.get("provider") == "claude"
                             and a.get("email") == email)]
    dirn = os.path.dirname(cache) or "."
    fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".usage-cache.")
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, 0o600); os.replace(tmp, cache)
PY

# --- report -------------------------------------------------------------------
echo "Removed banked account: $target"
echo "  bank file deleted:    $tf"
if [ "$removed_from_cfg" = "1" ]; then
  echo "  auto-ping entry:      removed from .config.json"
fi
echo "  keychain:             untouched (live login unaffected; snapshots kept as history)"
echo "  auto-pick pool:       $target excluded automatically (no bank file)"
