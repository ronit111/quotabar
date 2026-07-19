#!/usr/bin/env python3
"""validate_blob.py — read a candidate keychain blob on STDIN (never argv) and
exit 0 only if it is a well-formed Claude credential blob. Explicit schema checks
(no assert — assert vanishes under PYTHONOPTIMIZE, finding #11).

Prints nothing on success; a short reason to stderr on failure. Never echoes the
secret.
"""
import sys, json

def fail(msg):
    sys.stderr.write(f"blob invalid: {msg}\n")
    sys.exit(1)

raw = sys.stdin.read()
if not raw.strip():
    fail("empty")
try:
    b = json.loads(raw)
except Exception as e:
    fail(f"not JSON ({type(e).__name__})")
if not isinstance(b, dict):
    fail("top-level not object")
oa = b.get("claudeAiOauth")
if not isinstance(oa, dict):
    fail("missing claudeAiOauth object")
at = oa.get("accessToken")
rt = oa.get("refreshToken")
exp = oa.get("expiresAt")
if not isinstance(at, str) or not at:
    fail("accessToken missing/empty")
if not isinstance(rt, str) or not rt:
    fail("refreshToken missing/empty")
if not isinstance(exp, (int, float)):
    fail("expiresAt missing/not numeric")
# reject whitespace: security -i tokenizes the blob on the command line by
# whitespace, so a compact (space-free) blob is required for a safe write.
if any(ch.isspace() for ch in raw.strip()):
    fail("contains whitespace (must be compact JSON before keychain write)")
sys.exit(0)
