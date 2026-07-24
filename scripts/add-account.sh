#!/bin/bash
# add-account.sh <email> — the interactive seeding flow (ISOLATION-DESIGN.md rev 8 §7).
# Invoked as `claude-acct --add <email>` (owner present; browser will open).
#
# Implements the full transaction: quiesce checklist -> SEEDING freeze (generation-
# fenced) -> staged skeleton -> keychain snapshot (F0) -> /login in the staged home
# (dedicated setsid group) -> G5 branch -> verification turn + G9 -> atomic
# publication (fsync tree -> rename -> parent fsync -> READY commit LAST) ->
# unfreeze. Any failure: journal shows the phase; seedflow.py recover applies the
# rev-8 rules (freeze retained whenever the keychain is unproven).
set -u
EMAIL="${1:?usage: add-account.sh <email>}"
ACC="${ACCOUNT_BANK_DIR:-$HOME/.claude/accounts}"
# (r11 #2) resolve the scripts dir like claude-acct/bin-claude: env override, else THIS
# script's own dir (so an installed add-account.sh finds its sibling bank_common.py at the
# XDG path), else the legacy default only if the resolved dir lacks the scripts.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
SCRIPTS="${ACCOUNT_BANK_SCRIPTS_DIR:-$_SELF_DIR}"
[ -f "$SCRIPTS/bank_common.py" ] || SCRIPTS="$HOME/.claude/scripts/account-bank"
# (r12 sweep-a) EXPORT the resolved dir so every child python heredoc below inherits it
# (the inline `sys.path.insert(...ACCOUNT_BANK_SCRIPTS_DIR...)` fall back to the legacy path
# otherwise). One export covers the login/harvest/verification/publication children.
export ACCOUNT_BANK_SCRIPTS_DIR="$SCRIPTS"
# (finding 32) email + scripts dir pass through argv, NEVER interpolated into the
# Python source — a quote-bearing email cannot inject code.
SAFE="$(python3 - "$EMAIL" "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
import bank_common
s = bank_common.safe_email(sys.argv[1])
print(s if s else "")
PY
)"
[ -n "$SAFE" ] || { echo "add-account: unsafe email" >&2; exit 64; }
STAGED="$ACC/homes/.staging/$SAFE"
FINAL="$ACC/homes/$SAFE"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { echo "add-account: $*" >&2; exit 1; }

[ -d "$FINAL" ] && die "home already exists: $FINAL (remove or reconnect instead)"

say "Seeding a permanent isolated home for $EMAIL"
echo "This mints a FRESH OAuth grant via /login (browser). ~2 minutes."
say "Quiesce checklist — confirm each (rev 8 §7 step 1):"
for item in \
  "Claude Desktop is QUIT (Cmd-Q, not just closed)" \
  "All other claude terminal sessions are closed" \
  "QuotaBar is paused (or quit)"; do
    read -r -p "  [$item] — confirmed? [y/N] " a </dev/tty
    [ "$a" = "y" ] || die "quiesce not confirmed; aborting (nothing touched)"
done

# freeze (full barrier + generation bump + transaction journal, before ANYTHING)
python3 "$SCRIPTS/seedflow.py" freeze "$EMAIL" >/dev/null || die "freeze failed (another seeding pending? run: seedflow.py recover)"
# (r13 #2) record THIS orchestrating process (add-account.sh, $$) in the journal so recovery
# judges the transaction's liveness by the long-lived parent — NOT the /login child that dies
# when login exits. Without this, `seedflow.py recover` during a live VERIFIED phase would
# misclassify the transaction as stale and clear its freeze mid-publication.
python3 "$SCRIPTS/seedflow.py" record-orchestrator "$$" || die "could not record orchestrator identity; run: seedflow.py recover"
trap 'echo; echo "add-account: interrupted — run: python3 '"$SCRIPTS"'/seedflow.py recover" >&2' INT TERM

# staged skeleton + audit — (finding 32) scripts dir via argv + QUOTED heredoc so no
# shell value is interpolated into the Python source.
python3 - "$STAGED" "$HOME/.claude" "$ACC/seed-audit.jsonl" "$SCRIPTS" <<'EOF' || die "skeleton failed"
import sys
sys.path.insert(0, sys.argv[4])
import seedflow
seedflow.build_skeleton(sys.argv[1], sys.argv[2], sys.argv[3])
EOF

# F0 snapshot + archive happened INSIDE the freeze barrier (rev 9 §7 step 1).
# Advance the journal to LOGIN_STARTED (write-ahead intent before the spawn).
python3 "$SCRIPTS/seedflow.py" phase LOGIN_STARTED || die "journal phase failed"

# (live-gate fix 2, 2026-07-22) passing '/login' as a launch argument died silently
# after the fresh home's trust dialog (session exited without running the command; found
# at the first real G5). Launch a PLAIN interactive session in the staged home instead
# and have the owner type /login themselves — one less moving part in an owner-present
# step that is interactive anyway.
say "Opening a claude session in the staged home — type /login IN IT, then /exit."
echo "  1. In the session that opens: type  /login  and press Enter"
echo "  2. Log into EXACTLY $EMAIL in the browser (paste the code back if asked)"
echo "  3. After 'login successful': type  /exit"
# (live-gate fixes 1-4, 2026-07-22, found at the first real G5 run) The original spawn
# (python Popen + start_new_session) detached the TUI from the terminal; three repair
# attempts (pgroup + tcsetpgrp handoff, plain-session launch, tty-as-stdin) each moved
# the failure but the TUI never became fully interactive. Root lesson: don't hand-roll
# job control around an interactive TUI. Use BASH'S OWN monitor mode: `set -m` gives the
# background job its own process group (containment preserved — the journal records it),
# and `fg` performs the canonical foreground/tty handoff exactly as an interactive shell
# would. The helper child still write-ahead journals its own identity (r9) and execs
# claude with the stripped OAuth-only env (r12 #5) — computed by the helper itself now.
_LOGIN_HELPER=$(cat <<'PY'
import os, sys
sys.path.insert(0, os.environ["ACCOUNT_BANK_SCRIPTS_DIR"])
import seedflow, sessions, isolated_refresh
acc, staged = sys.argv[1], sys.argv[2]
cbin = isolated_refresh.resolve_claude_bin()
if not cbin:
    sys.exit(2)
# (r12 #5 / sweep-c) strip alt-auth env: the login turn must not route through a stray
# ANTHROPIC_API_KEY / Bedrock/Vertex identity. OAuth-only env, CLAUDE_CONFIG_DIR=staged.
env = dict(isolated_refresh._oauth_only_env(staged),
           ACCOUNT_BANK_SCRIPTS_DIR=os.environ["ACCOUNT_BANK_SCRIPTS_DIR"])
# (r9) WRITE-AHEAD identity: journal own pgid + pid + proc-start BEFORE exec'ing claude
# via seedflow.amend_leader (bank-lock + txn-checked) — never a raw journal rewrite.
rec = seedflow._journal_read(acc)
seedflow.amend_leader(acc, rec["txn"], os.getpgid(0), os.getpid(),
                      sessions._proc_start(os.getpid()))
os.execve(cbin, [cbin], env)
PY
)
export ACCOUNT_BANK_SCRIPTS_DIR="$SCRIPTS"
set -m
python3 -c "$_LOGIN_HELPER" "$ACC" "$STAGED" &
fg %+
rc=$?
set +m
[ $rc -eq 0 ] || die "login session failed (rc $rc); run: python3 $SCRIPTS/seedflow.py recover"

# G5 branch
if [ -f "$STAGED/.credentials.json" ]; then
    say "G5 RESULT: /login wrote FILE credentials into the home (G5a — best case)."
    python3 "$SCRIPTS/seedflow.py" phase HOME_WRITTEN g5=a || die "journal"
else
    # (G5c, live 2026-07-22) CLI 2.1.217 writes the staged /login credential into a
    # PER-CONFIG-DIR keychain slot (Claude Code-credentials-<sha256(staged)[:8]>), not
    # the shared default slot and not the home file. Check that slot FIRST; the default-
    # slot CAS harvest below stays as the legacy fallback for older CLIs.
    say "G5 RESULT: /login did not write the home file — checking the per-config-dir keychain slot (G5c)…"
    python3 - "$ACC" "$STAGED" "$EMAIL" <<'EOF'
import sys, os
sys.path.insert(0, os.environ.get("ACCOUNT_BANK_SCRIPTS_DIR", os.path.expanduser("~/.claude/scripts/account-bank")))
import seedflow, identity, homewrite
acc, staged, email = sys.argv[1], sys.argv[2], sys.argv[3]
rec = seedflow._journal_read(acc)
svc = seedflow.config_slot_service(staged)
blob, raw, status = seedflow._sh_keychain_read(service=svc)
if status == "error":
    print("G5c slot read: keychain unreadable (locked/denied); ABORT — freeze retained", file=sys.stderr)
    sys.exit(2)
if status == "absent":
    sys.exit(10)     # no per-dir slot: fall back to the legacy default-slot harvest
o = (blob or {}).get("claudeAiOauth") or {}
owned, r = identity.verify_owner(o.get("accessToken", ""), email)
if owned is not True:
    print(f"G5c identity check failed ({r.verdict} {r.email}); ABORT — freeze retained", file=sys.stderr)
    sys.exit(4)
seedflow._set_phase(acc, rec, "HARVEST_READ", fp_L=seedflow._fp(blob))
homewrite.write_credential(staged, o, "seed-harvest-g5c", expected_email=email)
seedflow._set_phase(acc, rec, "HOME_WRITTEN")
# hygiene: drop the staging-path slot — the published home's path hashes differently,
# so a leftover staging slot is an orphaned credential copy in the keychain.
seedflow._sh_keychain_delete(svc)
# sanity: in the G5c world the DEFAULT slot (active account) should be untouched.
blob0, _, st0 = seedflow._sh_keychain_read()
if st0 == "present" and seedflow._fp(blob0) != rec.get("fp_F0"):
    print("WARN: default keychain slot changed during seeding (unexpected under G5c)", file=sys.stderr)
sys.exit(0)
EOF
    _g5c_rc=$?
    case "$_g5c_rc" in
        0)  say "G5 RESULT: harvested from the per-config-dir slot (G5c — modern CLI path)." ;;
        10) say "G5c: no per-config-dir slot — falling back to the legacy default-slot harvest (G5b)…" ;;
        *)  echo "HARVEST FAILED (G5c rc $_g5c_rc) — freeze retained; run: seedflow.py recover" >&2; exit 1 ;;
    esac
fi
if [ ! -f "$STAGED/.credentials.json" ]; then
    say "G5 RESULT: legacy default-slot harvest under CAS (G5b)…"
    python3 - "$ACC" "$STAGED" "$EMAIL" <<'EOF' || { echo "HARVEST FAILED — freeze retained; run: seedflow.py recover" >&2; exit 1; }
import sys, os, json
sys.path.insert(0, os.environ.get("ACCOUNT_BANK_SCRIPTS_DIR", os.path.expanduser("~/.claude/scripts/account-bank")))
import seedflow, identity, homewrite
acc, staged, email = sys.argv[1], sys.argv[2], sys.argv[3]
rec = seedflow._journal_read(acc)
blob, raw, status = seedflow._sh_keychain_read()
# (r8 #1) an unreadable slot is UNKNOWN, not "no credential": abort the harvest
# fail-closed (freeze retained) rather than treat a locked/denied read as absence.
if status == "error":
    print("harvest read: keychain unreadable (locked/denied); ABORT — freeze retained", file=sys.stderr)
    sys.exit(2)
if not blob:
    sys.exit(2)
fpL = seedflow._fp(blob)
if fpL == rec.get("fp_F0"):
    print("slot unchanged (still F0) — login landed nowhere we can see; ABORT", file=sys.stderr)
    sys.exit(3)
o = blob.get("claudeAiOauth")
owned, r = identity.verify_owner(o.get("accessToken",""), email)
if owned is not True:
    print(f"harvest identity check failed ({r.verdict} {r.email}); ABORT", file=sys.stderr)
    sys.exit(4)
seedflow._set_phase(acc, rec, "HARVEST_READ", fp_L=fpL)
homewrite.write_credential(staged, o, "seed-harvest", expected_email=email)
seedflow._set_phase(acc, rec, "HOME_WRITTEN")
# restore F0 under CAS: slot must still be L
seedflow._set_phase(acc, rec, "RESTORE_STARTED")
blob2, _, status2 = seedflow._sh_keychain_read()
# (r8 #1) unreadable re-read is UNKNOWN: do NOT restore (a failed read must not be
# taken as "slot changed" OR as "still L"); freeze retained, operator recovers from F0.
if status2 == "error":
    print("slot re-read failed during harvest (locked/denied); NOT restoring; freeze retained", file=sys.stderr)
    sys.exit(5)
if seedflow._fp(blob2) != fpL:
    print("slot changed during harvest; NOT restoring; freeze retained", file=sys.stderr)
    sys.exit(5)
import subprocess
f0_arch = rec.get("f0_archive", "")
fp_f0 = rec.get("fp_F0")
# (r3 IB2) the restore target is decided by seedflow.restore_action (a pure, unit-tested
# function) keyed on the JOURNALED F0 fingerprint, NOT on whether the archive happens to
# exist. "delete" (empty original) | "restore" (F0 from archive) | "fail-closed".
# (r14 #2) ABSOLUTE /usr/bin/security everywhere on the credential path — a PATH-prepended
# proxy named `security` would exfiltrate the F0 OAuth blob during restore. Owner-set
# override honored; default is the absolute system binary, never PATH.
_SEC = os.environ.get("ACCOUNT_BANK_SECURITY_BIN", "/usr/bin/security")
_action = seedflow.restore_action(fp_f0, bool(f0_arch and os.path.exists(f0_arch)))
if _action == "delete":
    # restore an empty slot: DELETE the harvested item. rc 0/44 are the only successes;
    # absence is CONFIRMED via `security find` rc 44 (a failed re-read is never "empty").
    dr = subprocess.run([_SEC,"delete-generic-password","-s","Claude Code-credentials",
                         "-a", os.environ.get("USER","")], capture_output=True, text=True)
    if dr.returncode not in (0, 44):
        print(f"F0 restore (delete) failed rc {dr.returncode}: {dr.stderr[:120]}; freeze retained", file=sys.stderr)
        sys.exit(6)
    fr = subprocess.run([_SEC,"find-generic-password","-s","Claude Code-credentials",
                         "-a", os.environ.get("USER","")], capture_output=True, text=True)
    if fr.returncode != 44:   # 44 == errSecItemNotFound == confirmed absent
        print(f"post-delete verify: slot NOT confirmed empty (find rc {fr.returncode}); freeze retained", file=sys.stderr)
        sys.exit(7)
elif _action == "restore":
    # (finding 31) the F0 blob travels through `security -i` STDIN, never argv —
    # so the OAuth material is not visible to same-user `ps`/process inspection.
    raw0 = open(f0_arch).read().strip()
    # (seat live-fix) same `security -i` tokenization bug as seedflow._sh_keychain_write:
    # a raw JSON value must be a double-quoted, backslash-escaped token or the parse fails.
    _esc0 = raw0.replace("\\", "\\\\").replace('"', '\\"')
    cmd = 'add-generic-password -U -s "Claude Code-credentials" -a "%s" -w "%s"\n' % (
        os.environ.get("USER",""), _esc0)
    pr = subprocess.run([_SEC,"-i"], input=cmd, capture_output=True, text=True)
    if pr.returncode != 0:
        print("F0 restore write failed; freeze retained", file=sys.stderr)
        sys.exit(6)
    blob3, _, status3 = seedflow._sh_keychain_read()
    if status3 == "error" or seedflow._fp(blob3) != fp_f0:
        print("post-restore verify failed (unreadable or mismatch); freeze retained", file=sys.stderr)
        sys.exit(7)
else:
    # (r3 IB2) nonempty original slot but the F0 archive is gone -> NEVER delete the
    # harvested credential. Fail closed: the operator restores F0 from the journal.
    print(f"F0 archive missing for a NONEMPTY original slot (fp_F0={fp_f0!r}); "
          "cannot restore, refusing to delete the harvested credential; freeze retained; "
          "operator card", file=sys.stderr)
    sys.exit(6)
seedflow._set_phase(acc, rec, "RESTORED")
EOF
fi

# verification turn + G9 in the staged home
say "Verifying the new grant (one tiny turn + identity check)…"
python3 - "$ACC" "$STAGED" "$EMAIL" <<'EOF' || die "verification failed; freeze retained — run: seedflow.py recover"
import sys, os, json, subprocess
sys.path.insert(0, os.environ.get("ACCOUNT_BANK_SCRIPTS_DIR", os.path.expanduser("~/.claude/scripts/account-bank")))
import seedflow, identity, isolated_refresh
acc, staged, email = sys.argv[1], sys.argv[2], sys.argv[3]
# (seat) read the staged home's SEAT — during seeding it is the FILE, but the verification turn
# below is a LAUNCH that may migrate file->slot, so read via the shared seat module either way.
_sb, _sr, _sst, _sk = seedflow.seat_read(staged)
o = (_sb or {}).get("claudeAiOauth", {}) if _sst == "present" else {}
owned, r = identity.verify_owner(o.get("accessToken",""), email)
if owned is not True:
    print(f"G9 says {r.verdict}/{r.email}, expected {email}", file=sys.stderr); sys.exit(2)
cbin = isolated_refresh.resolve_claude_bin()
# (r12 #5 / sweep-c) STRIP alternate-auth env — an inherited ANTHROPIC_API_KEY /
# ANTHROPIC_AUTH_TOKEN / Bedrock/Vertex routing var would make the verification turn bill
# through THAT identity, then publish the home READY against the wrong account. Reuse the
# same OAuth-only env isolated_refresh already uses (CLAUDE_CONFIG_DIR -> the staged home).
env = isolated_refresh._oauth_only_env(staged)
p = subprocess.run([cbin, "-p", "reply with just: ok", "--model", "haiku"],
                   env=env, capture_output=True, text=True, timeout=120)
if p.returncode != 0:
    print(f"verification turn failed rc {p.returncode}: {(p.stderr or p.stdout)[:200]}", file=sys.stderr)
    sys.exit(3)
# (r14 #1 CRITICAL) RE-VERIFY the credential AFTER the turn. The pre-turn G9 above proves the
# staged credential was the target's — but the CLI could have REPLACED .credentials.json with a
# DIFFERENT account's grant during the turn (and exited 0), which would then be published READY.
# Re-read the home credential and re-run G9; require the SAME account (uuid AND email) as before.
# Any mismatch/indeterminate -> ABORT seeding, NO publish.
# (seat) re-read the SEAT after the turn — the verification turn is a first pinned launch that
# may have MIGRATED the file into the per-config-dir slot and DELETED the file. Reading the file
# directly would spuriously fail here; seat_read follows the credential to its new seat.
_sb2, _sr2, _sst2, _sk2 = seedflow.seat_read(staged)
o2 = (_sb2 or {}).get("claudeAiOauth", {}) if _sst2 == "present" else {}
owned2, r2 = identity.verify_owner(o2.get("accessToken",""), email)
if owned2 is not True or r2.uuid != r.uuid:
    print(f"post-turn identity changed: {r2.verdict}/{r2.email}/{r2.uuid} != {email}/{r.uuid}; "
          "the credential was swapped during verification — ABORT, not publishing", file=sys.stderr)
    sys.exit(4)
rec = seedflow._journal_read(acc)
seedflow._set_phase(acc, rec, "VERIFIED", uuid=r2.uuid)
EOF

# atomic publication: fsync tree -> rename -> parent fsync -> READY commit LAST
python3 - "$ACC" "$STAGED" "$FINAL" "$EMAIL" <<'EOF' || die "publication failed; freeze retained"
import sys, os, json
sys.path.insert(0, os.environ.get("ACCOUNT_BANK_SCRIPTS_DIR", os.path.expanduser("~/.claude/scripts/account-bank")))
import seedflow, registry, banklock
acc, staged, final, email = sys.argv[1:5]
rec = seedflow._journal_read(acc)
# (finding 6) READY publication is a tier-1 registry write: it MUST run under the
# bank lock so a concurrent flip cannot freeze/enumerate the registry mid RMW.
lk = banklock.BankLock(acc)
if not lk.acquire(timeout=15):
    print("publication: bank lock contended; freeze retained", file=sys.stderr); sys.exit(1)
try:
    # (r9 #1) archive C1 into the STAGED home BEFORE it is reachable. The r8 placement
    # archived AFTER registry.publish_ready — but once READY, a concurrent
    # `claude-acct <email>` can launch a turn that refreshes C1->C2, so the initial
    # snapshot captured C2 and C1 was lost forever. Archiving into staged/archive/ now
    # (before the fsync walk + rename) makes the C1 snapshot part of the atomically-
    # published tree and durable before any launcher can reach the home.
    seedflow.initial_archive(staged)
    # fsync staged tree — BOTH files and directory entries (finding 6): a
    # subdirectory created in staging must be durable before READY is visible.
    for root, dirs, files in os.walk(staged):
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                fd = os.open(p, os.O_RDONLY)
                try: os.fsync(fd)
                finally: os.close(fd)
        dfd = os.open(root, os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    os.rename(staged, final)
    dfd = os.open(os.path.dirname(final), os.O_RDONLY)
    try: os.fsync(dfd)
    finally: os.close(dfd)
    registry.publish_ready(acc, email, final, rec.get("uuid", "unknown"))   # READY commit LAST
    # (r8 #15 / r9 #1) C1 was durably archived into the staged tree above, BEFORE this
    # READY commit — the archive travelled with the atomic rename, so it is captured and
    # durable before the home is reachable and cannot be a post-READY C2.
    # (finding 6) we already HOLD the bank lock — pass _locked=True so _set_phase does
    # NOT re-acquire it (non-reentrant mkdir) and self-deadlock, which would strand the
    # now-READY home with its SEEDING freeze permanently retained.
    seedflow._set_phase(acc, rec, "PUBLISHED", _locked=True)
finally:
    lk.release()
EOF

python3 "$SCRIPTS/seedflow.py" unfreeze || die "unfreeze failed (journal cleared manually via recover)"
say "DONE: $EMAIL is READY at $FINAL"
echo "Launch pinned:   claude-acct $EMAIL"
echo "Make it default: QuotaBar Switch (or repoint via autopick)"
