#!/usr/bin/env bash
# list-accounts.sh — table of banked accounts: email, banked_at, active marker,
# access-token expiry status.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ensure_bank
active="$(active_email)"

python3 - "$HERE" "$BANK_DIR" "$active" <<'PY'
import sys, json, os, time, glob
sys.path.insert(0, sys.argv[1])
import bank_common
bank, active = sys.argv[2], sys.argv[3]
now_ms = time.time() * 1000
rows = []
# Each row is rendered DEFENSIVELY (finding #53): a malformed record (string
# expiry, non-string plan/email) becomes an explicit "INVALID" row instead of
# raising and hiding EVERY account. We render from the raw dict but guard every
# field access + comparison.
for f in sorted(glob.glob(os.path.join(bank, "*.json"))):
    # (r13 #12) skip v2 control-plane JSON (registry/sessions/archiver.status/…) — they
    # live under accounts/ and would otherwise render as bogus INVALID rows (same class as
    # the r8 #3 usage.py fix; shared skip set in bank_common).
    if os.path.basename(f) in bank_common.V2_CONTROL_JSON:
        continue
    fname_email = os.path.basename(f)[:-5]
    try:
        d = json.load(open(f))
    except Exception as e:
        rows.append((" ", fname_email, "?", "?", f"INVALID (unreadable: {type(e).__name__})"))
        continue
    if not isinstance(d, dict):
        rows.append((" ", fname_email, "?", "?", "INVALID (not an object)"))
        continue
    br = bank_common.load_bank_record(f)
    email = d.get("email") if isinstance(d.get("email"), str) else fname_email
    mark = "●" if email == active else " "
    if not br.ok:
        rows.append((mark, email, "?", str(d.get("banked_at", "?"))[:20],
                     f"INVALID ({br.reason})"))
        continue
    oauth = d.get("claudeAiOauth") or {}
    exp = oauth.get("expiresAt")
    rexp = oauth.get("refreshTokenExpiresAt")
    if not isinstance(exp, (int, float)) or isinstance(exp, bool):
        tok = "unknown"
    elif exp > now_ms:
        mins = int((exp - now_ms) / 60000)
        tok = f"valid ({mins//60}h{mins%60}m left)" if mins >= 60 else f"valid ({mins}m left)"
    else:
        tok = "EXPIRED"
    if isinstance(rexp, (int, float)) and not isinstance(rexp, bool) and rexp <= now_ms:
        tok += " / refresh EXPIRED"
    banked = str(d.get("banked_at", "?"))
    sub = oauth.get("subscriptionType")
    sub = sub if isinstance(sub, str) else "?"
    if d.get("status") == "needs-relogin":
        tok = "NEEDS RE-LOGIN"
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
