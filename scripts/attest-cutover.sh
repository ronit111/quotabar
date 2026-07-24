#!/bin/bash
# attest-cutover.sh — rev 9 §8 launch-surface attestation. Run BEFORE flipping to v2;
# ANY failing context => cutover ABORTS. This script only REPORTS (writes
# accounts/attestation.json); flip.py refuses shadow->v2 unless this exits 0 with a
# FRESH (<10 min) report (finding 28).
#
# "Surface" = every CONCRETE live launch context (r5/r6/finding 27): each live shell,
# the VS Code helper processes, every loaded launchd job AND crontab entry whose
# program invokes claude, and the exact running QuotaBar PID. Absolute-path invocation
# of the real binary is UNSUPPORTED-but-detected (SessionStart telemetry).
#
# This is a LIVE morning gate (it inspects the running system) — not part of the unit
# suite.
set -u
ACC="${ACCOUNT_BANK_DIR:-$HOME/.claude/accounts}"
SHIM="$ACC/bin/claude"
REPORT="$ACC/attestation.json"
fails=0; checks=()

note() {
    # note <check> <ok:true|false> <detail>
    # (flip-sitting #3) detail is embedded in the hand-assembled report JSON — escape
    # backslashes and double quotes, or an ack example like ATTEST_SHELLS_ACK="1 2"
    # corrupts the report (and a corrupt report also fails flip.py's parse gate).
    # (release-eve) control characters need escaping too: a detail carrying a raw
    # newline/CR/tab (a ps comm, a crontab line, a launchctl label) breaks the JSON
    # string just as a bare quote does. Escape backslashes FIRST, then quotes, then
    # the control chars — so the backslashes we introduce here are not re-escaped.
    local d="$3"
    d="${d//\\/\\\\}"
    d="${d//\"/\\\"}"
    d="${d//$'\n'/\\n}"
    d="${d//$'\r'/\\r}"
    d="${d//$'\t'/\\t}"
    checks+=("{\"check\":\"$1\",\"ok\":$2,\"detail\":\"$d\"}")
    [ "$2" = "false" ] && fails=$((fails+1))
    return 0
}

# (r5 item 3) match `claude` as a COMMAND TOKEN — an absolute/relative path ending in
# `claude`, OR a bare `claude` (relying on PATH). Preceded by start or a non-word char;
# followed by a non-word char that is NOT `-` (excludes claude-acct) and NOT `/`
# (excludes the `.claude/` directory component), or end-of-line. `claudexyz` never matches.
_CLAUDE_RE='(^|[^a-zA-Z0-9_])claude([^a-zA-Z0-9_/-]|$)'

# (r8 #14) The command-token regex above deliberately excludes `/` after `claude` (to
# skip the `.claude/` directory component) — but that also blinds it to DIRECT
# invocations of the real versioned binary / JS entrypoint, which bypass the shim just
# as effectively as a bare `claude`. These paths are the real CLI's install shapes:
#   .../claude/versions/<v>/...   (versioned binary tree)
#   ~/.claude/local/...           (local install — real `claude` + node_modules)
#   .../cli.js                    (the Claude Code JS entrypoint, run via `node`)
# Fail-closed on suspicion: a launchd/cron line hitting any of these is UNSHIMMED.
_REAL_ENTRY_RE='(claude/versions/|[.]claude/local/|/cli[.]js([^a-zA-Z0-9_]|$))'

# (r8 #13) _all_acked <ack-list> <pid...> — returns 0 iff EVERY pid argument appears as a
# whole token in the operator's ack list. A blanket ack (the old ATTEST_*_ACK=1) can no
# longer pass a set of live contexts: `1` matches only a pid literally 1 (init), so it
# fails closed. The operator must list each refreshed pid explicitly.
_all_acked() {
    local ack=" $1 "; shift
    local p
    for p in "$@"; do
        case "$ack" in *" $p "*) : ;; *) return 1 ;; esac
    done
    return 0
}

# (r6 b6) _has_unshimmed_claude — reads a definition on STDIN, returns 0 (true) iff ANY
# LINE invokes claude as a command token WITHOUT routing through the shim or claude-acct
# ON THAT SAME LINE. This is PER-LINE by construction: a safe `$SHIM`/`claude-acct` line
# elsewhere in the same definition can NEVER whitelist a bare-`claude` line — the old
# whole-definition grep accepted a direct `claude` as long as the shim appeared anywhere.
# (r10 #7) _filter_unshimmed_claude — reads definition lines on STDIN and PRINTS each line
# that STILL invokes claude as a real-binary/bare command token AFTER the SAFE tokens (the
# shim path, `claude-acct`) are removed from it. The old `grep -vF "$SHIM"` dropped the
# WHOLE line whenever it merely MENTIONED the shim, so `/opt/homebrew/bin/claude -p x; #
# .../accounts/bin/claude` (real invocation + a shim mention on the same line, after `;` or
# in a comment) passed clean. Stripping the tokens first, then testing the remainder, flags
# a real invocation on the same line while still clearing genuine shim/claude-acct lines.
_filter_unshimmed_claude() {
    local line stripped
    while IFS= read -r line; do
        stripped="$line"
        [ -n "$SHIM" ] && stripped="${stripped//$SHIM/}"   # fixed-string strip of the shim path
        stripped="${stripped//claude-acct/}"               # and of the claude-acct wrapper token
        # (flip-sitting #2) and of the reverse-DNS label component: every job of ours is
        # labelled com.claude.<name>, and the bare `claude` between the dots matched the
        # command-token regex, flagging every plist/loaded label BY NAME. A domain prefix
        # can never invoke the binary; a real path (…/bin/claude) never contains it, so a
        # genuine invocation on the same line still matches after the strip.
        stripped="${stripped//com.claude./}"
        printf '%s\n' "$stripped" | grep -Eq "$_CLAUDE_RE|$_REAL_ENTRY_RE" && printf '%s\n' "$line"
    done
}

# (flip-sitting #2) strip XML comment spans (<!-- … -->, multi-line) before scanning a raw
# plist: comments are inert — they cannot invoke anything — and ours mention "~/.claude
# commits"/"~/.claude sync" as prose, which the token regex matched. PlistBuddy output and
# launchctl print carry no XML comments, so this applies only to the raw-plist cat.
# (release-eve) FAIL CLOSED on an UNTERMINATED comment. The old stripper suppressed
# everything after a `<!--` that never closed, so a single unbalanced comment anywhere
# in a plist hid every Program/ProgramArguments/EnvironmentVariables line below it from
# the scan — a malformed plist could silently pass the gate while invoking the real
# binary. Hold the suppressed span in a buffer and, if EOF arrives with the comment
# still open, emit it: an unclosed comment is not evidence that the text is inert, so
# the scanner gets to see it. A genuinely closed comment still emits nothing.
_strip_xml_comments() {
    awk 'BEGIN{inc=0; held=""}
    {
        line=$0; out=""
        while (1) {
            if (!inc) {
                i=index(line,"<!--")
                if (i) { out=out substr(line,1,i-1); line=substr(line,i+4); inc=1; held="" }
                else   { out=out line; break }
            } else {
                j=index(line,"-->")
                if (j) { held=""; line=substr(line,j+3); inc=0 }
                else   { held=held line "\n"; break }
            }
        }
        print out
    }
    END {
        if (inc) printf "%s", held
    }'
}

# (release-eve) _nondescendant_shell_pids <root-pid> — PURE: reads a `pid ppid comm`
# table on STDIN and prints the shell PIDs that are NOT <root-pid> and NOT any of its
# transitive descendants. Extracted from the live probe below so the walk is testable
# without a running system. Rows may arrive in ANY order (ps output is not topological):
# the fixpoint loop keeps sweeping until no new descendant is added, and terminates
# because `keep` only ever grows and is bounded by the row count.
_nondescendant_shell_pids() {
    awk -v root="$1" '
    { pid[NR]=$1; pp[NR]=$2; cm[NR]=$3 }
    END {
        keep[root]=1; changed=1
        while (changed) { changed=0
            for (i=1;i<=NR;i++) if (!(pid[i] in keep) && (pp[i] in keep)) { keep[pid[i]]=1; changed=1 } }
        for (i=1;i<=NR;i++) if (!(pid[i] in keep) && cm[i] ~ /(zsh|bash)$/) printf "%s ", pid[i]
    }' | sed 's/ *$//'
}

_has_unshimmed_claude() {
    _filter_unshimmed_claude | grep -q .
}

# 1. shim installed + executable + resolves a REAL binary. (finding 27) the probe
#    exit code is captured cleanly: 67 = shim ran but could NOT resolve a real CLI
#    (a real failure); any other code means the shim resolved and exec'd one.

# (release-eve) REFUSE to run the live gate when SOURCED — this is a GATE BYPASS, not a
# style nit. Sourced, `$$` is the OPERATOR'S OWN SHELL, so the self-exclusion walk below
# treats that shell and every descendant of it as "this attestation run" and drops them
# from the live-shells enumeration. Every terminal the operator is actually working in
# vanishes from the gate and `live-shells` passes with zero unacknowledged shells — the
# exact stale-PATH population the check exists to catch. Everything ABOVE this line is
# pure definitions (tests/test_attest.sh sources a copy truncated here, so the guard is
# absent from that copy and the truncated-source pattern keeps working).
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    echo "attest-cutover.sh: refusing to run the live gate when sourced — \$\$ would be your own shell," >&2
    echo "  which the self-exclusion walk would drop from the live-shells enumeration (gate bypass)." >&2
    echo "  Run it as a command instead:  bash attest-cutover.sh" >&2
    return 2 2>/dev/null || exit 2
fi

if [ -x "$SHIM" ]; then
    # (r13 #9) run the probe with a SANITIZED env (no inherited CLAUDE_ACCT_SHIM / CLAUDE_CONFIG_DIR
    # that would make the shim exit 66 pre-resolution) and treat ONLY the documented success rc
    # (0 = real binary resolved) as a pass — fail closed on ANY other code. The old check accepted
    # every rc except 67, so an inherited marker's 66 was a false PASS that could authorize cutover.
    env -u CLAUDE_ACCT_SHIM -u CLAUDE_CONFIG_DIR "$SHIM" --account-bank-attest-probe </dev/null >/dev/null 2>&1
    probe_rc=$?
    if [ "$probe_rc" -eq 0 ]; then
        note "shim-installed" true "$SHIM resolves a real binary (probe rc 0)"
    else
        note "shim-installed" false "shim did NOT resolve a real claude binary (probe rc $probe_rc; expected 0)"
    fi
else
    note "shim-installed" false "missing/not executable at $SHIM"
fi

# 2. a FRESH login shell resolves `claude` to the shim (PATH order)
RES="$(/bin/zsh -lc 'command -v claude' 2>/dev/null)"
if [ "$RES" = "$SHIM" ]; then
    note "zsh-login-shell" true "$RES"
else
    note "zsh-login-shell" false "resolves to ${RES:-nothing}, not the shim"
fi

# 3. every LIVE interactive shell (finding 27): enumerate zsh/bash processes. macOS has
#    no /proc, so a running shell's cached PATH cannot be verified from outside — this
#    is a REAL gate, not a silent pass: any live shell FAILS the attestation unless the
#    operator has confirmed each was refreshed (`hash -r` / new tab) via
#    ATTEST_SHELLS_ACK=1. The PIDs are listed so the operator can audit them.
# (flip-sitting #1) exclude the attestation run ITSELF ($$ + descendants) from the
# enumeration: this bash process and the transient $(...)/pipeline subshells it forks
# die with the script and can never launch a stale claude — but their PIDs are
# unknowable before launch, so counting them made the gate unpassable (no ack list
# could ever be complete). One ps snapshot feeds BOTH the descendant walk and the
# shell match, so a subshell forked for this very capture is in its own snapshot and
# excluded, and nothing spawned later can slip between two snapshots. The operator's
# invoking shell is $$'s PARENT — not a descendant — so it stays in the gate.
# (release-eve) the walk itself is _nondescendant_shell_pids (pure, table-tested above).
LIVE_SHELL_PIDS="$(ps -axo pid=,ppid=,comm= | _nondescendant_shell_pids $$)"
LIVE_SHELLS="$(printf '%s' "$LIVE_SHELL_PIDS" | wc -w | tr -d ' ')"
# (r8 #13) EVERY live shell pid must be individually acknowledged in ATTEST_SHELLS_ACK
# (a space/comma-separated pid list). A single blanket flag can no longer pass two shells
# when only one was refreshed — the stale one would keep its cached PATH and bypass the
# shim after cutover. Fail-closed: any unlisted live pid fails the gate.
_SHELLS_ACK="$(printf '%s' "${ATTEST_SHELLS_ACK:-}" | tr ',' ' ')"
if [ "$LIVE_SHELLS" -eq 0 ] || _all_acked "$_SHELLS_ACK" $LIVE_SHELL_PIDS; then
    note "live-shells" true "$LIVE_SHELLS live shell(s) [$LIVE_SHELL_PIDS]; each operator-acknowledged refreshed"
else
    note "live-shells" false "$LIVE_SHELLS live shell(s) not all confirmed refreshed [$LIVE_SHELL_PIDS] — run 'hash -r'/new tabs, then re-run with ATTEST_SHELLS_ACK listing EVERY pid (e.g. ATTEST_SHELLS_ACK=\"$LIVE_SHELL_PIDS\")"
fi

# 4. VS Code integrated-terminal hosts (finding 27): enumerate the helper processes.
#    Same limitation — their inherited PATH cannot be inspected from outside, so any
#    running host FAILS unless operator-acknowledged (ATTEST_VSCODE_ACK=1).
VSCODE_PIDS="$(ps -axo pid=,command= | grep -iE 'Code Helper|Visual Studio Code' | grep -v grep | awk '{print $1}' | tr '\n' ' ' | sed 's/ *$//')"
VSCODE_N="$(printf '%s' "$VSCODE_PIDS" | wc -w | tr -d ' ')"
# (r8 #13) same per-PID discipline for VS Code helper hosts — a blanket ack cannot pass
# a set of windows when only some were reloaded.
_VSCODE_ACK="$(printf '%s' "${ATTEST_VSCODE_ACK:-}" | tr ',' ' ')"
if [ "$VSCODE_N" -eq 0 ] || _all_acked "$_VSCODE_ACK" $VSCODE_PIDS; then
    note "vscode-hosts" true "$VSCODE_N VS Code helper(s); each acknowledged or none running"
else
    note "vscode-hosts" false "$VSCODE_N VS Code helper(s) running — close/reload windows, then re-run with ATTEST_VSCODE_ACK listing EVERY pid (e.g. ATTEST_VSCODE_ACK=\"$VSCODE_PIDS\")"
fi

# 5. launchd jobs whose program line invokes claude directly (finding 27): inspect the
#    REAL ProgramArguments of every on-disk job AND every LOADED job (launchctl list),
#    not one literal string — a loaded job with no on-disk plist would otherwise hide.
BAD_JOBS=""
for plist in ~/Library/LaunchAgents/*.plist /Library/LaunchAgents/*.plist /Library/LaunchDaemons/*.plist; do
    [ -e "$plist" ] || continue
    # (r6 b6) inspect the resolved ProgramArguments AND the raw plist, PER LINE: flag the
    # job iff a claude-invoking line is not itself a shim/claude-acct line. A safe line
    # elsewhere in the same plist no longer whitelists a direct-`claude` line.
    if { /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$plist" 2>/dev/null; cat "$plist" 2>/dev/null | _strip_xml_comments; } \
         | _has_unshimmed_claude; then
        BAD_JOBS="$BAD_JOBS $(basename "$plist")"
    fi
done
# (r4 #27) LOADED jobs: inspect EVERY loaded label with the DOMAIN-QUALIFIED
# `launchctl print gui/<uid>/<label>`, which reports the full argv + environment
# (`launchctl list <label>` does NOT reliably expose the command line). Also probe the
# system domain for daemons. Flag any real-binary claude invocation not routed through
# the shim / claude-acct.
_UID="$(id -u)"
UNPRINTABLE=""
ENUM_FAIL=""
# (r6 b7) attest the GUI and SYSTEM launchd contexts INDEPENDENTLY. A label is ambiguous
# across domains, so a printable gui/<uid>/<label> must NOT stand in for (and hide) a
# same-label system/<label> — we enumerate each context separately, never dedup a label
# ACROSS contexts, and inspect each in its OWN domain (no `gui || system` fallback).
# Enumerating a context is itself part of the gate: a FAILED enumeration is a FAIL, never
# an empty passing set (the old code let an unlistable domain collapse to "no jobs").
_gui_raw="$(launchctl print "gui/$_UID" 2>/dev/null)"; _gui_rc=$?
_sys_raw="$(launchctl print system 2>/dev/null)";      _sys_rc=$?
if [ "$_gui_rc" -ne 0 ] || [ -z "$_gui_raw" ]; then ENUM_FAIL="$ENUM_FAIL gui/$_UID"; fi
if [ "$_sys_rc" -ne 0 ] || [ -z "$_sys_raw" ]; then ENUM_FAIL="$ENUM_FAIL system"; fi
# (r8) parse the LOADED "services = {" table (rows: PID exit-status label), NOT the
# "disabled services = {" override map (rows: "label" => enabled|disabled). The old
# `=> ` awk matched the disabled map — enumerating known/disabled overrides, not
# actually-loaded jobs — and its quoted labels could never be printed.
_svc_labels() {
    printf '%s\n' "$1" | awk '
        /^[[:space:]]*services = \{/       { in_svc=1; next }
        in_svc && /^[[:space:]]*\}/        { in_svc=0 }
        in_svc && NF >= 3                  { print $3 }
    '
}
_gui_labels="$(_svc_labels "$_gui_raw")"
_sys_labels="$(_svc_labels "$_sys_raw")"
while IFS='	' read -r ctx label; do
    [ -n "$label" ] || continue
    def="$(launchctl print "$ctx/$label" 2>/dev/null)"
    if [ -z "$def" ]; then
        # (r5 item 3) an attested surface MUST be inspectable — an unprintable loaded job
        # is a FAIL, never a silent skip (it could be invoking the real binary invisibly).
        case " $UNPRINTABLE " in *" $ctx/$label "*) : ;; *) UNPRINTABLE="$UNPRINTABLE $ctx/$label" ;; esac
        continue
    fi
    # (r6 b6) PER-LINE claude-token match: a same-label safe line never whitelists a
    # bare-claude line in the same definition.
    if printf '%s\n' "$def" | _has_unshimmed_claude; then
        case " $BAD_JOBS " in *" $ctx/$label "*) : ;; *) BAD_JOBS="$BAD_JOBS $ctx/$label" ;; esac
    fi
done < <( { printf '%s\n' "$_gui_labels" | sed "s#^#gui/$_UID	#"; \
           printf '%s\n' "$_sys_labels" | sed "s#^#system	#"; } | grep -v '	$' )
if [ -n "$ENUM_FAIL" ]; then
    note "launchd-jobs" false "could not enumerate launchd context(s):$ENUM_FAIL (an attested surface must be enumerable; run with sufficient privileges)"
elif [ -n "$BAD_JOBS" ]; then
    note "launchd-jobs" false "direct real-binary invocations:$BAD_JOBS"
elif [ -n "$UNPRINTABLE" ]; then
    note "launchd-jobs" false "loaded job(s) could not be inspected (attested surface must be printable):$UNPRINTABLE"
else
    note "launchd-jobs" true "every on-disk plist + gui/system loaded job inspected independently; none invokes the real binary directly"
fi

# 6. crontab entries invoking claude directly (finding 27: cron was absent). Same
#    command-token regex as the launchd inspection (catches bare + path claude).
# (r6 b6) PER-LINE and fixed-string: an uncommented crontab line invokes claude as a
# command token but is NOT itself a shim/claude-acct line. A safe cron line elsewhere no
# longer whitelists a bare-`claude` line. -F on $SHIM guards against path metacharacters.
# (r10 #7) route cron through the same token-strip filter so a real-binary invocation on a
# line that also mentions the shim/claude-acct is still caught.
CRON_BAD="$(crontab -l 2>/dev/null | grep -vE '^[[:space:]]*#' | _filter_unshimmed_claude | sed 's/[[:space:]]\{1,\}/ /g' | head -5 | tr '\n' ';')"
[ -z "$CRON_BAD" ] && note "cron-jobs" true "no crontab entry invokes the real binary directly" \
                  || note "cron-jobs" false "crontab invokes real binary: $CRON_BAD"

# 7. old QuotaBar process gone (bundle swap does NOT kill the old app). (r2 finding 27)
#    Validate the RUNNING pid's CONTEXT, not the on-disk bundle: an epoch-aware
#    QuotaBar writes accounts/quotabar.runtime.json {pid, epoch_aware:true} at launch.
#    The live pid must MATCH that marker AND be epoch-aware — otherwise the OLD
#    (pre-cutover) app is still in memory even though the new bundle is on disk.
QB_PIDS="$(pgrep -x QuotaBar | tr '\n' ' ' | sed 's/ *$//' || true)"
if [ -n "$QB_PIDS" ]; then
    # (r3 #27) EVERY live QuotaBar pid must match the epoch-aware runtime marker. A single
    # matching pid is NOT enough — a second (old, pre-cutover) pid still in memory must
    # fail the gate. Collect the unmatched ones.
    bad_qb=""
    for pid in $QB_PIDS; do
        m="$(python3 - "$ACC/quotabar.runtime.json" "$pid" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("1" if str(d.get("pid")) == sys.argv[2] and d.get("epoch_aware") is True else "0")
except Exception:
    print("0")
PY
)"
        [ "$m" = "1" ] || bad_qb="$bad_qb $pid"
    done
    if [ -z "$bad_qb" ]; then
        note "quotabar-process" true "every live QuotaBar pid ($QB_PIDS) matches the epoch-aware runtime marker"
    else
        note "quotabar-process" false "QuotaBar pid(s)$bad_qb do NOT match an epoch-aware runtime marker (old app still in memory?) — quit + relaunch the new build"
    fi
else
    # (r4 #27) §8 requires the QuotaBar process to be RESTARTED and runtime-attested as
    # part of cutover — its ABSENCE is NOT a pass. A cutover with no running epoch-aware
    # QuotaBar means the app was never relaunched into the new build.
    note "quotabar-process" false "QuotaBar is NOT running — §8 requires it to be restarted into the epoch-aware build and runtime-attested; launch it before cutover"
fi

# 8. archiver daemon loaded + heartbeat fresh
if launchctl list 2>/dev/null | grep -q com.quotabar.archiver; then
    AGE=$(python3 - "$ACC" <<'PY'
import json,sys,time,os
p=os.path.join(sys.argv[1],"archiver.status.json")
try: print(int(time.time()-json.load(open(p))["ts"]))
except Exception: print(99999)
PY
)
    [ "$AGE" -lt 30 ] && note "archiver" true "heartbeat ${AGE}s" || note "archiver" false "heartbeat stale (${AGE}s)"
else
    note "archiver" false "launchd job not loaded"
fi

printf '{"ts": %s, "fails": %s, "checks": [%s]}\n' "$(date +%s)" "$fails" "$(IFS=,; echo "${checks[*]}")" > "$REPORT"
cat "$REPORT" | python3 -m json.tool
[ "$fails" -eq 0 ] && echo "ATTESTATION PASS" || echo "ATTESTATION FAIL ($fails) — cutover must not proceed"
exit "$fails"
