#!/usr/bin/env python3
"""Tests for archiverd.py — observation, rename-replace re-arm, dedup, health,
drift detection, G7-style burst (final version never missed). Uses --once scan
cycles plus a live daemon subprocess for the kqueue path."""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import archiverd  # noqa: E402
import registry  # noqa: E402

FAILS = []
COUNT = [0]


def ok(cond, msg):
    COUNT[0] += 1
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def write_cred(home, tag, rename=True):
    """Simulate the CLI's atomic rename-replace commit."""
    cred = os.path.join(home, ".credentials.json")
    payload = json.dumps({"claudeAiOauth": {"accessToken": f"at-{tag}",
                                            "refreshToken": f"rt-{tag}",
                                            "expiresAt": 9}})
    if rename:
        tmp = cred + f".tmp{time.monotonic_ns()}"
        with open(tmp, "w") as f:
            f.write(payload)
        os.replace(tmp, cred)
    else:
        with open(cred, "w") as f:
            f.write(payload)


def archived_tags(home):
    adir = os.path.join(home, "archive")
    tags = set()
    if not os.path.isdir(adir):
        return tags
    for e in os.listdir(adir):
        if e.endswith(".json"):
            try:
                with open(os.path.join(adir, e)) as f:
                    tags.add(json.load(f)["claudeAiOauth"]["accessToken"])
            except Exception:
                pass
    return tags


def main():
    # (seat) the archiver now reads each home's SEAT (file OR per-config-dir slot). Point the
    # seat reader at a FAKE keychain for the WHOLE run (inherited by the daemon subprocesses too)
    # so a file-absent home's slot read NEVER touches the real keychain. File-seat homes still
    # read their .credentials.json (file precedence); the fake only backs slot reads.
    os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"] = os.path.join(tempfile.mkdtemp(prefix="archd-fkc-"), "kc")
    acc = tempfile.mkdtemp(prefix="archd-acc-")
    home = os.path.join(acc, "homes", "a-at-x.com")
    os.makedirs(home)
    registry.publish_ready(acc, "a@x.com", home, "uuid-a")
    write_cred(home, "v0")

    # --once: baseline scan archives the current version + writes health
    a = archiverd.Archiver(acc)
    a.scan()
    a.write_status()
    ok("at-v0" in archived_tags(home), "baseline scan archives current version")
    st = json.load(open(os.path.join(acc, archiverd.STATUS_NAME)))
    ok(home in st["homes"] and st["homes"][home]["armed"] is not None,
       "health reports an armed watch")
    ok(st["homes"][home]["blind"] is False, "armed watch is not blind")

    # rename-replace goes stale -> scan re-arms on the NEW inode and archives
    write_cred(home, "v1")           # rename-replace: armed inode now stale
    a.scan()
    a.write_status()
    ok("at-v1" in archived_tags(home), "rename-replaced version archived")
    st = json.load(open(os.path.join(acc, archiverd.STATUS_NAME)))
    ok(st["homes"][home]["blind"] is False, "re-armed on the new inode (not blind)")

    # dedup: rescanning identical content adds no archive entries
    n = len(os.listdir(os.path.join(home, "archive")))
    a.scan()
    ok(len(os.listdir(os.path.join(home, "archive"))) == n, "identical content deduped")

    # drift detection: settings.json symlink replaced by a real file
    tgt = os.path.join(acc, "shared-settings.json")
    open(tgt, "w").write("{}")
    os.symlink(tgt, os.path.join(home, "settings.json"))
    a.scan()
    ok(a.drift[home] == [], "symlinked settings.json -> no drift")
    os.remove(os.path.join(home, "settings.json"))
    open(os.path.join(home, "settings.json"), "w").write("{}")
    a.scan()
    a.write_status()
    st = json.load(open(os.path.join(acc, archiverd.STATUS_NAME)))
    ok(st["homes"][home]["forked_shared_files"] == ["settings.json"],
       "forked settings.json detected + reported")

    # (finding 25) a FAILED archive write must NOT poison the dedup set: block the
    # archive dir (replace it with a FILE so makedirs raises) so the write fails, then
    # heal it and rescan — the unchanged landed version must still get archived.
    import shutil as _shutil
    write_cred(home, "recover-me")
    adir = os.path.join(home, "archive")
    _saved = adir + ".saved"
    _shutil.move(adir, _saved)
    open(adir, "w").write("not a dir")        # makedirs(exist_ok=True) now raises
    a.scan()                                   # archive_current hits OSError -> None
    ok("at-recover-me" not in archived_tags(home), "failed archive did not land (expected)")
    os.remove(adir)
    _shutil.move(_saved, adir)                 # heal the fault
    a.scan()                                   # rescan must NOT skip it (not poisoned)
    ok("at-recover-me" in archived_tags(home),
       "unchanged version archived on rescan after a transient failure (finding 25)")

    # (finding 36) fork convergence: global wins, forked copy archived + re-linked.
    gl = os.path.join(acc, "global"); os.makedirs(gl, exist_ok=True)
    open(os.path.join(gl, "CLAUDE.md"), "w").write("GLOBAL")
    os.remove(os.path.join(home, "settings.json")) if os.path.islink(os.path.join(home, "settings.json")) else None
    open(os.path.join(home, "CLAUDE.md"), "w").write("FORKED")   # a real (forked) file
    a.scan()
    ok("CLAUDE.md" in a.drift[home], "forked CLAUDE.md detected across the expanded watch list (finding 36)")
    conv = a.converge_drift(home, gl)
    ok("CLAUDE.md" in conv and os.path.islink(os.path.join(home, "CLAUDE.md")),
       "converge_drift re-links the fork to the global (global wins, finding 36)")
    ok(any(e.endswith("fork-CLAUDE.md") for e in os.listdir(os.path.join(home, "archive"))),
       "forked copy archived before relink (never-destroy, finding 36)")

    # (r2 MAJOR) a fork with NO global target is LEFT in place (never lose the only copy)
    open(os.path.join(home, "errors.md"), "w").write("home-only fork")
    a.scan()
    conv2 = a.converge_drift(home, gl)                 # gl has no errors.md
    ep = os.path.join(home, "errors.md")
    ok("errors.md" not in conv2 and os.path.isfile(ep) and not os.path.islink(ep),
       "fork with no global target is LEFT in place (r2 MAJOR copy-before-remove)")
    os.remove(ep)

    # (r2 MAJOR) an armed watch whose credential is MISSING reports blind=True
    aw = archiverd.Archiver(acc)
    aw.scan()                                          # arms on the live cred inode
    os.remove(os.path.join(home, ".credentials.json"))
    aw.write_status()
    stb = json.load(open(os.path.join(acc, archiverd.STATUS_NAME)))
    ok(stb["homes"][home]["blind"] is True,
       "armed watch + MISSING credential -> blind=True (r2 MAJOR)")
    write_cred(home, "restored-after-blind")           # restore for the live section

    # (r3 #30) an UNARMED watch over a LIVE credential (armed=None) is BLIND, not healthy.
    aw2 = archiverd.Archiver(acc)
    aw2.watches[home] = archiverd.HomeWatch(home)       # a watch that never armed
    aw2.write_status()
    st2 = json.load(open(os.path.join(acc, archiverd.STATUS_NAME)))
    ok(st2["homes"][home]["armed"] is None and st2["homes"][home]["blind"] is True,
       "armed=None over a live credential -> blind=True (r3 #30)")

    # live daemon: kqueue event path + G7 burst contract (§12). Default suite runs a
    # REDUCED SMOKE (not a G7-passing run); G7_FULL=1 runs the ×100 contract. (r4 blocker 4)
    # Each burst is a rapid double-rename (-a then -b); the -b is the burst's COMPLETED
    # FINAL and MUST be archived — §5 makes only the FIRST rename (-a) best-effort, not a
    # completed burst's final. We wait for each -b to be archived before the next burst
    # (deterministic enumeration of all N finals) and RAISE ARCHIVE_KEEP so none is pruned
    # before the check. Zero missed -b finals is the criterion.
    # (r8 #16) this daemon exercises the ARCHIVING/re-arm contract, not reconciliation;
    # keep the detached reconcile trigger OFF so the run stays hermetic (no G9 network) and
    # the kqueue loop is never perturbed. The reconcile TRIGGER is covered hermetically by
    # test_reconcile_trigger below (injected stub reconciler, no network).
    env = dict(os.environ, ACCOUNT_BANK_DIR=acc, ACCOUNT_BANK_ARCHIVER_RECONCILE="0")
    full = os.environ.get("G7_FULL") == "1"
    n_bursts = 100 if full else 8
    env["ACCOUNT_BANK_ARCHIVE_KEEP"] = str(3 * n_bursts + 20)   # keep every final retained
    p = subprocess.Popen([sys.executable, os.path.join(HERE, "archiverd.py")],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.0)                       # let it arm
        missed_live = []
        for burst in range(n_bursts):
            write_cred(home, f"burst-{burst}-a")
            write_cred(home, f"burst-{burst}-b")   # rapid double-rename; -b is the FINAL
            # (r4 blocker 4) wait for the daemon to archive THIS burst's -b before the
            # next burst — so every completed-burst final is enumerated, not just the last.
            t0 = time.time()
            while f"at-burst-{burst}-b" not in archived_tags(home) and time.time() - t0 < 5.0:
                time.sleep(0.02)
            if f"at-burst-{burst}-b" not in archived_tags(home):
                missed_live.append(f"at-burst-{burst}-b")
        got = archived_tags(home)
        label = "G7 (×100)" if full else "SMOKE (reduced)"
        missed_finals = [f"at-burst-{i}-b" for i in range(n_bursts) if f"at-burst-{i}-b" not in got]
        ok(missed_finals == [] and missed_live == [],
           f"burst {label}: ZERO missed FINAL (-b) versions across all {n_bursts} bursts "
           f"(missed={missed_finals or missed_live})")
        # (finding 30) PER-PHASE health AFTER activity settles: armed inode == live inode.
        st = json.load(open(os.path.join(acc, archiverd.STATUS_NAME)))
        ok(st["homes"].get(home, {}).get("blind") is False,
           "armed-inode health == lstat AFTER the burst phase (not blind, finding 30)")

        # (finding 30) missing-path re-arm MEASURED <= 2s: delete the credential, then
        # recreate and poll until the new version is archived; assert the observed
        # latency is within the 2s re-arm contract (not merely "eventually").
        os.remove(os.path.join(home, ".credentials.json"))
        time.sleep(1.2)                       # let the daemon observe the missing path
        t_create = time.time()
        write_cred(home, "rearm-after-missing")
        rearm_latency = None
        while time.time() - t_create < 5.0:
            if "at-rearm-after-missing" in archived_tags(home):
                rearm_latency = time.time() - t_create
                break
            time.sleep(0.1)
        ok(rearm_latency is not None and rearm_latency <= 2.0,
           f"missing-path re-armed + archived within 2s (finding 30: {rearm_latency})")
        # (finding 30) PER-PHASE health: armed inode == lstat AFTER the re-arm phase too
        st = json.load(open(os.path.join(acc, archiverd.STATUS_NAME)))
        ok(st["homes"].get(home, {}).get("blind") is False,
           "armed-inode health == lstat AFTER the re-arm phase (not blind, finding 30)")

        # daemon kill/restart mid-activity -> rescan catches the landed version
        p.send_signal(signal.SIGKILL)
        p.wait()
        write_cred(home, "while-down")
        p2 = subprocess.Popen([sys.executable, os.path.join(HERE, "archiverd.py")],
                              env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(1.5)
            ok("at-while-down" in archived_tags(home),
               "restart rescan archives the version written while down")
        finally:
            p2.terminate()
            p2.wait()
    finally:
        if p.poll() is None:
            p.terminate()
            p.wait()

    # (r8 #18) converge_drift ATOMICITY: if the relink fails, the fork must NOT be lost
    # (the old os.remove-then-symlink left the home with neither file nor link, invisible
    # to drift scans). Force os.symlink to fail and assert the fork stays in place.
    acc18 = tempfile.mkdtemp(prefix="archd-18-")
    home18 = os.path.join(acc18, "homes", "z-at-x.com"); os.makedirs(home18)
    registry.publish_ready(acc18, "z@x.com", home18, "uuid-z")
    write_cred(home18, "c18")
    gl18 = os.path.join(acc18, "global"); os.makedirs(gl18)
    open(os.path.join(gl18, "CLAUDE.md"), "w").write("GLOBAL")
    open(os.path.join(home18, "CLAUDE.md"), "w").write("FORKED18")
    a18 = archiverd.Archiver(acc18); a18.scan()
    _orig_symlink = os.symlink
    os.symlink = lambda *a, **k: (_ for _ in ()).throw(OSError("simulated ENOSPC"))
    try:
        conv18 = a18.converge_drift(home18, gl18)
    finally:
        os.symlink = _orig_symlink
    forkp = os.path.join(home18, "CLAUDE.md")
    ok("CLAUDE.md" not in conv18 and os.path.isfile(forkp) and not os.path.islink(forkp)
       and open(forkp).read() == "FORKED18",
       "converge relink failure LEAVES the fork intact — never lost (r8 #18)")
    ok(not any(e.startswith(".drift-relink.") for e in os.listdir(home18)),
       "no leftover temp-symlink debris after a failed relink (r8 #18)")
    # with symlink working again, convergence completes atomically (fork -> link).
    conv18b = a18.converge_drift(home18, gl18)
    ok("CLAUDE.md" in conv18b and os.path.islink(forkp),
       "converge completes atomically once relink can succeed (r8 #18)")

    # (r8 #16) the archiver TRIGGERS reconcile on an observed credential CHANGE (a §5
    # archiver event) — reconcile_home had no production caller. Injected stub keeps this
    # hermetic (no G9 network). First scan (seed) must NOT reconcile; a later change must.
    acc16 = tempfile.mkdtemp(prefix="archd-16-")
    home16 = os.path.join(acc16, "homes", "r-at-x.com"); os.makedirs(home16)
    registry.publish_ready(acc16, "r@x.com", home16, "uuid-r")
    write_cred(home16, "seed16")
    calls = []
    a16 = archiverd.Archiver(acc16, reconciler=lambda acc, email: calls.append((acc, email)))
    # (r10 #13) FIRST scan of an observed credential now dispatches reconcile too — a
    # foreign/invalid credential that landed while the daemon was down is seen for the
    # first time on restart and must still be reconciled (the reconciler self-guards).
    a16.scan()
    ok(calls == [(acc16, "r@x.com")],
       "first-scan of an observed credential dispatches reconcile (r10 #13)")
    write_cred(home16, "changed16")             # a later CLI write is also reconciled
    a16.scan()
    ok(calls == [(acc16, "r@x.com"), (acc16, "r@x.com")],
       "a later credential CHANGE also triggers reconcile (r8 #16 / r10 #13)")

    # (r9 #8) the daemon is a shadow|v2 tool: after a rollback to v1 it must PARK — no
    # scanning/archiving of READY homes — and write an epoch_parked health status. An
    # ABSENT EPOCH stays permissive (the whole suite above ran with no EPOCH file).
    import epoch as _epoch
    acc8 = tempfile.mkdtemp(prefix="archd-8-")
    home8 = os.path.join(acc8, "homes", "e-at-x.com"); os.makedirs(home8)
    registry.publish_ready(acc8, "e@x.com", home8, "uuid-e")
    write_cred(home8, "v2cred")
    a8 = archiverd.Archiver(acc8)
    ok(a8.epoch_allows() is True, "epoch_allows True when no EPOCH file (permissive) (r9 #8)")
    _epoch.write_epoch(acc8, "v2", 1)
    ok(a8.epoch_allows() is True, "epoch_allows True under v2 (r9 #8)")
    a8.cycle()                                   # v2: archives the credential
    ok("at-v2cred" in archived_tags(home8), "v2 cycle archives the credential (r9 #8)")
    # roll back to v1: the cycle must PARK — no new archive, parked status written
    _epoch.write_epoch(acc8, "v1", 2)
    ok(a8.epoch_allows() is False, "epoch_allows False after rollback to v1 (r9 #8)")
    write_cred(home8, "v1cred-should-not-be-archived")
    a8.cycle()
    ok("at-v1cred-should-not-be-archived" not in archived_tags(home8),
       "v1 cycle does NOT archive READY-home credentials (parked) (r9 #8)")
    _st = json.load(open(os.path.join(acc8, archiverd.STATUS_NAME)))
    ok(_st.get("epoch_parked") is True and _st.get("homes") == {},
       "parked cycle writes an epoch_parked health status with no watched homes (r9 #8)")
    # a broken EPOCH also parks (fail-closed)
    with open(os.path.join(acc8, "EPOCH"), "w") as f:
        f.write("{broken")
    ok(a8.epoch_allows() is False, "epoch_allows False on a broken EPOCH (fail-closed) (r9 #8)")

    # (r10 #12) --once and --converge run through main(); they must respect the epoch gate
    # (a direct scan()/converge would mutate READY homes even after a rollback to v1).
    acc12 = tempfile.mkdtemp(prefix="archd-12-")
    home12 = os.path.join(acc12, "homes", "f-at-x.com"); os.makedirs(home12)
    registry.publish_ready(acc12, "f@x.com", home12, "uuid-f")
    write_cred(home12, "v1once")
    _epoch.write_epoch(acc12, "v1", 1)
    env12 = dict(os.environ, ACCOUNT_BANK_DIR=acc12, ACCOUNT_BANK_ARCHIVER_RECONCILE="0")
    subprocess.run([sys.executable, os.path.join(HERE, "archiverd.py"), "--once"],
                   env=env12, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    ok("at-v1once" not in archived_tags(home12),
       "--once under EPOCH v1 does NOT archive (routes through the epoch gate) (r10 #12)")
    _st12 = json.load(open(os.path.join(acc12, archiverd.STATUS_NAME)))
    ok(_st12.get("epoch_parked") is True, "--once under v1 writes a parked status (r10 #12)")
    # --converge under v1 -> parked, no convergence
    open(os.path.join(home12, "CLAUDE.md"), "w").write("FORKED12")
    r = subprocess.run([sys.executable, os.path.join(HERE, "archiverd.py"), "--converge"],
                       env=env12, capture_output=True, text=True, timeout=30)
    ok('"epoch_parked": true' in r.stdout,
       "--converge under EPOCH v1 parks (no fork convergence) (r10 #12)")
    ok(os.path.isfile(os.path.join(home12, "CLAUDE.md")) and not os.path.islink(os.path.join(home12, "CLAUDE.md")),
       "--converge under v1 leaves the fork untouched (r10 #12)")
    # sanity: under v2, --once DOES archive (gate open)
    _epoch.write_epoch(acc12, "v2", 2)
    subprocess.run([sys.executable, os.path.join(HERE, "archiverd.py"), "--once"],
                   env=env12, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    ok("at-v1once" in archived_tags(home12), "--once under EPOCH v2 archives (gate open) (r10 #12)")

    # (r11 #7) scan() itself re-checks epoch per-home (not just cycle()); converge_drift too.
    acc7 = tempfile.mkdtemp(prefix="archd-7-")
    home7 = os.path.join(acc7, "homes", "g-at-x.com"); os.makedirs(home7)
    registry.publish_ready(acc7, "g@x.com", home7, "uuid-g")
    write_cred(home7, "v2seed7")
    a7 = archiverd.Archiver(acc7)
    _epoch.write_epoch(acc7, "v2", 1)
    a7.scan()                                          # v2: archives the seed
    ok("at-v2seed7" in archived_tags(home7), "scan archives under v2 (r11 #7 baseline)")
    # a flip to v1 lands; a bare scan() must NOT archive a new version (per-home gate)
    _epoch.write_epoch(acc7, "v1", 2)
    write_cred(home7, "v1-after-flip7")
    a7.scan()
    ok("at-v1-after-flip7" not in archived_tags(home7),
       "scan() re-checks epoch per-home; no archive after a flip to v1 (r11 #7)")
    # converge_drift also refuses under v1
    _gl7 = os.path.join(acc7, "global"); os.makedirs(_gl7); open(os.path.join(_gl7, "CLAUDE.md"), "w").write("G")
    open(os.path.join(home7, "CLAUDE.md"), "w").write("FORK7")
    conv7 = a7.converge_drift(home7, _gl7)
    ok(conv7 == [] and os.path.isfile(os.path.join(home7, "CLAUDE.md")) and not os.path.islink(os.path.join(home7, "CLAUDE.md")),
       "converge_drift refuses under v1 (per-home epoch recheck) (r11 #7)")
    # (r11 #9) the v2 ping cooldown marker is a per-home control file, NOT drift
    open(os.path.join(home7, ".ping-marker.json"), "w").write('{"last_ping": 1}')
    ok(".ping-marker.json" not in archiverd.Archiver._drift_check(home7),
       ".ping-marker.json is not flagged as forked drift (r11 #9)")
    # (rollback-day) per-config-dir RUNTIME files SHOULD diverge and are pure noise on the health
    # surface — the named three plus any *.lock are excluded, while a genuine forked shared config
    # (settings.json) is STILL flagged (proving the exclusion did not over-broaden).
    for _rt in ("daemon.lock", "daemon.status.json", "gh-pr-status-cache.json", "other.lock"):
        open(os.path.join(home7, _rt), "w").write("runtime")
    open(os.path.join(home7, "settings.json"), "w").write('{"x": 1}')   # a real forked shared file
    _drift7 = archiverd.Archiver._drift_check(home7)
    ok(all(_rt not in _drift7 for _rt in
           ("daemon.lock", "daemon.status.json", "gh-pr-status-cache.json", "other.lock")),
       "per-config-dir runtime files + *.lock are excluded from fork drift (rollback-day)")
    ok("settings.json" in _drift7,
       "a genuine forked shared config is STILL flagged (exclusion not over-broadened) (rollback-day)")

    # (release-eve) the exclusion is a CLASS rule now, not an instance list. The instance list
    # was already behind reality — .last-update-result.json was forking on the live homes with
    # no entry to cover it — and would fall behind again with the next runtime file. Assert the
    # four known instances AND the previously-missed one, then re-assert the negative control:
    # a forked settings.json must still be flagged, so the class rule did not become `*.json`.
    _runtime_names = ("daemon.lock", "daemon.status.json", "gh-pr-status-cache.json",
                      "other.lock", ".last-update-result.json")
    for _rt in _runtime_names:
        open(os.path.join(home7, _rt), "w").write("runtime")
    _drift_cls = archiverd.Archiver._drift_check(home7)
    ok(all(_rt not in _drift_cls for _rt in _runtime_names),
       "class rule excludes *.lock / *.status.json / *-cache.json / .last-* (release-eve)")
    ok("settings.json" in _drift_cls,
       "forked settings.json STILL flagged under the class rule (negative control) (release-eve)")
    # shape-level coverage: names never seen before must be classified by SHAPE, and
    # look-alike CONFIG names must not be swept up by it.
    for _new in ("someotherd.status.json", "npm-cache.json", ".last-refresh.json", "x.lock"):
        open(os.path.join(home7, _new), "w").write("runtime")
    for _cfg in ("status.json", "cache.json", "last-run.json"):
        open(os.path.join(home7, _cfg), "w").write('{"shared": 1}')
    _drift_shape = archiverd.Archiver._drift_check(home7)
    ok(all(_n not in _drift_shape for _n in
           ("someotherd.status.json", "npm-cache.json", ".last-refresh.json", "x.lock")),
       "UNSEEN runtime files are excluded by shape, no list update needed (release-eve)")
    ok(all(_c in _drift_shape for _c in ("status.json", "cache.json", "last-run.json")),
       "config look-alikes (status.json/cache.json/last-run.json) are STILL flagged (release-eve)")

    # (r12 #6-sweep) _prune keeps the NEWEST ARCHIVE_KEEP by mtime, not by lexicographic name.
    # A same-second pair whose names sort the NEWER one "older" (lower pid) must not be pruned
    # while the stale one is kept.
    import archiverd as _ad
    _keep = _ad.ARCHIVE_KEEP
    padir = tempfile.mkdtemp(prefix="prune-")
    # write ARCHIVE_KEEP+1 entries; make the LAST-written (newest mtime) have a name that sorts
    # EARLY (low pid), so a name-based prune would delete it.
    newest = os.path.join(padir, "20260101T000000Z-000001-0000000000000000.json")
    for i in range(_keep):
        p = os.path.join(padir, f"20260101T000000Z-{900000+i:06d}-{i:016x}.json")
        open(p, "w").write("{}"); os.utime(p, ns=(1_000_000_000 + i, 1_000_000_000 + i))
    open(newest, "w").write("{}"); os.utime(newest, ns=(9_000_000_000, 9_000_000_000))  # newest by mtime
    _ad.HomeWatch._prune(padir)
    ok(os.path.exists(newest),
       "_prune keeps the chronologically-newest entry even when its NAME sorts early (r12 #6-sweep)")
    ok(len([e for e in os.listdir(padir) if e.endswith(".json")]) == _keep,
       f"_prune trimmed to ARCHIVE_KEEP ({_keep}) entries (r12 #6-sweep)")

    # (seat) a SLOT-seat home (the file migrated away → lives in the per-config-dir keychain slot)
    # is still archived by the periodic scan, and its slot rotation is picked up. Migration is a
    # seat CHANGE, never a lost credential. Uses the fake keychain set at the top of main().
    import seedflow as _sf
    accSeat = tempfile.mkdtemp(prefix="archd-seat-")
    homeSeat = os.path.join(accSeat, "homes", "sl-at-x.com"); os.makedirs(homeSeat)
    registry.publish_ready(accSeat, "sl@x.com", homeSeat, "uuid-sl")
    _slotsvc = _sf.config_slot_service(homeSeat)
    _fk = os.environ["ACCOUNT_BANK_FAKE_KEYCHAIN"]
    with open(_sf._fake_slot_path(_fk, _slotsvc), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"SEATCRED","refreshToken":"r","expiresAt":9}}')
    aSeat = archiverd.Archiver(accSeat)   # NO .credentials.json file -> the seat is the slot
    aSeat.scan(); aSeat.write_status()
    ok("SEATCRED" in archived_tags(homeSeat), "slot-seat credential archived by the periodic scan (seat)")
    _st = json.load(open(os.path.join(accSeat, archiverd.STATUS_NAME)))
    ok(_st["homes"].get(homeSeat, {}).get("seat") == "slot", "health status reports seat='slot' (seat)")
    # a slot ROTATION is a new version -> archived; unchanged content is deduped
    n_before = len([e for e in os.listdir(os.path.join(homeSeat, "archive")) if e.endswith(".json")])
    aSeat.scan()
    ok(len([e for e in os.listdir(os.path.join(homeSeat, "archive")) if e.endswith(".json")]) == n_before,
       "unchanged slot content is NOT re-archived (dedup) (seat)")
    with open(_sf._fake_slot_path(_fk, _slotsvc), "w") as f:
        f.write('{"claudeAiOauth":{"accessToken":"SEATCRED2","refreshToken":"r","expiresAt":9}}')
    aSeat.scan()
    ok("SEATCRED2" in archived_tags(homeSeat), "a slot rotation IS archived (seat)")

    # (v101) SINGLE INSTANCE. A manually-bootstrapped daemon and the launchd one coexisted
    # for two days, alternating status writes so the health surface flapped between two views
    # and each doubled the other's archiving. The daemon loop now takes a pid-lock.
    import banklock as _bl
    accL = tempfile.mkdtemp(prefix="archd-lock-")
    envL = dict(os.environ, ACCOUNT_BANK_DIR=accL, ACCOUNT_BANK_ARCHIVER_RECONCILE="0")
    held = _bl.DaemonLock(accL, archiverd.DAEMON_LOCK_NAME)
    ok(held.acquire() is True, "the first archiverd takes the single-instance lock (v101)")
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, "archiverd.py")],
                           env=envL, capture_output=True, text=True, timeout=30)
        rc, errtext = r.returncode, r.stderr
    except subprocess.TimeoutExpired:
        rc, errtext = None, "(second instance never exited — it ran run_forever)"
    ok(rc == 0 and "another instance is already running" in errtext,
       "a SECOND archiverd exits cleanly with one line instead of becoming a second writer (v101)")
    ok(f"pid {os.getpid()}" in errtext, "the stand-down line names the live holder (v101)")
    ok(not os.path.exists(os.path.join(accL, archiverd.STATUS_NAME)),
       "the stood-down instance wrote NO status — the alternating-writes damage is gone (v101)")
    held.release()

    # A holder killed by a signal never releases. Reclaim is on POSITIVE DEATH of the recorded
    # owner, with no age window: BankLock's 5-min staleness rule would lock a launchd KeepAlive
    # restart out for five minutes after every crash, since a daemon's lock dir is as old as
    # the daemon. (The SIGKILL-then-restart sequence earlier in this file exercises the same
    # path against the real daemon.)
    dead = subprocess.Popen([sys.executable, "-c", "pass"]); dead.wait()
    lockdir = os.path.join(accL, archiverd.DAEMON_LOCK_NAME)
    os.makedirs(lockdir)
    with open(os.path.join(lockdir, "owner"), "w") as f:
        f.write(f"{dead.pid} tok-of-a-dead-daemon Mon Jan  1 00:00:00 2020")
    ok(_bl.BankLock(accL, archiverd.DAEMON_LOCK_NAME).acquire(timeout=0) is False,
       "bank-lock age semantics would NOT reclaim a just-crashed daemon's lock (v101)")
    fresh = _bl.DaemonLock(accL, archiverd.DAEMON_LOCK_NAME)
    ok(fresh.acquire() is True,
       "DaemonLock reclaims a provably-dead holder immediately — no age window (v101)")
    ok(fresh.owner_pid() == os.getpid(), "the reclaimed lock records the new holder (v101)")
    fresh.release()
    ok(not os.path.isdir(lockdir), "release removes the daemon lock dir (v101)")

    # a LIVE holder is never reclaimed, however old the lock is
    live = _bl.DaemonLock(accL, archiverd.DAEMON_LOCK_NAME)
    ok(live.acquire() is True, "re-acquire after release (v101)")
    os.utime(lockdir, (1, 1))                 # ancient mtime, live owner
    ok(_bl.DaemonLock(accL, archiverd.DAEMON_LOCK_NAME).acquire() is False,
       "an ancient lock with a LIVE owner is never reclaimed (v101)")
    live.release()

    print(f"-- archiverd: {COUNT[0] - len(FAILS)} passed, {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
