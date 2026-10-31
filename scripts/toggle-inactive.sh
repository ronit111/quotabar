#!/usr/bin/env bash
# toggle-inactive.sh <email> — flip an account's inactive flag in
# $BANK_DIR/.config.json (add if absent, remove if present). An inactive account
# stays in the bank but is never polled, refreshed or pinged. Runs under
# the bank lock, writes atomically (0600), fail-soft on a malformed config
# (recreates a minimal valid file). Prints the new state.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

email="${1:-}"
[ -n "$email" ] || { err "Usage: toggle-inactive.sh <email>"; exit 2; }

ensure_bank
acquire_lock || { err "toggle-inactive: could not acquire lock; try again."; exit 1; }
trap 'release_lock' EXIT
trap 'release_lock; exit 130' INT TERM HUP PIPE

# (r6 b10) this list is v1 state, like auto_ping — gate the config mutation with the SAME
# v1-gate + generation fence every credential mutator uses. rc 78 = fenced, config UNCHANGED.
if ! epoch_guard; then
  err "toggle-inactive: epoch gate refused the mutation (rc 78; config UNCHANGED). Re-run after the flip/seed settles."
  exit 78
fi

CONFIG="$BANK_DIR/.config.json"
python3 - "$CONFIG" "$email" <<'PY'
import sys, json, os, tempfile, time
config, email = sys.argv[1], sys.argv[2]
# Same rule as toggle-autoping.sh (finding #54): a malformed config is moved aside, never overwritten.
if os.path.exists(config):
    try:
        c = json.load(open(config))
    except Exception:
        c = None
    if not isinstance(c, dict):
        q = f"{config}.corrupt.{int(time.time())}"
        try:
            os.rename(config, q)
        except OSError:
            pass
        sys.stderr.write(f"toggle-inactive: .config.json is malformed; quarantined to "
                         f"{os.path.basename(q)}. Refusing to overwrite unrelated settings.\n")
        sys.stderr.write("Re-run to toggle against a fresh config, or restore the quarantined file.\n")
        sys.exit(1)
else:
    c = {}
ap = c.get("inactive")
if not isinstance(ap, list):
    ap = []
ap = [e for e in ap if isinstance(e, str)]
if email in ap:
    ap = [e for e in ap if e != email]
    state = "active"
else:
    ap.append(email)
    state = "inactive"
c["inactive"] = ap
dirn = os.path.dirname(config) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".config.")
with os.fdopen(fd, "w") as f:
    json.dump(c, f, indent=2); f.flush(); os.fsync(f.fileno())
os.chmod(tmp, 0o600)
os.replace(tmp, config)
print(f"{email} is now {state}")
PY
