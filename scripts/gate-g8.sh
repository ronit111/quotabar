#!/bin/bash
# gate-g8.sh <email> [--live] — G8 release gate (rev 9 §12): two-process same-home
# forced refresh, >=20 adversarial trials, binary PASS/FAIL. This gate LAUNCHES the
# real claude CLI against a real seeded home + keychain, so it runs ONLY at the morning
# gate behind --live. Without --live it performs the NON-LIVE structural checks
# (finding 37): registry READY-home lookup resolves, the tier-1 writer is importable,
# and it reports that the live body is gated — then exits 0 WITHOUT touching anything.
set -u
EMAIL="${1:?usage: gate-g8.sh <email> [--live]}"
LIVE=0; for a in "$@"; do [ "$a" = "--live" ] && LIVE=1; done
ACC="${ACCOUNT_BANK_DIR:-$HOME/.claude/accounts}"
# (r12 #4 / sweep-a) resolve the scripts dir like the shim: env override, else THIS script's
# own dir (so an installed gate-g8.sh finds its sibling registry.py at the XDG path), else
# the legacy default only if the resolved dir lacks the scripts.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
S="${ACCOUNT_BANK_SCRIPTS_DIR:-$_SELF_DIR}"
[ -f "$S/registry.py" ] || S="$HOME/.claude/scripts/account-bank"

# (r9 #4) hermetic self-test of the fail-closed keychain sampling the live gate uses.
# Driven by ACCOUNT_BANK_FAKE_KEYCHAIN so it never reads the real slot; proves that a
# failed/empty read is a FAIL, never a comparable equal hash. No home / registry needed.
for a in "$@"; do [ "$a" = "--kc-selftest" ] && { python3 - "$S" <<'PY'
import sys, hashlib
sys.path.insert(0, sys.argv[1])
import seedflow
def sample(label):
    _b, raw, st = seedflow._sh_keychain_read()
    if st != "present":
        print(f"{label}: NON-PRESENT ({st}) -> refusing to produce a comparable hash")
        return None
    return hashlib.sha256((raw or "").encode()).hexdigest()
h0, h1 = sample("baseline"), sample("final")
if h0 is None or h1 is None:
    print("G8-KC SELFTEST FAIL: a keychain read was not 'present' (fail-closed)"); sys.exit(1)
print("G8-KC SELFTEST PASS: keychain unchanged" if h0 == h1 else "G8-KC SELFTEST FAIL: keychain CHANGED")
sys.exit(0 if h0 == h1 else 1)
PY
exit $?; }; done

HOME_PATH="$(python3 "$S/registry.py" ready-home "$ACC" "$EMAIL")" || { echo "no READY home for $EMAIL"; exit 64; }

if [ "$LIVE" -ne 1 ]; then
    # (finding 37) structural preconditions only — never launches claude or reads the
    # real keychain. Proves the harness is wired to the tier-1 writer + registry.
    python3 - "$HOME_PATH" "$S" <<'PY'
import os, sys
home, S = sys.argv[1], sys.argv[2]
sys.path.insert(0, S)
import homewrite, identity, bank_common   # tier-1 writer + G9 must be importable
assert hasattr(homewrite, "write_credential"), "tier-1 writer missing"
assert os.path.isdir(home), "resolved home is not a directory"
print("G8 structural check OK (home=%s). Live trials require --live at the morning gate." % home)
PY
    exit 0
fi

python3 - "$ACC" "$HOME_PATH" "$EMAIL" "$S" <<'PY'
import json, os, subprocess, sys, time, hashlib, threading
acc, home, email, S = sys.argv[1:5]
sys.path.insert(0, S)
import identity, isolated_refresh, bank_common, homewrite, seedflow
# (seat) the home's credential is read/written through seedflow.seat_read/seat_write below —
# file OR migrated per-config-dir slot — never a hard-coded .credentials.json path.
cbin = isolated_refresh.resolve_claude_bin()
# (r9 #4) sample the keychain through the three-valued fail-closed reader: a read that
# FAILS (locked/denied) or is EMPTY must NEVER become a hashable value. Two failed reads
# would otherwise both hash sha256("") and compare EQUAL — a false "keychain unchanged"
# PASS. Only a proven-'present' baseline may anchor the isolation check.
_b0, _raw0, _st0 = seedflow._sh_keychain_read()
if _st0 != "present":
    print(f"G8 FAIL: baseline keychain read not 'present' (status {_st0}) — cannot establish an isolation baseline")
    sys.exit(1)
kc_fp0 = hashlib.sha256((_raw0 or "").encode()).hexdigest()

# (r2 finding 37) the archiver DAEMON (tier-2) must independently capture a predecessor
# — a tier-1 backdate archiving its own predecessor cannot stand in for that evidence.
# Run archiverd for the duration and require a daemon "-observed" archive at the end.
_archd = subprocess.Popen([sys.executable, os.path.join(S, "archiverd.py")],
                          env=dict(os.environ, ACCOUNT_BANK_DIR=acc),
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1.0)
import hashlib as _h
arch_dir = os.path.join(home, "archive")
def _observed_hashes():
    out = set()
    if os.path.isdir(arch_dir):
        for e in os.listdir(arch_dir):
            if e.endswith("-observed.json"):
                try: out.add(_h.sha256(open(os.path.join(arch_dir, e), "rb").read()).hexdigest())
                except Exception: pass
    return out
# (r3 MAJOR4) BASELINE the daemon's pre-trial -observed set. The tier-2 evidence must be
# a NEW -observed entry produced DURING the trials, hash-distinct from this baseline —
# the daemon's initial scan of the current credential cannot satisfy the requirement.
baseline_observed = _observed_hashes()

def _seat_oauth():
    # (seat) the home's live credential from its SEAT — file OR migrated per-config-dir slot.
    _b, _r, _st, _k = seedflow.seat_read(home)
    return (_b or {}).get("claudeAiOauth", {}) if _st == "present" else {}

def fp():
    return bank_common.cred_fingerprint(_seat_oauth())

def backdate():
    # (finding 37 / seat) backdate through the SEAT writer (never a raw replace): pre-archive +
    # identity gate + the correct seat (slot when migrated, file otherwise) all run, so the
    # harness exercises the real write path and never leaves an un-archived predecessor.
    o = _seat_oauth()
    o["expiresAt"] = int(time.time()*1000) - 60000
    seedflow.seat_write(home, o, "g8-backdate", expected_email=email)

def turn(tag, pre_fp_box, idx):
    # (r3 MAJOR4) EVIDENCE OVERLAP recorded by the CLI PROCESS ITSELF: a wrapper reads the
    # credential fingerprint THIS process sees, writes it to a per-process file, then
    # exec's claude. So the overlap proof is the concurrent processes' OWN observations,
    # not a harness thread's read.
    procfp = os.path.join(acc, f".g8-procfp-{tag}")
    try: os.remove(procfp)
    except OSError: pass
    # (r12 sweep-c) G8 trials run real Claude turns — strip alt-auth env so an inherited
    # ANTHROPIC_API_KEY / Bedrock/Vertex var can't bill/route them through a different
    # identity and invalidate the isolation evidence. OAuth-only env (CLAUDE_CONFIG_DIR=home).
    env = isolated_refresh._oauth_only_env(home)
    # (seat) the CLI process records the fingerprint IT sees from the home's SEAT (file OR the
    # migrated per-config-dir slot) — argv[1] is now the HOME dir, read via seedflow.seat_read.
    wrapper = (
        "import json,sys,os;"
        "sys.path.insert(0, sys.argv[3]);"
        "import bank_common, seedflow;"
        "_b,_r,_st,_k = seedflow.seat_read(sys.argv[1]);"
        "open(sys.argv[2],'w').write("
        "bank_common.cred_fingerprint((_b or {}).get('claudeAiOauth',{})));"
        "os.execv(sys.argv[4], [sys.argv[4],'-p','reply with just: ok','--model','haiku'])"
    )
    p = subprocess.run([sys.executable, "-c", wrapper, home, procfp, S, cbin],
                       env=env, capture_output=True, text=True, timeout=180)
    try: pre_fp_box[idx] = open(procfp).read().strip()
    except Exception: pre_fp_box[idx] = None
    return {"tag":tag,"rc":p.returncode,"err":(p.stderr or "")[-160:]}

fails = []
# (r4 blocker 5) collect the PREDECESSOR fingerprints observed during the trials. The
# tier-2 evidence at the end must be a daemon -observed archive whose credential
# fingerprint IS one of these predecessors — not merely any new hash (a post-refresh
# FINAL credential would also be new, but it is not a predecessor).
pred_fps = set()
# (r2 finding 37) the trial floor is 20 — a caller cannot weaken the gate by setting
# G8_TRIALS below the contract; only MORE trials are honored.
trials = max(20, int(os.environ.get("G8_TRIALS","20")))
# (r13 #8) hold the PER-HOME lock across every backdate read-modify-write. Backdating a home
# credential without it races homerec / any tier-1 writer that holds the same home lock — G8
# could read an old credential and overwrite a newer commit with stale data, violating the
# single per-home lock ABI. Held for all trials + the final KC compare; released at process exit.
import banklock as _bl, atexit
_hlk = _bl.BankLock(home)
if not _hlk.acquire(timeout=15):
    print("G8 FAIL: could not acquire the per-home lock (another tooling writer holds it); "
          "cannot run trials without racing home writes")
    sys.exit(1)
atexit.register(lambda: _hlk.release())
for t in range(trials):
    backdate()
    pre = fp()
    pred_fps.add(pre)
    results = [None,None]; pre_fps = [None,None]
    def run(i): results[i] = turn(f"t{t}p{i}", pre_fps, i)
    th = [threading.Thread(target=run,args=(i,)) for i in (0,1)]
    for x in th: x.start()
    for x in th: x.join()
    # both processes must have observed the SAME predecessor fingerprint before either
    # committed (evidenced overlap, not launch timing).
    if not (pre_fps[0] == pre_fps[1] == pre):
        fails.append(f"trial {t}: processes did not observe the same predecessor fp "
                     f"({pre_fps[0]} / {pre_fps[1]} / expected {pre})"); break
    # (r2 finding 37) BOTH concurrent processes must SUCCEED — a silent failure of one
    # while the other rides the fresh token cannot pass G8.
    if results[0]["rc"] != 0 or results[1]["rc"] != 0:
        fails.append(f"trial {t}: a concurrent process failed: {results}"); break
    o = _seat_oauth()   # (seat) final blob from the home's seat, file or slot
    owned, r = identity.verify_owner(o.get("accessToken",""), email)
    if owned is not True:
        fails.append(f"trial {t}: final blob not owned/RESOLVED ({r.verdict})"); break
    if not bank_common.valid_oauth(o):
        fails.append(f"trial {t}: final seat credential not schema-valid"); break
    # third turn FORCES another refresh (r5: catch a spent refresh token)
    backdate()
    third = turn(f"t{t}third", [None,None], 0)
    if third["rc"] != 0:
        fails.append(f"trial {t}: forced third-refresh turn failed: {third}"); break
    print(f"trial {t}: outcomes {[x['rc'] for x in results]} third_rc {third['rc']} "
          f"overlap_fp {pre[:12]}")
# (r9 #4) final sample, same fail-closed discipline: a non-'present' read is itself a
# gate FAIL (we cannot prove the slot stayed unchanged), never a silent equal-hash pass.
_b1, _raw1, _st1 = seedflow._sh_keychain_read()
if _st1 != "present":
    fails.append(f"final keychain read not 'present' (status {_st1}) — cannot prove the keychain stayed unchanged")
elif hashlib.sha256((_raw1 or "").encode()).hexdigest() != kc_fp0:
    fails.append("KEYCHAIN CHANGED during G8 — isolation violated")
# (r4 blocker 5) the DAEMON must have captured an actual PREDECESSOR during the trials.
# Require a tier-2 "-observed" archive entry that is (a) NEW vs the pre-trial baseline AND
# (b) whose credential fingerprint IS one of the predecessor fingerprints the trial
# processes observed — NOT merely any new hash (a post-refresh FINAL credential is also
# new but is not a predecessor).
time.sleep(2.0)
_archd.terminate()
try: _archd.wait(timeout=5)
except Exception: _archd.kill()
def _observed_new_predecessor():
    if not os.path.isdir(arch_dir):
        return False
    for e in os.listdir(arch_dir):
        if not e.endswith("-observed.json"):
            continue
        try:
            raw = open(os.path.join(arch_dir, e), "rb").read()
            hh = _h.sha256(raw).hexdigest()
            if hh in baseline_observed:
                continue                       # pre-trial baseline, not evidence
            o = json.loads(raw).get("claudeAiOauth", {})
            if bank_common.cred_fingerprint(o) in pred_fps:
                return True                    # a daemon-observed genuine predecessor
        except Exception:
            continue
    return False
if not _observed_new_predecessor():
    fails.append("tier-2 archiver captured NO NEW PREDECESSOR during the trials "
                 "(no -observed entry that is baseline-distinct AND matches a recorded "
                 "predecessor fingerprint)")
print("G8", "PASS" if not fails else f"FAIL: {fails}")
sys.exit(0 if not fails else 1)
PY
