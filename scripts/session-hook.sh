#!/bin/bash
# session-hook.sh <kind> — the SHARED lifecycle hook entrypoint (rev 7 §13).
# Wired into settings.json at shadow/cutover as:
#   SessionStart          -> session-hook.sh start
#   UserPromptSubmit      -> session-hook.sh prompt
#   Notification          -> session-hook.sh notify   (idle_prompt => idle edge)
#   Stop                  -> session-hook.sh stop     (advisory only)
#   SessionEnd            -> session-hook.sh end
#
# Semantics (rev 7 §0/§13):
#  - Only MANAGED sessions (CLAUDE_CONFIG_DIR under accounts/homes/) are tracked;
#    everything else exits 0 untouched — except the v2 escaped-launch telemetry:
#    EPOCH v2 + no config dir -> loud stderr banner (detection net, §8).
#  - prompt: FAIL-CLOSED (r6): if BUSY cannot be persisted, exit 2 (block) with an
#    explanation. Also blocks (2) while the session's RESTARTING lease is held.
#  - notify: only the idle_prompt notification flips IDLE; others ignored.
#  - never prints token material; hook stdin JSON is consumed, not stored.
set -u
KIND="${1:-}"
ACC="${ACCOUNT_BANK_DIR:-$HOME/.claude/accounts}"
# (r12 #1 / sweep-a) resolve the scripts dir from THIS hook's own location (env override,
# else self-dir, else legacy). The hooks fragment invokes us by absolute path, so self-dir
# is where our sibling sessions.py / epoch.py live — the legacy default bricked a clean
# XDG install (every prompt then hit a nonexistent sessions.py and blocked).
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
SCRIPTS="${ACCOUNT_BANK_SCRIPTS_DIR:-$_SELF_DIR}"
[ -f "$SCRIPTS/sessions.py" ] || SCRIPTS="$HOME/.claude/scripts/account-bank"
# (r3 IB3) the originating process pid for this hook. In production it is the claude
# process (PPID), constant for a session's lifetime, so lifecycle events bind to it and
# a DELAYED predecessor event (different pid) is ignored. ACCOUNT_BANK_HOOK_PID overrides
# for embedding/testing where PPID is not the claude pid.
HOOK_PID="${ACCOUNT_BANK_HOOK_PID:-${PPID:-0}}"

IN="$(cat 2>/dev/null || true)"
jget() { printf '%s' "$IN" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
v=d
for k in sys.argv[1:]:
    v=v.get(k,{}) if isinstance(v,dict) else {}
print(v if isinstance(v,str) else '')" "$@" 2>/dev/null; }

SID="$(jget session_id)"
CFG="${CLAUDE_CONFIG_DIR:-}"

# escaped-launch telemetry (§8): v2 world, unmanaged default launch
if [ -z "$CFG" ] && [ "$KIND" = "start" ]; then
    ST="$(python3 "$SCRIPTS/epoch.py" snapshot "$ACC" 2>/dev/null || echo v1 0)"
    if [ "${ST%% *}" = "v2" ]; then
        echo "⚠ QuotaBar v2: this claude session BYPASSED the account shim and is" >&2
        echo "  using the shared keychain. Launch via 'claude' (shim) or claude-acct." >&2
    fi
    exit 0
fi

# managed sessions only
case "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${CFG:-/nonexistent}")" in
    "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ACC")"/homes/*) : ;;
    *) exit 0 ;;
esac
[ -n "$SID" ] || exit 0

# (r12 #1 / r13 #3) a MANAGED session whose helpers are MISSING is a BROKEN INSTALL. Rev 9
# requires BUSY persistence to fail CLOSED: a `prompt` that cannot record BUSY must BLOCK (exit
# 2), else a restart controller still sees the session IDLE and can SIGTERM it mid-turn. But we
# may fail OPEN only when NO registered session can exist in this state — i.e. NO session
# registry (sessions.json) is present, so no controller can target anything. Precise rule:
#   * prompt + a registry EXISTS  -> BLOCK (exit 2), fail-closed.
#   * prompt + NO registry        -> fail OPEN (exit 0); nothing can be restarted.
#   * any other kind              -> exit 0 (it cannot cause a mid-turn SIGTERM).
# All paths surface the broken install LOUDLY.
if [ ! -f "$SCRIPTS/sessions.py" ]; then
    echo "QuotaBar: session-hook.sh cannot find sessions.py under '$SCRIPTS' (broken/incomplete" >&2
    echo "  install); session lifecycle tracking is DISABLED here. Reinstall or set ACCOUNT_BANK_SCRIPTS_DIR." >&2
    if [ "$KIND" = "prompt" ] && [ -f "$ACC/sessions.json" ]; then
        echo "QuotaBar: BLOCKING this prompt (fail-closed): cannot persist BUSY while a session" >&2
        echo "  registry exists — a restart controller could SIGTERM this session mid-turn." >&2
        exit 2
    fi
    exit 0
fi

case "$KIND" in
    start)
        # (finding 33) build the payload with json.dumps so a cwd/transcript path
        # containing quotes/backslashes/newlines cannot produce invalid JSON (which
        # would silently leave the session unregistered).
        python3 -c '
import json, sys
print(json.dumps({"home": sys.argv[1], "cwd": sys.argv[2],
                  "pid": int(sys.argv[3] or 0), "transcript": sys.argv[4]}))' \
            "$CFG" "$(jget cwd)" "$HOOK_PID" "$(jget transcript_path)" \
            | python3 "$SCRIPTS/sessions.py" event "$ACC" start "$SID" || true
        exit 0 ;;
    prompt)
        # (finding 8) ONE atomic call contends for the restart lease AND records BUSY
        # under the sessions lock — no check-then-write gap for restart to slip into.
        # (r3 IB3) pass PPID so a delayed predecessor prompt can't mutate the successor.
        python3 "$SCRIPTS/sessions.py" prompt-admit "$ACC" "$SID" "$HOOK_PID" </dev/null; rc=$?
        [ $rc -eq 2 ] && exit 2                       # blocked by RESTARTING lease
        if [ $rc -ne 0 ]; then
            # fail-closed BUSY persistence (r6): cannot record BUSY => block the prompt
            echo "QuotaBar: could not record session activity (fail-closed); prompt blocked. Check accounts dir health." >&2
            exit 2
        fi
        exit 0 ;;
    notify)
        # only the idle_prompt notification is the IDLE edge. (r3 IB3) bind to PPID so a
        # DELAYED predecessor idle can't mark the active successor IDLE (restartable).
        NT="$(jget notification_type)"
        [ -z "$NT" ] && NT="$(jget type)"
        if [ "$NT" = "idle_prompt" ]; then
            printf '{"pid":%s}' "$HOOK_PID" \
              | python3 "$SCRIPTS/sessions.py" event "$ACC" idle "$SID" || true
        fi
        exit 0 ;;
    stop)
        printf '{"pid":%s}' "$HOOK_PID" \
          | python3 "$SCRIPTS/sessions.py" event "$ACC" stop "$SID" || true
        exit 0 ;;
    end)
        # (r3 IB3) bind to PPID so a delayed predecessor `end` can't tombstone the successor.
        printf '{"pid":%s}' "$HOOK_PID" \
          | python3 "$SCRIPTS/sessions.py" event "$ACC" end "$SID" || true
        exit 0 ;;
    *)  exit 0 ;;
esac
