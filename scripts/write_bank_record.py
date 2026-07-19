#!/usr/bin/env python3
"""write_bank_record.py — write/update a bank record atomically.

The keychain blob is read from STDIN (never argv, finding #12). Other args are
non-secret. Preserves banked_at / last_ping from an existing record.

Usage:  <blob-on-stdin> | write_bank_record.py <claude_json> <email> <out> <iso> <epoch>
"""
import sys, json, os, tempfile

claude_json, email, out, iso, epoch = sys.argv[1:6]
raw = sys.stdin.read()
if not raw.strip():
    sys.stderr.write("write_bank_record: empty blob on stdin\n"); sys.exit(1)
try:
    blob = json.loads(raw)
except Exception as e:
    sys.stderr.write(f"write_bank_record: blob not JSON ({e})\n"); sys.exit(1)
oauth = blob.get("claudeAiOauth") if isinstance(blob, dict) else None
if not isinstance(oauth, dict) or not oauth.get("accessToken"):
    sys.stderr.write("write_bank_record: blob missing claudeAiOauth.accessToken\n"); sys.exit(1)

try:
    cj = json.load(open(claude_json)); oauth_account = cj.get("oauthAccount") or {}
except Exception:
    oauth_account = {}

prev = {}
if os.path.exists(out):
    try:
        p = json.load(open(out))
        if isinstance(p, dict):
            prev = p
    except Exception:
        prev = {}

record = {
    "email": email,
    "banked_at": prev.get("banked_at", iso),
    "banked_at_epoch": prev.get("banked_at_epoch", int(epoch)),
    "status": "ok",
    "last_verified": iso,
    "last_ping": prev.get("last_ping", 0),
    "claudeAiOauth": oauth,
    "oauthAccount": oauth_account,
}
# Preserve the auto-ping debounce state across a re-bank (finding #15): dropping
# last_autoping / last_ping_failed would re-enable an early retry right after a
# failed or in-flight detached ping. stagger_hold_since is preserved too so the
# 2.5h phase-stagger cap survives a re-bank/restart (Addendum 2). Only carry them
# forward if they existed.
for _k in ("last_autoping", "last_ping_failed", "stagger_hold_since"):
    if _k in prev:
        record[_k] = prev[_k]
dirn = os.path.dirname(out) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".acct.")
with os.fdopen(fd, "w") as f:
    json.dump(record, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, out)
