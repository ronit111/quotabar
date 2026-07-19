#!/usr/bin/env bash
# list-accounts.sh — table of banked accounts: email, banked_at, active marker,
# access-token expiry status.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ensure_bank
active="$(active_email)"

python3 - "$BANK_DIR" "$active" <<'PY'
import sys, json, os, time, glob
bank, active = sys.argv[1], sys.argv[2]
now_ms = time.time() * 1000
rows = []
for f in sorted(glob.glob(os.path.join(bank, "*.json"))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    email = d.get("email", os.path.basename(f)[:-5])
    oauth = d.get("claudeAiOauth", {})
    exp = oauth.get("expiresAt")           # access token expiry (ms)
    rexp = oauth.get("refreshTokenExpiresAt")
    if exp is None:
        tok = "unknown"
    elif exp > now_ms:
        mins = int((exp - now_ms) / 60000)
        tok = f"valid ({mins//60}h{mins%60}m left)" if mins >= 60 else f"valid ({mins}m left)"
    else:
        tok = "EXPIRED"
    if rexp is not None and rexp <= now_ms:
        tok += " / refresh EXPIRED"
    banked = d.get("banked_at", "?")
    sub = oauth.get("subscriptionType", "?")
    status = d.get("status", "ok")
    if status == "needs-relogin":
        tok = "NEEDS RE-LOGIN"
    mark = "●" if email == active else " "
    rows.append((mark, email, sub, banked, tok))

if not rows:
    print("No banked accounts yet. Bank the current one with bank-account.sh")
    sys.exit(0)

w_email = max(len("EMAIL"), max(len(r[1]) for r in rows))
w_sub   = max(len("PLAN"),  max(len(r[2]) for r in rows))
print(f"  {'EMAIL':<{w_email}}  {'PLAN':<{w_sub}}  {'BANKED_AT':<20}  STATUS")
print(f"  {'-'*w_email}  {'-'*w_sub}  {'-'*20}  {'-'*24}")
for mark, email, sub, banked, tok in rows:
    print(f"{mark} {email:<{w_email}}  {sub:<{w_sub}}  {banked:<20}  {tok}")
print()
print("  ● = active (currently in keychain)")
PY
