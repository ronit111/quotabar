#!/usr/bin/env bash
# QuotaBar installer.
#
# (release-eve) EXACTLY what a default run writes — the old header claimed "nothing here
# touches your accounts, keychain, or Claude Code config", which was not true of the
# pinning steps it performed unconditionally. Enumerated instead of summarized:
#
#   1. $SCRIPTS_DEST — the account-bank scripts
#      (~/.local/share/quotabar/account-bank; override via QUOTABAR_SCRIPTS_DIR / XDG_DATA_HOME)
#   2. $SCRIPTS_DEST/hooks-fragment.resolved.json — a hooks snippet, written as a FILE
#      for you to merge yourself if you want the SessionStart hook. Nothing merges it.
#   3. /Applications/QuotaBar.app — built from source and installed
#
# With --with-pinning (OFF by default; only needed for the launch-pinning rail) it ALSO writes:
#   4. ~/.claude/accounts/.config.json — merges ONE key, REAL_CLAUDE_BIN
#   5. ~/.claude/accounts/bin/claude   — the launch shim, STAGED only (never put on PATH here)
#   6. ~/Library/LaunchAgents/com.quotabar.archiver.plist — written, NOT loaded
#
# What it never does, in either mode: it does not read or write the Keychain, does not
# merge anything into ~/.claude/settings.json, does not modify your PATH, does not load
# or start any launchd job, and does not touch your banked accounts or credentials.
# Re-running this script is safe.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# (release-eve) The default install is the rail-only user: app + scripts, nothing that
# reaches into ~/.claude. Launch pinning (shim + REAL_CLAUDE_BIN + archiver job) is an
# opt-in for the cutover path, so the default run neither writes those files nor talks
# about ceremonies the user is not performing.
WITH_PINNING=0
for _arg in "$@"; do
  case "$_arg" in
    --with-pinning) WITH_PINNING=1 ;;
    -h|--help)
      echo "usage: install.sh [--with-pinning]"
      echo "  --with-pinning  also record REAL_CLAUDE_BIN, stage ~/.claude/accounts/bin/claude,"
      echo "                  and write (not load) the archiver launchd job."
      exit 0 ;;
    *) echo "install.sh: unknown option: $_arg (see --help)" >&2; exit 64 ;;
  esac
done
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
SCRIPTS_DEST="${QUOTABAR_SCRIPTS_DIR:-$XDG_DATA/quotabar/account-bank}"

echo "==> Installing account-bank scripts to: $SCRIPTS_DEST"
mkdir -p "$SCRIPTS_DEST"
/usr/bin/ditto "$REPO_DIR/scripts" "$SCRIPTS_DEST"
rm -rf "$SCRIPTS_DEST/__pycache__"
chmod +x "$SCRIPTS_DEST"/*.sh "$SCRIPTS_DEST"/*.py 2>/dev/null || true

# ===== opt-in launch pinning (--with-pinning) ================================
# (release-eve) Everything between here and "end opt-in launch pinning" writes OUTSIDE the
# install dir (~/.claude/accounts, ~/Library/LaunchAgents) and exists only for the launch-
# pinning rail. It used to run on every install. The bodies are intentionally left at their
# original indentation: they contain quoted heredocs whose terminators must stay column-0.
if [ "$WITH_PINNING" -eq 1 ]; then

# (r10 #3) Record the real Claude CLI + stage the v2 launch shim. bin/claude resolves the
# real binary from accounts/.config.json REAL_CLAUDE_BIN (§3); no install path wrote it, so
# on a machine whose real CLI is at a nonstandard PATH location the shim exits 67 once
# accounts/bin is PATH-prepended. Resolve `claude` NOW (before any shim is on PATH — this IS
# the real binary), record it, and stage the shim into accounts/bin so cutover can
# PATH-prepend it. We do NOT modify PATH here — cutover (owner-driven) does that.
# (release-eve) same resolution order as scripts/lib.sh: BANK_DIR (test/explicit) first,
# then ACCOUNT_BANK_DIR (the convention the shim/claude-acct/hooks use), then the default.
# Hard-coding the default here made the installer write REAL_CLAUDE_BIN and stage the shim
# into a bank the rest of the toolchain was not reading.
ACCOUNTS_DIR="${BANK_DIR:-${ACCOUNT_BANK_DIR:-$HOME/.claude/accounts}}"
SHIM_PATH="$ACCOUNTS_DIR/bin/claude"
# (r11 #1) resolve the REAL binary EXCLUDING the shim. Re-running the installer AFTER
# cutover has a shim-first PATH, so `command -v claude` returns accounts/bin/claude — the
# shim. Recording that as REAL_CLAUDE_BIN is self-referential (the shim rejects itself ->
# every launch exits 67). Skip any candidate whose realpath is under accounts/bin.
_realpath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null; }
_BINROOT="$(_realpath "$ACCOUNTS_DIR/bin")"
_is_shim() { case "$(_realpath "$1")" in "$_BINROOT"|"$_BINROOT"/*) return 0;; *) return 1;; esac; }
REAL_CLAUDE=""
for _cand in "$(command -v claude 2>/dev/null || true)" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -n "$_cand" ] && [ -x "$_cand" ] || continue
  _is_shim "$_cand" && continue           # never record the shim as the real binary
  REAL_CLAUDE="$_cand"; break
done
mkdir -p "$ACCOUNTS_DIR/bin"
# (r12 #2) stage the shim WITHOUT following an existing symlink/hardlink at the destination
# (cp would clobber the REAL binary the link points at, violating "never over the real CLI").
# rm the dest first (removes the LINK, not its target), and refuse if the dest realpath IS
# the resolved real binary.
_stage_shim() {   # $1 = shim source
  if [ -n "$REAL_CLAUDE" ] && [ "$(_realpath "$SHIM_PATH")" = "$(_realpath "$REAL_CLAUDE")" ]; then
    echo "==> WARNING: $SHIM_PATH resolves to the REAL claude binary; refusing to overwrite it." >&2
    return 1
  fi
  rm -f "$SHIM_PATH" 2>/dev/null || true    # remove the link/file itself, never follow it
  cp "$1" "$SHIM_PATH" && chmod +x "$SHIM_PATH"
}
if [ -n "$REAL_CLAUDE" ]; then
  # (r12 #8) merge REAL_CLAUDE_BIN into .config.json UNDER THE BANK LOCK — toggle-autoping.sh
  # writes the same file under the lock; without it the installer's read-modify-write races a
  # concurrent auto_ping toggle and can discard it. Python json handles arbitrary path chars.
  REAL_CLAUDE_BIN="$REAL_CLAUDE" CONFIG_PATH="$ACCOUNTS_DIR/.config.json" \
    ACC="$ACCOUNTS_DIR" SD="$SCRIPTS_DEST" python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SD"])
import banklock
lk = banklock.BankLock(os.environ["ACC"])
if not lk.acquire(timeout=15):
    # (r13 #10) a SKIPPED recording is a FAILED install step, not a silent success — the shim
    # would exit 67 at cutover with the real binary at a nonstandard path. Exit NONZERO so the
    # caller refuses to stage the shim and warns loudly.
    sys.stderr.write("install: could not acquire bank lock for .config.json merge; REAL_CLAUDE_BIN NOT recorded\n")
    sys.exit(3)
try:
    cfg_path = os.environ["CONFIG_PATH"]
    try:
        cfg = json.load(open(cfg_path))
        if not isinstance(cfg, dict):
            cfg = {}
    except Exception:
        cfg = {}
    cfg["REAL_CLAUDE_BIN"] = os.environ["REAL_CLAUDE_BIN"]
    tmp = cfg_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=1)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, cfg_path)
finally:
    lk.release()
PY
  _merge_rc=$?
  # (r13 #10) only stage the shim if REAL_CLAUDE_BIN was actually recorded. A skipped merge
  # (bank-lock timeout, rc 3) must NOT be reported as a recorded binary + staged shim.
  if [ "$_merge_rc" -eq 0 ]; then
    _stage_shim "$SCRIPTS_DEST/bin/claude" \
      && echo "==> Recorded REAL_CLAUDE_BIN=$REAL_CLAUDE and staged the shim at $SHIM_PATH (PATH-prepended at cutover)"
  else
    echo "==> WARNING: REAL_CLAUDE_BIN was NOT recorded (bank lock busy); shim NOT staged. Re-run install.sh" >&2
    echo "    when QuotaBar is idle, or set REAL_CLAUDE_BIN in $ACCOUNTS_DIR/.config.json + stage $SHIM_PATH manually." >&2
  fi
else
  # (r11 #1) no NON-shim binary found: KEEP any existing recorded REAL_CLAUDE_BIN rather
  # than overwrite it with a shim path. Only warn if none was ever recorded.
  _HAVE="$(python3 -c 'import json,os,sys
try:
  print(1 if json.load(open(sys.argv[1])).get("REAL_CLAUDE_BIN") else 0)
except Exception: print(0)' "$ACCOUNTS_DIR/.config.json" 2>/dev/null)"
  _stage_shim "$SCRIPTS_DEST/bin/claude" || true
  if [ "$_HAVE" = "1" ]; then
    echo "==> Kept the existing REAL_CLAUDE_BIN (only the shim is on PATH now; not overwriting with a shim path)"
  else
    echo "==> WARNING: no real 'claude' binary found to record as REAL_CLAUDE_BIN; set it in $ACCOUNTS_DIR/.config.json before cutover" >&2
  fi
fi

# (r9 #3) Materialize the archiver launchd job from its template. The shipped plist carries
# a literal __SCRIPTS_DIR__/archiverd.py placeholder; nothing substituted it, so loading it
# ran python3 against a nonexistent path and KeepAlive hot-looped a dead daemon. Substitute
# the real install path and write the resolved plist to ~/Library/LaunchAgents. We do NOT
# load it here — cutover (owner-driven) loads it; the daemon is epoch-gated (#8) anyway.
ARCHIVER_TEMPLATE="$REPO_DIR/scripts/launchd/com.quotabar.archiver.plist"
if [ -f "$ARCHIVER_TEMPLATE" ]; then
  LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
  mkdir -p "$LAUNCH_AGENTS"
  ARCHIVER_PLIST="$LAUNCH_AGENTS/com.quotabar.archiver.plist"
  # (r10 #5) substitute via Python (LITERAL) — sed broke on '&'/'|' in the path.
  # (r11 #4) XML-ESCAPE the path before inserting it into the plist: an unescaped '&'/'<'
  # (e.g. QUOTABAR_SCRIPTS_DIR='/tmp/q&b') produces invalid XML launchd cannot load.
  SCRIPTS_DEST="$SCRIPTS_DEST" TEMPLATE="$ARCHIVER_TEMPLATE" ARCHIVER_PLIST="$ARCHIVER_PLIST" python3 - <<'PY'
import os
from xml.sax.saxutils import escape
src = open(os.environ["TEMPLATE"]).read()
out = src.replace("__SCRIPTS_DIR__", escape(os.environ["SCRIPTS_DEST"]))  # XML-safe (& < >)
with open(os.environ["ARCHIVER_PLIST"], "w") as f:
    f.write(out)
PY
  echo "==> Wrote archiver launchd job: $ARCHIVER_PLIST (not loaded; load at cutover)"
fi

fi
# ===== end opt-in launch pinning =============================================

# (r11 #3) Emit a RESOLVED lifecycle-hooks fragment. The shipped template
# (scripts/hooks-fragment.json) is placeholder-driven (__SCRIPTS_DIR__/session-hook.sh);
# merging it verbatim after a clean XDG install makes every hook exit 127 (the hardcoded
# ~/.claude path does not exist). Substitute the real install path (JSON-safe via Python)
# and write a resolved fragment NEXT TO THE INSTALLED SCRIPTS. This only creates a file
# inside the install dir — the installer never merges it into ~/.claude/settings.json.
HOOKS_TEMPLATE="$SCRIPTS_DEST/hooks-fragment.json"
if [ -f "$HOOKS_TEMPLATE" ]; then
  HOOKS_RESOLVED="$SCRIPTS_DEST/hooks-fragment.resolved.json"
  SCRIPTS_DEST="$SCRIPTS_DEST" HOOKS_TEMPLATE="$HOOKS_TEMPLATE" HOOKS_RESOLVED="$HOOKS_RESOLVED" python3 - <<'PY'
import json, os, shlex
src = open(os.environ["HOOKS_TEMPLATE"]).read()
# (r12 #3) the placeholder sits inside a SHELL command string ("bash __SCRIPTS_DIR__/…")
# INSIDE a JSON string value. It needs BOTH: shell-quoting (a path with spaces like
# "/tmp/Quota Bar" would otherwise word-split and no hook would run) AND JSON-escaping
# (for any '"'/'\\' shlex leaves). shlex.quote first, then json-escape the result.
safe = json.dumps(shlex.quote(os.environ["SCRIPTS_DEST"]))[1:-1]
out = src.replace("__SCRIPTS_DIR__", safe)
json.loads(out)   # validate the result is still well-formed JSON (fail loudly if not)
with open(os.environ["HOOKS_RESOLVED"], "w") as f:
    f.write(out)
PY
  echo "==> Wrote resolved hooks fragment: $HOOKS_RESOLVED"
  echo "    (optional: merge it into ~/.claude/settings.json yourself to auto-bank new accounts; see README)"
fi

echo "==> Building and installing QuotaBar.app"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi
make -C "$REPO_DIR/app" install

cat <<'NOTES'

==> Done.

QuotaBar.app is in /Applications and the scripts are installed. Two things to know:

1. First launch is Gatekeeper-blocked (the app is ad-hoc signed, not notarized).
   Right-click QuotaBar.app in /Applications -> Open -> Open, once. After that it
   launches normally. Or clear the quarantine flag:
       xattr -dr com.apple.quarantine /Applications/QuotaBar.app

2. Fast account swaps need a one-time Keychain authorization so the scripts can
   read Claude Code's credential item without a password prompt each time:
       security set-generic-password-partition-list \
         -s "Claude Code-credentials" -a "$USER" -k "" -S "apple:,apple-tool:"
   (This grants Apple-signed tools -- including /usr/bin/security -- access to
   that one item. It does not expose the secret; it just stops the repeated GUI
   prompt. You will be asked for your login password once to apply it.)

Add accounts: run `/login` in Claude Code for each account. With the SessionStart
hook enabled (optional, see README), the next session banks it automatically;
otherwise bank it once with:
    bash ~/.local/share/quotabar/account-bank/bank-account.sh

Set QuotaBar to launch at login from its menu (the auto features only run while
it is open). The app's runtime data lives in ~/.local/share/quotabar and its log
in ~/Library/Logs/QuotaBar.log -- both outside this repo.
NOTES

# (release-eve) the cutover/SHADOW vocabulary belongs to the pinning rail only — a default
# install never performs those ceremonies, so it never mentions them.
if [ "$WITH_PINNING" -eq 1 ]; then
  cat <<PINNING

==> Launch pinning was staged (--with-pinning). Nothing is active yet:

   - REAL_CLAUDE_BIN recorded in $ACCOUNTS_DIR/.config.json
   - shim staged at $ACCOUNTS_DIR/bin/claude (NOT on your PATH)
   - archiver job written to ~/Library/LaunchAgents (NOT loaded)

   Activating them is the owner-driven cutover (prepending accounts/bin to PATH and
   loading the launchd job by hand), run separately after attest-cutover.sh passes.
   Skip all of it if you only want the menu bar app and manual swaps -- that is the
   default install.
PINNING
fi
# ===== end opt-in launch pinning =============================================
