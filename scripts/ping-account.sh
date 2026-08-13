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

# (r9 #5) v2 dispatch: under EPOCH v2 the shared keychain is bypassed and each account
# lives in its own permanent home. A ping is one turn PINNED to the target's READY home
# (its own .credentials.json is authoritative; the keychain is never touched; a refresh
# writes into the home and the tier-2 archiver captures it). Keys off EPOCH + the READY
# registry — NOT the legacy bank record (v2-seeded homes have none) — and skips the v1
# reconcile / active-vs-parked / keychain machinery entirely.
EPOCH_STATE="$(python3 "$_LIB_HERE/epoch.py" snapshot "$BANK_DIR" 2>/dev/null | awk '{print $1}')"
# (r13 #6) home pings run in shadow OR v2 (rev 9 §8: v2 home pings are shadow|v2). Under v2,
# --active resolves via the pointer. Under SHADOW (v1 still live on the keychain), only an
# EXPLICIT email that HAS a READY home takes the home-ping path — --active and legacy accounts
# fall through to the v1 keychain ping below.
v2_target=""; HOME_PATH=""
if [ "$EPOCH_STATE" = "v2" ]; then
  v2_target="$arg"
  if [ -z "$arg" ] || [ "$arg" = "--active" ]; then
    v2_target="$(ACCOUNT_BANK_DIR="$BANK_DIR" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" bash "$HERE/claude-acct" --current 2>/dev/null)"
    case "$v2_target" in
      ""|"(no pointer)")
        err "ping: no current pointer under EPOCH v2; run 'claude-acct <email>' or QuotaBar Switch first."
        exit 1 ;;
    esac
  fi
  HOME_PATH="$(python3 "$HERE/registry.py" ready-home "$BANK_DIR" "$v2_target" 2>/dev/null)" \
    || { err "ping: no READY home for '$v2_target' under EPOCH v2 (seed it: claude-acct --add $v2_target)."; exit 1; }
elif [ "$EPOCH_STATE" = "shadow" ] && [ -n "$arg" ] && [ "$arg" != "--active" ]; then
  # shadow + explicit email: home-ping ONLY if it has a READY home; else fall through to v1.
  if HOME_PATH="$(python3 "$HERE/registry.py" ready-home "$BANK_DIR" "$arg" 2>/dev/null)"; then
    v2_target="$arg"
  else
    HOME_PATH=""
  fi
fi
if [ -n "$HOME_PATH" ]; then

  # (r11 #9) v2 homes have no legacy <email>.json, so their ping cooldown markers live in a
  # per-home file. Enforce the SAME 30-min success / 5-min failure cooldowns as v1 BEFORE
  # launching a turn — otherwise two consecutive pings fire two Claude turns.
  V2_MARK="$HOME_PATH/.ping-marker.json"
  _decision="$(python3 - "$V2_MARK" "$PING_COOLDOWN" "$PING_FAIL_COOLDOWN" <<'PY'
import json, sys, time
p, cd, fcd = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
now = int(time.time())
try:
    d = json.load(open(p))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
lp = int(d.get("last_ping", 0) or 0)
lpf = int(d.get("last_ping_failed", 0) or 0)
if lp > 0 and now - lp < cd:
    print("skip-success %d" % ((cd - (now - lp) + 59) // 60)); sys.exit(0)
if lpf > 0 and now - lpf < fcd:
    print("skip-failure %d" % ((fcd - (now - lpf) + 59) // 60)); sys.exit(0)
print("go 0")
PY
)"
  case "$_decision" in
    skip-success\ *)
      echo "Ping skipped: $v2_target was pinged recently (30-min cooldown, ${_decision##* }m left)."
      release_lock; trap - EXIT INT TERM HUP PIPE; exit 0 ;;
    skip-failure\ *)
      echo "Ping skipped: $v2_target's last ping failed recently (5-min failure cooldown, ${_decision##* }m left)."
      release_lock; trap - EXIT INT TERM HUP PIPE; exit 0 ;;
  esac

  # marker writer (fsync'd, atomic) — success or failure timestamp
  # (v105) Also maintains the state auto-ping needs to STOP retrying a hopeless home:
  #   ping_fail_streak   — consecutive failures; usage.py escalates its cooldown off this.
  #   needs_login_since  — set when the turn said the home has no credential at all
  #                        ("Not logged in / please run /login"). No amount of retrying
  #                        fixes that; only an interactive /login does.
  # A success clears both. Recording only — the manual Ping path is unchanged, so Ronit
  # can always retry by hand (that is how he verifies a /login worked).
  _v2_mark() {   # $1 = last_ping | last_ping_failed [$2 = needs_login]
    python3 - "$V2_MARK" "$1" "${2:-}" <<'PY'
import json, os, sys, time
p, field = sys.argv[1], sys.argv[2]
flag = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    d = json.load(open(p))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
if field == "last_ping":
    d["ping_fail_streak"] = 0
    d.pop("needs_login_since", None)
else:
    try:
        d["ping_fail_streak"] = int(d.get("ping_fail_streak", 0) or 0) + 1
    except Exception:
        d["ping_fail_streak"] = 1
    if flag == "needs_login" and not d.get("needs_login_since"):
        d["needs_login_since"] = int(time.time())
d[field] = int(time.time())
tmp = p + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    json.dump(d, f); f.flush(); os.fsync(f.fileno())
os.replace(tmp, p)
PY
  }

  if ! CLAUDE="$(claude_bin)"; then
    err "Ping deferred: could not resolve an executable 'claude' binary (transient); will retry."
    _v2_mark last_ping_failed || true
    exit 1
  fi
  echo "Pinging v2 READY home for $v2_target (model $MODEL, 60s cap)…"
  # (r12 sweep-c) strip alt-auth env so the turn bills the HOME's OAuth, never an inherited
  # ANTHROPIC_API_KEY / Bedrock/Vertex identity. CLAUDE_CONFIG_DIR is kept (not in the list).
  # (v105) The turn's output was previously discarded (>/dev/null 2>&1), which meant a
  # home with NO credential looked identical to a network blip — so auto-ping retried a
  # hopeless home every ~10 min indefinitely (60 consecutive failures observed 11-13 Aug
  # 2026, both homes, ~33h). Capture it 0600, classify, then discard. The raw text is
  # NEVER logged or echoed; only the category escapes this block.
  _out="$(mktemp "${TMPDIR:-/tmp}/.abping.XXXXXX")" || _out=""
  [ -n "$_out" ] && chmod 600 "$_out" 2>/dev/null
  if CLAUDE_CONFIG_DIR="$HOME_PATH" run_with_timeout 60 /usr/bin/env $(_auth_env_u_args) "$CLAUDE" -p "reply with just: ok" --model "$MODEL" </dev/null >"${_out:-/dev/null}" 2>&1; then
    [ -n "$_out" ] && rm -f "$_out"
    if ! _v2_mark last_ping; then err "Ping ran but the cooldown marker write FAILED; treating as failed."; exit 1; fi
    echo "Ping OK — 5h window started for $v2_target (home $HOME_PATH)."
    release_lock; trap - EXIT INT TERM HUP PIPE
    exit 0
  else
    rc=$?
    # "Not logged in · Please run /login" = the config dir holds no credential at all.
    # Unlike a server-side OAuth rejection this is not ambiguous and not transient, but
    # an ambiguous response (403 / 429 / network / timeout) still vetoes the verdict —
    # same fail-closed posture as isolated_refresh.AUTH_TRANSIENT_MARKERS.
    _flag=""
    if [ -n "$_out" ] && [ -s "$_out" ]; then
      if grep -qiE 'not logged in|please run /login' "$_out" 2>/dev/null \
         && ! grep -qiE '403|forbidden|not permitted|429|rate.?limit|overloaded|timeout|timed out|network|connection|temporarily' "$_out" 2>/dev/null; then
        _flag="needs_login"
      fi
    fi
    [ -n "$_out" ] && rm -f "$_out"
    if [ "$_flag" = "needs_login" ]; then
      err "Ping failed: $v2_target's home has NO credential — run /login for it (auto-ping will stand down until it succeeds)."
    else
      err "Ping failed (v2 home turn exited rc $rc; output redacted)."
    fi
    _v2_mark last_ping_failed "$_flag" || true
    exit 1
  fi
fi

# We already hold the lock (re-review issue 2): tell reconcile so it does NOT try
# to self-acquire and get success-on-contention. Any nonzero result (10 =
# unresolved torn swap, or an unexpected error) BLOCKS the mutation (issue 3).
ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/reconcile.py"; rcrc=$?
if [ "$rcrc" -ne 0 ]; then
  err "ping: reconcile did not complete cleanly (rc $rcrc); refusing to ping until resolved."
  exit 1
fi

# resolve target UNDER the lock
if [ -z "$arg" ] || [ "$arg" = "--active" ]; then
  target="$(active_email)"
  [ -z "$target" ] && { err "Could not determine active account."; exit 1; }
else
  target="$arg"
fi

tf="$(bank_file_for "$target")" || { err "ping: refusing unsafe target email '$target'."; exit 2; }
[ -f "$tf" ] || { err "Account '$target' is not in the bank. Bank it first (bank-account.sh)."; exit 1; }

# status + cooldowns, read under the lock via the VALIDATED loader (finding #39):
# a malformed record is refused up front rather than defaulted-through and later
# clobbered by a marker write.
read -r status last_ping last_ping_failed <<EOF
$(python3 - "$HERE" "$tf" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import bank_common
br = bank_common.load_bank_record(sys.argv[2])
if not br.ok:
    sys.stderr.write(f"__INVALID__ {br.reason}\n")
    print("__INVALID__ 0 0")
    sys.exit(0)
rec = br.record
print(rec.get("status", "ok"), rec.get("last_ping", 0), rec.get("last_ping_failed", 0))
PY
)
EOF
if [ "$status" = "__INVALID__" ]; then
  err "Account '$target' has a malformed bank record; refusing to ping (re-bank it)."
  exit 1
fi
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

# (#2/#41) re-derive active UNDER the lock, immediately before choosing a path
active="$(active_email)"

# Marker writers (finding #39): route through the VALIDATED loader so a malformed
# active bank record can NEVER be replaced by a marker-only {"last_ping":...} that
# deletes the credentials. On a parse/schema failure they REFUSE (exit 2). They
# also fsync and the caller checks their exit status — no silent marker failure.
_marker_py="$HERE/_ping_marker.py"
# (r6 b10) the marker writer is a v1 record mutator: pass the lock-acquire epoch snapshot
# (set by acquire_lock in THIS shell) so _ping_marker.py's v1-gate + generation fence can
# refuse a stamp under a moved epoch (flip/seed), exactly like kc_write. rc 78 = fenced.
set_last_ping()        { ACCOUNT_BANK_EPOCH_SNAP="$EPOCH_SNAP" python3 "$_marker_py" "$tf" "$nowsec" success; }
set_last_ping_failed() { ACCOUNT_BANK_EPOCH_SNAP="$EPOCH_SNAP" python3 "$_marker_py" "$tf" "$nowsec" failed; }
mark_needs_relogin()   { ACCOUNT_BANK_EPOCH_SNAP="$EPOCH_SNAP" python3 "$_marker_py" "$tf" "$nowsec" needs-relogin; }

ok=0
if [ "$target" = "$active" ]; then
  # (r2 new blocker) the active-ping launches a keychain-backed real claude — a v1
  # keychain-touching operation. In v2 the shared keychain is bypassed (sessions are
  # pinned to per-home config dirs), so this path must be REFUSED by the epoch gate,
  # exactly like every other v1 keychain toucher. rc 78 = fenced, nothing launched.
  if ! python3 "$_LIB_HERE/epoch.py" v1-gate "$BANK_DIR" 2>/dev/null; then
    err "ping: active-ping refused — epoch is not v1/shadow (v2 pins sessions to homes, not the shared keychain)."
    exit 78
  fi
  echo "Pinging ACTIVE account $target (model $MODEL, 60s cap)…"
  # </dev/null: never block on stdin in non-tty contexts (GUI app, hooks).
  # Absolute path: bare `claude` is not on PATH under the QuotaBar GUI app (rc 127).
  # An unresolved binary is a TRANSIENT failure (finding #3/#5): defer with the
  # 5-min failure cooldown, never treat it as a dead account.
  if ! CLAUDE="$(claude_bin)"; then
    err "Ping deferred: could not resolve an executable 'claude' binary (transient). Set ACCOUNT_BANK_CLAUDE_BIN or check the install; will retry."
    set_last_ping_failed || true
    exit 1
  fi
  # (#41) verify the active identity IMMEDIATELY before execution: a /login could
  # have switched the active account after our earlier read. If so, the turn would
  # bill a different account than the one we'd stamp — abort instead.
  pre_active="$(active_email)"
  if [ "$pre_active" != "$target" ]; then
    err "Aborting ping: active account changed to '${pre_active:-none}' before execution; not billing/stamping $target."
    exit 1
  fi
  # (r5 #4) BIND identity via the SINGLE fail-closed resolver. The turn bills
  # whoever the KEYCHAIN authenticates as, not whoever metadata names, so we stamp
  # $target's cooldown ONLY when the live keychain credential RESOLVES to exactly
  # $target: its fingerprint matches $target's CURRENT bank record AND metadata
  # names $target. Every UNRESOLVED state aborts with NO bill/stamp — a keychain-
  # first /login holding another OR an unbanked account (r4 #8's residual, now
  # closed), an ambiguous match, or $target's own token having drifted ahead of its
  # bank record (benign drift is offline-indistinguishable from an intruding login,
  # so it too fails closed here; re-bank $target to re-sync). Capture the live blob
  # ONCE so the post-turn check re-verifies the SAME credential.
  live_blob="$(kc_read)"
  if [ "$(printf '%s' "$live_blob" | resolve_identity "$(active_email)")" != "$target" ]; then
    err "Aborting ping: could not bind the live keychain to '$target' (identity UNRESOLVED —"
    err "another/unbanked account, ambiguous, or a token drifted from the bank record; a"
    err "/login may be in progress). Not billing/stamping $target. Re-bank $target if it is"
    err "genuinely active (bash $HERE/bank-account.sh)."
    exit 1
  fi
  pre_cred_fp="$(printf '%s' "$live_blob" | _cred_fp)"
  # (#38) ONE shared wall-clock deadline across the requested-model + fallback
  # attempts, so the lock is never held for ~2x the advertised cap.
  deadline=$(( $(now_epoch) + 60 ))
  # (re-review issue 14) discard the child's raw output — it must never reach the
  # terminal or the autoping log (it can contain arbitrary text). We key only off
  # the exit code and emit redacted categories.
  # (r12 sweep-c) strip alt-auth env so the active ping bills the KEYCHAIN identity we
  # verified, never an inherited ANTHROPIC_API_KEY / Bedrock/Vertex credential.
  run_with_timeout 60 /usr/bin/env $(_auth_env_u_args) "$CLAUDE" -p "reply with just: ok" --model "$MODEL" </dev/null >/dev/null 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    rem=$(( deadline - $(now_epoch) )); [ "$rem" -lt 1 ] && rem=1
    run_with_timeout "$rem" /usr/bin/env $(_auth_env_u_args) "$CLAUDE" -p "reply with just: ok" </dev/null >/dev/null 2>&1; rc=$?
  fi
  if [ $rc -eq 0 ]; then
    # (r5 #4) re-verify identity via the SAME resolver before ATTRIBUTION: if a
    # /login switched the active account OR the live credential moved during the
    # turn (metadata email can read == target both before and after a fast turn
    # while the keychain — and thus the account actually billed — is different), the
    # started 5h window does not belong to $target. Only a clean re-resolution to
    # $target permits the stamp.
    if [ "$(resolve_active_identity)" != "$target" ]; then
      err "Ping ran but the live identity no longer resolves to $target (a /login"
      err "transition, or the token drifted during the turn); the started 5h window may"
      err "belong to another account. NOT stamping $target."
      exit 1
    fi
    echo "Ping OK — 5h window started for $target."
    if ! set_last_ping; then err "Ping ran but the cooldown marker write FAILED; treating as failed."; exit 1; fi
    ok=1
  else
    err "Ping failed (active turn exited rc $rc; output redacted)."; set_last_ping_failed || true; exit 1
  fi
else
  echo "Pinging PARKED account $target via isolated profile (model $MODEL, 60s cap)…"
  # isolated_refresh.py runs the turn in a throwaway config dir, writes a recovery
  # journal on rotation, then commits rotated creds to the bank. exit 3 = dead
  # token. We already hold the lock, so tell it not to re-acquire (finding #25).
  # (issue 14) its stderr is our OWN redacted status lines (never raw claude
  # output), but we still discard it rather than echo it into the autoping log.
  if ACCOUNT_BANK_HOLDS_LOCK=1 python3 "$HERE/isolated_refresh.py" "$tf" >/dev/null 2>&1; then
    echo "Ping OK — 5h window started for $target."
    if ! set_last_ping; then err "Ping ran but the cooldown marker write FAILED; treating as failed."; exit 1; fi
    ok=1
  else
    rc=$?
    if [ $rc -eq 3 ]; then
      if ! mark_needs_relogin; then
        err "Ping: token confirmed dead but the needs-relogin marker write FAILED (record malformed?)."
      fi
      err "Ping failed: $target's parked token is dead (confirmed auth rejection / refresh token expired). Marked needs-relogin."
      err "Run /login in Claude Code, pick $target, then: bash $HERE/bank-account.sh"
    elif [ $rc -eq 6 ]; then
      # transient (resolver/launch/timeout/non-auth nonzero): token untouched,
      # account stays retriable — do NOT mark needs-relogin (finding #1).
      err "Ping deferred: transient failure (rc 6); $target's token is untouched and will be retried."
    else
      err "Ping failed (rc $rc)."
    fi
    set_last_ping_failed || true
    exit 1
  fi
fi

# release the lock BEFORE refreshing the cache — usage.py needs to take the lock.
release_lock; trap - EXIT INT TERM HUP PIPE
if [ "$ok" -eq 1 ]; then
  # (#40) force a FRESH poll of exactly this target so the cache reflects the new
  # 5h window immediately, instead of serving the old lapsed reset for up to 30m
  # while claiming "refreshed".
  ACCOUNT_BANK_FORCE_FRESH="$target" python3 "$HERE/usage.py" >/dev/null 2>&1 || true
  echo "Usage cache refreshed."
fi
