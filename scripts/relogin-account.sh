#!/usr/bin/env bash
# relogin-account.sh <email> [--sync | --detach]
#
# One-click recovery for a `needs-relogin` account: the grant was revoked server-side
# (on the shared account this happens whenever someone else logs out or in), so nothing
# local can revive it — only a fresh browser OAuth can. This automates the standing
# manual ceremony end to end:
#
#   1. mktemp a throwaway CLAUDE_CONFIG_DIR (0700, inside the bank so a tmp sweep or a
#      reboot cannot delete a freshly captured credential).
#   2. Open a Terminal window running `CLAUDE_CONFIG_DIR=<dir> claude`. A virgin config
#      dir enters the login flow; the owner completes the browser OAuth AS THE TARGET.
#      The DEFAULT seat is never touched, so running sessions never notice.
#   3. Watch that dir's seat for the credential the login writes (file or per-config-dir
#      keychain slot — the CLI migrates one into the other), prove via the G9 profile
#      oracle that it belongs to <email>, and materialize it as the dir's
#      `.credentials.json`.
#   4. Run the FULL banking ceremony pinned to that dir (`bank-account.sh`, unchanged —
#      lock, reconcile, torn-snapshot guard, identity re-check, atomic 0600 write).
#   5. Delete the throwaway dir AND every keychain slot its path spellings produced,
#      clear the auto-ping circuit breaker, and force a fresh poll so the card heals.
#
# The owner picking the WRONG account in the browser is a first-class outcome: the
# identity gate refuses it, everything is cleaned up, and nothing is banked.
#
# The bank lock is deliberately NEVER held here — step 2 waits on a human for minutes,
# and `bank-account.sh` takes the lock itself for the seconds it actually needs it.
#
# (r2) Two things the first cut got wrong, both about what happens when this does NOT go
# to plan. A pending-relogin JOURNAL entry is written before the Terminal opens and
# cleared only after cleanup, because a login completed after we gave up would otherwise
# strand a live credential in a keychain slot whose config dir no longer exists — nothing
# could ever recompute that service name. Every abandoning path now TERMINATES the login
# (the launcher records its own pid) before deleting anything, every entry runs a sweep of
# stale journal entries first, and a second Re-bank while one is pending is refused
# instead of opening a second window. And the banked record is ASSERTED to hold the
# credential this login captured — `bank-account.sh` re-reads the credential itself
# through cred_read, whose shape gate can silently fall back to the active account's
# default slot (see relogin_capture.py). A mismatch restores the pre-bank record.
#
# Invocation: with no tty (QuotaBar's Re-bank routes here) it DETACHES — the Terminal
# window is the owner's interface from that point and the app's action queue must not
# sit blocked behind a human. The detached run reports through a macOS notification and
# `<bank>/.relogin.log`. `--sync` forces the foreground form (a tty gets it by default).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RELOGIN_TIMEOUT="${ACCOUNT_BANK_RELOGIN_TIMEOUT:-300}"   # how long to wait on the human

email="${1:-}"
mode="${2:-}"
if [ -z "$email" ]; then
  err "usage: relogin-account.sh <email> [--sync|--detach]"
  exit 2
fi
ensure_bank
bank_file_for "$email" >/dev/null || exit 1

# --- detach decision ---------------------------------------------------------
case "$mode" in
  --sync)   detach=0 ;;
  --detach) detach=1 ;;
  "")
    if [ -n "${ACCOUNT_BANK_RELOGIN_DETACH:-}" ]; then
      detach="$ACCOUNT_BANK_RELOGIN_DETACH"
    elif [ -t 0 ] || [ -t 1 ]; then
      detach=0
    else
      detach=1
    fi ;;
  *) err "relogin-account.sh: unknown option '$mode'"; exit 2 ;;
esac

# Reap anything a previous run left behind (killed, rebooted, timed out mid-login) BEFORE
# deciding whether one is pending — otherwise a dead entry would refuse every future
# attempt. MAX_AGE bounds the pid-liveness test so a recycled pid cannot pin an entry.
RELOGIN_MAX_AGE=$(( RELOGIN_TIMEOUT + 600 ))
# Not in the detached child: its parent's claim may still carry the PARENT's pid, and the
# parent has by then exited — the child would reap the very entry it is about to fill in.
if [ -z "${ACCOUNT_BANK_RELOGIN_CLAIMED:-}" ]; then
  python3 "$HERE/relogin_capture.py" journal-sweep "$BANK_DIR" "$RELOGIN_MAX_AGE" >/dev/null 2>&1 || true
fi

# One re-login per account at a time. QuotaBar cannot enforce this — its per-card busy
# guard clears the moment the flow detaches — so the claim lives here, and it is taken in
# whichever process runs FIRST (the detaching parent, or a --sync run started by hand),
# never in the detached child, where two rapid clicks could both get past it.
if [ -z "${ACCOUNT_BANK_RELOGIN_CLAIMED:-}" ]; then
  claim_out="$(python3 "$HERE/relogin_capture.py" journal-claim "$BANK_DIR" "$email" "$$" "$RELOGIN_MAX_AGE")"
  if [ $? -ne 0 ]; then
    err "Re-login refused: $claim_out"
    err "Finish (or close) the login window already open for $email, then try again."
    exit 9
  fi
fi

if [ "$detach" = "1" ]; then
  LOG="$BANK_DIR/.relogin.log"
  ( umask 077; : >>"$LOG" ) || true
  chmod 600 "$LOG" 2>/dev/null || true
  # nohup so the app's process-group teardown cannot take the login window with it.
  ACCOUNT_BANK_RELOGIN_CLAIMED=1 nohup /bin/bash "$HERE/relogin-account.sh" "$email" --sync >>"$LOG" 2>&1 &
  # hand ownership of the claim to the child, so the guard tracks the process that is
  # actually running the login rather than this one, which is about to exit
  python3 "$HERE/relogin_capture.py" journal-update "$BANK_DIR" "$email" owner_pid "$!" >/dev/null 2>&1 || true
  # The ONE machine-readable line in this flow: QuotaBar reads it to caption the card
  # "Login window opened" instead of claiming the account was re-banked (RebankSummary).
  echo "QUOTABAR_STATUS: relogin-started"
  echo "Re-login started for $email — complete the browser login in the Terminal window that just opened."
  echo "Banking finishes automatically; you'll get a notification. Log: $LOG"
  exit 0
fi

# From here this process owns the claim: stamp our pid so a concurrent sweep sees a live
# entry, and make sure an early exit releases it rather than blocking the next attempt.
python3 "$HERE/relogin_capture.py" journal-update "$BANK_DIR" "$email" owner_pid "$$" >/dev/null 2>&1 || true
trap 'python3 "$HERE/relogin_capture.py" journal-release "$BANK_DIR" "$email" >/dev/null 2>&1 || true' EXIT

echo "[$(now_iso)] relogin-account.sh $email — starting."

if ! CLAUDE="$(claude_bin)"; then
  err "Re-login aborted: could not resolve an executable 'claude' binary (set ACCOUNT_BANK_CLAUDE_BIN)."
  exit 6
fi

# --- throwaway config dir ----------------------------------------------------
# Inside BANK_DIR, not TMPDIR: an interrupted run can leave a real, freshly rotated
# credential in here, and the bank is the one place nothing external sweeps. The name is
# dotted so list_bank_emails' email-shaped-basename rule can never see it as an account.
CFG="$(umask 077; mktemp -d "$BANK_DIR/.relogin.XXXXXXXX")" || {
  err "Re-login aborted: could not create a throwaway config dir under $BANK_DIR."; exit 6; }
chmod 700 "$CFG"
# Order matters: kill the login FIRST, then delete. Deleting the config dir while the
# login is still in flight is precisely how a credential gets stranded in an
# unrecomputable slot — the OAuth completes afterwards and the CLI writes to a service
# name derived from a path that no longer exists.
_finish() {
  python3 "$HERE/relogin_capture.py" journal-kill "$BANK_DIR" "$email" >/dev/null 2>&1 || true
  python3 "$HERE/relogin_capture.py" cleanup "$CFG" >/dev/null 2>&1 || true
  python3 "$HERE/relogin_capture.py" journal-release "$BANK_DIR" "$email" >/dev/null 2>&1 || true
}
trap '_finish' EXIT
trap '_finish; exit 130' INT TERM HUP PIPE

# The journal must know the dir BEFORE the login can write anything into it, and this is
# the one journal write that is load-bearing rather than advisory: without it the sweep
# has no dir to reclaim and the stranded-credential leak comes back for this run. So it
# is FATAL, not best-effort — and it is cheap to obey, because nothing sensitive exists
# yet and the trap above tears down the empty dir on the way out.
if ! python3 "$HERE/relogin_capture.py" journal-update "$BANK_DIR" "$email" config_dir "$CFG"; then
  err "Re-login aborted: could not record the pending-login journal entry for $email."
  err "Refusing to open a login window that nothing could clean up after. Nothing changed."
  exit 6
fi

# --- the login window --------------------------------------------------------
LOGIN_SH="$CFG/login-here.sh"
UARGS="$(_auth_env_u_args)"     # strip inherited alt-auth/proxy vars from the CLI launch
{
  printf '#!/bin/bash\n'
  printf 'echo ""\n'
  printf 'echo "  QuotaBar — re-login for %s"\n' "$email"
  printf 'echo "  ------------------------------------------------------------"\n'
  printf 'echo "  Claude Code is starting in an ISOLATED profile. Your normal"\n'
  printf 'echo "  login and any running sessions are NOT affected."\n'
  printf 'echo ""\n'
  printf 'echo "  1. Complete the login in the browser window that opens."\n'
  printf 'echo "  2. PICK THE ACCOUNT: %s  (anything else is refused)"\n' "$email"
  printf 'echo "  3. That is all — banking finishes on its own, and this"\n'
  printf 'echo "     window closes itself when it is done."\n'
  printf 'echo ""\n'
  # $$ before the exec IS the claude process's pid (exec replaces this shell in place),
  # and it lives in the config dir so it survives any crash between here and a journal
  # write — the journal only has to point at the directory. The start-time token beside
  # it is what makes the pid PROVABLE later: exec preserves both pid and start time, so
  # this token still describes `claude`, and a recycled pid cannot match it. Nothing is
  # ever signalled without that match.
  printf 'echo $$ > %q\n' "$CFG/login.pid"
  printf 'ps -o stat=,lstart= -p $$ 2>/dev/null | tr -s " " | sed "s/^ *//;s/^[^ ]* //;s/ *$//" > %q\n' "$CFG/login.start"
  printf 'CLAUDE_CONFIG_DIR=%q exec /usr/bin/env%s %q\n' "$CFG" "$UARGS" "$CLAUDE"
} >"$LOGIN_SH"
chmod 700 "$LOGIN_SH"

if [ -n "${ACCOUNT_BANK_RELOGIN_TERMINAL_CMD:-}" ]; then
  # Test/dry-run seam: run this instead of opening Terminal.app, so the orchestration
  # can be exercised end to end without a real browser login. $1 = the launcher script.
  # ("$@" appended so the named command RECEIVES the three arguments, rather than the
  # shell silently dropping them: launcher path, config dir, target email.)
  /bin/bash -c "$ACCOUNT_BANK_RELOGIN_TERMINAL_CMD \"\$@\"" _relogin "$LOGIN_SH" "$CFG" "$email" &
else
  # The window id comes back so an abandoned flow can close the window it opened rather
  # than leaving a dead shell on screen.
  _osa="${ACCOUNT_BANK_OSASCRIPT_BIN:-/usr/bin/osascript}"
  _win="$("$_osa" - "$LOGIN_SH" 2>/dev/null <<'OSA'
on run argv
  tell application "Terminal"
    activate
    do script ("/bin/bash " & quoted form of (item 1 of argv))
    return id of front window
  end tell
end run
OSA
)"
  if [ $? -ne 0 ]; then
    err "Re-login aborted: could not open a Terminal window for the login."
    exit 6
  fi
  python3 "$HERE/relogin_capture.py" journal-update "$BANK_DIR" "$email" term_window "$_win" >/dev/null 2>&1 || true
fi
if [ "$RELOGIN_TIMEOUT" -ge 60 ]; then _budget="$((RELOGIN_TIMEOUT / 60))m"; else _budget="${RELOGIN_TIMEOUT}s"; fi
echo "Waiting up to $_budget for the login to complete (pick $email)…"

# --- capture + identity gate -------------------------------------------------
watch_out="$(python3 "$HERE/relogin_capture.py" watch "$CFG" "$email" "$RELOGIN_TIMEOUT")"
wrc=$?
case "$wrc" in
  0) echo "Captured: $watch_out" ;;
  4) err "Re-login timed out: no credential appeared within $_budget. Nothing banked."
     python3 "$HERE/notify.py" say "QuotaBar — re-login timed out" "$email was not re-banked; nothing changed." >/dev/null 2>&1 || true
     exit 4 ;;
  5) err "Re-login ABORTED — $watch_out"
     err "Nothing was banked and the throwaway profile is being deleted. Run it again and pick $email."
     python3 "$HERE/notify.py" say "QuotaBar — wrong account picked" "$email was not re-banked. Run Re-bank again and pick $email." >/dev/null 2>&1 || true
     exit 5 ;;
  *) err "Re-login could not complete — $watch_out. Nothing banked; the account is unchanged."
     python3 "$HERE/notify.py" say "QuotaBar — re-login incomplete" "$email was not re-banked; try again." >/dev/null 2>&1 || true
     exit 6 ;;
esac

# --- the real banking ceremony, pinned to the captured profile ---------------
# Snapshot the record first: if the assertion below finds the wrong credential got
# banked, this is what goes back. (No snapshot file == there was no record, and the
# correct restoration is to remove the one this run created.)
_rec="$(bank_file_for "$email")"
_snap=""
if [ -f "$_rec" ]; then
  _snap="$CFG/pre-bank.json"
  ( umask 077; cp "$_rec" "$_snap" ) || _snap=""
fi

if ! BANK_DIR="$BANK_DIR" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_JSON="$CFG/.claude.json" \
     /bin/bash "$HERE/bank-account.sh"; then
  err "Re-login captured a verified credential for $email but bank-account.sh refused it."
  err "The credential is NOT lost by that: re-run this once whatever it reported is resolved."
  python3 "$HERE/notify.py" say "QuotaBar — banking refused" "$email logged in but the bank ceremony refused; see the log." >/dev/null 2>&1 || true
  exit 1
fi

# --- assert we banked what we captured ---------------------------------------
# bank-account.sh re-reads "the live credential" itself; it does not take ours. cred_read
# accepts a config dir's file only when the raw text carries "claudeAiOauth"/"oauth", so a
# flat blob falls through to the BARE default slot — the ACTIVE account — and every
# downstream identity check still agrees, because the email comes from the target's own
# metadata. This is the one check that would notice, and it is shape-agnostic on purpose.
_verify="$(python3 "$HERE/relogin_capture.py" verify-banked "$CFG" "$_rec" "$_snap")"
if [ $? -ne 0 ]; then
  err "Re-login FAILED the banked-credential check for $email: $_verify"
  err "Nothing healthy was left behind — the record is back to its pre-login state."
  python3 "$HERE/notify.py" say "QuotaBar — $email NOT re-banked" "The banked credential did not match the login; the record was restored." >/dev/null 2>&1 || true
  exit 8
fi

# --- heal the card -----------------------------------------------------------
python3 "$HERE/relogin_capture.py" clear-breaker "$BANK_DIR" "$email" || true
ACCOUNT_BANK_FORCE_FRESH="$email" python3 "$HERE/usage.py" >/dev/null 2>&1 || true

# That forced poll is the first LIVE use of the captured credential, and its verdict is
# the only one here that comes from the server rather than from us. If it came back
# anything but healthy the flow did not succeed, however clean the capture was — calling
# it "complete" then would be the same lie the card used to tell while serving a stale
# figure. (usage.py writes needs-relogin only on a CONFIRMED rejection; a network failure
# leaves the freshly-banked "ok" standing, so this cannot misfire on a blip.)
_final="$(ACCOUNT_BANK_HERE="$HERE" python3 - "$(bank_file_for "$email")" <<'STATUS'
import sys, os
sys.path.insert(0, os.environ["ACCOUNT_BANK_HERE"])
import bank_common
br = bank_common.load_bank_record(sys.argv[1])
print(br.record.get("status", "ok") if br.ok else "malformed")
STATUS
)"
if [ "$_final" != "ok" ]; then
  err "Re-login banked a verified credential for $email, but its first live poll came back"
  err "'$_final' — the server is rejecting the new grant too. Nothing further to retry locally."
  python3 "$HERE/notify.py" say "QuotaBar — $email still not healthy" "The new login was banked but the server rejected it ($_final)." >/dev/null 2>&1 || true
  exit 7
fi
python3 "$HERE/notify.py" say "QuotaBar — $email re-banked" "Re-login succeeded; the card is healthy again." >/dev/null 2>&1 || true
echo "Re-login complete: $email re-banked, breaker cleared, usage cache refreshed."
