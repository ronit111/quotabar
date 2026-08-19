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
# Reject FORMATTING whitespace — whitespace between JSON tokens, i.e. a pretty-printed
# blob. kc_write needs the blob compact.
#
# (v112) This used to be `any(ch.isspace() for ch in raw)`, a character scan over the
# whole document. That was a correct proxy for "compact" only while no string VALUE
# contained a space. CLI 2.1.235 put `mcpOAuth` in the same keychain item, and an OAuth
# `scope` is space-delimited by specification ("read write offline") — so the scan began
# rejecting the live blob outright, which is what made every swap abort at
# swap-account.sh's capture gate. `compact_blob` could never fix it either: spaces inside
# a string are content, not formatting, and re-serializing preserves them.
#
# The scanner itself lives in bank_common so this gate and reconcile's restore gate
# cannot drift apart — they already had, once, and that drift is what would have made a
# torn swap unrecoverable.
if bank_common.formatting_whitespace(raw.strip()):
    fail("contains formatting whitespace (must be compact JSON before keychain write)")
sys.exit(0)
