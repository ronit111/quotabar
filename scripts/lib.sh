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
# (r13 #11) single resolution order shared with swiftbar-render.py: BANK_DIR (test/explicit)
# first, then ACCOUNT_BANK_DIR (the v2 convention the shim/claude-acct/hooks use), then the
# shared default ~/.claude/accounts. Every tool must read the SAME .config.json the scripts mutate.
BANK_DIR="${BANK_DIR:-${ACCOUNT_BANK_DIR:-$HOME/.claude/accounts}}"
SNAP_DIR="$BANK_DIR/.keychain-snapshots"
LOCK_DIR="$BANK_DIR/.lock"
RECLAIM_DIR="$BANK_DIR/.lock.reclaim"   # reclaim mutex (re-review issue 1)
CACHE_FILE="$BANK_DIR/.usage-cache.json"
_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# (r12 sweep-c) shared alt-auth env strip list + helpers for Claude-turn launchers.
[ -f "$_LIB_HERE/_authenv.sh" ] && . "$_LIB_HERE/_authenv.sh"

KC_TIMEOUT="${ACCOUNT_BANK_KC_TIMEOUT:-8}"
LOCK_STALE_SECS=300   # 5 min
# (r3 #16) reclaim mutex is held only microseconds; anything older is abandoned.
RECLAIM_STALE_SECS=30

# claude_bin — absolute path to the claude CLI, or nonzero return when unresolved.
# When usage.py/ping run from a GUI app (QuotaBar, LSUIElement) the PATH is minimal
# and bare `claude` is NOT found (rc 127) — which silently broke auto-ping and
# token-refresh once SwiftBar (shell PATH) was retired. This is the ONE resolver
# contract, mirrored by isolated_refresh.py resolve_claude_bin (findings #3/#4/#5):
#   - honor ACCOUNT_BANK_CLAUDE_BIN, but only if it is an actually-executable file;
#   - else `command -v`, then the known install locations;
#   - every candidate must be a real, executable regular file: `-f` rejects the
#     alias/function/builtin descriptions `command -v` can print (finding #5), and
#     `-x` rejects a non-executable match;
#   - NO login-shell fallback: `sh -lc` runs synchronously after lock acquisition
#     and a slow login profile could block the bank lock unboundedly (finding #4),
#     and its stdout can be contaminated by profile chatter (finding #5).
#     ~/.local/bin + homebrew cover this machine.
# Returns 1 (empty stdout) when unresolved; callers MUST treat that as a TRANSIENT
# failure (retry), never a dead token.
claude_bin() {
  local override="${ACCOUNT_BANK_CLAUDE_BIN:-}"
  if [ -n "$override" ]; then
    if [ -f "$override" ] && [ -x "$override" ]; then printf '%s\n' "$override"; return 0; fi
    return 1
  fi
  local c
  c="$(command -v claude 2>/dev/null)"
  if [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
  for cand in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -f "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# security_bin — absolute path to the macOS `security` CLI (finding #36: never a
# bare name on PATH). Honors ACCOUNT_BANK_SECURITY_BIN (an executable file) so
# tests can point it at a stub; otherwise the fixed system path, then PATH.
security_bin() {
  local override="${ACCOUNT_BANK_SECURITY_BIN:-}"
  if [ -n "$override" ]; then
    if [ -f "$override" ] && [ -x "$override" ]; then printf '%s\n' "$override"; return 0; fi
    return 1
  fi
  if [ -x /usr/bin/security ]; then printf '%s\n' /usr/bin/security; return 0; fi
  # (r14 #2) NO PATH fallback for a credential-bearing tool — a `security` proxy on PATH
  # could exfiltrate the OAuth blob. If the absolute binary is gone, fail.
  return 1
}

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

# _fsync_dir <dir> — fsync a DIRECTORY so a rename/unlink that happened inside it is
# durable (r15 #2). On macOS a file's own fsync does not make its DIRECTORY ENTRY
# durable: after a power loss the rename or unlink can be lost while later steps of the
# same transaction survive, which is exactly how a swap can end up with the target's
# keychain credential paired with the outgoing account's metadata and no journal left to
# recover from. Any multi-step transaction whose ORDER matters syncs the parent after each
# step — the discipline repoint.py applies to the pointer transaction (its _fsync_dir) and
# write_swap_journal already applies when creating the journal.
# Best-effort by design: a directory we cannot even open is not grounds to fail a mutation
# that already completed. Callers that need the ordering enforced check the step itself.
_fsync_dir() {
  python3 -c 'import os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY)
except OSError:
    sys.exit(0)
try:
    os.fsync(fd)
finally:
    os.close(fd)' "$1" 2>/dev/null || true
}

# _fsync_dir_checked <dir> — the same directory sync, but REPORTED (v101-confirm). Nonzero
# when the directory could not be opened or the fsync failed. Use this wherever the sync is
# part of the transaction's correctness (the swap journal's removal) rather than a best-effort
# tightening; silently succeeding there is what let "the journal is durably gone" be claimed
# on evidence nobody ever checked.
_fsync_dir_checked() {
  python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)' "$1" 2>/dev/null
}

# run_with_timeout <secs> <cmd...> — portable timeout (macOS lacks `timeout`).
#
# PROCESS-GROUP kill (findings #2/#22): we enable monitor mode (`set -m`) just
# for the launch so the command becomes the leader of its OWN process group,
# then the watchdog signals the WHOLE group (`kill -TERM -PGID`). A naive
# `kill $cpid` left descendants (a `claude` turn's node children, a `security`
# helper) running after the reported timeout — still holding resources or, worse,
# still able to rotate credentials. Killing the group reaps them together.
#
# Cleanup escalates SIGTERM->SIGKILL: a caller may ignore TERM across a commit
# (swap-account.sh `trap '' TERM`) and `trap ''` is inherited as SIG_IGN by
# children, so a lone TERM can be dropped and make the cleanup `wait` block the
# full `secs`. KILL cannot be ignored. `set -m`'s job-control notices go to
# stderr, so `$(...)` stdout capture stays clean (verified 2026-07-21).
run_with_timeout() {
  local secs="$1"; shift
  local had_m=0; case "$-" in *m*) had_m=1;; esac
  set -m
  "$@" &
  local cpid=$!
  [ "$had_m" -eq 0 ] && set +m
  # Detach watchdog fds so, inside $(...), it can't hold the capture pipe open
  # for the full `secs` after the command exits early. Signal the whole group
  # (negative pid); fall back to the bare pid if the group send fails.
  ( sleep "$secs"
    kill -TERM -"$cpid" 2>/dev/null || kill -TERM "$cpid" 2>/dev/null
    sleep 0.3
    kill -KILL -"$cpid" 2>/dev/null || kill -KILL "$cpid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local wpid=$!
  local rc=0
  wait "$cpid" 2>/dev/null; rc=$?
  kill -KILL "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; } && rc=124
  return $rc
}

# --- locking (token-owned mkdir lock) ---------------------------------------
# acquire_lock [wait_secs] -> 0 on success (sets LOCK_TOKEN), 1 on failure.
# _proc_starttime <pid> — a stable-ish per-process start-time token (macOS ps
# lstart), used to detect PID REUSE (finding #3): a dead holder's PID recycled by
# an unrelated long-lived process would otherwise read as "alive" forever. Empty
# when the pid is gone or ps fails.
_proc_starttime() {
  # (r6 b4) empty for a gone pid, a ps failure, OR a ZOMBIE (ps stat starts 'Z'). A
  # zombie still reports lstart but is DEAD for every purpose we have, so it must NOT read
  # as a live matching start-time. Mirrors banklock._proc_starttime / sessions._proc_start.
  local line stat
  line="$(ps -o stat=,lstart= -p "$1" 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086
  set -- $line
  stat="$1"
  case "$stat" in Z*) return 0 ;; esac
  shift
  printf '%s' "$*" | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

# _lock_stale_and_dead — 0 (true) iff LOCK_DIR is older than the stale window AND
# its recorded holder is provably gone (missing/dead pid, or a reused pid whose
# start-time differs). Used both for the cheap pre-check and the re-verify under
# the reclaim mutex (re-review issue 1).
#
# (r3 #1) POSITIVE-DEATH ONLY. Anything we cannot positively prove is death — a
# missing/unreadable owner record, a live pid whose start-time `ps` won't report,
# a pid that is not signalable but still exists (EPERM / another uid) — is UNKNOWN,
# and an UNKNOWN holder is NEVER reclaimed. Only a provably-gone pid, or a proven
# pid-reuse (recorded start-time != live start-time), makes a lock reclaimable.
# Presuming death on a probe failure could evict a LIVE holder and let two
# processes mutate credential state at once.
# (r5 item 6) _owner_provably_dead <owner_file> <start_field> — 0 (dead) iff the owner
# record is READABLE and its holder is PROVABLY gone: the pid does not exist (ESRCH via
# kill -0 AND `ps -p` both fail), or the pid is alive but a recorded start-time proves
# PID reuse. An unreadable/ownerless record, a missing start-time, a `ps` that cannot
# report a start-time, or an EPERM/unknown probe ALL yield 1 (UNKNOWN -> NEVER reclaimed).
# <start_field> is the 1-indexed `cut` field where the multi-word start-time begins
# (3 for the "pid token start" format shared by the main lock AND the reclaim mutex).
_owner_provably_dead() {
  local of="$1" sf="$2" opid ostart livestart
  [ -f "$of" ] || return 1
  opid="$(cut -d' ' -f1 "$of" 2>/dev/null)"
  ostart="$(cut -d' ' -f"${sf}"- "$of" 2>/dev/null)"
  [ -n "$opid" ] || return 1
  case "$opid" in *[!0-9]*) return 1;; esac
  if kill -0 "$opid" 2>/dev/null; then
    [ -n "$ostart" ] || return 1                # alive, no recorded start -> can't prove
    livestart="$(_proc_starttime "$opid")"
    if [ -z "$livestart" ]; then
      # (r6 b4) kill -0 says the pid exists but no live start-time: distinguish a ZOMBIE
      # (dead — reap it) from a transient ps failure (UNKNOWN — never reclaim).
      case "$(ps -o stat= -p "$opid" 2>/dev/null | tr -d ' ')" in
        Z*) return 0 ;;                          # zombie -> provably dead
        *)  return 1 ;;                          # ps failure / unreadable -> UNKNOWN
      esac
    fi
    [ "$ostart" = "$livestart" ] && return 1    # same process still alive
    return 0                                     # pid reused -> original dead
  fi
  ps -p "$opid" >/dev/null 2>&1 && return 1     # exists but unsignalable (EPERM) -> alive
  return 0                                       # ESRCH -> provably gone -> dead
}

# (v101-confirm) _ownerless_past_grace <dir> — 0 iff <dir> exists, carries NO owner record at
# all, and is older than OWNERLESS_GRACE_SECS. Acquisition is mkdir-then-publish-owner and the
# gap between them is milliseconds, so an ownerless directory that survived a whole grace
# window is an acquisition killed inside that gap — not one in progress. Without this a
# SIGKILL/power loss there left a lock nobody could ever prove dead: every later acquirer
# (including every launchd restart of the archiver) blocked forever on it. An owner record
# that EXISTS but is unreadable or unparseable is NOT this state — that stays UNKNOWN and is
# never reclaimed. Mirrors banklock.ownerless_past_grace exactly; the two implementations
# contend for the same directories and must agree on what is reclaimable.
OWNERLESS_GRACE_SECS=60
_ownerless_past_grace() {
  local d="$1" age
  [ -d "$d" ] || return 1
  [ -e "$d/owner" ] && return 1
  age=$(( $(now_epoch) - $(_mtime "$d") ))
  [ "$age" -gt "$OWNERLESS_GRACE_SECS" ]
}

# _reclaimable_dir <dir> <start_field> [allow_ownerless] — 0 iff <dir> may be reclaimed:
# POSITIVE owner death, or (when allow_ownerless=1) ownerless past the bounded grace.
_reclaimable_dir() {
  local d="$1" sf="$2" ow="${3:-0}"
  if _owner_provably_dead "$d/owner" "$sf"; then return 0; fi
  if [ "$ow" = "1" ] && _ownerless_past_grace "$d"; then return 0; fi
  return 1
}

# (r5 item 6) _reclaim_dir_if_dead <dir> <start_field> [allow_ownerless] — reclaim a stale
# lock/mutex dir SAFELY via RENAME-FIRST-VERIFY-INSIDE: rename it away atomically (exactly one
# contender wins the mv), verify INSIDE the renamed copy no one else can touch, then delete or
# restore (unexpectedly alive). Binds deletion to the exact inspected instance — a successor
# created at the original path can never be destroyed. The re-check on the frozen copy is what
# makes the ownerless case safe too: an acquirer that published its owner between our
# pre-check and the mv makes the frozen copy non-ownerless, and it is restored untouched.
# Returns 0 iff the dir was removed.
_reclaim_dir_if_dead() {
  local d="$1" sf="$2" ow="${3:-0}" stolen
  _reclaimable_dir "$d" "$sf" "$ow" || return 1            # pre-check at the original path
  stolen="$d.stealing.$$.$RANDOM$RANDOM"
  mv "$d" "$stolen" 2>/dev/null || return 1                # atomic; exactly one winner
  if _reclaimable_dir "$stolen" "$sf" "$ow"; then
    rm -rf "$stolen" 2>/dev/null
    return 0
  fi
  # (r6 b1) NOT provably dead on the frozen copy: NEVER rm -rf `stolen` (it may hold a
  # LIVE owner) and NEVER `mv "$stolen" "$d"` when `$d` exists — shell `mv` NESTS the old
  # dir INSIDE the fresh acquirer's lock ("$d/$stolen"), corrupting a valid new lock.
  # Restore only into a still-absent original path; otherwise leave `stolen` as inert,
  # uniquely-named debris (token-owned -> release-safe). Debris is the fail-closed cost.
  [ -e "$d" ] || mv "$stolen" "$d" 2>/dev/null || true
  return 1
}

# (r5 item 6) _release_reclaim_mutex <dir> <token> — tear down OUR reclaim mutex only
# (own-token bound), via a rename-away so we never delete a contender's mutex.
_release_reclaim_mutex() {
  local d="$1" tok="$2" curtok gone
  curtok="$(cut -d' ' -f2 "$d/owner" 2>/dev/null)"
  [ "$curtok" = "$tok" ] || return 0
  gone="$d.done.$$.$RANDOM$RANDOM"
  # (r6 b2) tear down ONLY via the rename-away. If the mv fails, NEVER fall back to an
  # rm -rf at the LIVE original path — a contender may already hold our mutex path there.
  # Leave it; once we exit it is a provably-dead-owner mutex the rename-first reclaim
  # primitive removes safely on a later pass.
  if mv "$d" "$gone" 2>/dev/null; then rm -rf "$gone" 2>/dev/null; fi
}

# _lock_stale_and_dead — 0 iff LOCK_DIR is older than the 5-min stale window AND its
# holder is PROVABLY dead — or (v101-confirm) it is OWNERLESS past the bounded startup grace.
# Main-lock owner is "pid token start" -> start at cut field 3.
_lock_stale_and_dead() {
  [ -d "$LOCK_DIR" ] || return 1
  local age
  age=$(( $(now_epoch) - $(_mtime "$LOCK_DIR") ))
  [ "$age" -gt "$LOCK_STALE_SECS" ] || return 1
  _reclaimable_dir "$LOCK_DIR" 3 1
}

acquire_lock() {
  ensure_bank
  # wait budget: explicit arg > ACCOUNT_BANK_LOCK_WAIT env > 12s default.
  local waitmax="${1:-${ACCOUNT_BANK_LOCK_WAIT:-12}}" waited=0 tok
  tok="$$-$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$tok" ] || tok="$$-$RANDOM$RANDOM"
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # write owner atomically: "pid token starttime". If the owner write fails we
      # have a lock dir with no ownership record — normal release (token match)
      # could never remove it, so it would sit until the 5-min stale reclaim. Undo
      # the mkdir and report failure instead (finding #17). starttime lets stale
      # reclaim tell a live holder from a reused PID (finding #3).
      # (r14 #4) the start-time MUST be provable: an EMPTY one (transient ps failure) would
      # make future reclaim unable to prove death / detect pid reuse -> permanent lock-out.
      # Retry; if still empty, undo the mkdir and fail rather than publish an unprovable owner.
      local _pstart="" _i=0
      while [ "$_i" -lt 4 ]; do
        _pstart="$(_proc_starttime "$$")"
        [ -n "$_pstart" ] && break
        _i=$((_i + 1)); sleep 0.05 2>/dev/null || sleep 1
      done
      if [ -z "$_pstart" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        err "account-bank: could not read a stable process start-time; refusing to publish an unprovable lock owner (transient). Retry."
        return 1
      fi
      if printf '%s %s %s\n' "$$" "$tok" "$_pstart" | atomic_write "$LOCK_DIR/owner"; then
        LOCK_TOKEN="$tok"
        # (r12 #11) EXPORT the lock token so a child helper invoked with
        # ACCOUNT_BANK_HOLDS_LOCK=1 can PROVE it holds the lock (banklock.verify_caller_holds
        # matches this against the on-disk owner token). A process that merely sets
        # HOLDS_LOCK without holding the lock does not know this token.
        export ACCOUNT_BANK_LOCK_TOKEN="$tok"
        # (v2 rev6 §8) capture the epoch snapshot AT lock-acquire; kc_write re-reads
        # it inside the held lock immediately before mutating (generation fence).
        # A broken/unreadable EPOCH means we cannot prove the world's state:
        # fail closed — release and refuse the lock (a v1 mutator without a valid
        # snapshot must never mutate).
        if ! EPOCH_SNAP="$(python3 "$_LIB_HERE/epoch.py" snapshot "$BANK_DIR" 2>/dev/null)"; then
          err "account-bank: cannot read EPOCH; refusing to hold the lock (fail-closed)."
          release_lock
          return 1
        fi
        return 0
      fi
      rm -rf "$LOCK_DIR" 2>/dev/null
      err "account-bank: acquired lock dir but failed to write owner token; released and aborting."
      return 1
    fi
    # contended: consider stale reclaim (r5 item 6 — rename-first-verify-inside).
    # Reclamation is serialized under RECLAIM_DIR and re-verifies staleness while
    # holding it. The reclaim MUTEX is itself reclaimed ONLY via the safe rename-first
    # primitive on POSITIVE death (no age fallback, ownerless/unreadable = never), and
    # we FINALLY re-verify we still own the mutex (own-token) immediately before the
    # main-lock rename.
    if _lock_stale_and_dead; then
      if mkdir "$RECLAIM_DIR" 2>/dev/null; then
        local mtok curtok
        mtok="$$-$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        [ -n "$mtok" ] || mtok="$$-$RANDOM$RANDOM"
        # mutex owner is "pid token start" — byte-compatible with banklock.py. (r6 b3)
        # if the owner write FAILS, the mutex dir we just created would be OWNERLESS —
        # and ownerless reclaim now (correctly) fails closed, wedging every future
        # reclaimer forever. We exclusively own it (just mkdir'd, no owner yet), so
        # remove OUR OWN dir rather than strand it; the outer wait loop retries.
        # (r15 #8) An EMPTY start-time is the same wedge by a different route: reclaim is
        # positive-death-only, so an owner whose death can never be proven is permanent.
        # Same retry-then-tear-down discipline the main lock applies above.
        local _mstart="" _mi=0
        while [ "$_mi" -lt 4 ]; do
          _mstart="$(_proc_starttime "$$")"
          [ -n "$_mstart" ] && break
          _mi=$((_mi + 1)); sleep 0.05 2>/dev/null || sleep 1
        done
        if [ -z "$_mstart" ]; then
          rm -rf "$RECLAIM_DIR" 2>/dev/null
        elif ! printf '%s %s %s\n' "$$" "$mtok" "$_mstart" | atomic_write "$RECLAIM_DIR/owner"; then
          rm -rf "$RECLAIM_DIR" 2>/dev/null
        elif [ ! -d "$LOCK_DIR" ]; then
          _release_reclaim_mutex "$RECLAIM_DIR" "$mtok"
          continue                       # already gone -> retry mkdir
        else
          if _lock_stale_and_dead; then
            # FINAL own-token verification immediately before the main-lock rename.
            curtok="$(cut -d' ' -f2 "$RECLAIM_DIR/owner" 2>/dev/null)"
            if [ "$curtok" = "$mtok" ]; then
              if _reclaim_dir_if_dead "$LOCK_DIR" 3 1; then
                _release_reclaim_mutex "$RECLAIM_DIR" "$mtok"
                continue                 # retry mkdir
              fi
            fi
          fi
          _release_reclaim_mutex "$RECLAIM_DIR" "$mtok"
        fi
      else
        # mutex contended: reclaim it ONLY if its holder is provably dead — or (v101-confirm)
        # it is ownerless past the bounded grace, the same interrupted-acquisition state the
        # main lock can land in. Via the safe rename-first primitive; an unreadable-owner or
        # live mutex is left alone.
        _reclaim_dir_if_dead "$RECLAIM_DIR" 3 1 || true
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
  # (r6 b9) EPOCH_SNAP is bound to a HELD lock — it is the proof-of-lock a v1 mutator's
  # generation fence checks. Clear it here (unconditionally) so a stale snapshot can never
  # outlive the lock and let a subsequent unlocked kc_write/epoch_guard pass the fence.
  EPOCH_SNAP=""
  unset ACCOUNT_BANK_LOCK_TOKEN   # (r12 #11) a released lock proves nothing to children
  [ -n "$LOCK_TOKEN" ] || return 0
  local cur
  cur="$(cut -d' ' -f2 "$LOCK_DIR/owner" 2>/dev/null)"
  if [ "$cur" = "$LOCK_TOKEN" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
    LOCK_TOKEN=""
  fi
  return 0
}

# (r6 b9/b10) epoch_guard — the v1-mutation gate EVERY v1 credential/config/record
# mutator MUST pass immediately before its FIRST mutation, WHILE holding the lock. It is
# kc_write's gate, extracted so swap/ping/toggle/remove enforce the SAME rc-78 contract:
#   1. lock actually HELD (LOCK_TOKEN non-empty) — a caller that never acquire_lock'd has
#      no business mutating; an inherited/stale EPOCH_SNAP must not fake proof-of-lock;
#   2. EPOCH_SNAP present (the snapshot acquire_lock captured under the held lock);
#   3. v1-gate new-entrant check (state v1|shadow AND no SEEDING freeze);
#   4. generation fence against the lock-acquire snapshot (exact {state,generation}).
# Returns 0 to proceed, 78 (fenced; caller MUST abort WITHOUT mutating) on any refusal.
epoch_guard() {
  if [ -z "${LOCK_TOKEN:-}" ] || [ -z "${EPOCH_SNAP:-}" ]; then
    err "epoch_guard: lock not held / no epoch snapshot (caller did not acquire_lock); refusing (rc 78; nothing mutated)."
    return 78
  fi
  if ! python3 "$_LIB_HERE/epoch.py" v1-gate "$BANK_DIR"; then
    err "epoch_guard: v1-gate refused the mutation (rc 78; nothing mutated)."
    return 78
  fi
  # shellcheck disable=SC2086
  if ! python3 "$_LIB_HERE/epoch.py" fence "$BANK_DIR" $EPOCH_SNAP v1 shadow; then
    err "epoch_guard: epoch moved since lock-acquire; fenced (rc 78; nothing mutated)."
    return 78
  fi
  return 0
}

# --- keychain ----------------------------------------------------------------
# kc_read -> prints the raw stored secret. EXACT service+account match only
# (no service-only fallback). Bounded, stdin closed. Empty output => absent/fail.
# A fresh `security` process occasionally returns empty on the first hit (ACL
# re-eval); retry a couple of times so a present item is not misread as absent.
kc_read() {
  local out i sec
  sec="$(security_bin)" || { err "kc_read: could not resolve the 'security' binary"; return 1; }
  for i in 1 2 3; do
    out="$(run_with_timeout "$KC_TIMEOUT" \
      "$sec" find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w </dev/null 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    sleep 0.3
  done
  return 1
}
# back-compat alias used by older call sites
read_keychain_raw() { kc_read; }

# kc_absent — return 0 ONLY when the credential slot is CONFIRMED EMPTY; nonzero for
# "occupied" AND for "we could not look". (r15 #3) `security find-generic-password` answers
# 44 (errSecItemNotFound) for a genuinely absent item and some other nonzero for a failure to
# see (locked keychain, timeout, denied, missing binary). kc_read collapses both into empty
# output, so a caller that must not confuse "nothing is there" with "we are blind" asks HERE
# — the same rc-44 discipline add-account.sh uses before restoring an empty slot ("absence is
# CONFIRMED via `security find` rc 44; a failed re-read is never 'empty'"). Two consecutive
# 44s are required so a slot being written underneath us cannot read as stably empty.
kc_absent() {
  local sec i rc
  sec="$(security_bin)" || return 1
  for i in 1 2; do
    run_with_timeout "$KC_TIMEOUT" \
      "$sec" find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w </dev/null >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 44 ] || return 1
  done
  return 0
}

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

# _cred_fp — full-credential fingerprint of a blob/oauth on STDIN (findings 11/21).
# Empty output when it can't be computed. Never echoes the secret.
_cred_fp() { python3 "$_LIB_HERE/bank_common.py" --fingerprint 2>/dev/null; }

# kc_write  — new secret blob on STDIN. Validates schema (stdin), fail-closed
# snapshot of the current item, update-in-place via `security -i` (secret travels
# through security's stdin, never argv), then VERIFIES the live item now carries
# the intended credential. Refuses to CREATE an item unless ACCOUNT_BANK_BOOTSTRAP=1.
# Bounded by KC_TIMEOUT, killed by PROCESS GROUP.
#
# Return codes are load-bearing (findings #10/#12 — "a failed write is NOT the
# same as 'unchanged'"):
#   0   = write VERIFIED: the live keychain now holds exactly the intended cred.
#   10  = PRE-WRITE failure, keychain DEFINITELY UNCHANGED (empty/invalid blob,
#         no existing item without bootstrap, snapshot failure). Safe to treat as
#         a clean no-op.
#   1   = INDETERMINATE: the write timed out, or the post-write verify shows a
#         different/absent credential (a concurrent /login or torn write). The
#         caller MUST NOT assume the keychain is unchanged — it must verify /
#         retain recovery material. This is the fail-LOUD path.
#   11  = (r4 #2) ROTATED-UNDER-US, keychain DEFINITELY UNCHANGED: a final re-read
#         immediately before the write syscall found the live outgoing credential
#         no longer matches the bytes we snapshotted (an external /login rotated it
#         since the snapshot). We REFUSE to overwrite the fresh token; KC_LAST_SNAPSHOT
#         is refreshed to the newest live bytes so the caller can re-bank the true
#         latest outgoing credential and abort. Like rc 10 the keychain is unchanged.
# KC_LAST_SNAPSHOT — set by kc_write to the path of the snapshot it took of the
# item it OVERWROTE (the true pre-overwrite live credential). Empty when no
# snapshot was taken (bootstrap create). Consumed by swap-account.sh to re-bank
# the outgoing account from the EXACT bytes present at overwrite time, closing the
# rotation-vs-replacement window (r3 #4).
#
# (r4 #1) kc_write is frequently invoked on the RHS of a pipeline (`... | kc_write`),
# which runs it in a SUBSHELL — a KC_LAST_SNAPSHOT assignment there never reaches
# the caller, so the snapshot path was silently lost and the outgoing re-bank block
# was dead. Besides the variable, kc_write now also writes the snapshot path to
# KC_LAST_SNAPSHOT_FILE (a fixed path), which survives a subshell. Callers should
# invoke kc_write via process substitution (so the variable is set directly) AND/OR
# read KC_LAST_SNAPSHOT_FILE as a fallback.
KC_LAST_SNAPSHOT=""
KC_LAST_SNAPSHOT_FILE="${KC_LAST_SNAPSHOT_FILE:-$SNAP_DIR/.last-snapshot-path}"
kc_write() {
  ensure_bank
  # (v2 rev6 §8 / r6 b9+b10) THE v1 keychain-mutation gate, immediately before first
  # mutation: lock actually held + v1-gate + generation fence against the lock-acquire
  # snapshot. (finding 22 / r6 b9) the gate is MANDATORY, not conditional — a caller that
  # invoked kc_write without acquire_lock has no held lock and no EPOCH_SNAP, cannot prove
  # the world's state, and must be refused (an inherited EPOCH_SNAP without a held lock is
  # not proof). rc 78 = fenced, keychain UNCHANGED. Shared with swap/ping/toggle/remove.
  epoch_guard || return 78
  KC_LAST_SNAPSHOT=""
  KC_LAST_SNAPSHOT_FILE="${KC_LAST_SNAPSHOT_FILE:-$SNAP_DIR/.last-snapshot-path}"
  rm -f "$KC_LAST_SNAPSHOT_FILE" 2>/dev/null || true
  local blob; blob="$(cat)"
  [ -n "$blob" ] || { err "kc_write: empty blob"; return 10; }
  # schema validation — blob via stdin, never argv
  if ! printf '%s' "$blob" | python3 "$_LIB_HERE/validate_blob.py"; then
    err "kc_write: blob failed validation; NOT writing"; return 10
  fi
  local want_fp; want_fp="$(printf '%s' "$blob" | _cred_fp)"
  # fail-closed: the exact item must already exist unless bootstrapping
  local cur; cur="$(kc_read)"
  if [ -z "$cur" ]; then
    if [ "${ACCOUNT_BANK_BOOTSTRAP:-0}" != "1" ]; then
      err "kc_write: no existing keychain item for $KEYCHAIN_SERVICE/$KEYCHAIN_ACCOUNT."
      err "          Refusing to create it. Re-run with ACCOUNT_BANK_BOOTSTRAP=1 to bootstrap."
      return 10
    fi
  else
    # snapshot the blob we just read (no second keychain hit); abort on failure
    ensure_bank
    local snap="$SNAP_DIR/$(now_epoch)-$$.json"
    if ! printf '%s' "$cur" | atomic_write "$snap"; then
      err "kc_write: could not snapshot the live item; aborting write (fail-closed)."
      return 10
    fi
    KC_LAST_SNAPSHOT="$snap"   # (r3 #4) expose the pre-overwrite capture to callers
    printf '%s' "$snap" > "$KC_LAST_SNAPSHOT_FILE" 2>/dev/null || true   # (r4 #1) subshell-safe
    ls -1t "$SNAP_DIR"/*.json 2>/dev/null | tail -n +21 | while read -r old; do rm -f "$old"; done
    # (r5 PRINCIPLE 2) never-destroy: archive the pre-overwrite credential to the
    # unified <BANK_DIR>/archive/ dir BEFORE we destroy it, labelled with the account
    # that owns it (or "unknown"). This makes even an unwinnable rotation race
    # recoverable. Fail CLOSED: if archiving cannot durably land, refuse the write —
    # the keychain is still UNCHANGED here (rc 10), a safe no-op. Done before the
    # final recheck so the recheck stays as close to the write syscall as possible.
    local _kc_owner _kc_arch
    _kc_owner="$(printf '%s' "$cur" | fp_owner)"
    if ! _kc_arch="$(printf '%s' "$cur" | archive_blob "$_kc_owner")"; then
      err "kc_write: could not archive the pre-overwrite credential; refusing to overwrite"
      err "          (fail-closed). Keychain UNCHANGED (rc 10)."
      return 10
    fi
    # (r4 #2 + r5 #1) SHRINK the rotation-vs-overwrite window and CLOSE the fail-open:
    # re-read the live item one last time immediately before the write and confirm it
    # STILL matches the bytes we snapshotted. An external /login could have rotated the
    # outgoing token since the snapshot; overwriting then would destroy a fresh token
    # whose only copy (the snapshot) is the SPENT predecessor. (r5 #1) an empty /
    # unreadable / invalid RE-READ must NEVER bypass the mismatch gate and proceed —
    # we cannot prove the live outgoing credential is still what we snapshotted, so we
    # REFUSE (rc 11, keychain UNCHANGED) rather than overwrite blind. In both the
    # unreadable and the diverged case we refresh KC_LAST_SNAPSHOT to whatever bytes we
    # could read so the caller re-banks the true-latest outgoing credential and aborts.
    local recheck recheck_fp cur_fp
    recheck="$(kc_read)"
    recheck_fp="$(printf '%s' "$recheck" | _cred_fp)"
    cur_fp="$(printf '%s' "$cur" | _cred_fp)"
    if [ -z "$recheck_fp" ] || [ -z "$cur_fp" ] || [ "$recheck_fp" != "$cur_fp" ]; then
      if [ -n "$recheck" ]; then
        local snap2="$SNAP_DIR/$(now_epoch)-$$.json"
        if printf '%s' "$recheck" | atomic_write "$snap2"; then
          KC_LAST_SNAPSHOT="$snap2"
          printf '%s' "$snap2" > "$KC_LAST_SNAPSHOT_FILE" 2>/dev/null || true
        fi
      fi
      if [ -z "$recheck_fp" ] || [ -z "$cur_fp" ]; then
        err "kc_write: could not re-verify the live outgoing credential before the write"
        err "          (empty/unreadable/invalid re-read); refusing to overwrite blind."
        err "          Keychain UNCHANGED (rc 11)."
      else
        err "kc_write: outgoing credential rotated between snapshot and write; refusing to"
        err "          overwrite the fresh token. Keychain UNCHANGED (rc 11)."
      fi
      return 11
    fi
  fi
  # write, bounded, PROCESS-GROUP killed (findings #2/#22): the `security -i`
  # subshell leads its own group so a timeout reaps security itself, not just the
  # shell wrapper. printf is a shell builtin -> the secret is not in any argv.
  # Service/account are double-quoted (service contains a space; security -i
  # splits its command line on whitespace and honors double-quotes). The blob is
  # left unquoted: it is compact (validated: no whitespace) and starts with '{',
  # so security -i takes the whole run as one literal token.
  local sec; sec="$(security_bin)" || { err "kc_write: could not resolve the 'security' binary"; return 10; }
  local had_m=0; case "$-" in *m*) had_m=1;; esac
  set -m
  ( printf 'add-generic-password -U -s "%s" -a "%s" -w %s\n' \
      "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" "$blob" | "$sec" -i ) &
  local p=$!
  [ "$had_m" -eq 0 ] && set +m
  ( sleep "$KC_TIMEOUT"
    kill -TERM -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
    sleep 0.3
    kill -KILL -"$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null
  ) >/dev/null 2>&1 &
  local w=$!
  local rc=0
  wait "$p" 2>/dev/null; rc=$?
  kill -KILL "$w" 2>/dev/null; wait "$w" 2>/dev/null
  { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; } && rc=124
  # POST-WRITE VERIFY (findings #10/#12): never trust the security exit code as
  # proof. `security -i` can commit just before a timeout-kill (nonzero rc but the
  # write LANDED), or a concurrent /login can overwrite our blob a moment later.
  # Re-read the live item and compare the FULL-credential fingerprint. Only an
  # exact match is success; anything else is indeterminate (fail loud, rc 1).
  local live_fp; live_fp="$(kc_read | _cred_fp)"
  if [ -n "$want_fp" ] && [ "$live_fp" = "$want_fp" ]; then
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    err "kc_write: write timed out AND live item does not match intended (indeterminate)."
  else
    err "kc_write: post-write verify FAILED (security rc=$rc; live item != intended). Concurrent write?"
  fi
  return 1
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

# write_swap_journal <target> <current> <target_fp>  — compact pre-swap blob on
# STDIN. Records BOTH credential fingerprints (findings #12/#14/#15) so reconcile
# can distinguish a committed swap, a torn swap, and an unrelated external /login
# by comparing the LIVE keychain against target_fp / pre_fp — never rolling back
# on top of a newer login it doesn't recognize. fsync'd (finding #4) so the
# recovery record survives power loss. The program is passed via -c so STDIN
# stays free to carry the secret blob; the blob never enters argv.
write_swap_journal() {
  ensure_bank
  python3 -c '
import sys, json, os, tempfile, time
libdir, path, target, current, target_fp = sys.argv[1:6]
sys.path.insert(0, libdir)
import bank_common
blob = sys.stdin.read()
pre_fp = bank_common.cred_fingerprint(blob)
obj = {"type": "swap", "pre_swap_blob": blob, "pre_fp": pre_fp,
       "target": target, "target_fp": target_fp, "current": current, "ts": time.time()}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".swapj.")
with os.fdopen(fd, "w") as f:
    json.dump(obj, f)
    f.flush(); os.fsync(f.fileno())
os.chmod(tmp, 0o600); os.replace(tmp, path)
d = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
try: os.fsync(d)
finally: os.close(d)
' "$_LIB_HERE" "$SWAP_JOURNAL" "$1" "$2" "${3:-}"
}

# clear_swap_journal — the COMMIT POINT of the swap transaction: once the journal is
# gone, nothing can reconstruct a torn keychain/metadata pairing. (r15 #2) The unlink is
# therefore CHECKED (an unchecked `rm -f` reports success for a journal still on disk,
# which would strand a real recovery record while the caller prints "swapped") and made
# DURABLE by syncing the bank directory afterwards. Without that sync a power loss can
# preserve the keychain write and this deletion while losing the metadata rename that
# happened between them — the precise ordering inversion the journal exists to survive.
# Returns nonzero if the journal is still present; callers run without errexit and treat
# that as "keep the journal, let reconcile resolve it".
# (v101-confirm) Two DISTINCT failures, neither of which may read as success:
#   rc 1 — the journal is still on disk (the recovery record survives; reconcile will act).
#   rc 2 — the unlink landed but its DIRECTORY ENTRY could not be synced, so a power loss can
#          resurrect the journal on top of a committed swap. The old code ended on the
#          best-effort _fsync_dir, whose `|| true` turned exactly that into rc 0.
clear_swap_journal() {
  [ -e "$SWAP_JOURNAL" ] || return 0
  rm -f "$SWAP_JOURNAL" 2>/dev/null
  if [ -e "$SWAP_JOURNAL" ]; then
    err "account-bank: FAILED to clear the swap journal ($SWAP_JOURNAL); leaving it for reconcile."
    return 1
  fi
  if ! _fsync_dir_checked "$(dirname "$SWAP_JOURNAL")"; then
    err "account-bank: the swap journal was removed but $(dirname "$SWAP_JOURNAL") could not be"
    err "synced; the removal is NOT proven durable. Treat the swap's cleanup as incomplete."
    return 2
  fi
  return 0
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

# --- bank files --------------------------------------------------------------
# bank_file_for <email> — safe path to <BANK_DIR>/<email>.json, or nonzero+empty
# when the email is unsafe as a filename component (critical finding #1). Rejects
# path separators, "."/".."/leading-dot, ".." substrings, whitespace/control, and
# anything without '@'. Mirrors bank_common.safe_email so shell and Python agree.
# Callers MUST check the exit status:  tf="$(bank_file_for "$x")" || exit 1
bank_file_for() {
  local email="$1"
  case "$email" in
    ""|.|..) err "bank_file_for: refusing empty/'.'/'..' email"; return 1 ;;
    .*)      err "bank_file_for: refusing leading-dot email '$email'"; return 1 ;;
    */*|*\\*) err "bank_file_for: refusing email with path separator '$email'"; return 1 ;;
    *..*)    err "bank_file_for: refusing '..' in email '$email'"; return 1 ;;
    *@*)     ;;
    *)       err "bank_file_for: refusing non-email '$email' (no @)"; return 1 ;;
  esac
  # reject any whitespace/control character (glob can't express these cleanly)
  case "$email" in
    *[![:print:]]*|*" "*|*"	"*) err "bank_file_for: refusing whitespace/control in email"; return 1 ;;
  esac
  printf '%s/%s.json' "$BANK_DIR" "$email"
}

list_bank_emails() {
  ensure_bank
  local b
  for f in "$BANK_DIR"/*.json; do
    [ -e "$f" ] || continue
    b="$(basename "$f" .json)"
    # (release-eve) STRUCTURAL invariant instead of a hand-enumerated skip list: a bank
    # record is named after the account it holds, so its basename is an EMAIL and always
    # contains '@'; no control-plane file in BANK_DIR ever does. The old list mirrored
    # bank_common.V2_CONTROL_JSON by hand and silently drifted every time that set grew —
    # a new control file would have been rendered as a phantom "account". Keep only
    # email-shaped basenames; everything else is not a bank record, present or future.
    case "$b" in
      *@*) : ;;
      *) continue ;;
    esac
    printf '%s\n' "$b"
  done
}

# codex_bin — absolute path to the codex CLI, or nonzero (empty stdout) when
# unresolved (finding #36). Same contract as claude_bin: honor an override only
# if executable, else PATH, else known install dirs; every candidate must be a
# real executable regular file. Unresolved => TRANSIENT, never a hard failure.
codex_bin() {
  local override="${ACCOUNT_BANK_CODEX_BIN:-}"
  if [ -n "$override" ]; then
    if [ -f "$override" ] && [ -x "$override" ]; then printf '%s\n' "$override"; return 0; fi
    return 1
  fi
  local c
  c="$(command -v codex 2>/dev/null)"
  if [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
  for cand in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
    [ -f "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# --- sanitized child invocation (finding #48) --------------------------------
# run_child_bash <script> [args...] — run a child bash script with /bin/bash and
# a sanitized environment: BASH_ENV / ENV / CDPATH stripped so ambient startup
# code can't mutate bank variables, add delays, or contaminate output before the
# safety logic runs. Absolute interpreter, never bare `bash` on PATH.
run_child_bash() {
  env -u BASH_ENV -u ENV -u CDPATH /bin/bash "$@"
}

# --- active-identity snapshot (external-/login race guard, patterns #4) -------
# active_cred_fp — fingerprint of the LIVE keychain credential right now, or ""
# when absent. Pair with active_email() to snapshot the active identity under the
# lock immediately before any keychain write / attribution / deletion, and abort
# if either changed (findings #12/#26/#27/#41/#51).
active_cred_fp() { kc_read | _cred_fp; }

# (r5) fp_owner_other_than was retired: the "is the live keychain a DIFFERENT
# banked account?" question is now answered by the single fail-closed resolver
# below (resolve_identity), which additionally requires a POSITIVE bind to the
# intended account instead of only catching a match to some OTHER account — closing
# r4 #8's residual (an intruding UNBANKED account, or one whose bank token drifted,
# produced no "other" match and slipped through). See resolve_identity.

# --- SINGLE fail-closed identity primitive (r5 #1/#4/#6) ----------------------
# resolve_identity <active_meta_email>  — live keychain blob on STDIN. Delegates to
# bank_common.resolve_identity: prints the RESOLVED owner email + returns 0 IFF the
# live credential's fingerprint matches EXACTLY ONE current bank record AND
# <active_meta_email> names that same account. Prints nothing + returns 1 on any
# UNRESOLVED state (empty/unreadable/invalid keychain, unknown/drifted token, a
# match to another account, metadata mismatch). Secret travels on STDIN, never argv.
# This is the ONE resolver every mutating consumer routes identity through; a shell
# caller MUST fail closed (abort the mutation) when it returns nonzero.
resolve_identity() {
  BANK_DIR="$BANK_DIR" python3 "$_LIB_HERE/bank_common.py" --resolve-identity "$BANK_DIR" "${1:-}"
}

# resolve_active_identity  — read the live keychain + active metadata ONCE and
# resolve. Prints the owner email + rc 0 when RESOLVED, else nothing + rc 1.
resolve_active_identity() {
  local blob meta
  blob="$(kc_read)"
  meta="$(active_email)"
  printf '%s' "$blob" | resolve_identity "$meta"
}

# fp_owner  — blob on STDIN. Prints the single banked account owning that exact
# credential fingerprint, or nothing (unknown/ambiguous). Metadata-independent;
# used only to LABEL an archive (who owns the credential we are about to destroy).
fp_owner() {
  BANK_DIR="$BANK_DIR" python3 "$_LIB_HERE/bank_common.py" --fp-owner "$BANK_DIR"
}

# --- never-destroy invariant (r5 PRINCIPLE 2) --------------------------------
# archive_blob <email-or-empty>  — blob on STDIN. Preserves a credential blob about
# to be OVERWRITTEN to <BANK_DIR>/archive/<email-or-unknown>.<utc>.json (0600,
# fsync'd, newest-10-per-account) BEFORE it is destroyed. Prints the archive path.
# Returns nonzero ONLY on a hard IO failure, so a caller can fail closed and refuse
# the overwrite. A blank blob is a no-op (rc 0, no output). Secret via STDIN.
archive_blob() {
  BANK_DIR="$BANK_DIR" python3 "$_LIB_HERE/bank_common.py" --archive-blob "$BANK_DIR" "${1:-}"
}
