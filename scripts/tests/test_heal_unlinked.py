#!/usr/bin/env python3
"""(v101) Benign UNLINKED auto-heal on the POLL path.

The ACTIVE account's keychain token rotates with use while its bank record lags; the
fail-closed identity oracle reports that (correctly) as UNRESOLVED, and the app painted an
"UNLINKED + Link account" chip for a state the SessionStart hook silently re-banks. usage.py
now heals the same state mid-poll — but ONLY when it is provably that state.

Asserted here: the benign case heals through the sanctioned writer (write_bank_record.py) and
the identity resolves within the same poll; an email mismatch, an unbanked active identity, a
needs-relogin record, a plan-tier change and EPOCH v2 all refuse; and a failed heal arms a
backoff so an unhealable state cannot re-run the writer every cycle.

(r15 #1) Also asserted: the heal requires POSITIVE identity confirmation from the live G9
oracle. The oracle naming a different account refuses, and every non-RESOLVED verdict
(INDETERMINATE/offline, INVALID, a missing primitive, a raising one) refuses — including the
case the v101 docstring documented as an accepted residual, a keychain-first /login installing
an UNBANKED, SAME-PLAN account while ~/.claude.json still names the active one, which every
offline gate passes and only the oracle catches."""
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


def record(email, oauth, status="ok", org="claude_max"):
    return {"email": email, "banked_at": "2026-01-01T00:00:00Z", "banked_at_epoch": 1,
            "status": status, "last_verified": "2026-01-01T00:00:00Z", "last_ping": 0,
            "claudeAiOauth": oauth,
            "oauthAccount": {"emailAddress": email, "organizationType": org}}


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f)


# (r15 #1) stand-in for identity.IdentityResult; the tests never touch the network.
Res = namedtuple("Res", "verdict uuid email plan detail")


def oracle_saying(email, verdict="RESOLVED"):
    """An oracle that resolves EVERY token to `email`. Installed as usage._identity_oracle."""
    return lambda tok: Res(verdict, "uuid-" + str(email), email, "max", "stub")


def main():
    base = tempfile.mkdtemp(prefix="heal-unlinked-")
    bank = os.path.join(base, "bank"); os.makedirs(bank)
    os.environ["BANK_DIR"] = bank
    os.environ["CLAUDE_JSON"] = os.path.join(base, "claude.json")
    os.environ.pop("ACCOUNT_BANK_HEAL_UNLINKED", None)

    import bank_common
    import usage

    a_path = os.path.join(bank, "a@x.com.json")
    banked = cred("v1")
    write_json(a_path, record("a@x.com", banked))
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})

    rotated = cred("v2")          # same account, token rotated ahead of the record
    ok(bank_common.resolve_identity(bank, rotated, "a@x.com") is None,
       "premise: a rotated active token reads as UNRESOLVED (fail-closed oracle)")

    # (r15 #1) the live G9 oracle is the heal's decisive gate; stub it for the whole file so
    # no test reaches the network. Default: the live credential IS a@x.com (the benign case).
    usage._identity_oracle = oracle_saying("a@x.com")

    # the heal is a lock-owning mutation: take the real lock so _LOCK.token is provable
    ok(usage.acquire_lock(timeout=5) is True, "test holds the real bank lock")

    # --- refusals ------------------------------------------------------------
    write_json(a_path, record("a@x.com", banked, status="needs-relogin"))
    ok(usage._benign_drift_refusal("a@x.com", rotated) == "record is needs-relogin",
       "needs-relogin record REFUSES the heal (a real re-login is needed)")
    write_json(a_path, record("a@x.com", banked))

    # the live credential is the CURRENT credential of a DIFFERENT banked account
    b_path = os.path.join(bank, "b@x.com.json")
    write_json(b_path, record("b@x.com", rotated))
    ok(usage._benign_drift_refusal("a@x.com", rotated)
       == "credential belongs to another banked account",
       "a credential owned by another banked account REFUSES the heal (email mismatch)")
    os.remove(b_path)

    # metadata names an account that is not banked at all
    ok(usage._benign_drift_refusal("nobody@x.com", rotated) == "active identity is not banked",
       "an unbanked active identity REFUSES the heal")

    # (v102) a plan-tier change is no longer a refusal — see test_v102_plan_heal.py for the
    # heal + notice. Asserted here only so this file's refusal list stays honest about it.
    ok(usage._benign_drift_refusal("a@x.com", cred("v2", plan="pro")) == "",
       "(v102) an oracle-confirmed plan-tier change is NOT a refusal any more")

    # nothing to heal: the keychain already matches the record
    ok(usage._benign_drift_refusal("a@x.com", banked) == "no drift to heal",
       "an in-sync record REFUSES the heal (UNRESOLVED for some other reason)")

    # EPOCH v2 — no bank-record rail to heal; the v1-mutator gate must fence it
    write_json(os.path.join(bank, "EPOCH"), {"state": "v2", "generation": 3})
    ok(usage._benign_drift_refusal("a@x.com", rotated).startswith("epoch gate refused"),
       "EPOCH v2 REFUSES the heal (v1-mutator gate)")
    write_json(os.path.join(bank, "EPOCH"), {"state": "shadow", "generation": 3})
    ok(usage._benign_drift_refusal("a@x.com", rotated) == "",
       "EPOCH shadow ALLOWS the heal (the shipped hybrid rail)")
    os.remove(os.path.join(bank, "EPOCH"))

    # a SEEDING freeze is the same gate
    open(os.path.join(bank, ".seeding.json"), "w").write("{}")
    ok(usage._benign_drift_refusal("a@x.com", rotated).startswith("epoch gate refused"),
       "an active SEEDING freeze REFUSES the heal")
    os.remove(os.path.join(bank, ".seeding.json"))

    # --- (r15 #1) POSITIVE IDENTITY CONFIRMATION -----------------------------
    # The oracle must NAME the active account. Anything else refuses.
    usage._identity_oracle = oracle_saying("b@x.com")
    ok(usage._benign_drift_refusal("a@x.com", rotated) == "live identity is a different account",
       "(r15 #1) oracle resolving the live credential to ANOTHER email REFUSES the heal")

    for _verdict in ("INDETERMINATE", "INVALID"):
        usage._identity_oracle = oracle_saying("a@x.com", verdict=_verdict)
        ok(usage._benign_drift_refusal("a@x.com", rotated) == "live identity unconfirmed",
           f"(r15 #1) a {_verdict} oracle REFUSES the heal (cannot-confirm is never confirmed)")

    usage._identity_oracle = lambda tok: None
    ok(usage._benign_drift_refusal("a@x.com", rotated) == "live identity unconfirmed",
       "(r15 #1) an UNAVAILABLE oracle (offline / primitive missing) REFUSES the heal")

    def _boom(tok):
        raise RuntimeError("network stack exploded")
    usage._identity_oracle = _boom
    ok(usage._benign_drift_refusal("a@x.com", rotated) == "live identity unconfirmed",
       "(r15 #1) a RAISING oracle REFUSES the heal (and _benign_drift_refusal never raises)")

    # THE RESIDUAL, now closed: a keychain-first /login installs an UNBANKED, SAME-PLAN
    # account while ~/.claude.json still names a@x.com. Offline this is byte-identical to
    # a@x.com's own token rotating — assert that FIRST (every offline gate passes), then that
    # the oracle alone refuses it. Before r15 this state healed and banked b's tokens under
    # a@x.com's email, so "switching to a@x.com" would have authenticated b.
    intruder = cred("intruder")                      # same plan ("max"), NOT banked anywhere
    ok(bank_common.fp_owner(bank, intruder) is None,
       "residual premise: the intruding credential belongs to NO banked account (unbanked)")
    ok(intruder["subscriptionType"] == banked["subscriptionType"],
       "residual premise: the intruder is the SAME plan tier (the plan cross-check passes)")
    usage._identity_oracle = oracle_saying("a@x.com")   # offline gates only -> looks benign
    ok(usage._benign_drift_refusal("a@x.com", intruder) == "",
       "residual premise: every OFFLINE gate passes — this is exactly the v101 residual")
    usage._identity_oracle = oracle_saying("unbanked-b@x.com")   # the truth the endpoint tells
    ok(usage._benign_drift_refusal("a@x.com", intruder) == "live identity is a different account",
       "(r15 #1) the same-plan UNBANKED /login residual now REFUSES (oracle names the intruder)")

    usage._identity_oracle = oracle_saying("a@x.com")

    # --- the benign case, end to end through the sanctioned writer -----------
    ok(usage._benign_drift_refusal("a@x.com", rotated) == "",
       "(r15 #1) oracle-CONFIRMED same email + benign rotation is classified as healable")
    ok(usage._heal_unlinked("a@x.com", rotated) is True,
       "the heal re-banks via write_bank_record.py under the lock we already hold")
    on_disk = json.load(open(a_path))
    ok(bank_common.cred_fingerprint(on_disk["claudeAiOauth"])
       == bank_common.cred_fingerprint(rotated),
       "the bank record now carries the rotated credential")
    ok(bank_common.resolve_identity(bank, rotated, "a@x.com") == "a@x.com",
       "identity RESOLVES after the heal -> no UNLINKED chip in this poll's payload")
    ok(on_disk.get("banked_at") == "2026-01-01T00:00:00Z",
       "the sanctioned writer preserved banked_at (it is the one writer, not a second one)")
    ok(any(e.startswith("a@x.com.") for e in
           os.listdir(os.path.join(bank, "archive"))),
       "the predecessor credential was archived before the overwrite (never-destroy)")

    # --- backoff: a failed heal must not storm ------------------------------
    usage._heal_clear_backoff()
    ok(usage._heal_backoff_active() is False, "no backoff armed after a successful heal")
    usage._heal_mark_failure()
    ok(usage._heal_backoff_active() is True,
       "a failed heal arms a backoff window (no retry storm across polls)")
    ok(os.stat(usage.HEAL_MARKER).st_mode & 0o777 == 0o600, "the backoff marker is 0600")
    ok(not [p for p in os.listdir(bank) if not p.startswith(".") and p.endswith(".json")
            and p not in ("a@x.com.json",)],
       "the marker is a dotfile — never rendered as a bank account")
    usage._heal_clear_backoff()
    ok(usage._heal_backoff_active() is False, "clearing the marker disarms the backoff")

    # the off switch
    usage.HEAL_UNLINKED = False
    ok(usage._benign_drift_refusal("a@x.com", cred("v3")) == "auto-heal disabled",
       "ACCOUNT_BANK_HEAL_UNLINKED=0 refuses every heal")
    usage.HEAL_UNLINKED = True

    usage.release_lock()
    ok(usage._benign_drift_refusal("a@x.com", cred("v4"))
       == "bank lock ownership not provable",
       "without a provable lock token the heal refuses (never contends with itself)")

    # --- the call site: a full poll heals and emits a chip-free payload ------
    # (the app renders UNLINKED purely from the `(active/unresolved)` entry, so its absence
    # IS the chip-visibility contract — no new pipe field, no transient "healing" state.)
    usage.CACHE_FILE = os.path.join(bank, ".usage-cache.json")
    rotated2 = cred("v3")
    usage._reconcile = None
    usage._stable_identity = lambda retries=3: ("a@x.com", rotated2, True)
    usage.process_claude = lambda email, oauth, is_active, bank_path, status, oauth_account=None: (
        {"provider": "claude", "email": email, "active": is_active, "status": "ok",
         "worst_limit": {"percent": 5.0}, "fetched_at": usage.now()}, False)
    usage.process_codex = lambda: (None, False)
    usage.maybe_autoping = lambda results, bank_paths: []
    usage.main()
    doc = json.load(open(usage.CACHE_FILE))
    emails = [a.get("email") for a in doc.get("accounts", []) if a.get("provider") == "claude"]
    ok("(active/unresolved)" not in emails,
       "a healed poll emits NO unresolved entry -> the UNLINKED chip never renders")
    ok("a@x.com" in emails and not any(a.get("unresolved") for a in doc.get("accounts", [])),
       "the active account is reported under its real identity, unresolved flag absent")
    ok(bank_common.cred_fingerprint(json.load(open(a_path))["claudeAiOauth"])
       == bank_common.cred_fingerprint(rotated2),
       "the poll's heal landed the newly rotated credential in the bank record")

    # (r15 #1) the same end-to-end path with an oracle that cannot answer: the poll must
    # leave BOTH the chip and the bank record exactly as they were. This is the offline
    # contract — a full poll with no reachable oracle can mutate nothing.
    before_fp = bank_common.cred_fingerprint(json.load(open(a_path))["claudeAiOauth"])
    usage._identity_oracle = lambda tok: Res("INDETERMINATE", "", "", "", "offline")
    usage._stable_identity = lambda retries=3: ("a@x.com", cred("v4"), True)
    usage._heal_clear_backoff()
    usage.main()
    doc = json.load(open(usage.CACHE_FILE))
    ok("(active/unresolved)" in [a.get("email") for a in doc.get("accounts", [])],
       "(r15 #1) an OFFLINE poll cannot confirm identity -> the UNLINKED chip stands")
    ok(bank_common.cred_fingerprint(json.load(open(a_path))["claudeAiOauth"]) == before_fp,
       "(r15 #1) an OFFLINE poll left the bank record byte-identical (no blind re-bank)")
    usage._identity_oracle = oracle_saying("a@x.com")
    usage._heal_clear_backoff()

    # a NON-benign unresolved state still surfaces the chip after a full poll
    write_json(os.path.join(bank, "b@x.com.json"), record("b@x.com", cred("bee"), org="claude_max"))
    usage._stable_identity = lambda retries=3: ("a@x.com", cred("bee"), True)
    usage.main()
    doc = json.load(open(usage.CACHE_FILE))
    ok("(active/unresolved)" in [a.get("email") for a in doc.get("accounts", [])],
       "a credential owned by another banked account still renders UNLINKED (needs attention)")

    print(f"  -- heal_unlinked: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
