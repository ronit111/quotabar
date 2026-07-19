#!/usr/bin/env bash
# ping-account.sh [email|--active] — run one minimal Claude turn to START an idle
# 5-hour window, so the clock is already running before a work block.
#
#   active account : `claude -p` directly (uses the keychain login).
#   parked account : the isolated CLAUDE_CONFIG_DIR technique — the turn bills the
#                    parked account and, if its token was expired, the Claude Code
#                    CLI refreshes it and we write the rotated tokens back to the
#                    bank (keep-alive bonus). The keychain is never touched.
#
# Hardened (review 2026-07-19): the lock is acquired BEFORE we decide active vs
# parked, and the active/parked decision is re-derived under the lock, so a
# concurrent swap cannot make us isolated-refresh (rotate) an account that has
# just become active. 30-min per-account cooldown. needs-relogin is refused.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PING_COOLDOWN=1800          # 30-min cooldown after a SUCCESSFUL ping
PING_FAIL_COOLDOWN=300       # 5-min cooldown after a FAILED ping (anti hot-loop, #8)
MODEL="${ACCOUNT_BANK_PING_MODEL:-haiku}"
arg="${1:-}"

ensure_bank
acquire_lock || { err "ping: could not acquire lock; another bank/swap/usage op is running. Aborting."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE
python3 "$HERE/reconcile.py" 2>/dev/null || true

# resolve target UNDER the lock
if [ -z "$arg" ] || [ "$arg" = "--active" ]; then
  target="$(active_email)"
  [ -z "$target" ] && { err "Could not determine active account."; exit 1; }
else
  target="$arg"
fi

tf="$(bank_file_for "$target")"
[ -f "$tf" ] || { err "Account '$target' is not in the bank. Bank it first (bank-account.sh)."; exit 1; }

# status + cooldowns, read under the lock
read -r status last_ping last_ping_failed <<EOF
$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    d=d if isinstance(d,dict) else {}
except Exception:
    d={}
print(d.get("status","ok"), d.get("last_ping",0), d.get("last_ping_failed",0))' "$tf")
EOF
if [ "$status" = "needs-relogin" ]; then
  err "Account '$target' needs re-login — cannot ping."
  err "Run /login in Claude Code, pick $target, then: bash $HERE/bank-account.sh"
  exit 1
fi
nowsec="$(now_epoch)"
elapsed=$(( nowsec - ${last_ping%.*} ))
if [ "${last_ping%.*}" -gt 0 ] && [ "$elapsed" -lt "$PING_COOLDOWN" ]; then
  ago=$(( elapsed / 60 )); remain=$(( (PING_COOLDOWN - elapsed + 59) / 60 ))
  echo "Ping skipped: $target was pinged ${ago}m ago (30-min cooldown, ${remain}m left)."
  exit 0
fi
# distinct 5-min failure cooldown (finding #8): a ping that failed recently must
# not be retried every cycle. Kept separate from the 30-min success cooldown.
felapsed=$(( nowsec - ${last_ping_failed%.*} ))
if [ "${last_ping_failed%.*}" -gt 0 ] && [ "$felapsed" -lt "$PING_FAIL_COOLDOWN" ]; then
  fago=$(( felapsed / 60 )); fremain=$(( (PING_FAIL_COOLDOWN - felapsed + 59) / 60 ))
  echo "Ping skipped: $target's last ping failed ${fago}m ago (5-min failure cooldown, ${fremain}m left)."
  exit 0
fi

# (#2) re-derive active/parked UNDER the lock, immediately before choosing a path
active="$(active_email)"

set_last_ping() {
  python3 - "$tf" "$nowsec" <<'PY'
import json, sys, os, tempfile
tf = sys.argv[1]; ts = int(sys.argv[2] or "0")
try:
    rec = json.load(open(tf))
    if not isinstance(rec, dict): rec = {}
except Exception:
    rec = {}
rec["last_ping"] = ts
# a real success clears the failure-cooldown marker so the next window can ping
rec.pop("last_ping_failed", None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(tf), prefix=".acct.")
with os.fdopen(fd, "w") as f: json.dump(rec, f, indent=2)
os.chmod(tmp, 0o600); os.replace(tmp, tf)
PY
}

# stamp last_ping_failed (finding #8): a failed ping gets the 5-min failure
# cooldown, distinct from the 30-min success cooldown. Preserves all other fields
# (incl. any status just set to needs-relogin). Runs under the lock.
set_last_ping_failed() {
  python3 - "$tf" "$nowsec" <<'PY'
import json, sys, os, tempfile
tf = sys.argv[1]; ts = int(sys.argv[2] or "0")
try:
    rec = json.load(open(tf))
    if not isinstance(rec, dict): rec = {}
except Exception:
    rec = {}
rec["last_ping_failed"] = ts
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(tf), prefix=".acct.")
with os.fdopen(fd, "w") as f: json.dump(rec, f, indent=2)
os.chmod(tmp, 0o600); os.replace(tmp, tf)
PY
}

ok=0
if [ "$target" = "$active" ]; then
  echo "Pinging ACTIVE account $target (model $MODEL, 60s cap)…"
  # </dev/null: never block on stdin in non-tty contexts (SwiftBar, hooks).
  out="$(run_with_timeout 60 claude -p "reply with just: ok" --model "$MODEL" </dev/null 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    out="$(run_with_timeout 60 claude -p "reply with just: ok" </dev/null 2>&1)"; rc=$?
  fi
  if [ $rc -eq 0 ]; then
    echo "Ping OK — 5h window started for $target."
    set_last_ping; ok=1
  else
    err "Ping failed (rc $rc): ${out:0:200}"; set_last_ping_failed; exit 1
  fi
else
  echo "Pinging PARKED account $target via isolated profile (model $MODEL, 60s cap)…"
  jerr="${TMPDIR:-/tmp}/acctbank_ping.$$"
  # isolated_refresh.py runs the turn in a throwaway config dir, writes a recovery
  # journal on rotation, then commits rotated creds to the bank. exit 3 = dead token.
  if python3 "$HERE/isolated_refresh.py" "$tf" 2>"$jerr"; then
    msg="$(cat "$jerr" 2>/dev/null)"; rm -f "$jerr"
    echo "Ping OK — 5h window started for $target (${msg:-turn ran})."
    set_last_ping; ok=1
  else
    rc=$?; rm -f "$jerr"
    if [ $rc -eq 3 ]; then
      python3 - "$tf" <<'PY'
import json,sys,os,tempfile
tf=sys.argv[1]
try:
    r=json.load(open(tf)); r=r if isinstance(r,dict) else {}
except Exception:
    r={}
r["status"]="needs-relogin"
fd,t=tempfile.mkstemp(dir=os.path.dirname(tf),prefix=".acct.")
with os.fdopen(fd,"w") as f: json.dump(r,f,indent=2)
os.chmod(t,0o600); os.replace(t,tf)
PY
      err "Ping failed: $target's parked token is dead (refresh rejected). Marked needs-relogin."
      err "Run /login in Claude Code, pick $target, then: bash $HERE/bank-account.sh"
    else
      err "Ping failed (rc $rc)."
    fi
    set_last_ping_failed
    exit 1
  fi
fi

# release the lock BEFORE refreshing the cache — usage.py needs to take the lock.
release_lock; trap - EXIT INT TERM HUP PIPE
if [ "$ok" -eq 1 ]; then
  python3 "$HERE/usage.py" >/dev/null 2>&1 || true
  echo "Usage cache refreshed."
fi
