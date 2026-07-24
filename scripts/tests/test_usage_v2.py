#!/usr/bin/env python3
"""(r8 #3 + #8) usage.py under the v2 control plane.

#3: accounts/ (== BANK_DIR) holds v2 control-plane JSON (registry.json, sessions.json,
    archiver.status.json). The `*.json` bank glob matches them, and pre-fix they were
    rendered as malformed "account" error cards. They must be SKIPPED, never parsed.
#8: under EPOCH v2 the ACTIVE account is the POINTER target, not the shared keychain
    slot. A stale keychain leftover (A) must NOT be shown ACTIVE while the pointer names
    a different home (B); active_email must be B.

Fully hermetic: every network/keychain/lock path is stubbed; only the local control
files + pointer + registry are real.
"""
import json
import os
import sys
import tempfile

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


def run_usage(bank):
    import usage
    usage.BANK_DIR = bank
    usage.CACHE_FILE = os.path.join(bank, ".usage-cache.json")
    usage.CLAUDE_JSON = os.path.join(bank, "claude.json")
    usage.acquire_lock = lambda timeout=10: True
    usage.release_lock = lambda: None
    usage._reconcile = None
    usage.process_codex = lambda: (None, False)
    if not hasattr(usage, "_REAL_MAYBE_AUTOPING"):
        usage._REAL_MAYBE_AUTOPING = usage.maybe_autoping   # stash before stubbing
    usage.maybe_autoping = lambda results, bank_paths: []

    def fake_process_claude(email, oauth, is_active, bank_path, status, oauth_account=None):
        return ({"provider": "claude", "email": email, "active": is_active, "status": "ok",
                 "worst_limit": {"percent": 5.0}, "fetched_at": usage.now()}, False)
    usage.process_claude = fake_process_claude
    usage.main()
    return json.load(open(usage.CACHE_FILE))


def main():
    import epoch, registry, repoint
    import usage as _u
    _real_process_claude = _u.process_claude   # capture BEFORE run_usage stubs it (r13 #7)

    # --- #3: control-plane files must not be parsed as accounts -------------------
    base = tempfile.mkdtemp(prefix="usage-v2-3-")
    bank = os.path.join(base, "accounts"); os.makedirs(os.path.join(bank, "homes"))
    # a legit bank record
    with open(os.path.join(bank, "real@x.com.json"), "w") as f:
        json.dump({"email": "real@x.com", "status": "ok", "banked_at": "x", "banked_at_epoch": 1,
                   "claudeAiOauth": {"accessToken": "R", "refreshToken": "rR", "expiresAt": 9,
                                     "subscriptionType": "max"},
                   "oauthAccount": {"emailAddress": "real@x.com", "organizationType": "claude_max"}}, f)
    # v2 control-plane files that also match *.json
    for name in ("sessions.json", "archiver.status.json", "attestation.json", "quotabar.runtime.json"):
        with open(os.path.join(bank, name), "w") as f:
            json.dump({"some": "control-plane state"}, f)
    home_real = os.path.join(bank, "homes", "real"); os.makedirs(home_real)
    registry.publish_ready(bank, "real@x.com", home_real, "uuid-real")  # writes registry.json

    os.environ["BANK_DIR"] = bank
    doc = run_usage(bank)
    claude_emails = [a.get("email") for a in doc["accounts"] if a.get("provider") == "claude"]
    control_stems = {"registry", "sessions", "archiver.status", "attestation", "quotabar.runtime"}
    ok(not (control_stems & set(claude_emails)),
       f"(r8 #3) no control-plane file rendered as an account card (emails={claude_emails})")
    ok(not any(a.get("error") and a.get("email") in control_stems for a in doc["accounts"]),
       "(r8 #3) no error card synthesized for a control-plane JSON file")
    ok("real@x.com" in claude_emails, "(r8 #3) the real account still surfaces")

    # --- #8: under v2 the active account is the POINTER target, not the keychain ---
    base2 = tempfile.mkdtemp(prefix="usage-v2-8-")
    bank2 = os.path.join(base2, "accounts"); os.makedirs(os.path.join(bank2, "homes"))
    home_b = os.path.join(bank2, "homes", "b-at-x.com"); os.makedirs(home_b)
    # bank record for A (the stale keychain-active leftover)
    with open(os.path.join(bank2, "a@x.com.json"), "w") as f:
        json.dump({"email": "a@x.com", "status": "ok", "banked_at": "x", "banked_at_epoch": 1,
                   "claudeAiOauth": {"accessToken": "A", "refreshToken": "rA", "expiresAt": 9,
                                     "subscriptionType": "max"},
                   "oauthAccount": {"emailAddress": "a@x.com", "organizationType": "claude_max"}}, f)
    registry.publish_ready(bank2, "b@x.com", home_b, "uuid-b")
    epoch.write_epoch(bank2, "v2", 5)
    repoint.repoint(bank2, home_b, "test", registry_check=lambda h: registry.is_ready_home(bank2, h))

    import usage
    # keychain says the active account is A (a v1-era leftover). Under v2 that must NOT win.
    usage._stable_identity = lambda retries=3: ("a@x.com",
                                                {"accessToken": "A", "refreshToken": "rA",
                                                 "expiresAt": 9, "subscriptionType": "max"}, True)
    os.environ["BANK_DIR"] = bank2
    doc2 = run_usage(bank2)
    a_entry = next((a for a in doc2["accounts"] if a.get("email") == "a@x.com"), None)
    ok(a_entry is not None and a_entry.get("active") is False,
       "(r8 #8) stale keychain account A is NOT shown ACTIVE under v2")
    ok(doc2.get("active_email") == "b@x.com",
       f"(r8 #8) active_email is the pointer target B, not the keychain A (got {doc2.get('active_email')})")

    # --- #6: set_bank_status must NOT rewrite a legacy v1 record under EPOCH v2 --------
    base6 = tempfile.mkdtemp(prefix="usage-v2-6-")
    bank6 = os.path.join(base6, "accounts"); os.makedirs(bank6)
    recp = os.path.join(bank6, "leg@x.com.json")
    with open(recp, "w") as f:
        json.dump({"email": "leg@x.com", "status": "needs-relogin"}, f)
    usage.BANK_DIR = bank6
    usage.LOCKED = True
    # EPOCH v2 present -> the rewrite is a forbidden v1 mutation -> skipped
    epoch.write_epoch(bank6, "v2", 3)
    usage.set_bank_status(recp, "ok")
    ok(json.load(open(recp)).get("status") == "needs-relogin" and "last_verified" not in json.load(open(recp)),
       "(r8 #6) set_bank_status does NOT rewrite a v1 record under EPOCH v2")
    # shadow permits it (v1 mutators run in v1|shadow)
    epoch.write_epoch(bank6, "shadow", 4)
    usage.set_bank_status(recp, "ok")
    ok(json.load(open(recp)).get("status") == "ok",
       "(r8 #6) set_bank_status DOES write under EPOCH shadow (v1|shadow allowed)")

    # (r12 #12) even under shadow, an active SEEDING freeze must BLOCK set_bank_status (it is
    # a v1 mutator; the full v1_gate — not just the epoch state — includes the freeze check).
    with open(os.path.join(bank6, "leg@x.com.json"), "w") as f:
        json.dump({"email": "leg@x.com", "status": "needs-relogin"}, f)   # reset to observe a block
    open(os.path.join(bank6, ".seeding.json"), "w").write('{"phase": "LOGIN_STARTED"}')
    usage.set_bank_status(recp, "ok")
    ok(json.load(open(recp)).get("status") == "needs-relogin",
       "(r12 #12) set_bank_status is BLOCKED by an active SEEDING freeze, even under shadow")
    os.remove(os.path.join(bank6, ".seeding.json"))

    # --- #8: v2 READY homes with NO legacy <email>.json are discovered from the registry --
    base8 = tempfile.mkdtemp(prefix="usage-v2-8b-")
    bank8 = os.path.join(base8, "accounts"); os.makedirs(os.path.join(bank8, "homes"))
    home_v2 = os.path.join(bank8, "homes", "v2only-at-x.com"); os.makedirs(home_v2)
    # the home's OWN credential + per-home metadata — the only record for this account
    with open(os.path.join(home_v2, ".credentials.json"), "w") as f:
        json.dump({"claudeAiOauth": {"accessToken": "V2", "refreshToken": "rV2", "expiresAt": 9,
                                     "subscriptionType": "max"}}, f)
    with open(os.path.join(home_v2, ".claude.json"), "w") as f:
        json.dump({"oauthAccount": {"emailAddress": "v2only@x.com", "organizationType": "claude_max"}}, f)
    registry.publish_ready(bank8, "v2only@x.com", home_v2, "uuid-v2only")
    epoch.write_epoch(bank8, "v2", 1)
    # NO v2only@x.com.json bank record exists anywhere
    ok(not os.path.exists(os.path.join(bank8, "v2only@x.com.json")), "precondition: no legacy record")
    os.environ["BANK_DIR"] = bank8
    doc8 = run_usage(bank8)
    v2_emails = [a.get("email") for a in doc8["accounts"] if a.get("provider") == "claude"]
    ok("v2only@x.com" in v2_emails,
       f"(r11 #8) a v2 READY home with no legacy record IS discovered + monitored (emails={v2_emails})")

    # --- #7: a v2 READY home with an EXPIRED token is NEVER parked-refreshed (monitor-only) ---
    base7 = tempfile.mkdtemp(prefix="usage-v2-7-")
    bank7 = os.path.join(base7, "accounts"); os.makedirs(os.path.join(bank7, "homes"))
    home7 = os.path.join(bank7, "homes", "exp-at-x.com"); os.makedirs(home7)
    with open(os.path.join(home7, ".credentials.json"), "w") as f:
        json.dump({"claudeAiOauth": {"accessToken": "EXP", "refreshToken": "rEXP",
                                     "expiresAt": 1, "subscriptionType": "max"}}, f)  # expiresAt=1 -> expired
    registry.publish_ready(bank7, "exp@x.com", home7, "uuid-exp")
    epoch.write_epoch(bank7, "shadow", 1)
    import usage
    usage.BANK_DIR = bank7
    usage.CACHE_FILE = os.path.join(bank7, ".usage-cache.json")
    usage.CLAUDE_JSON = os.path.join(bank7, "claude.json")
    usage.acquire_lock = lambda timeout=10: True
    usage.release_lock = lambda: None
    usage._reconcile = None
    usage.process_codex = lambda: (None, False)
    if not hasattr(usage, "_REAL_MAYBE_AUTOPING"):
        usage._REAL_MAYBE_AUTOPING = usage.maybe_autoping   # stash before stubbing
    usage.maybe_autoping = lambda results, bank_paths: []
    usage._stable_identity = lambda retries=3: ("legacy@x.com", None, True)
    # FAIL LOUD if the legacy refresh is ever invoked for a v2 home
    def _boom(*a, **k):
        raise AssertionError("v2 home must NOT be parked-refreshed (r13 #7)")
    if usage.isolated_refresh is not None:
        usage.isolated_refresh.refresh_via_config_dir = _boom
    # earlier blocks (via run_usage) stubbed process_claude — restore the REAL one so the
    # monitor-only refresh guard is actually exercised.
    usage.process_claude = _real_process_claude
    os.environ["BANK_DIR"] = bank7
    usage.main()
    doc7 = json.load(open(usage.CACHE_FILE))
    e7 = next((a for a in doc7["accounts"] if a.get("email") == "exp@x.com"), None)
    ok(e7 is not None and e7.get("monitor_only") is True,
       "(r13 #7) an expired v2 home is MONITOR-ONLY, not parked-refreshed (no token spend)")
    ok(e7 is not None and "monitor-only" in str(e7.get("error", "")),
       "(r13 #7) v2 home surfaces the monitor-only reason (rotation owned by the home)")

    # --- (seat) a v2 home whose credential SEAT is the SLOT (file migrated away) is discovered ---
    import seedflow as _sf
    base9 = tempfile.mkdtemp(prefix="usage-v2-seat-")
    bank9 = os.path.join(base9, "accounts"); os.makedirs(os.path.join(bank9, "homes"))
    home9 = os.path.join(bank9, "homes", "slot-at-x.com"); os.makedirs(home9)   # NO .credentials.json
    with open(os.path.join(home9, ".claude.json"), "w") as f:
        json.dump({"oauthAccount": {"emailAddress": "slot@x.com", "organizationType": "claude_max"}}, f)
    fk9 = os.path.join(bank9, "fkc")
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = fk9
    with open(_sf._fake_slot_path(fk9, _sf.config_slot_service(home9)), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"SLOT9","refreshToken":"r","expiresAt":9999999999999,"subscriptionType":"max"}}')
    registry.publish_ready(bank9, "slot@x.com", home9, "uuid-slot")
    epoch.write_epoch(bank9, "v2", 1)
    usage._stable_identity = lambda retries=3: (None, None, True)
    os.environ["BANK_DIR"] = bank9
    try:
        doc9 = run_usage(bank9)
    finally:
        os.environ.pop("ACCOUNT_BANK_FAKE_KEYCHAIN", None)
    emails9 = [a.get("email") for a in doc9["accounts"] if a.get("provider") == "claude"]
    ok("slot@x.com" in emails9,
       f"(seat) a v2 home with a SLOT seat (no file) is discovered + monitored (emails={emails9})")

    # (shadow-day fix 2026-07-23) registry must NOT replace the record of the account
    # that is ALSO the live ACTIVE keychain account under v1/shadow — the active slot's
    # token is fresh (401-refreshed by real sessions) while a parked home's seeded token
    # expires and is monitor-only; replacing it made the ACTIVE card go stale/error.
    base10 = tempfile.mkdtemp(prefix="usage-v2-actwins-")
    bank10 = os.path.join(base10, "accounts"); os.makedirs(os.path.join(bank10, "homes"))
    with open(os.path.join(bank10, "act-at-x.com.json"), "w") as f:
        json.dump({"email": "act@x.com", "credentials": {"claudeAiOauth": {
            "accessToken": "LEGACY-FRESH", "refreshToken": "r",
            "expiresAt": 9999999999999, "subscriptionType": "max"}}}, f)
    home10 = os.path.join(bank10, "homes", "act-at-x.com"); os.makedirs(home10)
    with open(os.path.join(home10, ".credentials.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"HOME-STALE","refreshToken":"r","expiresAt":1,"subscriptionType":"max"}}')
    registry.publish_ready(bank10, "act@x.com", home10, "uuid-act")
    epoch.write_epoch(bank10, "shadow", 1)
    _orig_active = usage.active_email
    usage.active_email = lambda: "act@x.com"
    os.environ["BANK_DIR"] = bank10
    try:
        doc10 = run_usage(bank10)
    finally:
        usage.active_email = _orig_active
    rec10 = next((a for a in doc10["accounts"] if a.get("email") == "act@x.com"), {})
    ok(not rec10.get("monitor_only"),
       "(active-wins) the ACTIVE keychain account is NOT demoted to a monitor-only v2 home under shadow")

    # (shadow-day fix 2, 2026-07-24) v2 homes must be auto-ping CANDIDATES: their rows
    # carry bank_path=None, and the legacy bank-record requirement silently excluded
    # them — the toggle looked enabled but never fired. Also: a poll error must not
    # exclude a v2 home (the home ping IS the expired-token recovery).
    base11 = tempfile.mkdtemp(prefix="usage-v2-autoping-")
    bank11 = os.path.join(base11, "accounts"); os.makedirs(os.path.join(bank11, "homes"))
    home11 = os.path.join(bank11, "homes", "v2ap-at-x.com"); os.makedirs(home11)
    with open(os.path.join(home11, ".credentials.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"V2AP","refreshToken":"r","expiresAt":1,"subscriptionType":"max"}}')
    with open(os.path.join(home11, ".claude.json"), "w") as f:
        json.dump({"oauthAccount": {"emailAddress": "v2ap@x.com"}}, f)
    registry.publish_ready(bank11, "v2ap@x.com", home11, "uuid-v2ap")
    epoch.write_epoch(bank11, "shadow", 1)
    with open(os.path.join(bank11, ".config.json"), "w") as f:
        json.dump({"auto_ping": ["v2ap@x.com"]}, f)
    # direct-call test of the REAL candidate filter (run_usage stubs maybe_autoping,
    # so the firing path is unobservable through the harness). The row mirrors a v2
    # monitor-only account whose token expired: five_hour absent AND error set — it
    # must STILL fire (the home ping is the recovery path).
    usage.BANK_DIR = bank11
    usage.CONFIG_FILE = os.path.join(bank11, ".config.json")
    usage.LOCKED = True
    usage.AUTOPING_DRYRUN = True
    usage.V2_HOME_EMAILS.clear(); usage.V2_HOME_EMAILS.add("v2ap@x.com")
    usage.V2_HOME_PATHS.clear(); usage.V2_HOME_PATHS["v2ap@x.com"] = home11
    try:
        _map = getattr(usage, "_REAL_MAYBE_AUTOPING", usage.maybe_autoping)
        fired11 = _map(
            [{"provider": "claude", "email": "v2ap@x.com", "five_hour": None,
              "error": "active token expired"}], {})
        # and the cooldown marker must SUPPRESS a refire
        with open(os.path.join(home11, ".ping-marker.json"), "w") as f:
            json.dump({"last_ping": int(__import__("time").time())}, f)
        fired11b = _map(
            [{"provider": "claude", "email": "v2ap@x.com", "five_hour": None,
              "error": "active token expired"}], {})
    finally:
        usage.AUTOPING_DRYRUN = False
        usage.LOCKED = False
    ok(any("v2ap@x.com" in str(x) for x in fired11),
       f"(autoping) a v2 home with auto-ping enabled fires despite bank_path=None + poll error (fired={fired11})")
    ok(not fired11b,
       f"(autoping) the home .ping-marker.json cooldown suppresses a refire (fired={fired11b})")

    # --- (v2 wiring) epoch + health + v2 ping cooldown reach the QuotaBar payload -----
    import time as _t
    base12 = tempfile.mkdtemp(prefix="usage-v2-wire-")
    bank12 = os.path.join(base12, "accounts"); os.makedirs(os.path.join(bank12, "homes"))
    home12 = os.path.join(bank12, "homes", "wire"); os.makedirs(home12)
    with open(os.path.join(home12, ".credentials.json"), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"W","refreshToken":"r","expiresAt":9999999999999,"subscriptionType":"max"}}')
    registry.publish_ready(bank12, "wire@x.com", home12, "uuid-wire")
    epoch.write_epoch(bank12, "v2", 2)
    json.dump({"last_ping": int(_t.time()) - 60},
              open(os.path.join(home12, ".ping-marker.json"), "w"))   # v2 home in cooldown
    json.dump({"ts": int(_t.time()), "pid": 1,
               "homes": {home12: {"blind": True, "forked_shared_files": ["settings.json"]}}},
              open(os.path.join(bank12, "archiver.status.json"), "w"))
    with open(os.path.join(bank12, "seed-audit.jsonl"), "w") as f:
        f.write(json.dumps({"ts": 111, "linked": ["a", "b"]}) + "\n")
        f.write(json.dumps({"ts": 222, "linked": ["mcp-cache.json"]}) + "\n")
    usage._stable_identity = lambda retries=3: (None, None, True)
    usage.read_keychain_blob = lambda: None
    usage.active_email = lambda: ""
    os.environ["BANK_DIR"] = bank12
    doc12 = run_usage(bank12)
    ok(doc12.get("epoch") == "v2",
       f"(v2 wiring) payload carries the epoch state (epoch={doc12.get('epoch')})")
    h = doc12.get("health") or {}
    ok(h.get("archiver", {}).get("blind_homes") == [home12],
       "(v2 wiring) health.archiver surfaces the blind home")
    ok(h.get("archiver", {}).get("heartbeat_age") is not None and h["archiver"]["heartbeat_age"] < 30,
       "(v2 wiring) health.archiver reports a fresh heartbeat age")
    ok(h.get("fork_drift", {}).get(home12) == ["settings.json"],
       "(v2 wiring) health.fork_drift surfaces a forked shared file")
    ok(h.get("seed_audit", {}).get("latest_ts") == 222 and h["seed_audit"]["count"] == 2,
       "(v2 wiring) health.seed_audit reports the newest seeding event")
    w = next((a for a in doc12["accounts"] if a.get("email") == "wire@x.com"), {})
    ok(isinstance(w.get("cooldown_until"), (int, float)) and w["cooldown_until"] > _t.time(),
       f"(v2 wiring) a v2 home in ping cooldown emits cooldown_until (row={w})")

    # --- (review #1) a null utilization must never yield an undecodable window -----------
    fh_none, sd_ok, _w, _mc = usage.summarize_claude(
        {"five_hour": {"utilization": None, "resets_at": "2026-07-24T07:00:00Z"},
         "seven_day": {"utilization": 5.0, "resets_at": "2026-07-25T07:00:00Z"}})
    ok(fh_none is None,
       "(review #1) summarize_claude DROPS a window whose utilization is null")
    ok(isinstance(sd_ok, dict) and sd_ok.get("utilization") == 5.0,
       "(review #1) summarize_claude keeps a window with a real utilization")
    cbase = tempfile.mkdtemp(prefix="usage-null-")
    cbank = os.path.join(cbase, "accounts"); os.makedirs(cbank)
    usage.BANK_DIR = cbank
    usage.CACHE_FILE = os.path.join(cbank, ".usage-cache.json")
    with open(usage.CACHE_FILE, "w") as f:
        json.dump({"accounts": [
            {"provider": "claude", "email": "n@x.com",
             "five_hour": {"utilization": None, "resets_at": "z"},
             "seven_day": {"utilization": 3.0, "resets_at": "y"}}]}, f)
    cached = usage.load_cache()["accounts"][0]
    ok(cached.get("five_hour") is None,
       "(review #1) load_cache NULLS a cached utilization-null window (old cache / codex row)")
    ok(isinstance(cached.get("seven_day"), dict) and cached["seven_day"].get("utilization") == 3.0,
       "(review #1) load_cache keeps a valid cached window")

    print(f"  -- usage_v2: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
