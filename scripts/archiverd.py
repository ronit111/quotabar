#!/usr/bin/env python3
"""archiverd.py — tier-2 credential archiver daemon (ISOLATION-DESIGN.md rev 6 §5).

Watches every READY home's .credentials.json via kqueue and archives each observed
version (0600, pruned) the moment it changes. BEST-EFFORT by design — tier-1
(homewrite.py) guarantees tooling writes; this daemon covers the CLI's own writes
(refresh commits, login/logout) with ms latency and an honest health surface.

Arm protocol (r5-hardened):
  - the PARENT DIRECTORY of each credential file is watched first (catches
    rename-replace while a file watch re-arms);
  - per file: open by path -> register kevent -> STABILIZATION LOOP: compare
    fstat(fd) vs lstat(path); mismatch -> close, re-open, re-register, repeat.
    (rename-replace changes the inode; watching a stale fd is the blind-watch bug.)
  - startup + periodic rescan: archive anything whose content hash is unseen.
  - health file (accounts/archiver.status.json): heartbeat ts + per-home
    {armed dev/inode, generation, last_event}. QuotaBar alarms on staleness OR on
    armed-inode ≠ lstat (healthy-but-blind detection).

Also the fork-drift detector (§6): symlinked shared files that became real files
are reported in the health file (repair is operator/QuotaBar-driven, never auto).

stdlib only; launchd KeepAlive runs main(); --once runs one scan cycle (for tests).
"""
import hashlib
import json
import os
import select
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import epoch
import registry

STATUS_NAME = "archiver.status.json"
POLL_FALLBACK_S = 1.0        # belt-and-suspenders rescan cadence (G7)
HEARTBEAT_EVERY_S = 5.0
# (r3 #30) the retained-archive cap is env-tunable so the G7_FULL acceptance run (×100
# final versions) can RAISE it and assert on retained files without the prune making the
# gate impossible. Default 20 in normal operation.
ARCHIVE_KEEP = int(os.environ.get("ACCOUNT_BANK_ARCHIVE_KEEP", "20"))

# (finding 36) the FULL §6 SHARED file-symlink set whose forking we detect — not just
# the four most common names. A forked copy of ANY of these silently diverges the home
# from the global system.
DRIFT_WATCH = (
    "CLAUDE.md", "settings.json", "settings.local.json", "history.jsonl",
    "statusline-command.sh", "textedit-wrapper.sh", "learnings.md", "errors.md",
    "feature-requests.md", "README.md", ".gitignore", ".gitattributes",
)


def _hash(b):
    return hashlib.sha256(b).hexdigest()


def _utc():
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


class HomeWatch(object):
    """One home's armed credential-file watch + dedup state."""

    def __init__(self, home):
        self.home = home
        self.cred = os.path.join(home, ".credentials.json")
        self.fd = -1
        self.armed = None          # (dev, inode) actually watched
        self.generation = 0
        self.last_event = 0
        self.seen = set()          # content hashes already archived
        self.seat_kind = "unknown" # (seat) file|slot|none|error — refreshed each archive_current

    def close(self):
        if self.fd >= 0:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = -1
            self.armed = None

    def arm(self, kq):
        """Open-by-path + register + stabilization loop (rev 6 §5)."""
        for _ in range(8):
            self.close()
            try:
                self.fd = os.open(self.cred, os.O_RDONLY)
            except OSError:
                self.armed = None
                return False          # file absent; parent-dir watch will re-arm us
            try:
                ev = select.kevent(
                    self.fd,
                    filter=select.KQ_FILTER_VNODE,
                    flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                    fflags=(select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE |
                            select.KQ_NOTE_RENAME | select.KQ_NOTE_EXTEND),
                )
                kq.control([ev], 0, 0)
            except OSError:
                self.close()
                return False
            try:
                st_fd = os.fstat(self.fd)
                st_path = os.lstat(self.cred)
            except OSError:
                continue               # replaced mid-arm; loop
            if (st_fd.st_dev, st_fd.st_ino) == (st_path.st_dev, st_path.st_ino):
                self.armed = (st_fd.st_dev, st_fd.st_ino)
                self.generation += 1
                return True
            # mismatch: the path moved under us — loop re-opens the NEW inode
        self.armed = None
        return False

    def archive_current(self):
        """(seat) Archive the home's current SEAT content if unseen. Returns archive path or None.
        Reads the SEAT (the .credentials.json FILE or, once the CLI has migrated + deleted the
        file on first launch, the per-config-dir keychain SLOT) via seedflow.seat_read — so slot
        seats and file->slot migrations are covered by the periodic scan (the kqueue watch only
        sees the file). Dedup by content hash: a migration of the SAME credential is NOT
        re-archived; a rotated slot version is a new hash and IS archived. A vanished file whose
        credential now lives in the slot is a seat CHANGE, never a lost/drifted credential."""
        import seedflow
        _blob, _raw, status, _kind = seedflow.seat_read(self.home)
        self.seat_kind = _kind if status != "error" else "error"
        if status != "present" or not _raw:
            return None
        raw = _raw.encode() if isinstance(_raw, str) else _raw
        h = _hash(raw)
        if h in self.seen:
            return None
        adir = os.path.join(self.home, "archive")
        try:
            os.makedirs(adir, exist_ok=True)
            os.chmod(adir, 0o700)
            dest = os.path.join(
                adir, f"{_utc()}-{os.getpid()}-{time.monotonic_ns():016x}-observed.json")
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            # (r2 finding 25) fsync the archive DIRECTORY too — the file's data is
            # durable but its directory entry is not until the dir is synced. Only
            # after BOTH is the archive truly durable; that is the point `seen` records.
            _dfd = os.open(adir, os.O_RDONLY)
            try:
                os.fsync(_dfd)
            finally:
                os.close(_dfd)
            # (finding 25) mark seen ONLY after a durable archive. Adding the hash
            # before the write meant a transient disk/permission failure poisoned the
            # dedup set forever — a later rescan would skip the unchanged landed
            # version and never recover it (a G7 rescan-recovery violation).
            self.seen.add(h)
            self.last_event = int(time.time())
            self._prune(adir)
            return dest
        except OSError:
            return None

    @staticmethod
    def _prune(adir):
        try:
            # (r12 #6-sweep) prune OLDEST-first by real write time (st_mtime_ns), NOT
            # lexicographic name order — the <utc>-<pid>-<monotonic> names sort same-second
            # entries by PID, so a name sort could prune a NEWER version and keep an older one.
            def _mtime(name):
                try:
                    return os.stat(os.path.join(adir, name)).st_mtime_ns
                except OSError:
                    return -1
            entries = sorted((e for e in os.listdir(adir) if e.endswith(".json")),
                             key=lambda n: (_mtime(n), n), reverse=True)
            for stale in entries[ARCHIVE_KEEP:]:
                try:
                    os.remove(os.path.join(adir, stale))
                except OSError:
                    pass
        except OSError:
            pass


class Archiver(object):
    def __init__(self, accounts_dir, reconciler=None):
        self.acc = accounts_dir
        self.kq = select.kqueue()
        self.watches = {}          # home -> HomeWatch
        self.dir_fds = {}          # home -> parent-dir watch fd
        self.drift = {}            # home -> [forked shared files]
        # (r8 #16) the home reconciler, wired by the production daemon (main → run_forever)
        # to homerec.reconcile_home. reconcile_home was previously DEAD in production — no
        # caller invoked it, so a CLI login writing a foreign/schema-invalid credential into
        # a READY home was archived but never reconciled; the broken blob stayed live. We
        # trigger a reconcile pass on a home the moment the archiver observes its credential
        # CHANGE (a §5 "archiver event"). Injectable so --once/tests stay hermetic (no G9).
        self.reconciler = reconciler
        self.home_email = {}       # home -> email (from the registry, for reconcile calls)
        self.reconcile_status = {} # home -> last reconcile verdict (for the health surface)

    # -- home discovery ------------------------------------------------------
    def _ready_homes(self):
        try:
            reg = registry.load(self.acc)
        except registry.RegistryError:
            return []
        out = []
        for email, ent in reg.items():
            if (isinstance(ent, dict) and ent.get("ready") is True
                    and isinstance(ent.get("home"), str) and os.path.isdir(ent["home"])):
                out.append(ent["home"])
                self.home_email[ent["home"]] = email
        return out

    def _watch_dir(self, home):
        if home in self.dir_fds:
            return
        try:
            fd = os.open(home, os.O_RDONLY)
            ev = select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                               flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                               fflags=select.KQ_NOTE_WRITE)
            self.kq.control([ev], 0, 0)
            self.dir_fds[home] = fd
        except OSError:
            pass

    # -- one scan cycle (startup, fallback poll, and --once) -----------------
    def scan(self):
        homes = self._ready_homes()
        for home in homes:
            # (r11 #7) RE-CHECK epoch immediately before each per-home archive. A cycle can
            # observe shadow, then a concurrent flip commits v1 mid-scan; without this the
            # scan keeps archiving READY homes after rollback. The archiver holds no home
            # lock, so the residual instant between this check and the archive write is the
            # accepted unavoidable window (§8); a landed flip stops all further archiving now.
            if not self.epoch_allows():
                return
            w = self.watches.get(home)
            if w is None:
                w = self.watches[home] = HomeWatch(home)
                self._watch_dir(home)
            new_ver = w.archive_current()
            # (r8 #16 / r10 #13) dispatch reconcile on ANY newly-observed version — the
            # FIRST scan included, not only a change vs a version THIS instance already saw.
            # On a daemon restart, a foreign/invalid credential that landed while it was down
            # is seen for the first time (had_seen would be False); the r8 change missed it,
            # leaving the broken credential live indefinitely. The reconciler self-guards
            # (repairs only a provably-broken home, no-op otherwise) and the dispatch is
            # detached, so reconciling each home once per (re)start is cheap and safe.
            if new_ver and self.reconciler is not None:
                email = self.home_email.get(home)
                if email:
                    try:
                        self.reconcile_status[home] = self.reconciler(self.acc, email)
                    except Exception as e:
                        self.reconcile_status[home] = f"reconcile-error: {type(e).__name__}"
            # (re)arm when unarmed or when the armed inode went stale
            try:
                st = os.lstat(w.cred)
                stale = w.armed != (st.st_dev, st.st_ino)
            except OSError:
                stale = True
            if w.fd < 0 or stale:
                w.arm(self.kq)
            self.drift[home] = self._drift_check(home)
        # forget homes that lost READY
        for home in list(self.watches):
            if home not in homes:
                self.watches.pop(home).close()
                fd = self.dir_fds.pop(home, None)
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass

    @staticmethod
    def _drift_check(home):
        """(r2 finding 36) DYNAMIC detection of rev 9's "remaining files" set: ANY
        top-level entry that is a REAL FILE (not a symlink) and is not a per-home real
        (`.credentials.json`/`.claude.json`) is a forked shared file. This catches
        files beyond the named DRIFT_WATCH list. Per-home dirs (backups/, archive/) are
        skipped; the credential file is the archiver's own domain, never "drift"."""
        forked = []
        try:
            for name in sorted(os.listdir(home)):
                # (r11 #9) .ping-marker.json is the v2 ping cooldown state — a legitimate
                # per-home control file, NOT forked shared drift; skip it like the other
                # per-home reals so it never shows as a spurious fork.
                # (rollback-day) daemon.lock / daemon.status.json / gh-pr-status-cache.json are
                # per-config-dir RUNTIME state that SHOULD diverge between ~/.claude and a home —
                # a live daemon writes its own lock/status/cache per dir, never a shared config to
                # reconcile. Flagging them was pure noise on the health surface.
                if name in (".credentials.json", ".claude.json", "backups", "archive",
                            ".ping-marker.json", ".DS_Store",
                            "daemon.lock", "daemon.status.json", "gh-pr-status-cache.json"):
                    continue
                # (rollback-day) Conservative runtime pattern: a lock file is by definition
                # per-process runtime state, never a shared config file worth converging. This
                # generalizes daemon.lock without touching *.json / *.md config (no over-broadening).
                # (release-eve) CLASS rule, not an instance list. The named exclusions above
                # were added one spurious fork at a time, and the list was already behind
                # reality: `.last-update-result.json` was forking on the live homes with no
                # entry to cover it. Per-config-dir runtime state has recognizable SHAPES —
                # a status file, a cache, a "last <thing>" result marker — and none of them
                # is a shared config worth converging. Deliberately NOT a bare `*.json`
                # wildcard: settings.json / CLAUDE.md and friends must still be flagged.
                if (name.endswith(".lock")
                        or name.endswith(".status.json")
                        or name.endswith("-cache.json")
                        or name.startswith(".last-")):
                    continue
                p = os.path.join(home, name)
                if os.path.isfile(p) and not os.path.islink(p):
                    forked.append(name)
        except OSError:
            pass
        return forked

    def converge_drift(self, home, global_root):
        """(finding 36) Resolve a detected fork per §6: GLOBAL WINS. For each forked
        shared file, archive the home's diverged copy into <home>/archive/, remove it,
        and re-link to the global (~/.claude/<name>). NEVER auto-invoked in scan() —
        the daemon only DETECTS; convergence is operator/QuotaBar-driven (CLI --converge
        or an explicit call). Returns the list of files converged.

        (r2 MAJOR) COPY-BEFORE-REMOVE and SKIP-IF-NO-GLOBAL: a fork is removed ONLY
        after its copy is durably archived AND only when a global target exists to
        re-link to — never leave the home without either the fork or a link, which
        would durably lose the only forked copy."""
        converged = []
        # (r11 #7) re-check epoch immediately before this per-home convergence mutation —
        # a flip may have committed v1 since the --converge entry gate.
        if not self.epoch_allows():
            return converged
        adir = os.path.join(home, "archive")
        for name in self._drift_check(home):
            src = os.path.join(home, name)
            target = os.path.join(global_root, name)
            if not (os.path.exists(target) or os.path.islink(target)):
                continue                        # no global to relink to -> leave the fork
            try:
                os.makedirs(adir, exist_ok=True)
                os.chmod(adir, 0o700)
                with open(src, "rb") as f:
                    raw = f.read()
                dest = os.path.join(
                    adir, f"{_utc()}-{os.getpid()}-{time.monotonic_ns():016x}-fork-{name}")
                fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "wb") as f:
                    f.write(raw)
                    f.flush()
                    os.fsync(f.fileno())
                _adfd = os.open(adir, os.O_RDONLY)   # durable archive before we remove
                try:
                    os.fsync(_adfd)
                finally:
                    os.close(_adfd)
                # (r8 #18) ATOMIC replace, no missing-file window: the old code did
                # os.remove(src) THEN os.symlink(target, src); if the symlink failed
                # (ENOSPC/EIO) the home was left with NEITHER the fork nor a link, and
                # since drift only flags REAL files (never a MISSING path) the loss was
                # invisible to every later scan. Build the symlink at a temp name and
                # rename() it over src — rename atomically replaces the regular file, so
                # src is never absent; a failure leaves the fork in place (reported next scan).
                tmplink = os.path.join(
                    home, f".drift-relink.{os.getpid()}.{time.monotonic_ns():016x}")
                try:
                    os.symlink(target, tmplink)
                    os.rename(tmplink, src)     # atomic: fork -> symlink, no gap
                except OSError:
                    if os.path.islink(tmplink) or os.path.lexists(tmplink):
                        try:
                            os.unlink(tmplink)
                        except OSError:
                            pass
                    continue                    # fork archived + still present; try next scan
                converged.append(name)
            except OSError:
                continue                        # best-effort; a failure stays reported
        return converged

    # -- health --------------------------------------------------------------
    def write_status(self):
        st = {"ts": int(time.time()), "pid": os.getpid(), "homes": {}}
        for home, w in self.watches.items():
            try:
                cur = os.lstat(w.cred)
                cur_id = [cur.st_dev, cur.st_ino]
            except OSError:
                cur_id = None
            armed_repr = list(w.armed) if w.armed else None
            st["homes"][home] = {
                "armed": armed_repr,
                "current": cur_id,
                # (r3 #30 / r2 MAJOR) BLIND == the armed inode does not match the live
                # credential inode. This is exactly `armed_repr != cur_id`:
                #   * cred present, armed matches      -> equal      -> healthy
                #   * cred present, armed None/mismatch -> not equal -> BLIND (unwatched)
                #   * cred absent,  armed present       -> not equal -> BLIND (ghost inode)
                #   * cred absent,  armed None          -> equal(None)-> not blind (nothing to watch)
                # The old `bool(armed) and ...` form falsely read an UNARMED watch over a
                # live credential (armed=None) as healthy.
                # (seat) a SLOT seat has no file to kqueue-watch; it is covered by the periodic
                # scan, so a missing file there is NOT "blind" (cred absent + armed None already
                # computes blind=False). The seat kind is surfaced so a slot seat's absent file
                # is never misread as a lost credential.
                "blind": armed_repr != cur_id,
                "seat": w.seat_kind,
                "generation": w.generation,
                "last_event": w.last_event,
                "forked_shared_files": self.drift.get(home, []),
            }
        tmp = os.path.join(self.acc, f".{STATUS_NAME}.{os.getpid()}")
        with open(tmp, "w") as f:
            json.dump(st, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, os.path.join(self.acc, STATUS_NAME))

    # -- epoch gate (r9 #8) --------------------------------------------------
    def epoch_allows(self):
        """The archiver is a shadow|v2 tool (§8 tool-state matrix). After a rollback to
        v1 it must PARK — never scan/archive/reconcile READY homes or arm watches on
        them. A PRESENT EPOCH outside shadow|v2 (or a broken one) parks; an ABSENT EPOCH
        is the pre-v2 world (kept permissive so the daemon is testable and a pre-cutover
        install is inert anyway)."""
        if not os.path.exists(os.path.join(self.acc, "EPOCH")):
            return True
        try:
            return epoch.read_epoch(self.acc)["state"] in ("shadow", "v2")
        except epoch.EpochError:
            return False

    def write_parked_status(self):
        """(r9 #8) Honest health surface while epoch-parked: fresh heartbeat + an explicit
        epoch_parked flag + no watched homes (we hold no armed fds over homes we must not
        touch). QuotaBar can render this as 'archiver idle (rolled back to v1)'."""
        st = {"ts": int(time.time()), "pid": os.getpid(), "epoch_parked": True, "homes": {}}
        tmp = os.path.join(self.acc, f".{STATUS_NAME}.{os.getpid()}")
        with open(tmp, "w") as f:
            json.dump(st, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, os.path.join(self.acc, STATUS_NAME))

    def _drop_watches(self):
        for home in list(self.watches):
            self.watches.pop(home).close()
            fd = self.dir_fds.pop(home, None)
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass

    def cycle(self):
        """One daemon iteration, epoch-gated. Extracted from run_forever so it is unit-
        testable (r9 #8)."""
        if not self.epoch_allows():
            self._drop_watches()      # release any v2-era armed fds before parking
            self.write_parked_status()
            return
        self.scan()                   # scan itself re-checks epoch per home (r11 #7)
        # (r11 #7) a flip may have landed DURING scan; re-check before writing a healthy
        # status, and park if we rolled back mid-cycle.
        if self.epoch_allows():
            self.write_status()
        else:
            self._drop_watches()
            self.write_parked_status()

    # -- main loop ------------------------------------------------------------
    def run_forever(self):
        self.cycle()
        while True:
            try:
                events = self.kq.control(None, 16, POLL_FALLBACK_S)
            except OSError:
                events = []
            # anything moved (or a fallback poll): re-run the (epoch-gated) cycle — it
            # archives new content and re-arms stale watches when active, or parks in v1.
            # (r4 blocker 4) status is flushed after EVERY cycle so a health reader always
            # sees post-phase state, not a stale pre-re-arm snapshot.
            self.cycle()


def _detached_reconcile(acc, email):
    """(r8 #16) Fire-and-forget reconcile trigger: spawn homerec.py detached so the
    archiver's kqueue loop is NEVER blocked on reconcile_home's G9 network probe. The
    reconciler is self-guarding (repairs only a provably-broken home; fail-closed on
    INDETERMINATE), so a spurious trigger is a no-op. Returns immediately."""
    try:
        subprocess.Popen(
            [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "homerec.py"), email],
            env=dict(os.environ, ACCOUNT_BANK_DIR=acc),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass
    return "dispatched"


def main():
    acc = os.environ.get("ACCOUNT_BANK_DIR", os.path.expanduser("~/.claude/accounts"))
    a = Archiver(acc)
    if "--once" in sys.argv:
        # (r10 #12) route through the epoch-gated cycle — a direct scan() would archive
        # READY-home credentials even after a rollback to v1, bypassing the §8 park.
        a.cycle()
        return 0
    if "--converge" in sys.argv:
        # (finding 36) operator/QuotaBar-driven fork convergence: global wins. Never
        # runs in the daemon loop — only on explicit request.
        # (r10 #12) convergence REPLACES forked files with symlinks — a v2 home mutation.
        # Epoch-park it too: in v1 do nothing but write a parked status.
        if not a.epoch_allows():
            a.write_parked_status()
            print(json.dumps({"epoch_parked": True}, indent=1))
            return 0
        global_root = os.environ.get("CLAUDE_GLOBAL_ROOT", os.path.expanduser("~/.claude"))
        a.scan()
        report = {}
        for home in list(a.watches):
            report[home] = a.converge_drift(home, global_root)
        a.write_status()
        print(json.dumps(report, indent=1))
        return 0
    # (r8 #16) production daemon: give the reconciler a real caller. It is DISPATCHED
    # DETACHED (never run inline) — reconcile_home does a G9 network probe (up to 15s),
    # and blocking the kqueue loop on it would make the archiver miss FINAL versions and
    # blow the re-arm SLA. Detachment keeps archiving latency untouched while still giving
    # reconcile_home the production caller it lacked. Gated by ACCOUNT_BANK_ARCHIVER_RECONCILE
    # (default on) so the hermetic archiving-contract test can keep it off (no real network).
    if os.environ.get("ACCOUNT_BANK_ARCHIVER_RECONCILE", "1") != "0":
        a.reconciler = _detached_reconcile
    a.run_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
