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

if [ "$detach" = "1" ]; then
  LOG="$BANK_DIR/.relogin.log"
  ( umask 077; : >>"$LOG" ) || true
  chmod 600 "$LOG" 2>/dev/null || true
  # nohup so the app's process-group teardown cannot take the login window with it.
  nohup /bin/bash "$HERE/relogin-account.sh" "$email" --sync >>"$LOG" 2>&1 &
  # The ONE machine-readable line in this flow: QuotaBar reads it to caption the card
  # "Login window opened" instead of claiming the account was re-banked (RebankSummary).
  echo "QUOTABAR_STATUS: relogin-started"
  echo "Re-login started for $email — complete the browser login in the Terminal window that just opened."
  echo "Banking finishes automatically; you'll get a notification. Log: $LOG"
  exit 0
fi

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

_cleanup() {
  # deletes the dir AND every per-config-dir keychain slot its path spellings produced
  python3 "$HERE/relogin_capture.py" cleanup "$CFG" >/dev/null 2>&1 || true
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT TERM HUP PIPE

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
  printf 'echo "  3. That is all — banking finishes on its own. You can close"\n'
  printf 'echo "     this window once the login says it succeeded."\n'
  printf 'echo ""\n'
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
  /usr/bin/osascript - "$LOGIN_SH" >/dev/null 2>&1 <<'OSA'
on run argv
  tell application "Terminal"
    activate
    do script ("/bin/bash " & quoted form of (item 1 of argv))
  end tell
end run
OSA
  if [ $? -ne 0 ]; then
    err "Re-login aborted: could not open a Terminal window for the login."
    exit 6
  fi
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
if ! BANK_DIR="$BANK_DIR" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_JSON="$CFG/.claude.json" \
     /bin/bash "$HERE/bank-account.sh"; then
  err "Re-login captured a verified credential for $email but bank-account.sh refused it."
  err "The credential is NOT lost by that: re-run this once whatever it reported is resolved."
  python3 "$HERE/notify.py" say "QuotaBar — banking refused" "$email logged in but the bank ceremony refused; see the log." >/dev/null 2>&1 || true
  exit 1
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
