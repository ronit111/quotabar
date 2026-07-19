#!/usr/bin/env bash
# lib.sh — shared helpers for the Claude multi-account bank / swap system.
#
# SAFETY CONTRACT (see README.md; hardened per cross-vendor review 2026-07-19):
#   - Keychain writes go through kc_write: exact-match only, snapshot-first
#     (fail-closed), secret via STDIN not argv, bounded by a timeout, and refuse
#     to CREATE an item unless ACCOUNT_BANK_BOOTSTRAP=1.
#   - All file writes are atomic: mktemp(0600) in the same dir, then rename.
#   - Locks are token-owned: release verifies ownership; stale reclaim only if
#     lock age > 5 min AND holder pid dead, via rename-away-then-verify.
#   - Secrets never enter argv and are never echoed.
#
# Sourced file. Does not set `set -e` (callers pick their own posture).

# --- constants ---------------------------------------------------------------
KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-$(id -un)}"   # macOS username; matches Claude Code's item
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
# The "bank" — where QuotaBar stores its own per-account records, snapshots, lock
# and cache. Independent of Claude Code's own config dir; override with BANK_DIR.
BANK_DIR="${BANK_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/quotabar}"
SNAP_DIR="$BANK_DIR/.keychain-snapshots"
LOCK_DIR="$BANK_DIR/.lock"
CACHE_FILE="$BANK_DIR/.usage-cache.json"
_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KC_TIMEOUT="${ACCOUNT_BANK_KC_TIMEOUT:-8}"
LOCK_STALE_SECS=300   # 5 min

LOCK_TOKEN=""         # set by acquire_lock; verified by release_lock

# --- fs setup ----------------------------------------------------------------
ensure_bank() {
  mkdir -p "$BANK_DIR" "$SNAP_DIR" 2>/dev/null || true
  chmod 700 "$BANK_DIR" 2>/dev/null || true
  chmod 700 "$SNAP_DIR" 2>/dev/null || true
}

now_epoch() { date +%s; }
now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
err() { printf '%s\n' "$*" >&2; }

# mtime of a path in epoch seconds (macOS stat)
_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# atomic_write <dest>  — content on STDIN -> mktemp(0600) in dest's dir -> rename.
atomic_write() {
  local dest="$1" dir tmp
  dir="$(dirname "$dest")"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || { err "atomic_write: mktemp failed in $dir"; return 1; }
  chmod 600 "$tmp" 2>/dev/null
  if cat > "$tmp"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"; return 1
  fi
}

# run_with_timeout <secs> <cmd...> — portable timeout (macOS lacks `timeout`).
# Cleanup uses SIGKILL, never SIGTERM: a caller may be ignoring TERM across a
# commit (swap-account.sh `trap '' TERM`), and `trap ''` is inherited as SIG_IGN
# by children — so a TERM sent to the watchdog (or to a genuinely-hung cmd) is
# silently dropped, making the cleanup `wait` block for the full `secs`. KILL
# cannot be ignored, so it works regardless of the caller's trap disposition.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local cpid=$!
  # Detach watchdog fds so, inside $(...), it can't hold the capture pipe open
  # for the full `secs` after the command exits early. On a real timeout,
  # escalate TERM->KILL so a cmd that inherited SIG_IGN(TERM) still dies.
  ( sleep "$secs"; kill -TERM "$cpid" 2>/dev/null; sleep 0.3; kill -KILL "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
  local wpid=$!
  local rc=0
  wait "$cpid" 2>/dev/null; rc=$?
  kill -KILL "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; } && rc=124
  return $rc
}

# --- locking (token-owned mkdir lock) ---------------------------------------
# acquire_lock [wait_secs] -> 0 on success (sets LOCK_TOKEN), 1 on failure.
acquire_lock() {
  ensure_bank
  # wait budget: explicit arg > ACCOUNT_BANK_LOCK_WAIT env > 12s default.
  local waitmax="${1:-${ACCOUNT_BANK_LOCK_WAIT:-12}}" waited=0 tok
  tok="$$-$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$tok" ] || tok="$$-$RANDOM$RANDOM"
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # write owner atomically: "pid token". If the owner write fails we have a
      # lock dir with no ownership record — normal release (token match) could
      # never remove it, so it would sit until the 5-min stale reclaim. Undo the
      # mkdir and report failure instead (finding #17).
      if printf '%s %s\n' "$$" "$tok" | atomic_write "$LOCK_DIR/owner"; then
        LOCK_TOKEN="$tok"
        return 0
      fi
      rm -rf "$LOCK_DIR" 2>/dev/null
      err "account-bank: acquired lock dir but failed to write owner token; released and aborting."
      return 1
    fi
    # contended: consider stale reclaim
    local age owner opid
    age=$(( $(now_epoch) - $(_mtime "$LOCK_DIR") ))
    opid=""
    [ -f "$LOCK_DIR/owner" ] && opid="$(cut -d' ' -f1 "$LOCK_DIR/owner" 2>/dev/null)"
    local dead=1
    [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && dead=0
    if [ "$age" -gt "$LOCK_STALE_SECS" ] && [ "$dead" -eq 1 ]; then
      # rename-away-then-verify: only one contender wins the atomic rename
      local stolen="$LOCK_DIR.stale.$$.$RANDOM"
      if mv "$LOCK_DIR" "$stolen" 2>/dev/null; then
        rm -rf "$stolen" 2>/dev/null
        continue   # retry mkdir
      fi
    fi
    waited=$((waited + 1))
    if [ "$waited" -ge "$waitmax" ]; then
      err "account-bank: could not acquire lock after ${waitmax}s (held by pid ${opid:-?})"
      return 1
    fi
    sleep 1
  done
}

# release_lock -> only removes the lock if WE own it (token match).
release_lock() {
  [ -n "$LOCK_TOKEN" ] || return 0
  local cur
  cur="$(cut -d' ' -f2 "$LOCK_DIR/owner" 2>/dev/null)"
  if [ "$cur" = "$LOCK_TOKEN" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
    LOCK_TOKEN=""
  fi
  return 0
}

# --- keychain ----------------------------------------------------------------
# kc_read -> prints the raw stored secret. EXACT service+account match only
# (no service-only fallback). Bounded, stdin closed. Empty output => absent/fail.
# A fresh `security` process occasionally returns empty on the first hit (ACL
# re-eval); retry a couple of times so a present item is not misread as absent.
kc_read() {
  local out i
  for i in 1 2 3; do
    out="$(run_with_timeout "$KC_TIMEOUT" \
      security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w </dev/null 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    sleep 0.3
  done
  return 1
}
# back-compat alias used by older call sites
read_keychain_raw() { kc_read; }

# snapshot_keychain -> atomically write the current keychain blob to
# $SNAP_DIR/<epoch>-<pid>.json (0600). Prints the path. Fails if item absent.
snapshot_keychain() {
  ensure_bank
  local raw path
  raw="$(kc_read)"
  [ -n "$raw" ] || { err "account-bank: no exact keychain item to snapshot"; return 1; }
  path="$SNAP_DIR/$(now_epoch)-$$.json"
  printf '%s' "$raw" | atomic_write "$path" || return 1
  ls -1t "$SNAP_DIR"/*.json 2>/dev/null | tail -n +21 | while read -r old; do rm -f "$old"; done
  printf '%s\n' "$path"
}

# kc_write  — new secret blob on STDIN. Validates schema (stdin), fail-closed
# snapshot of the current item, then update-in-place via `security -i` (secret
# travels through security's stdin, never argv). Refuses to CREATE an item
# unless ACCOUNT_BANK_BOOTSTRAP=1. Bounded by KC_TIMEOUT.
kc_write() {
  ensure_bank
  local blob; blob="$(cat)"
  [ -n "$blob" ] || { err "kc_write: empty blob"; return 1; }
  # schema validation — blob via stdin, never argv
  if ! printf '%s' "$blob" | python3 "$_LIB_HERE/validate_blob.py"; then
    err "kc_write: blob failed validation; NOT writing"; return 1
  fi
  # fail-closed: the exact item must already exist unless bootstrapping
  local cur; cur="$(kc_read)"
  if [ -z "$cur" ]; then
    if [ "${ACCOUNT_BANK_BOOTSTRAP:-0}" != "1" ]; then
      err "kc_write: no existing keychain item for $KEYCHAIN_SERVICE/$KEYCHAIN_ACCOUNT."
      err "          Refusing to create it. Re-run with ACCOUNT_BANK_BOOTSTRAP=1 to bootstrap."
      return 1
    fi
  else
    # snapshot the blob we just read (no second keychain hit); abort on failure
    ensure_bank
    local snap="$SNAP_DIR/$(now_epoch)-$$.json"
    if ! printf '%s' "$cur" | atomic_write "$snap"; then
      err "kc_write: could not snapshot the live item; aborting write (fail-closed)."
      return 1
    fi
    ls -1t "$SNAP_DIR"/*.json 2>/dev/null | tail -n +21 | while read -r old; do rm -f "$old"; done
  fi
  # write, bounded. printf is a shell builtin -> the secret is not in any argv.
  # Service/account are double-quoted (service contains a space; security -i
  # splits its command line on whitespace and honors double-quotes). The blob is
  # left unquoted: it is compact (validated: no whitespace) and starts with '{',
  # so security -i takes the whole run as one literal token.
  ( printf 'add-generic-password -U -s "%s" -a "%s" -w %s\n' \
      "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" "$blob" | security -i ) &
  local p=$!
  # Cleanup via SIGKILL, not SIGTERM: swap-account.sh ignores TERM across the
  # commit and `trap ''` is inherited as SIG_IGN by these children, so a TERM to
  # the watchdog would be dropped and the cleanup `wait` would block the full
  # KC_TIMEOUT. KILL is unignorable. Escalate the real-timeout kill too.
  ( sleep "$KC_TIMEOUT"; kill -TERM "$p" 2>/dev/null; sleep 0.3; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  local w=$!
  local rc=0
  wait "$p" 2>/dev/null; rc=$?
  kill -KILL "$w" 2>/dev/null; wait "$w" 2>/dev/null
  { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; } && rc=124
  return $rc
}

# compact_blob — read JSON on stdin, print compact (space-free) JSON on stdout.
# Used to normalize a blob before kc_write (security -i tokenizes on whitespace).
compact_blob() {
  python3 -c 'import sys,json; sys.stdout.write(json.dumps(json.load(sys.stdin), separators=(",",":")))'
}

# --- claude.json -------------------------------------------------------------
active_email() {
  python3 - "$CLAUDE_JSON" <<'PY' 2>/dev/null
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    v = (d.get("oauthAccount") or {}).get("emailAddress", "")
    print(v if isinstance(v, str) else "")
except Exception:
    pass
PY
}

# --- swap phase journal (finding #1) -----------------------------------------
# A swap writes this 0600 file (pre-swap keychain blob + the from/to emails)
# BEFORE the keychain write, and clears it AFTER the metadata commit. If a swap
# is interrupted between the keychain write and the metadata commit (external
# SIGKILL, crash), reconcile.py finds the journal on the next locked op and rolls
# the keychain back to the pre-swap blob so keychain and ~/.claude.json can never
# be left disagreeing. The pre-swap blob is a secret, so it arrives on STDIN.
SWAP_JOURNAL="$BANK_DIR/.swap-journal.json"

# write_swap_journal <target> <current>  — compact pre-swap blob on STDIN.
# The program is passed via -c (NOT a heredoc on stdin) so STDIN stays free to
# carry the secret blob; the blob never enters argv.
write_swap_journal() {
  ensure_bank
  python3 -c '
import sys, json, os, tempfile, time
path, target, current = sys.argv[1], sys.argv[2], sys.argv[3]
blob = sys.stdin.read()
obj = {"type": "swap", "pre_swap_blob": blob,
       "target": target, "current": current, "ts": time.time()}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".swapj.")
with os.fdopen(fd, "w") as f:
    json.dump(obj, f)
os.chmod(tmp, 0o600); os.replace(tmp, path)
' "$SWAP_JOURNAL" "$1" "$2"
}

clear_swap_journal() { rm -f "$SWAP_JOURNAL" 2>/dev/null; }

# --- bank files --------------------------------------------------------------
bank_file_for() { printf '%s/%s.json' "$BANK_DIR" "$1"; }

list_bank_emails() {
  ensure_bank
  for f in "$BANK_DIR"/*.json; do
    [ -e "$f" ] || continue
    basename "$f" .json
  done
}

# --- config (.config.json) ---------------------------------------------------
# drop_from_autoping <email> — remove <email> from the auto_ping list in
# .config.json, atomically (0600), fail-soft on a malformed config. Prints "1" if
# an entry was removed, "0" otherwise. Mirrors toggle-autoping.sh's write path.
# Never creates the file when it is absent and the email is not present (nothing
# to do) — a missing config just means the feature is off.
drop_from_autoping() {
  ensure_bank
  local email="$1" config="$BANK_DIR/.config.json"
  python3 - "$config" "$email" <<'PY'
import sys, json, os, tempfile
config, email = sys.argv[1], sys.argv[2]
try:
    c = json.load(open(config))
    if not isinstance(c, dict):
        c = {}
except Exception:
    c = {}
ap = c.get("auto_ping")
ap = [e for e in ap if isinstance(e, str)] if isinstance(ap, list) else []
if email not in ap:
    print("0")
    sys.exit(0)
c["auto_ping"] = [e for e in ap if e != email]
dirn = os.path.dirname(config) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".config.")
with os.fdopen(fd, "w") as f:
    json.dump(c, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, config)
print("1")
PY
}
