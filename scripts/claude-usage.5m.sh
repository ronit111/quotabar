#!/usr/bin/env bash
# <xbar.title>Claude Multi-Account Usage</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.author>account-bank</xbar.author>
# <xbar.desc>Per-account Claude 5h/weekly usage + one-click account swap.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
#
# SwiftBar plugin. Refreshes every 5 minutes (filename cadence). Renders the
# active account's worst-limit percentage first in the menu bar, colored by
# severity, with a per-account dropdown and one-click terminal swap items.
#
# Symlinked into the SwiftBar plugin dir (~/.swiftbar). It resolves the real
# scripts dir by following the symlink back to its install location, so keep the
# actual file inside the QuotaBar scripts dir and only symlink it into SwiftBar.
# QUOTABAR_SCRIPTS_DIR overrides.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -n "${QUOTABAR_SCRIPTS_DIR:-}" ]; then
  SELF_DIR="$QUOTABAR_SCRIPTS_DIR"
else
  _src="${BASH_SOURCE[0]}"
  while [ -h "$_src" ]; do
    _dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
  done
  SELF_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
fi

out="$(python3 "$SELF_DIR/usage.py" 2>/dev/null)"
if [ -z "$out" ]; then
  echo "⚡ ? | color=gray"
  echo "---"
  echo "usage.py produced no output"
  echo "Run manually | bash=\"python3\" param1=\"$SELF_DIR/usage.py\" terminal=true"
  exit 0
fi
printf '%s' "$out" | python3 "$SELF_DIR/swiftbar-render.py"
