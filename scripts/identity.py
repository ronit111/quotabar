#!/usr/bin/env python3
"""identity.py — the G9 endpoint identity primitive (ISOLATION-DESIGN.md rev 5).

blob → (account uuid, email) via GET https://api.anthropic.com/api/oauth/profile —
measured 2026-07-21: read-only, non-refreshing, returns account.uuid/email + plan.

Verdict contract (fail-closed for mutations):
  RESOLVED       -> identity is known: result.uuid / result.email populated.
  INVALID        -> the server REJECTED the credential (HTTP 401/403 with a parseable
                    auth-shaped body). The only verdict that may ever justify calling
                    a credential foreign/dead — and even then callers must apply their
                    own transient-marker discipline before acting.
  INDETERMINATE  -> network/timeout/5xx/parse failure/anything else. NEVER a verdict;
                    callers must not mutate on it.

Token material is never logged, never echoed, never included in errors. stdlib only.
"""
import json
import ssl
import urllib.error
import urllib.request
from collections import namedtuple

PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
OAUTH_BETA = "oauth-2025-04-20"
TIMEOUT_S = 15

IdentityResult = namedtuple("IdentityResult", "verdict uuid email plan detail")
# verdict: "RESOLVED" | "INVALID" | "INDETERMINATE"
# plan: "max" | "pro" | "free" | "" (advisory only — never an identity input)
# detail: short reason string, guaranteed token-free


def _plan_of(account):
    if account.get("has_claude_max"):
        return "max"
    if account.get("has_claude_pro"):
        return "pro"
    return "free"


def _is_auth_signature(body):
    """(finding 18) §G9: a 401/403 is INVALID (server rejected the credential) ONLY
    when it carries a STRUCTURED authentication signature — the Anthropic API error
    envelope {"type":"error","error":{"type":"authentication_error"|"permission_error"...}}.
    A bare/HTML/non-auth 401/403 from a proxy, WAF, or org policy layer carries no
    such signature and must stay INDETERMINATE (never condemn the credential)."""
    try:
        d = json.loads(body)
    except Exception:
        return False
    if not isinstance(d, dict):
        return False
    err = d.get("error")
    etype = err.get("type") if isinstance(err, dict) else d.get("type")
    return isinstance(etype, str) and etype.lower() in (
        "authentication_error", "permission_error")


def resolve(access_token):
    """One G9 call. Never raises; every failure mode maps into the verdict."""
    if not isinstance(access_token, str) or not access_token.strip():
        return IdentityResult("INDETERMINATE", "", "", "", "no access token supplied")
    req = urllib.request.Request(
        PROFILE_URL,
        headers={
            "Authorization": "Bearer " + access_token.strip(),
            "anthropic-beta": OAUTH_BETA,
            "Accept": "application/json",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S,
                                    context=ssl.create_default_context()) as resp:
            body = resp.read(1 << 20)
    except urllib.error.HTTPError as e:
        # 401/403: INVALID only when the body carries a structured auth signature
        # (finding 18). A proxy/WAF/policy 401/403 without it is INDETERMINATE — never
        # a verdict that condemns the credential. Everything else (429, 5xx) is
        # load/transient: INDETERMINATE.
        if e.code in (401, 403):
            try:
                eb = e.read(1 << 20)
            except Exception:
                eb = b""
            if _is_auth_signature(eb):
                return IdentityResult("INVALID", "", "", "", f"http {e.code} auth-signature")
            return IdentityResult("INDETERMINATE", "", "", "",
                                  f"http {e.code} without auth signature (proxy/WAF/policy?)")
        return IdentityResult("INDETERMINATE", "", "", "", f"http {e.code}")
    except Exception as e:
        # DNS/timeout/TLS/connection — transient by contract.
        return IdentityResult("INDETERMINATE", "", "", "", type(e).__name__)
    try:
        d = json.loads(body)
        acct = d["account"]
        uuid, email = acct["uuid"], acct["email"]   # field names as measured (G9)
        if not (isinstance(uuid, str) and uuid and isinstance(email, str) and email):
            raise ValueError("empty identity fields")
    except Exception as e:
        # A 200 we cannot parse identifies nothing — INDETERMINATE, never a guess.
        return IdentityResult("INDETERMINATE", "", "", "", f"unparseable profile: {type(e).__name__}")
    return IdentityResult("RESOLVED", uuid, email, _plan_of(acct), "ok")


def verify_owner(access_token, expected_email):
    """Convenience: (bool_or_None, result). True/False ONLY on RESOLVED; None on
    anything else (callers MUST treat None as do-not-mutate)."""
    r = resolve(access_token)
    if r.verdict != "RESOLVED":
        return None, r
    return r.email == expected_email, r


def _cli():
    """CLI: reads the ACCESS TOKEN on stdin (never argv — argv leaks into ps),
    prints `verdict uuid email plan` on one line. Exit 0 RESOLVED, 3 INVALID,
    6 INDETERMINATE (mirrors the bank's transient/dead code split)."""
    import sys
    tok = sys.stdin.read().strip()
    r = resolve(tok)
    print(f"{r.verdict} {r.uuid} {r.email} {r.plan}")
    return {"RESOLVED": 0, "INVALID": 3}.get(r.verdict, 6)


if __name__ == "__main__":
    raise SystemExit(_cli())
