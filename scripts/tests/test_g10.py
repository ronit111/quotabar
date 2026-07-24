#!/usr/bin/env python3
"""(finding 29) G10 — cross-home resume (§12). The prior suite used a stub spawn and
never asserted the §12 release-gate clauses. This brings the harness to the binary
contract: the NON-LIVE structural clauses (duplicate-resume refusal by the lease,
lease behavior during the transition, malformed-id rejection before --resume) run in
the suite NOW; the clauses that need a real `claude-acct B --resume` + a seeded home
(transcript continuation/no-interleave, cwd binding, G9 identity B, keychain unchanged)
run ONLY under G10_LIVE=1 at the morning gate.

Nothing here touches the real keychain or a real credential."""
import os
import subprocess
import sys
import json  # noqa: E402  (r3 #29: the live branch parses claude's JSON output)
import tempfile
import time  # noqa: E402  (r5 item 4: the live branch polls the registry/transcript)

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import registry  # noqa: E402
import restart  # noqa: E402
import sessions  # noqa: E402

FAILS = []
C = [0]


def ok(c, m):
    C[0] += 1
    print(("  ok   " if c else "  FAIL ") + m)
    if not c:
        FAILS.append(m)


_SPAWNED = []


def sleeper():
    p = subprocess.Popen(["sleep", "300"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    _SPAWNED.append(p)
    return p.pid, sessions._proc_start(p.pid)


def _g10_live(acc):
    """(r4 blocker 6) The REAL §12 G10 release gate — runs ONLY under G10_LIVE=1 with two
    seeded READY homes named by G10_EMAIL_A / G10_EMAIL_B. It exercises the ACTUAL §0
    assisted-restart TRANSACTION (restart.restart_session with the real Terminal spawn),
    NOT a one-shot direct resume: a live interactive session on A registers via the hook
    and goes IDLE, then restart_session performs verified-stop → lease/journal →
    transaction-bound registration of the successor resumed on B. Asserts REGISTERED,
    cross-home identity B, transcript continuation, cwd binding, keychain unchanged, and
    a duplicate resume DURING the transition refused by the lease."""
    import hashlib
    import identity  # noqa: E402
    import shlex
    import seedflow  # noqa: E402  (seat) shared credential-seat reader
    A = os.environ.get("G10_EMAIL_A")
    B = os.environ.get("G10_EMAIL_B")
    if not (A and B):
        raise SystemExit("G10_LIVE=1 requires G10_EMAIL_A and G10_EMAIL_B (two seeded homes)")
    # use the LIVE account bank (real registry/homes/hooks), NOT the structural temp acc.
    live_acc = os.environ.get("ACCOUNT_BANK_DIR", os.path.expanduser("~/.claude/accounts"))
    claude_acct = os.path.join(HERE, "claude-acct")
    scripts_dir = HERE
    X = tempfile.mkdtemp(prefix="g10-cwd-")

    def kc_fp():
        # (seat) sample the SHARED default keychain slot ('Claude Code-credentials') through the
        # hardened three-valued reader — it must stay UNCHANGED across the transaction (a pinned
        # v2 session, whose seat is its own per-config-dir slot, must NEVER touch the shared v1
        # slot). None on a failed/indeterminate read (fails the equality assertion, never a false
        # PASS). Uses the seat module's reader instead of a raw `security` subprocess.
        _b, raw, status = seedflow._sh_keychain_read()   # default slot (service=None)
        if status != "present" or raw is None:
            return None
        return hashlib.sha256((raw or "").encode()).hexdigest()

    kc0 = kc_fp()
    ok(kc0 is not None, "G10 live: baseline keychain fingerprint read succeeded (not indeterminate)")

    # 1. launch a LIVE INTERACTIVE session on home A at cwd X in a new Terminal window, so
    #    the SHARED SessionStart hook registers it in the session registry. Wait until it
    #    is registered on A's home at cwd X and has reached IDLE (idle_prompt).
    ahome = registry.ready_home(live_acc, A)

    # (live-gate fix, 2026-07-22) a FRESH temp cwd triggers the CLI's first-run TRUST
    # DIALOG in a seeded home (no trusted-projects entry), which blocks the REPL, so
    # idle_prompt never fires and the live run dies waiting. Pre-trust cwd X in BOTH
    # homes' .claude.json (key name confirmed from the CLI's own file:
    # projects[<cwd>].hasTrustDialogAccepted) — A for the initial session, B for the
    # resumed successor.
    def _pretrust(home_path, cwd):
        cfgp = os.path.join(home_path, ".claude.json")
        try:
            with open(cfgp) as f:
                cfg = json.load(f)
        except Exception:
            cfg = {}
        proj = cfg.setdefault("projects", {}).setdefault(cwd, {})
        # both keys required — mirrors the shape a real accepted dialog writes
        # (verified against the daily-driver ~/.claude.json's trusted-project entry)
        proj["hasTrustDialogAccepted"] = True
        proj["hasCompletedProjectOnboarding"] = True
        proj.setdefault("projectOnboardingSeenCount", 1)
        tmp = cfgp + ".g10tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=2)
        os.replace(tmp, cfgp)

    # (run-3 lesson) the CLI keys trusted projects by REALPATH — /var/folders/… temp dirs
    # canonicalize to /private/var/folders/…, so trust BOTH spellings.
    for _cwd_key in {X, os.path.realpath(X)}:
        _pretrust(ahome, _cwd_key)
        _pretrust(registry.ready_home(live_acc, B), _cwd_key)
    inner_a = (f"cd {shlex.quote(X)} || exit 1; "
               f"exec {shlex.quote(claude_acct)} {shlex.quote(A)}")
    _spawn = subprocess.run(["osascript", "-e",
                             'tell application "Terminal" to do script ' + json.dumps(inner_a)],
                            check=True, capture_output=True, text=True)
    # capture the spawned tab's window id so we can type INTO that exact tab later
    import re as _re
    _wid_m = _re.search(r"window id (\d+)", _spawn.stdout)
    _wid = _wid_m.group(1) if _wid_m else None

    def _type_into_spawned(text):
        """Send a line into the spawned session's tty (Terminal do-script-in-tab —
        no focus/accessibility games)."""
        if _wid is None:
            return False
        r = subprocess.run(
            ["osascript", "-e",
             f'tell application "Terminal" to do script {json.dumps(text)} in tab 1 of window id {_wid}'],
            capture_output=True, text=True)
        return r.returncode == 0
    sid = None
    t0 = time.time()
    while time.time() - t0 < 60 and sid is None:
        for s, rec in sessions.live_sessions(live_acc).items():
            if (os.path.realpath(rec.get("home", "")) == os.path.realpath(ahome)
                    and os.path.realpath(rec.get("cwd", "")) == os.path.realpath(X)):
                sid = s
                break
        time.sleep(0.5)
    ok(sid is not None, f"G10 live: interactive session on A registered at cwd X ({sid})")
    if sid is None:
        # (run-3 lesson) don't cascade a registration miss into _require_sid(None)
        # tracebacks — dump what IS registered so the miss is diagnosable, and stop.
        print("  .. registration miss diagnostics — live sessions right now:")
        for _s, _r in sessions.live_sessions(live_acc).items():
            print(f"     {_s[:8]} state={_r.get('state')} home={_r.get('home')} cwd={_r.get('cwd')}")
        return
    # (run-4/diagnostic lesson) a VIRGIN session that has never run a turn NEVER fires
    # idle_prompt — it stays BUSY forever (conservative-safe in production: an unused
    # session has nothing to resume). G10's target population is a session that WORKED
    # then idled, so send one tiny seed turn into the spawned tab; this also creates the
    # shared-projects transcript the resume-continuity assertion needs. idle_prompt then
    # fires ~60s after the turn ends — wait up to 180s.
    time.sleep(3)   # let the REPL settle before typing
    ok(_type_into_spawned("reply with exactly: g10-seed-turn"),
       "G10 live: seed prompt typed into the spawned session")
    t0 = time.time()
    while time.time() - t0 < 180:
        if sessions.live_sessions(live_acc).get(sid, {}).get("state") == "IDLE":
            break
        time.sleep(0.5)
    ok(sessions.live_sessions(live_acc).get(sid, {}).get("state") == "IDLE",
       "G10 live: A session reached IDLE (idle_prompt edge)")

    proj = os.path.expanduser("~/.claude/projects")
    def transcript_for(s):
        for root, _dirs, files in os.walk(proj):
            if f"{s}.jsonl" in files:
                return os.path.join(root, f"{s}.jsonl")
        return None
    tpath = transcript_for(sid)
    ok(tpath is not None, "G10 live: A transcript located under shared projects/")
    n0 = sum(1 for _ in open(tpath)) if tpath else 0
    proj_dir_before = os.path.dirname(tpath) if tpath else ""

    # 2. run the REAL §0 assisted-restart TRANSACTION onto home B (verified stop →
    #    lease/journal → transaction-bound registration). The spawn resumes the SAME sid
    #    on B at cwd X with a `-p` turn, which BOTH registers the successor (so the
    #    transaction-bound REGISTERED match fires) AND appends to the transcript so we can
    #    prove growth + canonical binding. A duplicate restart while the lease is held
    #    MUST be refused. (`restart_session` exercises the same code path the Terminal
    #    spawn drives; the spawn mechanism is injectable — "or its CLI" per §12.)
    import threading
    bhome = registry.ready_home(live_acc, B)
    spawned = {"p": None}
    def spawn_grow(email, cwd, s):
        # (r14 #5) the controller holds the lease; pass the OWNER TOKEN so claude-acct's r13
        # lease-gate AUTHORIZES this (controller-launched) resume instead of refusing rc 75.
        # This mirrors production _terminal_spawn. Without it the successor never registers and
        # the transaction stalls at SPAWNED, failing G10.
        _env = dict(os.environ, ACCOUNT_BANK_RESUME_LEASE_TOKEN=sessions._HELD_LEASE_TOKENS.get(s, ""))
        p = subprocess.Popen([claude_acct, email, "--resume", s, "-p", "reply with just: ok"],
                             cwd=cwd, env=_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        spawned["p"] = p
        return p.pid, sessions._proc_start(p.pid)
    dup_refused = {"v": False}
    def _dup():
        time.sleep(0.5)                          # after the lease is taken
        try:
            restart.restart_session(live_acc, sid, B, lambda *a: (0, ""))
        except restart.RestartError:
            # (r14 #6) ANY RestartError is a valid duplicate refusal — assert on the refusal,
            # not one message. Depending on timing the duplicate hits EITHER the lease
            # ("restart lease already held") OR the state machine ("session is RESTARTING, not
            # IDLE"), because restart_session checks registry state BEFORE acquiring the lease.
            dup_refused["v"] = True
    dt = threading.Thread(target=_dup); dt.start()
    rec = restart.restart_session(live_acc, sid, B, spawn_grow)
    dt.join()
    ok(rec.get("phase") == "REGISTERED",
       f"G10 live: §0 restart_session reached transaction-bound REGISTERED ({rec.get('phase')})")
    ok(dup_refused["v"], "G10 live: duplicate resume DURING the transition refused by the lease (§12)")

    # 3. the successor bound to home B at the SAME cwd X (from the transaction journal)
    ok(os.path.realpath(rec.get("target_home", "")) == os.path.realpath(bhome),
       "G10 live: successor bound to home B")
    ok(os.path.realpath(rec.get("cwd", "")) == os.path.realpath(X),
       "G10 live: successor cwd binding preserved (X)")

    # let the -p resume finish appending, then assert the transcript GREW and every
    # appended record parses and carries the SAME session-id (canonical binding /
    # no-interleave proxy).
    if spawned["p"] is not None:
        try: spawned["p"].wait(timeout=180)
        except Exception: pass
    t0 = time.time()
    n1 = n0
    while time.time() - t0 < 20:
        n1 = sum(1 for _ in open(tpath)) if (tpath and os.path.exists(tpath)) else 0
        if n1 > n0:
            break
        time.sleep(0.5)
    ok(n1 > n0, f"G10 live: transcript GREW on the same file ({n0} -> {n1})")
    appended_ok = True
    with open(tpath) as f:
        for i, line in enumerate(f):
            if i < n0 or not line.strip():
                continue
            try:
                rec_j = json.loads(line)
            except ValueError:
                appended_ok = False; break
            # (r6 b8) "every appended record CARRIES the sid": a record missing BOTH sid
            # keys must FAIL (the old `.get(...) not in (sid, None)` accepted None==None and
            # false-passed a sid-less record). Require at least one sid key PRESENT and
            # equal to the resumed sid; a present-but-different sid is an interleave -> FAIL.
            present = [rec_j[k] for k in ("sessionId", "session_id") if k in rec_j]
            if not present or any(v != sid for v in present):
                appended_ok = False; break
    ok(appended_ok,
       "G10 live: every appended transcript record parses and carries the resumed sid (canonical binding, no interleave)")
    ok(os.path.dirname(tpath) == proj_dir_before, "G10 live: same cwd-bound project dir (no drift)")

    # 4. the resumed session's identity is B (G9 on B's home SEAT — file OR migrated slot; a
    #    first-launch migration deletes the file, so read the seat, not the file); shared kc unchanged
    _bb, _br, _bst, _bk = seedflow.seat_read(bhome)
    bo = (_bb or {}).get("claudeAiOauth", {}) if _bst == "present" else {}
    rr = identity.resolve(bo.get("accessToken", ""))
    ok(rr.verdict == "RESOLVED" and rr.email == B,
       f"G10 live: resumed identity is B ({rr.verdict}/{rr.email})")
    kc1 = kc_fp()
    ok(kc1 is not None and kc1 == kc0,
       "G10 live: shared keychain fingerprint read OK and UNCHANGED across the transaction")


def main():
    acc = tempfile.mkdtemp(prefix="g10-acc-")
    home = os.path.join(acc, "homes", "b-at-x.com")
    os.makedirs(home)
    registry.publish_ready(acc, "b@x.com", home, "uuid-b")
    sid = "aaaaaaaa-2222-3333-4444-555555555555"

    # a live IDLE predecessor
    ppid, pstart = sleeper()
    sessions.record_event(acc, "start", sid, {"home": "/old", "cwd": "/tmp",
                                              "pid": ppid, "transcript": ""})
    sessions.record_event(acc, "idle", sid)

    # (§12 G10) DUPLICATE-RESUME during the transition is REFUSED BY THE LEASE. Simulate
    # an in-flight restart by holding the lease, then confirm a second restart_session
    # for the same session refuses before touching the predecessor.
    ok(sessions.lease_acquire(acc, sid), "in-flight restart holds the lease")
    raised = False
    try:
        restart.restart_session(acc, sid, "b@x.com", lambda *a: (0, ""))
    except restart.RestartError as e:
        raised = "lease already held" in str(e)
    ok(raised, "duplicate resume during transition REFUSED by the lease (§12 G10)")
    # the prompt hook also blocks new turns in that session while the lease is held
    ok(sessions.prompt_admit(acc, sid) is False, "prompt admission blocked during the transition")
    sessions.lease_release(acc, sid)

    # (§12 G10) session-ids are validated as UUIDs before any --resume/lease path
    for bad in ("../../etc", "b@x.com; rm -rf", "not-a-uuid"):
        raised = False
        try:
            restart.restart_session(acc, bad, "b@x.com", lambda *a: (0, ""))
        except ValueError:
            raised = True
        except restart.RestartError:
            raised = False   # a RestartError would mean it got past id validation
        ok(raised, f"malformed session-id {bad!r} rejected before --resume (§12 G10)")

    # (§12 G10) full stop->resume->transaction-bound-REGISTERED path with a stub spawn
    # (the STRUCTURAL half of the gate: lease released only at REGISTERED, no duplicate).
    def spawn_stub(email, cwd, s):
        cpid, cstart = sleeper()
        # a concurrent duplicate resume MUST be refused while we are mid-transition
        dup_refused = not sessions.lease_acquire(acc, s)
        ok(dup_refused, "concurrent duplicate resume refused mid-transition (§12 G10)")
        sessions.record_event(acc, "start", s, {"home": home, "cwd": cwd,
                                                "pid": cpid, "transcript": ""})
        return cpid, cstart

    rec = restart.restart_session(acc, sid, "b@x.com", spawn_stub, stop_timeout=10)
    ok(rec["phase"] == "REGISTERED", f"resume reaches transaction-bound REGISTERED ({rec['phase']})")
    ok(not sessions.lease_held(acc, sid), "lease released ONLY at REGISTERED")

    if os.environ.get("G10_LIVE") == "1":
        _g10_live(acc)          # REAL cross-home resume + §12 assertions (morning gate)
    else:
        print("  .. G10 LIVE clauses skipped (set G10_LIVE=1 + G10_EMAIL_A/B at the morning gate)")

    for p in _SPAWNED:
        try:
            p.kill(); p.wait()
        except Exception:
            pass

    print(f"-- g10: {C[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
