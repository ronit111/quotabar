#!/usr/bin/env python3
"""validate_blob.py — read a candidate keychain blob on STDIN (never argv) and
exit 0 only if it is a well-formed Claude credential blob. Explicit schema checks
(no assert — assert vanishes under PYTHONOPTIMIZE, finding #11).

Prints nothing on success; a short reason to stderr on failure. Never echoes the
secret.
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bank_common   # the SINGLE credential validator (re-review issue 6)

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
# Route through the shared validator so shell + Python agree on exactly what a
# valid credential is (accessToken+refreshToken non-empty strings, numeric-but-
# NOT-boolean expiresAt). A stray `True`/`False` expiresAt is rejected here too.
if not bank_common.valid_oauth(oa):
    fail("claudeAiOauth missing/invalid (need accessToken+refreshToken+numeric expiresAt)")
# reject whitespace: security -i tokenizes the blob on the command line by
# whitespace, so a compact (space-free) blob is required for a safe write.
if any(ch.isspace() for ch in raw.strip()):
    fail("contains whitespace (must be compact JSON before keychain write)")
sys.exit(0)
