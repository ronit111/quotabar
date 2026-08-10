#!/usr/bin/env python3
"""(v102) ITEM 1 — oracle-confirmed PLAN-TIER changes heal, and the signal survives.

Before v102 a plan-tier change was the one drift class NEITHER path wrote: the SessionStart
hook announced it and deferred, and the poll heal refused it outright. The owner was left
with an UNLINKED chip and a manual bank-account.sh. The r15 #1 oracle removed the reason for
that refusal — it positively confirms the credential belongs to the SAME email — so a plan
change is now a benign same-account event and heals like any other rotation.

The heal must not swallow the news. Asserted here:
  * an oracle-confirmed plan change is classified healable, heals through the sanctioned
    writer, and records a healed_plan_change notice carrying both tiers;
  * the notice reaches the app on the health pipe, expires on its own, and can be acked;
  * NOTHING else about the gate moved: an oracle naming another account, an INDETERMINATE /
    INVALID / missing / raising oracle, and every offline refusal still refuse a plan change
    exactly as they refuse a plain rotation — and a refused heal writes no notice;
  * the notice is only written after the WRITER succeeded (a failed write is not news);
  * the backoff marker and the notice share one file without clobbering each other.
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


def record(email, oauth, status="ok", org="claude_max"):
    return {"email": email, "banked_at": "2026-01-01T00:00:00Z", "banked_at_epoch": 1,
            "status": status, "last_verified": "2026-01-01T00:00:00Z", "last_ping": 0,
            "claudeAiOauth": oauth,
            "oauthAccount": {"emailAddress": email, "organizationType": org}}


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f)


Res = namedtuple("Res", "verdict uuid email plan detail")


def oracle_saying(email, verdict="RESOLVED", plan="max"):
    # (v103) `plan` must be SCENARIO-CONSISTENT now: the stamp correction reads it, so a
    # stub reporting a plan the scenario contradicts is stating a different scenario.
    return lambda tok: Res(verdict, "uuid-" + str(email), email, plan, "stub")


def main():
    base = tempfile.mkdtemp(prefix="v102-plan-heal-")
    bank = os.path.join(base, "bank"); os.makedirs(bank)
    os.environ["BANK_DIR"] = bank
    os.environ["CLAUDE_JSON"] = os.path.join(base, "claude.json")
    os.environ.pop("ACCOUNT_BANK_HEAL_UNLINKED", None)

    import bank_common
    import usage

    a_path = os.path.join(bank, "a@x.com.json")
    banked = cred("v1", plan="max")                  # banked: MAX
    write_json(a_path, record("a@x.com", banked))
    # the account really did upgrade/downgrade: the LIVE metadata moved with the credential,
    # which is why write_bank_record's live-vs-live plan cross-check still passes.
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_pro"}})
    upgraded = cred("v2", plan="pro")                # live: PRO, same account

    usage._identity_oracle = oracle_saying("a@x.com")
    ok(usage.acquire_lock(timeout=5) is True, "test holds the real bank lock")

    ok(bank_common.resolve_identity(bank, upgraded, "a@x.com") is None,
       "premise: the plan-changed credential reads as UNRESOLVED (the UNLINKED chip state)")

    # --- classification + the note the caller collects ------------------------
    note = {}
    ok(usage._benign_drift_refusal("a@x.com", upgraded, note) == "",
       "an oracle-confirmed plan change is HEALABLE (it was 'plan tier changed' in v101)")
    ok(note.get("healed_plan_change") == {"from": "max", "to": "pro", "email": "a@x.com"},
       "the refusal gate hands the caller both tiers and the account")

    # a rotation with NO plan change collects no note at all
    note2 = {}
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})
    ok(usage._benign_drift_refusal("a@x.com", cred("v3", plan="max"), note2) == ""
       and note2 == {},
       "a plain rotation heals with NO plan-change notice (nothing to announce)")

    # a tier that only LOOKS different is not a change (plan_tier is THE rule)
    note3 = {}
    ok(usage._benign_drift_refusal("a@x.com", cred("v4", plan="claude_max_20x"), note3) == ""
       and note3 == {},
       "claude_max_20x vs max is the SAME tier — not announced as a plan change")

    # a side with NO tier from EITHER source is no evidence of a change
    note4 = {}
    _no_plan = {k: v for k, v in cred("v5").items() if k != "subscriptionType"}
    write_json(os.environ["CLAUDE_JSON"], {"oauthAccount": {"emailAddress": "a@x.com"}})
    ok(usage._benign_drift_refusal("a@x.com", _no_plan, note4) == "" and note4 == {},
       "no organizationType AND no subscriptionType is not a plan change (KNOWN-vs-KNOWN only)")
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})

    # --- (v102-r2) THE UNCHANGED-TOKEN PLAN CHANGE ----------------------------
    # The case every existing fixture missed, because they all rotate a token field. A real
    # subscription change does not have to touch the credential at all: the tokens stay put and
    # only subscriptionType moves. Credential fingerprints exclude subscriptionType by design,
    # so that change was invisible to every fingerprint comparison in the stack — the hook
    # classified it "no drift to re-bank", the resolver said RESOLVED, and the poll's heal block
    # (gated on `not identity_resolved`) never ran. The tier the bank record reported was stale
    # indefinitely, and autopick reads that tier.
    same_tokens_pro = dict(banked, subscriptionType="pro")
    ok(bank_common.same_credentials(same_tokens_pro, banked) is True,
       "premise: only the plan moved — the CREDENTIAL is byte-identical to the banked one")
    ok(bank_common.resolve_identity(bank, same_tokens_pro, "a@x.com") == "a@x.com",
       "premise: identity RESOLVES, so nothing here looks like drift (the bypass)")
    ok(bank_common.hook_rebank_refusal(same_tokens_pro, banked) == "the plan tier changed",
       "the hook classifies it as a PLAN CHANGE, not as 'no drift to re-bank'")
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_pro"}})
    ok(usage._banked_plan_is_stale("a@x.com", same_tokens_pro) is True,
       "the poll notices the banked tier is stale even though identity resolved")
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})
    ok(usage._banked_plan_is_stale("a@x.com", banked) is False,
       "...and says nothing when the banked tier already agrees")

    # (v102-r3) THE SOURCE THE TRIGGER READS. Both comparisons used to read only the
    # credential's subscriptionType — the field cached at /login, and therefore the one a plan
    # change is least likely to have moved. A downgrade whose keychain still says `max` (or says
    # nothing at all) then read as no drift: the trigger stayed silent, the heal was never
    # attempted, the oracle was never asked, and autopick went on ranking the account as MAX.
    # organizationType is what ~/.claude.json rewrites each session, so it decides — on BOTH
    # sides — with subscriptionType only as a fallback.
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_pro"}})
    _stale_kc = dict(banked, subscriptionType="max")     # keychain plan metadata never moved
    ok(usage._banked_plan_is_stale("a@x.com", _stale_kc) is True,
       "a live organizationType downgrade is caught even when the keychain still says max")
    _absent_kc = {k: v for k, v in banked.items() if k != "subscriptionType"}
    ok(usage._banked_plan_is_stale("a@x.com", _absent_kc) is True,
       "...and when the keychain carries no plan at all (absent is not agreement)")
    n = {}
    ok(usage._benign_drift_refusal("a@x.com", _stale_kc, n) == ""
       and n.get("healed_plan_change") == {"from": "max", "to": "pro", "email": "a@x.com"},
       "...and the refusal gate reads the same source, so trigger and heal cannot disagree")

    n = {}
    ok(usage._benign_drift_refusal("a@x.com", same_tokens_pro, n) == "",
       "an unchanged-token plan change is HEALABLE (it was 'no drift to heal')")
    ok(n.get("healed_plan_change") == {"from": "max", "to": "pro", "email": "a@x.com"},
       "...and it announces the same way a token-rotating one does")
    # It reaches the healer through the SAME gate, not around it: the oracle still decides.
    usage._identity_oracle = oracle_saying("a@x.com", verdict="INDETERMINATE")
    n = {}
    ok(usage._benign_drift_refusal("a@x.com", same_tokens_pro, n) == "live identity unconfirmed"
       and n == {},
       "an unconfirmable oracle refuses it too — no plan-only fast path past the oracle")
    usage._identity_oracle = oracle_saying("b@x.com")
    ok(usage._benign_drift_refusal("a@x.com", same_tokens_pro)
       == "live identity is a different account",
       "...and an oracle naming another account refuses it")
    usage._identity_oracle = oracle_saying("a@x.com")

    # --- every OTHER gate is untouched: a plan change gets no special pass ----
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_pro"}})
    for _verdict in ("INDETERMINATE", "INVALID"):
        n = {}
        usage._identity_oracle = oracle_saying("a@x.com", verdict=_verdict)
        ok(usage._benign_drift_refusal("a@x.com", upgraded, n) == "live identity unconfirmed"
           and n == {},
           f"a {_verdict} oracle still REFUSES a plan change (and records no notice)")

    usage._identity_oracle = oracle_saying("b@x.com")
    n = {}
    ok(usage._benign_drift_refusal("a@x.com", upgraded, n)
       == "live identity is a different account" and n == {},
       "an oracle naming ANOTHER account still refuses — a plan change is not a loophole")

    usage._identity_oracle = lambda tok: None
    ok(usage._benign_drift_refusal("a@x.com", upgraded) == "live identity unconfirmed",
       "an UNAVAILABLE oracle still refuses a plan change (offline can never heal)")

    def _boom(tok):
        raise RuntimeError("network stack exploded")
    usage._identity_oracle = _boom
    ok(usage._benign_drift_refusal("a@x.com", upgraded) == "live identity unconfirmed",
       "a RAISING oracle still refuses a plan change")

    usage._identity_oracle = oracle_saying("a@x.com")

    # the offline refusals short-circuit before the plan change is even considered
    write_json(a_path, record("a@x.com", banked, status="needs-relogin"))
    ok(usage._benign_drift_refusal("a@x.com", upgraded) == "record is needs-relogin",
       "a needs-relogin record still refuses, plan change or not")
    write_json(a_path, record("a@x.com", banked))

    b_path = os.path.join(bank, "b@x.com.json")
    write_json(b_path, record("b@x.com", upgraded))
    ok(usage._benign_drift_refusal("a@x.com", upgraded)
       == "credential belongs to another banked account",
       "a plan-changed credential owned by ANOTHER banked account still refuses")
    os.remove(b_path)

    write_json(os.path.join(bank, "EPOCH"), {"state": "v2", "generation": 3})
    ok(usage._benign_drift_refusal("a@x.com", upgraded).startswith("epoch gate refused"),
       "EPOCH v2 still fences the heal (no bank-record rail to write)")
    os.remove(os.path.join(bank, "EPOCH"))

    # --- the heal itself, end to end -----------------------------------------
    ok(usage._heal_unlinked("a@x.com", upgraded) is True,
       "the plan-changed credential re-banks through write_bank_record.py")
    on_disk = json.load(open(a_path))
    ok(on_disk["claudeAiOauth"].get("subscriptionType") == "pro",
       "the bank record now carries the NEW plan tier")
    ok(bank_common.resolve_identity(bank, upgraded, "a@x.com") == "a@x.com",
       "identity RESOLVES after the heal -> the UNLINKED chip is gone")
    ok(any(e.startswith("a@x.com.") for e in os.listdir(os.path.join(bank, "archive"))),
       "the predecessor credential was archived before the overwrite (never-destroy)")

    # --- the metadata-lag window: the writer's live-vs-live check still bites --
    # ~/.claude.json's organizationType can trail the credential's subscriptionType during a
    # real upgrade. (v102-r3) The gate no longer calls that a plan CHANGE: organizationType is
    # the tier authority on both sides and it has not moved, so this is a plain rotation with
    # nothing to announce — which is also the only reading that does not fire the trigger on
    # every poll for a state no write can reach. write_bank_record still refuses the write
    # outright, because a credential whose subscriptionType disagrees with the live
    # organizationType is its crossed-identity tell: the heal FAILS either way — chip stands,
    # backoff armed, retry next cycle — and announces nothing.
    write_json(a_path, record("a@x.com", cred("lag1", plan="max")))
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}})
    lagged = cred("lag2", plan="pro")            # credential moved, metadata has not
    # (v103) in THIS story the account really is moving to pro, so the live oracle says pro —
    # it disagrees with the lagging metadata, which is exactly why no stamp correction fires
    # and the writer's conservative refusal below still stands. (The same bytes with an oracle
    # AGREEING with the metadata are the frozen-stamp upgrade — test_v103_stamp_heal.py.)
    usage._identity_oracle = oracle_saying("a@x.com", plan="pro")
    n = {}
    ok(usage._benign_drift_refusal("a@x.com", lagged, n) == "" and n == {},
       "a metadata-lagged credential is a rotation, not an announced plan change (v102-r3)")
    ok(usage._banked_plan_is_stale("a@x.com", lagged) is False,
       "...and the trigger does not fire on it either — both sides read organizationType")
    ok(usage._heal_unlinked("a@x.com", lagged) is False,
       "...while the writer REFUSES it anyway: organizationType disagrees with the credential")
    ok(json.load(open(a_path))["claudeAiOauth"]["accessToken"] == "at-lag1",
       "...leaving the bank record untouched (fail closed, retry next poll)")
    usage._identity_oracle = oracle_saying("a@x.com")
    write_json(a_path, record("a@x.com", banked))
    write_json(os.environ["CLAUDE_JSON"],
               {"oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_pro"}})
    ok(usage._heal_unlinked("a@x.com", upgraded) is True,
       "...and once the metadata catches up the same heal succeeds")

    # --- the notice ----------------------------------------------------------
    usage._heal_note_plan_change({"from": "max", "to": "pro", "email": "a@x.com"})
    n = usage._heal_notice()
    ok(isinstance(n, dict) and n["from"] == "max" and n["to"] == "pro"
       and n["email"] == "a@x.com" and n["ts"] > 0,
       "the notice records both tiers, the account, and when it happened")
    ok(usage._health_surface().get("healed_plan_change") == n,
       "the notice reaches the app on the health pipe")
    ok(os.stat(usage.HEAL_MARKER).st_mode & 0o777 == 0o600, "the marker file is 0600")
    ok(not [p for p in os.listdir(bank) if not p.startswith(".") and p.endswith(".json")
            and p != "a@x.com.json"],
       "the marker stays a dotfile — never rendered as a bank account")

    # notice + backoff share one file and must not clobber each other
    usage._heal_mark_failure()
    ok(usage._heal_backoff_active() is True and usage._heal_notice() is not None,
       "arming the backoff preserves a pending notice")
    usage._heal_clear_backoff()
    ok(usage._heal_backoff_active() is False and usage._heal_notice() is not None,
       "clearing the backoff preserves the notice (it drops a field, not the file)")

    # TTL: an unacknowledged notice does not become permanent chrome. Age the notice rather
    # than shrinking the window, so the assertion cannot race the clock.
    _d = usage._heal_marker_read()
    _fresh_ts = _d["healed_plan_change"]["ts"]
    _d["healed_plan_change"]["ts"] = _fresh_ts - int(usage.HEAL_NOTICE_TTL) - 60
    usage._heal_marker_write(_d)
    ok(usage._heal_notice() is None and "healed_plan_change" not in usage._health_surface(),
       "a notice older than HEAL_NOTICE_TTL stops being surfaced (no ack required)")
    _d["healed_plan_change"]["ts"] = _fresh_ts
    usage._heal_marker_write(_d)
    ok(usage._heal_notice() is not None, "...and it was expiry, not deletion, that hid it")

    # the ack path makes it genuinely one-time
    usage.release_lock()
    ok(usage._ack_heal_notice() == 0, "--ack-heal-notice succeeds when it can take the lock")
    ok(usage._heal_notice() is None and "healed_plan_change" not in usage._health_surface(),
       "an acknowledged notice is gone from the pipe")
    ok(usage._ack_heal_notice() == 0, "acking twice is a clean no-op")

    # a CONTENDED ack must not silently look like a successful one: QuotaBar drives this
    # through its action queue, and a lost ack has to leave the notice standing for a retry.
    usage._heal_note_plan_change({"from": "max", "to": "pro", "email": "a@x.com"})
    _other = usage.banklock.BankLock(bank)
    ok(_other.acquire(timeout=5) is True, "a second holder takes the bank lock")
    os.environ["ACCOUNT_BANK_LOCK_WAIT"] = "1"        # don't burn the default wait in a test
    ok(usage._ack_heal_notice() == 1, "an ack that cannot take the lock reports failure (rc 1)")
    ok(usage._heal_notice() is not None, "...and the notice is RETAINED for the next attempt")
    os.environ.pop("ACCOUNT_BANK_LOCK_WAIT")
    _other.release()
    ok(usage._ack_heal_notice() == 0 and usage._heal_notice() is None,
       "...and clears once the lock frees up")

    ok(usage.acquire_lock(timeout=5) is True, "re-take the lock for the remaining cases")

    # a REFUSED heal writes no notice — the call site only records after a real write
    usage._identity_oracle = oracle_saying("b@x.com")
    n = {}
    usage._benign_drift_refusal("a@x.com", cred("v9", plan="free"), n)
    ok(n == {} and usage._heal_notice() is None,
       "a refused plan change announces nothing (no notice for a write that never happened)")
    usage._identity_oracle = oracle_saying("a@x.com")

    # --- the call site: one full poll heals, resolves, and announces ---------
    usage.release_lock()
    base2 = tempfile.mkdtemp(prefix="v102-plan-poll-")
    bank2 = os.path.join(base2, "bank"); os.makedirs(bank2)
    usage.BANK_DIR = bank2
    usage.HEAL_MARKER = os.path.join(bank2, ".unlinked-heal.json")
    usage.CACHE_FILE = os.path.join(bank2, ".usage-cache.json")
    usage.CLAUDE_JSON = os.path.join(base2, "claude.json")
    usage._LOCK = usage.banklock.BankLock(bank2)
    c_path = os.path.join(bank2, "c@x.com.json")
    write_json(c_path, record("c@x.com", cred("c1", plan="max")))
    write_json(usage.CLAUDE_JSON,
               {"oauthAccount": {"emailAddress": "c@x.com", "organizationType": "claude_pro"}})
    c_up = cred("c2", plan="pro")

    usage._reconcile = None
    usage._identity_oracle = oracle_saying("c@x.com")
    usage._stable_identity = lambda retries=3: ("c@x.com", c_up, True)
    usage.process_claude = lambda email, oauth, is_active, bank_path, status, oauth_account=None: (
        {"provider": "claude", "email": email, "active": is_active, "status": "ok",
         "worst_limit": {"percent": 5.0}, "fetched_at": usage.now()}, False)
    usage.process_codex = lambda: (None, False)
    usage.maybe_autoping = lambda results, bank_paths: []
    usage.main()

    doc = json.load(open(usage.CACHE_FILE))
    emails = [a.get("email") for a in doc.get("accounts", []) if a.get("provider") == "claude"]
    ok("(active/unresolved)" not in emails,
       "the poll healed the plan change -> no UNLINKED chip in the payload")
    ok(json.load(open(c_path))["claudeAiOauth"].get("subscriptionType") == "pro",
       "the poll's heal landed the new plan tier in the bank record")
    hp = (doc.get("health") or {}).get("healed_plan_change")
    ok(isinstance(hp, dict) and hp.get("from") == "max" and hp.get("to") == "pro"
       and hp.get("email") == "c@x.com",
       "the SAME poll's payload carries the healed_plan_change notice (fixed AND reported)")

    # a second poll with nothing new must not re-heal, and must keep showing the notice
    usage.main()
    doc2 = json.load(open(usage.CACHE_FILE))
    ok((doc2.get("health") or {}).get("healed_plan_change", {}).get("ts") == hp.get("ts"),
       "the notice is not re-stamped by later polls (one event, one notice)")

    # (v102-r2) the same thing end to end: a poll where identity RESOLVES throughout and the
    # ONLY drift is the plan tier. Before the fix this poll did nothing at all — no chip to
    # prompt anyone, no heal, no notice, and a bank record that kept saying MAX forever.
    base3 = tempfile.mkdtemp(prefix="v102-plan-poll-unchanged-")
    bank3 = os.path.join(base3, "bank"); os.makedirs(bank3)
    usage.BANK_DIR = bank3
    usage.HEAL_MARKER = os.path.join(bank3, ".unlinked-heal.json")
    usage.CACHE_FILE = os.path.join(bank3, ".usage-cache.json")
    usage.CLAUDE_JSON = os.path.join(base3, "claude.json")
    usage._LOCK = usage.banklock.BankLock(bank3)
    d_path = os.path.join(bank3, "d@x.com.json")
    d_banked = cred("d1", plan="max")
    write_json(d_path, record("d@x.com", d_banked))
    write_json(usage.CLAUDE_JSON,
               {"oauthAccount": {"emailAddress": "d@x.com", "organizationType": "claude_pro"}})
    d_live = dict(d_banked, subscriptionType="pro")      # SAME tokens, new plan
    usage._identity_oracle = oracle_saying("d@x.com")
    usage._stable_identity = lambda retries=3: ("d@x.com", d_live, True)
    ok(bank_common.resolve_identity(bank3, d_live, "d@x.com") == "d@x.com",
       "premise: this poll's identity is RESOLVED from the first line to the last")
    usage.main()
    ok(json.load(open(d_path))["claudeAiOauth"].get("subscriptionType") == "pro",
       "the poll healed a plan-ONLY change: the bank record no longer reports a stale tier")
    doc3 = json.load(open(usage.CACHE_FILE))
    hp3 = (doc3.get("health") or {}).get("healed_plan_change")
    ok(isinstance(hp3, dict) and hp3.get("from") == "max" and hp3.get("to") == "pro"
       and hp3.get("email") == "d@x.com",
       "...and announced it, which is the only way the owner learns their plan changed")

    print(f"  -- v102_plan_heal: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
