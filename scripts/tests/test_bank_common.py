#!/usr/bin/env python3
"""Validated-load + fingerprint + email-safety (findings 1, 21, 35)."""
import os, sys, json, tempfile
AB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AB)
import bank_common as bc

P = F = 0
def ok(c, name):
    global P, F
    if c: P += 1; print("  ok  ", name)
    else: F += 1; print("  FAIL", name)

# --- email / path safety (finding 1) ---
ok(bc.safe_email("a@b.com") == "a@b.com", "plain email accepted")
ok(bc.safe_email("../etc/passwd") is None, "parent traversal rejected")
ok(bc.safe_email("a/b@c.com") is None, "slash rejected")
ok(bc.safe_email("..") is None, "'..' rejected")
ok(bc.safe_email(".hidden@x.com") is None, "leading dot rejected")
ok(bc.safe_email("a..b@x.com") is None, "double-dot rejected")
ok(bc.safe_email("no-at-sign") is None, "missing @ rejected")
ok(bc.safe_email("a b@x.com") is None, "whitespace rejected")

d = tempfile.mkdtemp()
ok(bc.bank_file_for(d, "a@b.com") == os.path.join(d, "a@b.com.json"), "bank_file_for safe path")
ok(bc.bank_file_for(d, "../evil") is None, "bank_file_for rejects traversal")

# --- fingerprint compares the FULL credential (finding 21) ---
base = {"accessToken": "a", "refreshToken": "r", "expiresAt": 1}
f_full = bc.cred_fingerprint({"claudeAiOauth": base})
f_bare = bc.cred_fingerprint(base)
ok(f_full == f_bare and f_full != "", "fingerprint: blob == bare oauth")
ok(bc.cred_fingerprint({"accessToken": "a", "refreshToken": "r2", "expiresAt": 1}) != f_bare,
   "fingerprint changes when only refreshToken rotates")
ok(bc.cred_fingerprint({"accessToken": "a", "refreshToken": "r", "expiresAt": 2}) != f_bare,
   "fingerprint changes when only expiresAt rotates")
ok(bc.cred_fingerprint("not json") == "", "fingerprint of junk is empty")
# (re-review issues 6, 7)
ok(bc.cred_fingerprint({}) == "", "fingerprint of {} is empty, not a hash of {}")
ok(bc.cred_fingerprint({"accessToken": "a", "refreshToken": "r", "expiresAt": True}) == "",
   "boolean expiresAt is invalid -> empty fingerprint")
_p1 = {"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "subscriptionType": "max"}
_p2 = {"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "subscriptionType": "pro"}
ok(bc.cred_fingerprint(_p1) == bc.cred_fingerprint(_p2) != "",
   "fingerprint EXCLUDES plan metadata (subscriptionType change -> same fp, issue 7)")
ok(bc.same_credentials({"claudeAiOauth": base}, dict(base)), "same_credentials true for equal")
ok(not bc.same_credentials(base, {"accessToken": "a", "refreshToken": "r", "expiresAt": 9}),
   "same_credentials false for rotated")

# --- validated load: malformed record never silently trusted (finding 35) ---
def write(path, content):
    with open(path, "w") as f: f.write(content)

valid = json.dumps({"email": "v@x.com", "status": "ok",
                    "claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 1},
                    "oauthAccount": {"emailAddress": "v@x.com", "organizationType": "claude_max"}})
p_ok = os.path.join(d, "v@x.com.json"); write(p_ok, valid)
br = bc.load_bank_record(p_ok)
ok(br.ok and br.email == "v@x.com" and br.plan == "claude_max", "valid record loads ok")

p_bad = os.path.join(d, "b@x.com.json"); write(p_bad, "{ not json")
br = bc.load_bank_record(p_bad)
ok((not br.ok) and "unparseable" in br.reason, "unparseable record -> ok=False with reason")

# email mismatch (record says other@x, filename says m@x) -> invalid
p_mm = os.path.join(d, "m@x.com.json")
write(p_mm, json.dumps({"email": "other@x.com", "status": "ok",
                        "claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 1}}))
br = bc.load_bank_record(p_mm)
ok(not br.ok, "email/filename mismatch rejected")

# missing refreshToken (incomplete cred) -> invalid, but record preserved for safe rewrite
p_inc = os.path.join(d, "i@x.com.json")
write(p_inc, json.dumps({"email": "i@x.com", "status": "ok",
                         "claudeAiOauth": {"accessToken": "a", "expiresAt": 1}}))
br = bc.load_bank_record(p_inc)
ok((not br.ok) and br.record is not None, "incomplete cred invalid but .record preserved (no destroy)")

# needs-relogin with absent token is a VALID (expected) state
p_nr = os.path.join(d, "n@x.com.json")
write(p_nr, json.dumps({"email": "n@x.com", "status": "needs-relogin"}))
br = bc.load_bank_record(p_nr)
ok(br.ok and br.status == "needs-relogin", "needs-relogin record is valid")

# error entry is non-eligible (no worst_limit, has error)
e = bc.error_account_entry("z@x.com", "boom")
ok(e.get("error") and e.get("worst_limit") is None, "error_account_entry is non-eligible")

# (r9 #2) FIRST archive_blob creates archive/ and durably lands the predecessor. This
# exercises the newly-created-parent-fsync branch (bank_dir must be fsync'd so archive/'s
# dirent survives before the caller overwrites the credential). We can't observe fsync,
# but we assert the branch runs cleanly and the archive is present and correct.
bdir = tempfile.mkdtemp(prefix="bc-arch-")
assert not os.path.isdir(os.path.join(bdir, "archive")), "precondition: no archive dir yet"
ap = bc.archive_blob(bdir, "a@x.com", {"claudeAiOauth": {"accessToken": "PRED"}})
ok(ap and os.path.exists(ap) and os.path.isdir(os.path.join(bdir, "archive")),
   "first archive_blob creates archive/ and lands the predecessor (r9 #2)")
ok(json.load(open(ap))["claudeAiOauth"]["accessToken"] == "PRED",
   "archived predecessor content is verbatim (r9 #2)")
# a SECOND archive into the now-existing dir also works (parent already durable)
ap2 = bc.archive_blob(bdir, "a@x.com", {"claudeAiOauth": {"accessToken": "PRED2"}})
ok(ap2 and os.path.exists(ap2) and ap2 != ap, "second archive into existing archive/ lands too (r9 #2)")

print(f"  -- bank_common: {P} passed, {F} failed")
sys.exit(1 if F else 0)
