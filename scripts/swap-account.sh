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

# (re-review issue 13) NEVER create the keychain item during a swap. If BOOTSTRAP
# is inherited, a no-preimage swap could CREATE the item and then have no rollback
# path on metadata failure. Force it off for the whole swap; kc_write then refuses
# to create (fails closed) rather than silently bootstrapping.
if [ "${ACCOUNT_BANK_BOOTSTRAP:-0}" = "1" ]; then
  err "swap: refusing to run with ACCOUNT_BANK_BOOTSTRAP=1 (would allow creating the"
  err "keychain item with no rollback path). Bootstrap the login separately first."
  exit 2
fi
export ACCOUNT_BANK_BOOTSTRAP=0

ensure_bank
acquire_lock || { err "swap: could not acquire lock; another bank/swap/usage op is running. Aborting."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE

# Reconcile crash-recovery journals UNDER our lock. If a torn swap cannot be
# resolved to a consistent state, reconcile exits 10 (unresolved) and we ABORT:
# mutating while the keychain/metadata pairing is unknown is exactly finding #13.
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/reconcile.py"; rcrc=$?
if [ "$rcrc" -ne 0 ]; then
  err "Aborting swap: reconcile did not complete cleanly (rc $rcrc — 10=unresolved torn"
  err "swap, other=unexpected error). The keychain and ~/.claude.json may disagree."
  err "Inspect list-accounts.sh / .swap-journal.json / .swap-unresolved and resolve"
  err "before swapping. No change made."
  exit 1
fi

tf="$(bank_file_for "$target")" || { err "swap: refusing unsafe target email '$target'."; exit 2; }
[ -f "$tf" ] || {
  err "Account '$target' is not in the bank ($BANK_DIR)."
  err "Banked accounts:"; list_bank_emails | sed 's/^/  - /' >&2
  err "Bank it first: run /login in Claude Code, pick the account, then bank-account.sh"
  exit 1
}

# --- validate the target fully, under the lock, before any keychain write ---
# Routes through the SHARED validated loader (re-review issue 10) so swap enforces
# exactly the same schema as every other reader — no weaker inline checks that
# accept an unknown status or a top-level email mismatch. Emits the compact
# keychain blob on stdout if valid; non-zero + reason otherwise.
target_blob="$(python3 - "$HERE" "$tf" "$target" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
import bank_common
tf, target = sys.argv[2], sys.argv[3]
br = bank_common.load_bank_record(tf)          # dict + email==filename + status + valid cred
if not br.ok:
    # a needs-relogin record is "ok" (valid) but not swappable — handle explicitly
    sys.stderr.write(f"invalid bank record: {br.reason}\n"); sys.exit(1)
if br.status == "needs-relogin":
    sys.stderr.write("needs-relogin\n"); sys.exit(2)
if br.email != target:
    sys.stderr.write("bank record email does not match requested target\n"); sys.exit(3)
meta = br.record.get("oauthAccount") or {}
if not isinstance(meta, dict) or meta.get("emailAddress") != target:
    sys.stderr.write("bank oauthAccount metadata missing or email mismatch; refusing swap\n"); sys.exit(3)
if not bank_common.valid_oauth(br.oauth):
    sys.stderr.write("bank creds incomplete (need access+refresh token + numeric expiresAt)\n"); sys.exit(1)
sys.stdout.write(json.dumps({"claudeAiOauth": br.oauth}, separators=(",", ":")))
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

# --- re-derive current active account + live credential under the lock ---
current="$(active_email)"
raw_current="$(cred_read)"   # live blob (v108: the SEAT), for re-bank AND rollback
target_fp="$(printf '%s' "$target_blob" | _cred_fp)"

# --- (finding #11) expected-active guard: bail if the world moved under us ---
if [ -n "$expect_active" ] && [ "$current" != "$expect_active" ]; then
  err "Aborting swap: expected active account '$expect_active' but it is now '$current'"
  err "(a newer manual/QuotaBar switch happened under the lock). No change made."
  exit 3
fi

# --- (5) no-op when target is already active: refresh the bank, never keychain ---
if [ -n "$current" ] && [ "$current" = "$target" ]; then
  # (r3 #17) do NOT suppress a re-bank failure with `|| true` and then claim the
  # bank copy was refreshed. Report the actual result honestly and fail loud if the
  # bank copy could not be synchronized — a stale/unwritable record presented as
  # "refreshed" is exactly the defect.
  if [ -n "$raw_current" ]; then
    cf="$(bank_file_for "$current")" || cf=""
    if [ -z "$cf" ]; then
      err "swap: outgoing email '$current' is unsafe; cannot refresh its bank copy."
      exit 1
    fi
    # FORCE_REBANK: we are writing VERIFIED-LIVE outgoing creds; recover over a
    # corrupt existing record rather than block on it (issue 10 balance).
    if printf '%s' "$raw_current" | ACCOUNT_BANK_FORCE_REBANK=1 ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/write_bank_record.py" \
        "$CLAUDE_JSON" "$current" "$cf" "$(now_iso)" "$(now_epoch)"; then
      echo "$target is already the active account. Refreshed its bank copy; keychain untouched."
      exit 0
    fi
    err "swap: $target is already active, but REFRESHING its bank copy FAILED. The"
    err "banked record may be stale; the keychain (live login) is untouched."
    exit 1
  fi
  # No live keychain read: can't refresh the bank copy, so don't claim we did.
  err "swap: $target is already active, but the live keychain was unreadable; could"
  err "NOT refresh its bank copy. Keychain untouched; re-run once the login settles."
  exit 1
fi

# --- (r3 #3) a live keychain credential with NO identifiable active email is a
#     torn/unknown state. If we proceeded, the outgoing credential could never be
#     banked under a known email and would be lost when the target overwrites it
#     (surviving only as an anonymous snapshot). Refuse rather than orphan it. ---
if [ -n "$raw_current" ] && [ -z "$current" ]; then
  err "Aborting swap: the live keychain holds a credential but the active identity"
  err "metadata (oauthAccount.emailAddress in $CLAUDE_JSON) is missing/unreadable."
  err "Refusing to overwrite an unidentifiable live credential — it could not be"
  err "banked under a known account and would be lost. Fix ~/.claude.json, then re-run."
  exit 1
fi

# --- (finding #8) require a valid captured preimage when there IS an outgoing
#     account. A transient empty keychain read must NOT let us proceed into the
#     commit with no rollback material. ---
precompact=""
if [ -n "$raw_current" ]; then
  precompact="$(printf '%s' "$raw_current" | compact_blob 2>/dev/null)" || precompact=""
fi
if [ -n "$current" ]; then
  if [ -z "$precompact" ] || ! printf '%s' "$precompact" | python3 "$HERE/validate_blob.py" >/dev/null 2>&1; then
    err "Aborting swap: could not capture a valid live credential for the outgoing account"
    err "'$current' (transient keychain read failure). No change made; re-run swap."
    exit 1
  fi
fi

# --- (finding #7) re-bank the outgoing account BEFORE any keychain mutation and
#     REQUIRE it to succeed: if its creds rotated and the bank write fails, we
#     must NOT park it with a spent refresh token. Abort instead. ---
if [ -n "$current" ]; then
  cf="$(bank_file_for "$current")" || { err "swap: outgoing email '$current' is unsafe; aborting."; exit 1; }
  # FORCE_REBANK: writing verified-live outgoing creds; recover over a corrupt
  # existing record so a swap-AWAY is never blocked by outgoing-record corruption.
  if ! printf '%s' "$raw_current" | ACCOUNT_BANK_FORCE_REBANK=1 ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/write_bank_record.py" \
        "$CLAUDE_JSON" "$current" "$cf" "$(now_iso)" "$(now_epoch)"; then
    err "Aborting swap: failed to re-bank the outgoing account '$current' (its freshest"
    err "tokens could not be saved). No keychain change made."
    exit 1
  fi
  echo "Re-banked current active account: $current (freshest tokens saved)"
fi

# === COMMIT SECTION (findings #7-#13) =======================================
# The keychain write and the ~/.claude.json metadata write must land together or
# not at all. Protections:
#   (a) A phase journal (pre-swap blob + BOTH credential fingerprints, 0600) is
#       written BEFORE the keychain write and cleared AFTER the metadata commit
#       AND its post-verify. reconcile.py resolves it if we die in between.
#   (b) We defer INT/TERM/HUP/PIPE across the commit so account-warn.sh's timeout
#       SIGTERM cannot tear it. The commit is sub-second; the signal is deferred;
#       the EXIT trap still releases the lock. A hard SIGKILL is survivable
#       because (a) makes the torn state self-healing.
#   (c) kc_write's return-code contract (0 verified / 10 definitely-unchanged / 11
#       rotated-under-us-unchanged (r4 #2) /
#       1 indeterminate) plus a post-commit fingerprint verify make "reported
#       success" mean the credential VERIFIABLY landed (findings #10/#12).
trap '' INT TERM HUP PIPE            # (b) defer signals across the commit
_restore_trap() { trap 'release_lock; exit 130' INT TERM HUP PIPE; }

# --- (finding #11 + r3 #4) rotation guard: re-read the live keychain immediately
#     before replacement. If the outgoing token rotated under us (external live
#     session), re-bank the FRESH creds and abort rather than parking a spent
#     token. This is the BEFORE half of the "re-verify immediately before AND after
#     the mutating write" requirement (r3 #4); the AFTER half re-banks the outgoing
#     from kc_write's own pre-overwrite snapshot once the write lands.
#
#     RESIDUAL WINDOW (documented honestly, r3 #4 + r4 #2 + r5 #1): perfect
#     atomicity between this re-read and an external `/login` that rotates the
#     outgoing token is impossible from shell. A rotation that lands AFTER this
#     guard's read but BEFORE kc_write snapshots the item is captured — kc_write
#     snapshots the EXACT bytes it is about to overwrite into $SNAP_DIR (never
#     deleted here), archives them to $BANK_DIR/archive/, and exposes the snapshot as
#     $KC_LAST_SNAPSHOT, and we re-bank the outgoing from THAT below. A rotation
#     landing between kc_write's snapshot read and its FINAL pre-write re-read is
#     also caught: that re-read compares the live item against the snapshot and, on
#     mismatch OR an empty/unreadable re-read (r5 #1 — no longer a fail-open bypass),
#     REFUSES the write (rc 11, keychain unchanged); we then re-bank the true-latest
#     outgoing credential and abort (see the rc 11 branch below).
#     The irreducible residual is a rotation landing between kc_write's FINAL re-read
#     and the actual `security -i` write syscall. That window is NOT "a few
#     microseconds": between them kc_write spawns two `python3 bank_common.py
#     --fingerprint` subprocesses (recheck_fp, cur_fp), resolves the `security`
#     binary, and sets up monitor-mode job control + a watchdog subshell before the
#     write launches — realistically tens to low hundreds of milliseconds. A /login
#     that rotates the outgoing token inside THAT window is the one case the snapshot
#     holds the SPENT predecessor and the fresh token is lost from the bank; the
#     phase journal is retained until the post-write verify passes so reconcile can
#     still resolve any torn keychain state. This window cannot be closed from shell.
if [ -n "$current" ]; then
  raw_now="$(cred_read)"
  now_fp="$(printf '%s' "$raw_now" | _cred_fp)"
  pre_fp="$(printf '%s' "$precompact" | _cred_fp)"
  if [ -z "$now_fp" ]; then
    _restore_trap
    err "Aborting swap: live keychain unreadable at commit (transient). No change made."
    exit 1
  fi
  if [ "$now_fp" != "$pre_fp" ]; then
    cf="$(bank_file_for "$current")" || cf=""
    [ -n "$cf" ] && printf '%s' "$raw_now" | ACCOUNT_BANK_FORCE_REBANK=1 ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/write_bank_record.py" \
      "$CLAUDE_JSON" "$current" "$cf" "$(now_iso)" "$(now_epoch)" || true
    _restore_trap
    err "Aborting swap: the outgoing account '$current' rotated its credentials during the"
    err "swap. Re-banked the fresh tokens; no keychain change made. Please re-run the swap."
    exit 1
  fi
fi

# --- (r6 b10) epoch gate the WHOLE commit — journal + keychain write are ONE v1 mutation.
# The phase journal is written BEFORE kc_write, so it must pass the SAME v1-gate +
# generation fence (kc_write's `epoch_guard`) or an in-flight swap that slept across a
# flip/freeze would durably journal under a stale epoch. rc 78 = fenced, NOTHING mutated.
if ! epoch_guard; then
  _restore_trap
  err "Aborting swap: epoch gate refused the mutation (rc 78; no change made). Re-run after the flip/seed settles."
  exit 78
fi

# --- (finding #9) the phase journal is a MANDATORY precondition for kc_write ---
if [ -n "$precompact" ]; then
  if ! printf '%s' "$precompact" | write_swap_journal "$target" "$current" "$target_fp"; then
    _restore_trap
    err "Aborting swap: could not durably journal the pre-swap credential. No change made."
    exit 1
  fi
fi

# --- (finding #10) write target creds; branch on the kc_write return contract ---
# (r4 #1) PROCESS SUBSTITUTION, not a pipe: kc_write must run in THIS shell so its
# KC_LAST_SNAPSHOT assignment reaches the outgoing re-bank block below. Piping ran
# kc_write in a subshell, so KC_LAST_SNAPSHOT was always empty here and that block
# was dead. (We also read KC_LAST_SNAPSHOT_FILE as a belt-and-suspenders fallback.)
kc_write < <(printf '%s' "$target_blob"); krc=$?
if [ "$krc" -eq 11 ]; then
  # (r4 #2) the outgoing credential rotated between kc_write's snapshot and its write;
  # kc_write refused the overwrite (keychain UNCHANGED) and refreshed KC_LAST_SNAPSHOT
  # to the newest live bytes. Re-bank the true-latest outgoing creds and abort so the
  # user re-runs; never park a spent token.
  _kc_snap="${KC_LAST_SNAPSHOT:-}"
  [ -z "$_kc_snap" ] && [ -s "$KC_LAST_SNAPSHOT_FILE" ] && _kc_snap="$(cat "$KC_LAST_SNAPSHOT_FILE")"
  if [ -n "$current" ] && [ -n "$_kc_snap" ] && [ -s "$_kc_snap" ]; then
    cf="$(bank_file_for "$current")" || cf=""
    if [ -n "$cf" ]; then
      snap_compact="$(compact_blob < "$_kc_snap" 2>/dev/null)" || snap_compact=""
      if [ -n "$snap_compact" ] && printf '%s' "$snap_compact" | python3 "$HERE/validate_blob.py" >/dev/null 2>&1; then
        printf '%s' "$snap_compact" | ACCOUNT_BANK_FORCE_REBANK=1 ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/write_bank_record.py" \
          "$CLAUDE_JSON" "$current" "$cf" "$(now_iso)" "$(now_epoch)" >/dev/null 2>&1 || true
      fi
    fi
  fi
  clear_swap_journal                 # keychain DEFINITELY unchanged (nothing written)
  _restore_trap
  err "Aborting swap: the outgoing account rotated its credentials at the instant of the"
  err "write. Re-banked the fresh tokens; keychain unchanged. Please re-run the swap."
  exit 1
elif [ "$krc" -eq 10 ]; then
  clear_swap_journal                 # pre-write failure: keychain DEFINITELY unchanged
  _restore_trap
  err "FAILED to write target credentials to keychain (pre-write check). Keychain unchanged."
  exit 1
elif [ "$krc" -ne 0 ]; then
  # INDETERMINATE (timeout, or verify mismatch): the write may or may not have
  # landed. KEEP the journal — reconcile.py resolves it on the next locked op by
  # comparing fingerprints. Never assume "unchanged" (finding #10).
  _restore_trap
  err "Keychain write INDETERMINATE (kc_write rc $krc). Journal RETAINED for reconcile."
  err "Run: bash $HERE/list-accounts.sh to confirm state; reconcile runs on the next op."
  exit 1
fi

# --- (r3 #4) AFTER the write: re-bank the outgoing account from kc_write's OWN
#     pre-overwrite snapshot ($KC_LAST_SNAPSHOT), the exact credential bytes present
#     at the instant of replacement. If the outgoing token rotated in the tiny
#     window after the rotation guard's read, the earlier re-bank stored the older
#     credential; this corrects it to the true latest, so we never park a spent
#     token. Best-effort (FORCE_REBANK over the verified-live snapshot); a failure
#     here does not tear the swap (the snapshot itself remains for recovery). ---
# (r4 #1) prefer the variable (set because kc_write ran in this shell via process
# substitution); fall back to the path file kc_write also wrote, in case a future
# caller pipes into kc_write.
_kc_snap="${KC_LAST_SNAPSHOT:-}"
[ -z "$_kc_snap" ] && [ -s "$KC_LAST_SNAPSHOT_FILE" ] && _kc_snap="$(cat "$KC_LAST_SNAPSHOT_FILE")"
if [ -n "$current" ] && [ -n "$_kc_snap" ] && [ -s "$_kc_snap" ]; then
  cf="$(bank_file_for "$current")" || cf=""
  if [ -n "$cf" ]; then
    snap_compact="$(compact_blob < "$_kc_snap" 2>/dev/null)" || snap_compact=""
    if [ -n "$snap_compact" ] && printf '%s' "$snap_compact" | python3 "$HERE/validate_blob.py" >/dev/null 2>&1; then
      printf '%s' "$snap_compact" | ACCOUNT_BANK_FORCE_REBANK=1 ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/write_bank_record.py" \
        "$CLAUDE_JSON" "$current" "$cf" "$(now_iso)" "$(now_epoch)" >/dev/null 2>&1 \
        || err "swap: note — outgoing '$current' re-bank from the overwrite snapshot did not"$'\n'"  complete; the snapshot is kept in $SNAP_DIR for recovery."
    fi
  fi
fi

# kc_write VERIFIED the target credential is live. --- (7) update ~/.claude.json ---
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
    f.flush(); os.fsync(f.fileno())
os.replace(tmp, claude_json)
# (r15 #2) fsync the PARENT so the rename itself is durable, not just the file's bytes.
# This rename is step 2 of a 3-step transaction (keychain write -> metadata rename ->
# journal clear) and it is the only step that was not synced: a power loss could keep
# steps 1 and 3 while losing this one, leaving the target's credential paired with the
# outgoing account's metadata and NO journal to recover from. Same discipline as
# repoint.py's pointer transaction and lib.sh write_swap_journal.
dfd = os.open(dirn, os.O_RDONLY)
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
PY
  err "Metadata update FAILED. Considering keychain rollback to the pre-swap account…"
  if [ -n "$precompact" ]; then
    # (re-review issue 8) rollback PRECONDITION: the live keychain must STILL hold
    # exactly the target creds we just installed (stable double-read). If a
    # concurrent /login replaced them (C), rolling back to the pre-swap blob would
    # clobber that newer login — keep the journal for reconcile instead.
    rb1="$(active_cred_fp)"; rb2="$(active_cred_fp)"
    if [ -n "$rb1" ] && [ "$rb1" = "$rb2" ] && [ "$rb1" = "$target_fp" ]; then
      printf '%s' "$precompact" | kc_write; rrc=$?
      if [ "$rrc" -eq 0 ]; then
        clear_swap_journal   # keychain and metadata both back to pre-swap: consistent
        err "Rollback complete: keychain restored to $current. No change applied."
      else
        err "ROLLBACK INDETERMINATE/FAILED (kc_write rc $rrc). Journal kept for reconcile."
      fi
    else
      err "Rollback SKIPPED: the live keychain changed since our write (a concurrent"
      err "/login may have intervened). Journal RETAINED for reconcile; not clobbering."
    fi
  else
    err "No pre-swap blob captured; latest snapshot is in $SNAP_DIR."
  fi
  _restore_trap
  exit 1
fi

# --- (finding #12) post-commit verify: BOTH stores must now name the target.
#     A concurrent /login could have overwritten the keychain (C) between our
#     verified kc_write and here. Re-derive and compare; retain the journal on any
#     mismatch so reconcile can resolve it. ---
post_fp="$(active_cred_fp)"
post_email="$(active_email)"
if [ "$post_fp" != "$target_fp" ] || [ "$post_email" != "$target" ]; then
  _restore_trap
  err "Post-commit verify FAILED: keychain/metadata do not both name $target"
  err "(a concurrent /login may have intervened). Journal RETAINED for reconcile;"
  err "run list-accounts.sh to inspect. The next locked op will reconcile."
  exit 1
fi

# both stores verified at the target: the swap committed cleanly.
# (v101-confirm) The journal clear is CHECKED here. Its failure is not a swap failure — the
# credential commit already landed and is verified — but it is not success either: a
# secret-bearing recovery journal is still on disk (or its removal is not durable), and the
# next mutator will refuse to run until reconcile clears it. Report the swap, then exit 6 so
# no caller can read a clean 0 for a state that still needs attention.
_journal_clear_rc=0
clear_swap_journal || _journal_clear_rc=$?
_restore_trap
# === END COMMIT SECTION =====================================================

# --- report ---
sub="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("claudeAiOauth") or {}).get("subscriptionType","?"))' "$tf")"
banked_at="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("banked_at","?"))' "$tf")"
echo ""
echo "Active account is now: $target  (subscription: $sub)"
echo "  banked_at: $banked_at"

# (re-review issue 14) report only a COUNT + bare PIDs of running claude processes,
# never their full command lines (argv can contain prompt text / paths). pgrep
# emits PIDs only; we never print the matched command lines.
pids="$(pgrep -f claude 2>/dev/null | grep -vx "$$" | sort -un || true)"
n="$(printf '%s\n' "$pids" | grep -c . || true)"
if [ "${n:-0}" -gt 0 ]; then
  echo ""
  echo "NOTE: $n running Claude-related process(es) switch to $target on their next"
  echo "  request (turn-level pickup). No /login needed; UIs may still DISPLAY the old"
  echo "  account (cosmetic). PIDs: $(printf '%s ' $pids)"
fi

# (v101-confirm) COMMIT LANDED, CLEANUP FAILED — a distinct outcome, never a silent 0.
if [ "$_journal_clear_rc" -ne 0 ]; then
  err ""
  err "WARNING: the swap to $target COMMITTED, but its recovery journal could not be cleared"
  err "cleanly (clear_swap_journal rc $_journal_clear_rc). The journal is secret-bearing and, while it"
  err "remains, the next locked operation reconciles (and may block) on it. Run reconcile.py,"
  err "or inspect $SWAP_JOURNAL. The account switch itself is verified and in effect."
  exit 6
fi
