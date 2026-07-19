#!/usr/bin/env bash
# toggle-autoping.sh <email> — flip an account's auto-ping membership in
# $BANK_DIR/.config.json (add if absent, remove if present). Runs under
# the bank lock, writes atomically (0600), fail-soft on a malformed config
# (recreates a minimal valid file). Prints the new state.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

email="${1:-}"
[ -n "$email" ] || { err "Usage: toggle-autoping.sh <email>"; exit 2; }

ensure_bank
acquire_lock || { err "toggle-autoping: could not acquire lock; try again."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE

CONFIG="$BANK_DIR/.config.json"
python3 - "$CONFIG" "$email" <<'PY'
import sys, json, os, tempfile
config, email = sys.argv[1], sys.argv[2]
# fail-soft load: any problem -> start from a minimal valid config
try:
    c = json.load(open(config))
    if not isinstance(c, dict):
        c = {}
except Exception:
    c = {}
ap = c.get("auto_ping")
if not isinstance(ap, list):
    ap = []
ap = [e for e in ap if isinstance(e, str)]
if email in ap:
    ap = [e for e in ap if e != email]
    state = "off"
else:
    ap.append(email)
    state = "on"
c["auto_ping"] = ap
dirn = os.path.dirname(config) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".config.")
with os.fdopen(fd, "w") as f:
    json.dump(c, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, config)
print(f"auto-ping for {email} is now {state.upper()}")
PY
