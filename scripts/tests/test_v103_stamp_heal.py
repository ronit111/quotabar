#!/usr/bin/env python3
"""(v103) ORACLE-ATTESTED PLAN-STAMP CORRECTION — the frozen-stamp upgrade heals.

The keychain blob's subscriptionType is stamped only by a real /login; a plan change while
banked leaves it stale indefinitely (token refreshes never rewrite it — verified live
2026-08-10, pro→max on ronitchidara111). write_bank_record's crossed-identity tell then
compared that frozen stamp against ~/.claude.json's fresh organizationType and refused every
heal: empty banked card + UNLINKED twin, forever, until a manual /login.

Offline, "upgraded with a frozen stamp" and "downgrading with lagging metadata" are the SAME
BYTES (stamp=pro, org=max). The oracle's live plan disambiguates them, so the correction
fires ONLY when the oracle and the live metadata AGREE on a tier the stamp contradicts:

  * upgrade, frozen stamp (oracle==metadata!=stamp): stamp corrected in the blob being
    banked (keychain untouched), the writer's live-vs-live tell agrees, the heal lands;
  * downgrade mid-flight (oracle==stamp!=metadata): NO correction, the writer's
    conservative refusal stands — test_v102_plan_heal.py keeps asserting that side;
  * any tier unknown, any refusal upstream (INDETERMINATE oracle, foreign account):
    stamp untouched, nothing healed.
"""
import json
import os
import sys
import tempfile
from collections import namedtuple

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
sys.path.insert(0, AB)

_pass = _fail = 0


def ok(cond, name):
    global _pass, _fail
    if cond:
        _pass += 1; print(f"  ok   {name}")
    else:
        _fail += 1; print(f"  FAIL {name}")


def cred(tag, plan="max"):
    return {"accessToken": f"at-{tag}", "refreshToken": f"rt-{tag}",
            "expiresAt": 4102444800, "subscriptionType": plan}


def record(email, oauth, status="ok", org="claude_pro"):
    return {"email": email, "banked_at": "2026-01-01T00:00:00Z", "banked_at_epoch": 1,
            "status": status, "last_verified": "2026-01-01T00:00:00Z", "last_ping": 0,
            "claudeAiOauth": oauth,
            "oauthAccount": {"emailAddress": email, "organizationType": org}}


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f)


Res = namedtuple("Res", "verdict uuid email plan detail")


def oracle_saying(email, verdict="RESOLVED", plan="max"):
    return lambda tok: Res(verdict, "uuid-" + str(email), email, plan, "stub")


def main():
    base = tempfile.mkdtemp(prefix="v103-stamp-heal-")
    bank = os.path.join(base, "bank"); os.makedirs(bank)
    os.environ["BANK_DIR"] = bank
    os.environ["CLAUDE_JSON"] = os.path.join(base, "claude.json")
    os.environ.pop("ACCOUNT_BANK_HEAL_UNLINKED", None)

    import bank_common
    import usage

    ok(usage.acquire_lock(timeout=5) is True, "test holds the real bank lock")

    # --- THE deadlock: banked pro, upgraded to max, stamp frozen at pro ------------
    a_path = os.path.join(bank, "a@x.com.json")
    write_json(a_path, record("a@x.com", cred("v1", plan="pro"), org="claude_pro"))
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})
    frozen = cred("v2", plan="pro")     # rotated token, stamp NOT re-stamped by /login
    usage._identity_oracle = oracle_saying("a@x.com", plan="max")

    note = {}
    ok(usage._benign_drift_refusal("a@x.com", frozen, note) == "",
       "oracle+metadata agreeing against the stamp is HEALABLE (the v102 deadlock)")
    corrected = note.get("stamp_corrected_blob")
    ok(isinstance(corrected, dict) and corrected.get("subscriptionType") == "max",
       "the correction lands on a COPY carried in the note (attested plan)")
    ok(frozen.get("subscriptionType") == "pro",
       "the caller's own blob is NEVER mutated (Codex P2)")
    ok(note.get("healed_plan_change") == {"from": "pro", "to": "max", "email": "a@x.com"},
       "the upgrade is announced as a plan change (banked pro -> live max)")
    ok(usage._heal_unlinked("a@x.com", corrected) is True,
       "the corrected blob passes write_bank_record's live-vs-live tell (was REFUSED)")
    on_disk = json.load(open(a_path))
    ok(on_disk["claudeAiOauth"].get("subscriptionType") == "max",
       "the bank record now carries the attested plan")
    ok(bank_common.resolve_identity(bank, frozen, "a@x.com") == "a@x.com",
       "identity RESOLVES after the heal -> UNLINKED chip gone, card links")

    # --- downgrade mid-flight: oracle sides with the STAMP, not the metadata -------
    write_json(a_path, record("a@x.com", cred("d1", plan="max"), org="claude_max"))
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})
    moving = cred("d2", plan="pro")
    usage._identity_oracle = oracle_saying("a@x.com", plan="pro")
    nd = {}
    ok(usage._benign_drift_refusal("a@x.com", moving, nd) == ""
       and "stamp_corrected_blob" not in nd,
       "oracle==stamp!=metadata: NO correction (same bytes, different story)")
    ok(usage._heal_unlinked("a@x.com", moving) is False,
       "...and the writer's conservative refusal still stands (fail closed)")

    # --- unknown tiers are no evidence ---------------------------------------------
    noplan = cred("n1", plan="pro"); noplan.pop("subscriptionType")
    usage._identity_oracle = oracle_saying("a@x.com", plan="max")
    write_json(a_path, record("a@x.com", cred("n0", plan="pro"), org="claude_pro"))
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})
    nn = {}
    usage._benign_drift_refusal("a@x.com", noplan, nn)
    ok("stamp_corrected_blob" not in nn,
       "a stamp with no tier is left alone (no invented field)")
    usage._identity_oracle = oracle_saying("a@x.com", plan="")
    ns = {}
    usage._benign_drift_refusal("a@x.com", cred("s1", plan="pro"), ns)
    ok("stamp_corrected_blob" not in ns,
       "an oracle with no plan corrects nothing")
    # (Codex P1) identity._plan_of() reports "free" as the ABSENCE default when the profile
    # carries neither plan flag — a free verdict is indistinguishable from missing evidence,
    # so it must never attest a correction even when the metadata agrees with it.
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_free"}})
    usage._identity_oracle = oracle_saying("a@x.com", plan="free")
    nf = {}
    usage._benign_drift_refusal("a@x.com", cred("f1", plan="pro"), nf)
    ok("stamp_corrected_blob" not in nf,
       "a FREE oracle verdict never attests (absence default, Codex P1)")
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})

    # --- upstream refusals never reach the correction ------------------------------
    usage._identity_oracle = oracle_saying("a@x.com", verdict="INDETERMINATE", plan="max")
    nu = {}
    ok(usage._benign_drift_refusal("a@x.com", cred("u1", plan="pro"), nu)
       == "live identity unconfirmed" and "stamp_corrected_blob" not in nu,
       "an unconfirmable oracle refuses AND corrects nothing")
    usage._identity_oracle = oracle_saying("b@x.com", plan="max")
    nu2 = {}
    ok(usage._benign_drift_refusal("a@x.com", cred("u2", plan="pro"), nu2)
       == "live identity is a different account" and "stamp_corrected_blob" not in nu2,
       "a foreign-account oracle refuses AND corrects nothing")

    usage.release_lock()
    print(f"\n{_pass} passed, {_fail} failed")
    return 1 if _fail else 0


if __name__ == "__main__":
    sys.exit(main())
