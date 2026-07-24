#!/usr/bin/env python3
"""(finding 18) Coverage for identity.resolve() — the G9 primitive that had NO test.
urllib is monkeypatched so nothing hits the network or a real credential; the point
is the verdict decision table, especially that a 401/403 is INVALID ONLY with a
structured auth signature (a bare proxy/WAF 403 must remain INDETERMINATE)."""
import io
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import identity  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def _patch(fn):
    identity.urllib.request.urlopen = fn


def _http_error(code, body):
    return urllib.error.HTTPError("u", code, "err", {}, io.BytesIO(body))


def main():
    # RESOLVED: a 200 with a well-formed profile
    def ok_profile(req, timeout=None, context=None):
        return _Resp(json.dumps({"account": {"uuid": "U1", "email": "a@x.com",
                                             "has_claude_max": True}}).encode())
    _patch(ok_profile)
    r = identity.resolve("tok")
    ok(r.verdict == "RESOLVED" and r.uuid == "U1" and r.email == "a@x.com" and r.plan == "max",
       "200 + valid profile -> RESOLVED with uuid/email/plan")

    # INVALID: 401 WITH a structured Anthropic auth signature
    def auth_401(req, timeout=None, context=None):
        raise _http_error(401, json.dumps(
            {"type": "error", "error": {"type": "authentication_error",
                                        "message": "invalid bearer token"}}).encode())
    _patch(auth_401)
    ok(identity.resolve("tok").verdict == "INVALID",
       "401 with authentication_error signature -> INVALID")

    # INVALID: 403 permission_error signature
    def perm_403(req, timeout=None, context=None):
        raise _http_error(403, json.dumps(
            {"type": "error", "error": {"type": "permission_error"}}).encode())
    _patch(perm_403)
    ok(identity.resolve("tok").verdict == "INVALID",
       "403 with permission_error signature -> INVALID")

    # INDETERMINATE: bare 403 with NO auth signature (proxy/WAF/policy) — must NOT
    # condemn the credential.
    def bare_403(req, timeout=None, context=None):
        raise _http_error(403, b"<html>403 Forbidden (edge proxy)</html>")
    _patch(bare_403)
    ok(identity.resolve("tok").verdict == "INDETERMINATE",
       "bare 403 (no auth signature) -> INDETERMINATE (finding 18)")

    # INDETERMINATE: 401 with a non-auth JSON error type
    def other_401(req, timeout=None, context=None):
        raise _http_error(401, json.dumps({"error": {"type": "rate_limit_error"}}).encode())
    _patch(other_401)
    ok(identity.resolve("tok").verdict == "INDETERMINATE",
       "401 with non-auth error type -> INDETERMINATE (finding 18)")

    # INDETERMINATE: 5xx / 429
    def five_oh_three(req, timeout=None, context=None):
        raise _http_error(503, b"upstream down")
    _patch(five_oh_three)
    ok(identity.resolve("tok").verdict == "INDETERMINATE", "503 -> INDETERMINATE")

    # INDETERMINATE: network exception
    def boom(req, timeout=None, context=None):
        raise urllib.error.URLError("dns")
    _patch(boom)
    ok(identity.resolve("tok").verdict == "INDETERMINATE", "network error -> INDETERMINATE")

    # INDETERMINATE: a 200 we cannot parse identifies nothing
    def garbage(req, timeout=None, context=None):
        return _Resp(b"not json")
    _patch(garbage)
    ok(identity.resolve("tok").verdict == "INDETERMINATE", "unparseable 200 -> INDETERMINATE")

    # INDETERMINATE: empty token, no call made
    ok(identity.resolve("").verdict == "INDETERMINATE", "empty token -> INDETERMINATE")

    # verify_owner: True/False only on RESOLVED, None otherwise
    _patch(ok_profile)
    ok(identity.verify_owner("tok", "a@x.com")[0] is True, "verify_owner True on match")
    ok(identity.verify_owner("tok", "b@x.com")[0] is False, "verify_owner False on mismatch")
    _patch(bare_403)
    ok(identity.verify_owner("tok", "a@x.com")[0] is None, "verify_owner None when not RESOLVED")

    print(f"-- identity_resolve: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
