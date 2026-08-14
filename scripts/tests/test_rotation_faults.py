#!/usr/bin/env python3
"""Regression tests for the isolated-refresh rotation-fault findings (r3 #5/#6/#7/
#15). Each exercises refresh_via_config_dir against the `claude` stub in a temp
BANK_DIR — the real keychain and live account are never touched. Every case is
written to FAIL on the pre-fix code path (noted per test)."""
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.dirname(HERE)
STUB = os.path.join(HERE, "stubs", "claude")
sys.path.insert(0, AB)

_pass = _fail = 0
def ok(name):
    global _pass; _pass += 1; print(f"  ok   {name}")
def bad(name, extra=""):
    global _fail; _fail += 1; print(f"  FAIL {name} {extra}")
def eq(exp, act, name):
    ok(name) if exp == act else bad(name, f"(expected {exp!r} got {act!r})")


def _env(base):
    os.environ["BANK_DIR"] = os.path.join(base, "bank")
    os.makedirs(os.environ["BANK_DIR"], exist_ok=True)
    os.chmod(os.environ["BANK_DIR"], 0o700)
    os.environ["CLAUDE_JSON"] = os.path.join(base, "claude.json")
    os.environ["ACCOUNT_BANK_CLAUDE_BIN"] = STUB
    os.environ["ACCOUNT_BANK_SECURITY_BIN"] = os.path.join(HERE, "stubs", "security")
    os.environ["KEYCHAIN_ACCOUNT"] = "tester"
    for k in ("STUB_CLAUDE_MODE", "STUB_BECOME_EMAIL"):
        os.environ.pop(k, None)


def _fresh_import():
    # reconcile/isolated_refresh read BANK_DIR at import; reload against the temp dir
    for m in ("isolated_refresh", "reconcile", "bank_common", "banklock"):
        sys.modules.pop(m, None)
    import isolated_refresh
    return isolated_refresh


OLD = {"accessToken": "OLD", "refreshToken": "rOLD",
       "expiresAt": 10_000_000_000_000, "subscriptionType": "max"}


def case_15_metaonly():
    # (r3 #15) a metadata-only readback delta (subscriptionType) is NOT a rotation.
    # Pre-fix: `new != creds` set rotated True. Post-fix: same_credentials -> False.
    base = tempfile.mkdtemp(prefix="rotflt15-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        os.environ["STUB_CLAUDE_MODE"] = "metaonly"
        rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                       claude_json=os.environ["CLAUDE_JSON"],
                                       bank_dir=os.environ["BANK_DIR"])
        eq(False, rr.rotated, "metadata-only change is NOT treated as a rotation (r3 #15)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_6_readback_torn():
    # (r3 #6) a torn/unreadable readback must fail-closed: reason readback_torn +
    # a preserved quarantine dir. Pre-fix: new=creds, reason "ok"/nonzero, temp dir deleted.
    base = tempfile.mkdtemp(prefix="rotflt6-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        os.environ["STUB_CLAUDE_MODE"] = "torn"
        rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                       claude_json=os.environ["CLAUDE_JSON"],
                                       bank_dir=os.environ["BANK_DIR"])
        eq("readback_torn", rr.reason, "torn readback -> reason readback_torn (r3 #6)")
        cond = bool(rr.quarantine) and os.path.isdir(rr.quarantine)
        eq(True, cond, "torn readback preserves a quarantine config dir (r3 #6)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_7_journal_failed():
    # (r3 #7) if the rotated-token journal write fails, fail-closed: reason
    # journal_failed + preserved quarantine (recovery material). Pre-fix: only a
    # WARNING, reason "ok", temp dir deleted -> a crash before commit loses the token.
    base = tempfile.mkdtemp(prefix="rotflt7-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        import bank_common
        # force write_journal to fail by pre-creating the journal PATH as a directory
        jp = ir._rec.journal_path("p@x.com")
        os.makedirs(jp, exist_ok=True)
        os.environ["STUB_CLAUDE_MODE"] = "ok"      # a real rotation
        rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                       claude_json=os.environ["CLAUDE_JSON"],
                                       bank_dir=os.environ["BANK_DIR"])
        eq(True, rr.rotated, "journal-fail case still detects the rotation (r3 #7)")
        eq("journal_failed", rr.reason, "journal write failure -> reason journal_failed (r3 #7)")
        cond = bool(rr.quarantine) and os.path.isdir(rr.quarantine) \
            and os.path.isfile(os.path.join(rr.quarantine, ".credentials.json"))
        eq(True, cond, "journal failure preserves the rotated creds in quarantine (r3 #7)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_5_became_active_after():
    # (r3 #5) if the parked account becomes ACTIVE during the turn and rotates, the
    # post-turn re-check fires: reason became_active_after + quarantine, NOT a silent
    # parked commit. Pre-fix: only a preflight check -> committed/journaled as parked.
    base = tempfile.mkdtemp(prefix="rotflt5-")
    try:
        _env(base)
        # start parked (active is someone else)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        os.environ["STUB_CLAUDE_MODE"] = "become_active"
        os.environ["STUB_BECOME_EMAIL"] = "p@x.com"    # stub flips active -> p during the turn
        rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                       claude_json=os.environ["CLAUDE_JSON"],
                                       bank_dir=os.environ["BANK_DIR"])
        eq("became_active_after", rr.reason, "became-active-mid-rotation detected post-turn (r3 #5)")
        cond = bool(rr.quarantine) and os.path.isdir(rr.quarantine)
        eq(True, cond, "became-active rotation is quarantined, not committed as parked (r3 #5)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_r4_3_parseable_torn():
    # (r4 #3) PARSEABLE-but-unsafe readbacks must ALSO fail-closed (preserve), not
    # just JSON-unparseable ones. Pre-fix: `{}` -> new=creds, reason "ok", temp dir
    # DELETED; a changed-but-malformed blob -> reason "malformed", temp dir DELETED.
    # Post-fix: both -> reason readback_torn + a preserved quarantine dir.
    for mode, label in (("emptydict", "empty-dict readback"),
                        ("changed_malformed", "changed-but-malformed readback")):
        base = tempfile.mkdtemp(prefix="rotflt_r43-")
        try:
            _env(base)
            json.dump({"oauthAccount": {"emailAddress": "other@x.com"}},
                      open(os.environ["CLAUDE_JSON"], "w"))
            ir = _fresh_import()
            os.environ["STUB_CLAUDE_MODE"] = mode
            rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                           claude_json=os.environ["CLAUDE_JSON"],
                                           bank_dir=os.environ["BANK_DIR"])
            eq("readback_torn", rr.reason, f"{label} -> reason readback_torn (r4 #3)")
            cond = bool(rr.quarantine) and os.path.isdir(rr.quarantine)
            eq(True, cond, f"{label} preserves a quarantine dir, not deleted (r4 #3)")
        finally:
            os.environ.pop("STUB_CLAUDE_MODE", None)
            shutil.rmtree(base, ignore_errors=True)


def case_r4_4_quarantine_rename_fail_preserves():
    # (r4 #4) if the quarantine move FAILS (e.g. os.rename raises a non-EXDEV error),
    # _quarantine_cfgdir must NOT return None (which the caller mapped to "delete") —
    # it must leave the original dir in place and return ITS path. Pre-fix: returned
    # None on OSError -> preserved=False -> the finally deleted the rotated token.
    base = tempfile.mkdtemp(prefix="rotflt_r44-")
    try:
        _env(base)
        ir = _fresh_import()
        d = tempfile.mkdtemp(prefix="acctbank-cfg-")
        open(os.path.join(d, ".credentials.json"), "w").write('{"claudeAiOauth":{}}')
        orig_rename = ir.os.rename
        def boom(*a, **k):
            raise OSError(1, "rename denied")   # errno 1 (EPERM), NOT EXDEV
        ir.os.rename = boom
        try:
            q = ir._quarantine_cfgdir(d, os.environ["BANK_DIR"], "p@x.com", "test rename fail")
        finally:
            ir.os.rename = orig_rename
        eq(d, q, "failed quarantine returns the original path, never None (r4 #4)")
        eq(True, os.path.isdir(d) and os.path.isfile(os.path.join(d, ".credentials.json")),
           "failed quarantine LEAVES the original dir in place, not deleted (r4 #4)")
        shutil.rmtree(d, ignore_errors=True)
    finally:
        shutil.rmtree(base, ignore_errors=True)


def case_r4_5_journal_unavailable():
    # (r4 #5) an UNAVAILABLE journal subsystem (reconcile import failed -> _rec None)
    # is journal FAILED, never silent success. Pre-fix: `_rec is None` skipped the
    # write WITHOUT setting journal_failed -> a valid rotation returned reason "ok"
    # and deleted its temp copy. Post-fix: reason journal_failed + preserved quarantine.
    base = tempfile.mkdtemp(prefix="rotflt_r45-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}},
                  open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        saved = ir._rec
        ir._rec = None                              # simulate reconcile import failure
        try:
            os.environ["STUB_CLAUDE_MODE"] = "ok"   # a real rotation
            rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                           claude_json=os.environ["CLAUDE_JSON"],
                                           bank_dir=os.environ["BANK_DIR"])
        finally:
            ir._rec = saved
            os.environ.pop("STUB_CLAUDE_MODE", None)
        eq(True, rr.rotated, "journal-unavailable case still detects the rotation (r4 #5)")
        eq("journal_failed", rr.reason, "reconcile unavailable -> reason journal_failed (r4 #5)")
        cond = bool(rr.quarantine) and os.path.isdir(rr.quarantine) \
            and os.path.isfile(os.path.join(rr.quarantine, ".credentials.json"))
        eq(True, cond, "journal-unavailable preserves the rotated creds in quarantine (r4 #5)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


ROT2 = {"accessToken": "ROT2", "refreshToken": "rROT2",
        "expiresAt": 10_000_000_000_001, "subscriptionType": "max"}
BLANK = {"accessToken": "", "refreshToken": "", "expiresAt": 0, "subscriptionType": "max"}


class _FakeSeedflow:
    """(v110) stands in for seedflow's slot primitives: refresh_via_config_dir imports
    seedflow lazily, so an object in sys.modules['seedflow'] is what it gets."""
    def __init__(self, oauth, status="present"):
        self._oauth, self._status = oauth, status
        self.deleted = []
    def config_slot_service(self, p):
        return "Claude Code-credentials-fake"
    def _sh_keychain_read(self, service=None):
        if self._status != "present":
            return None, None, self._status
        blob = {"claudeAiOauth": self._oauth}
        return blob, json.dumps(blob), "present"
    def _sh_keychain_delete(self, service):
        self.deleted.append(service)
        return True


def _with_fake_seedflow(fake):
    sys.modules["seedflow"] = fake


def case_v110_migrated_rotation_via_slot():
    # (v110) CLI >= 2.1.228: file credential migrated to the per-dir SLOT, file deleted.
    # Pre-fix: readback_torn quarantine on EVERY healthy refresh. Post-fix: the rotation
    # is harvested from the slot, committed normally, and the orphan slot is deleted.
    base = tempfile.mkdtemp(prefix="rotflt110a-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        fake = _FakeSeedflow(dict(ROT2))
        _with_fake_seedflow(fake)
        os.environ["STUB_CLAUDE_MODE"] = "migrate"
        try:
            rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                           claude_json=os.environ["CLAUDE_JSON"],
                                           bank_dir=os.environ["BANK_DIR"])
        finally:
            os.environ.pop("STUB_CLAUDE_MODE", None)
        eq(True, rr.rotated, "migrated readback: rotation harvested from the slot (v110)")
        eq("ok", rr.reason, "migrated readback commits normally, no quarantine (v110)")
        eq("ROT2", rr.creds.get("accessToken"), "migrated readback returns the SLOT's creds (v110)")
        eq(1, len(fake.deleted), "the orphan per-dir slot is deleted after harvest (v110)")
    finally:
        sys.modules.pop("seedflow", None)
        shutil.rmtree(base, ignore_errors=True)


def case_v110_blanked_slot_auth_death():
    # (v110) blanked slot (the CLI's cleared-login stamp) + confirmed auth signature
    # in the turn output -> DEAD (auth_rejected), bank creds unchanged.
    base = tempfile.mkdtemp(prefix="rotflt110b-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        fake = _FakeSeedflow(dict(BLANK))
        _with_fake_seedflow(fake)
        os.environ["STUB_CLAUDE_MODE"] = "migrate_authfail"
        try:
            rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                           claude_json=os.environ["CLAUDE_JSON"],
                                           bank_dir=os.environ["BANK_DIR"])
        finally:
            os.environ.pop("STUB_CLAUDE_MODE", None)
        eq(True, rr.auth_failed, "blanked slot + auth signature -> confirmed death (v110)")
        eq("auth_rejected", rr.reason, "reason auth_rejected (v110)")
        eq("OLD", rr.creds.get("accessToken"), "bank creds unchanged on death (v110)")
    finally:
        sys.modules.pop("seedflow", None)
        shutil.rmtree(base, ignore_errors=True)


def case_v110_blanked_slot_no_auth_text():
    # (v110) blanked slot WITHOUT a confirmed auth signature stays a distinct
    # TRANSIENT (v105.1: the verdict is fail-closed) — bank untouched, retriable,
    # and no quarantine (empty tokens are provably nothing to preserve).
    base = tempfile.mkdtemp(prefix="rotflt110c-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        fake = _FakeSeedflow(dict(BLANK))
        _with_fake_seedflow(fake)
        os.environ["STUB_CLAUDE_MODE"] = "migrate"
        try:
            rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                           claude_json=os.environ["CLAUDE_JSON"],
                                           bank_dir=os.environ["BANK_DIR"])
        finally:
            os.environ.pop("STUB_CLAUDE_MODE", None)
        eq(False, rr.auth_failed, "blanked slot without auth text is NOT death (v110)")
        eq("seat_blanked", rr.reason, "distinct seat_blanked reason (v110)")
        eq(None, rr.quarantine, "nothing to preserve -> no quarantine (v110)")
    finally:
        sys.modules.pop("seedflow", None)
        shutil.rmtree(base, ignore_errors=True)


def case_v110_slot_absent_still_torn():
    # (v110) file gone AND slot absent/unreadable: genuinely torn — the quarantine
    # path is unchanged, and the (absent) slot is NOT deleted.
    base = tempfile.mkdtemp(prefix="rotflt110d-")
    try:
        _env(base)
        json.dump({"oauthAccount": {"emailAddress": "other@x.com"}}, open(os.environ["CLAUDE_JSON"], "w"))
        ir = _fresh_import()
        fake = _FakeSeedflow(None, status="absent")
        _with_fake_seedflow(fake)
        os.environ["STUB_CLAUDE_MODE"] = "migrate"
        try:
            rr = ir.refresh_via_config_dir(dict(OLD), email="p@x.com",
                                           claude_json=os.environ["CLAUDE_JSON"],
                                           bank_dir=os.environ["BANK_DIR"])
        finally:
            os.environ.pop("STUB_CLAUDE_MODE", None)
        eq("readback_torn", rr.reason, "file gone + slot absent -> still torn (v110)")
        eq(0, len(fake.deleted), "no slot delete when nothing was harvested (v110)")
    finally:
        sys.modules.pop("seedflow", None)
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    case_15_metaonly()
    case_6_readback_torn()
    case_7_journal_failed()
    case_5_became_active_after()
    case_r4_3_parseable_torn()
    case_r4_4_quarantine_rename_fail_preserves()
    case_r4_5_journal_unavailable()
    case_v110_migrated_rotation_via_slot()
    case_v110_blanked_slot_auth_death()
    case_v110_blanked_slot_no_auth_text()
    case_v110_slot_absent_still_torn()
    print(f"  -- rotation_faults: {_pass} passed, {_fail} failed")
    sys.exit(1 if _fail else 0)
