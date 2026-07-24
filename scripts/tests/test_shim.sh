#!/bin/bash
# Tests for the launch shim + claude-acct (rev 6 §3): rule precedence, fail-closed
# pairing, READY gating, exit codes, self-exclusion. Uses a STUB real binary and an
# isolated accounts dir — never touches the live CLI, keychain, or real homes.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAILS=0
ok() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $2"; else FAILS=$((FAILS+1)); echo "  FAIL $2"; fi; }

T="$(mktemp -d)"
ACC="$T/accounts"
mkdir -p "$ACC/bin" "$ACC/homes/a-at-x.com" "$T/realbin" "$T/scripts"
for f in registry.py epoch.py repoint.py banklock.py sessions.py _authenv.sh; do cp "$HERE/$f" "$T/scripts/"; done

# stub "real" claude: proves exec reached it + echoes its view of the env
cat > "$T/realbin/claude" <<'EOF'
#!/bin/bash
echo "REAL-CLI cfg=${CLAUDE_CONFIG_DIR:-<unset>} marker=${CLAUDE_ACCT_SHIM:-<unset>} args=$* apikey=${ANTHROPIC_API_KEY:-<unset>}"
EOF
chmod +x "$T/realbin/claude"

# install the shim into the isolated accounts dir (as cutover would)
cp "$HERE/bin/claude" "$ACC/bin/claude"; chmod +x "$ACC/bin/claude"
printf '{"REAL_CLAUDE_BIN": "%s"}\n' "$T/realbin/claude" > "$ACC/.config.json"

# registry: a@x.com READY; EPOCH: v2 (so rule-4 is live)
# (release-eve) import the modules UNDER TEST from $HERE (this checkout), never from the
# author's live ~/.claude/scripts/account-bank: that path does not exist on a contributor's
# machine, so the whole suite failed there — and where it DID exist it silently tested the
# INSTALLED copy instead of the tree being changed. Quoted heredoc, so the path comes in
# through argv rather than expansion.
python3 - "$ACC" "$HERE" <<'EOF'
import sys, os
sys.path.insert(0, sys.argv[2])
import registry, epoch
acc = sys.argv[1]
registry.publish_ready(acc, "a@x.com", os.path.join(acc, "homes", "a-at-x.com"), "uuid-a")
epoch.write_epoch(acc, "v2", 1)
EOF

SHIM="$ACC/bin/claude"
# (r8 #6) the shim PINS the CANONICAL real-home path (realpath), not the value it was
# handed — on macOS $ACC under /var/... canonicalizes to /private/var/..., and a rail
# symlink must resolve to its real target. Compare against the canonical home.
CHOME="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$ACC/homes/a-at-x.com")"
run() { env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$@"; }

# rule 1: marker without config dir -> 66
out="$(run CLAUDE_ACCT_SHIM=1 "$SHIM" 2>&1)"; rc=$?
[ $rc -eq 66 ] && ok 0 "marker without CLAUDE_CONFIG_DIR -> exit 66" || ok 1 "marker without CLAUDE_CONFIG_DIR -> exit 66 (got $rc)"

# rule 1: marker with non-home config -> 66
out="$(run CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR="$T" "$SHIM" 2>&1)"; rc=$?
[ $rc -eq 66 ] && ok 0 "marker with non-home config -> exit 66" || ok 1 "marker with non-home config -> exit 66 (got $rc)"

# rule 1: marker with unregistered home-shaped path -> 66
mkdir -p "$ACC/homes/ghost"
out="$(run CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR="$ACC/homes/ghost" "$SHIM" 2>&1)"; rc=$?
[ $rc -eq 66 ] && ok 0 "marker with non-READY home -> exit 66" || ok 1 "marker with non-READY home -> exit 66 (got $rc)"

# rule 1: marker with READY home -> exec real CLI with env intact (canonical cfg, r8 #6)
out="$(run CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" "$SHIM" hello 2>&1)"; rc=$?
echo "$out" | grep -q "REAL-CLI cfg=$CHOME marker=1 args=hello" \
    && ok 0 "marker + READY home -> exec real CLI (canonical cfg)" || ok 1 "marker + READY home -> exec real CLI (got: $out)"

# (r8 #6) LIVE-FLIP RAIL: a symlink under homes/ pointing at a READY home must be pinned
# to its CANONICAL real target — otherwise repointing the rail mid-session live-flips the
# running session's identity (the forbidden §0 rail). The real CLI must see the resolved
# home, never the rail symlink path.
ln -s "a-at-x.com" "$ACC/homes/rail"
out="$(run CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR="$ACC/homes/rail" "$SHIM" hi 2>&1)"; rc=$?
echo "$out" | grep -q "cfg=$CHOME marker=1 args=hi" \
    && ok 0 "rail symlink pinned to CANONICAL real home, not the symlink (r8 #6)" || ok 1 "rail symlink pinned to canonical home (got: $out)"
echo "$out" | grep -q "cfg=$ACC/homes/rail" && ok 1 "rail symlink path must never be CLAUDE_CONFIG_DIR (r8 #6)" || ok 0 "rail symlink path is never the pinned CLAUDE_CONFIG_DIR (r8 #6)"
rm -f "$ACC/homes/rail"

# rule 2: no marker, READY home config -> exec with marker set
out="$(run CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" "$SHIM" 2>&1)"; rc=$?
echo "$out" | grep -q "marker=1" && ok 0 "pinned READY home -> exec, marker set" || ok 1 "pinned READY home -> exec, marker set (got: $out)"

# rule 2: no marker, non-READY home -> 65
out="$(run CLAUDE_CONFIG_DIR="$ACC/homes/ghost" "$SHIM" 2>&1)"; rc=$?
[ $rc -eq 65 ] && ok 0 "pinned non-READY home -> exit 65" || ok 1 "pinned non-READY home -> exit 65 (got $rc)"

# rule 3: user's own config dir -> transparent passthrough, no marker
out="$(run CLAUDE_CONFIG_DIR="$T/mycfg" "$SHIM" 2>&1)"
echo "$out" | grep -q "cfg=$T/mycfg marker=<unset>" && ok 0 "foreign config dir -> untouched passthrough" || ok 1 "foreign config dir -> untouched passthrough (got: $out)"

# (r12 sweep-c) a MANAGED launch (rule 1: marker + READY home) STRIPS alternate-auth env so
# an inherited ANTHROPIC_API_KEY can't override the home's OAuth identity.
out="$(run CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" ANTHROPIC_API_KEY=SECRET "$SHIM" 2>&1)"
echo "$out" | grep -q "apikey=<unset>" && ok 0 "managed launch STRIPS ANTHROPIC_API_KEY (r12 sweep-c)" || ok 1 "managed launch strips ANTHROPIC_API_KEY (got: $out)"
# rule 3 (user's own config) does NOT strip — respect the user's own environment
out="$(run CLAUDE_CONFIG_DIR="$T/mycfg" ANTHROPIC_API_KEY=SECRET "$SHIM" 2>&1)"
echo "$out" | grep -q "apikey=SECRET" && ok 0 "user-config passthrough keeps ANTHROPIC_API_KEY (not managed) (r12 sweep-c)" || ok 1 "user-config keeps api key (got: $out)"

# rule 4: default launch, no pointer -> 65
out="$(run "$SHIM" 2>&1)"; rc=$?
[ $rc -eq 65 ] && ok 0 "default launch without pointer -> exit 65" || ok 1 "default launch without pointer -> exit 65 (got $rc)"

# rule 4: default launch with READY pointer -> pinned exec of the REAL home path
python3 - "$ACC" "$HERE" <<'EOF'
import sys, os
sys.path.insert(0, sys.argv[2])
import repoint, registry
acc = sys.argv[1]
repoint.repoint(acc, os.path.join(acc, "homes", "a-at-x.com"), "test",
                registry_check=lambda h: registry.is_ready_home(acc, h))
EOF
out="$(run "$SHIM" 2>&1)"; rc=$?
echo "$out" | grep -q "cfg=.*homes/a-at-x.com marker=1" && ok 0 "default launch -> resolved REAL home (not the pointer path)" || ok 1 "default launch -> resolved REAL home (got: $out)"
echo "$out" | grep -q "cfg=$ACC/current" && ok 1 "pointer path must never be CLAUDE_CONFIG_DIR" || ok 0 "pointer path must never be CLAUDE_CONFIG_DIR"

# rule 4 pre-cutover: EPOCH=v1 -> transparent
python3 -c "
import sys, os
sys.path.insert(0, '$HERE')
import epoch; epoch.write_epoch('$ACC', 'v1', 2)"
out="$(run "$SHIM" 2>&1)"
echo "$out" | grep -q "cfg=<unset> marker=<unset>" && ok 0 "EPOCH v1 -> shim transparent" || ok 1 "EPOCH v1 -> shim transparent (got: $out)"

# self-exclusion: registry pointing at the shim itself must not recurse -> 67
printf '{"REAL_CLAUDE_BIN": "%s"}\n' "$ACC/bin/claude" > "$ACC/.config.json"
out="$(run CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" "$SHIM" 2>&1)"; rc=$?
[ $rc -eq 67 ] && ok 0 "shim-as-real-binary excluded -> exit 67 (no recursion)" || ok 1 "shim-as-real-binary excluded -> exit 67 (got $rc)"

# (finding 26) a HARD LINK to the shim OUTSIDE accounts/bin must also be excluded by
# dev/inode — a path-string check alone would accept it and recurse.
if ln "$ACC/bin/claude" "$T/hardlink-claude" 2>/dev/null; then
    printf '{"REAL_CLAUDE_BIN": "%s"}\n' "$T/hardlink-claude" > "$ACC/.config.json"
    out="$(run CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR="$ACC/homes/a-at-x.com" "$SHIM" 2>&1)"; rc=$?
    [ $rc -eq 67 ] && ok 0 "hard link to shim excluded by dev/inode -> exit 67 (finding 26)" || ok 1 "hard link to shim excluded -> exit 67 (got $rc)"
    rm -f "$T/hardlink-claude"
else
    ok 0 "hard-link test skipped (ln unsupported on this fs)"
fi
printf '{"REAL_CLAUDE_BIN": "%s"}\n' "$T/realbin/claude" > "$ACC/.config.json"

# claude-acct: unknown email -> 65; READY email -> pinned exec
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" nobody@x.com 2>&1)"; rc=$?
[ $rc -eq 65 ] && ok 0 "claude-acct unknown email -> exit 65" || ok 1 "claude-acct unknown email -> exit 65 (got $rc)"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" a@x.com hi 2>&1)"
echo "$out" | grep -q "cfg=$CHOME marker=1 args=hi" && ok 0 "claude-acct READY email -> pinned exec (canonical cfg)" || ok 1 "claude-acct READY email -> pinned exec (got: $out)"

# claude-acct --current maps pointer -> email
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" --current 2>&1)"
[ "$out" = "a@x.com" ] && ok 0 "claude-acct --current -> email" || ok 1 "claude-acct --current -> email (got: $out)"

# (r2 new MAJOR) claude-acct rejects a non-UUID --resume value before launching
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" a@x.com --resume "../../etc" 2>&1)"; rc=$?
[ $rc -eq 64 ] && ok 0 "claude-acct --resume rejects a non-UUID value -> exit 64" || ok 1 "claude-acct --resume non-UUID -> 64 (got $rc: $out)"
# a valid UUID --resume passes validation and reaches the real CLI
VUUID="11111111-2222-3333-4444-555555555555"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" a@x.com --resume "$VUUID" 2>&1)"
echo "$out" | grep -q "args=--resume $VUUID" && ok 0 "claude-acct --resume <uuid> passes to real CLI" || ok 1 "claude-acct --resume <uuid> passes (got: $out)"
# (r3 MINOR3) a TRAILING bare --resume (no value) is refused, never passed through
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" a@x.com --resume 2>&1)"; rc=$?
[ $rc -eq 64 ] && ok 0 "claude-acct trailing bare --resume -> exit 64 (r3 MINOR3)" || ok 1 "trailing bare --resume -> 64 (got $rc: $out)"

# (r10 #9 CRITICAL) --resume must REFUSE while the session's restart lease is held — the
# public launcher, not just restart_session(), enforces the §0/G10 duplicate-resume ban.
# Simulate a held lease with a fake lease dir (as restart.py's lease_acquire would create).
LSID="$VUUID"
mkdir -p "$ACC/sessions/$LSID.lease"
printf '{"pid":1,"proc_start":"x","token":"LEASE-TOK-123","txn":"t"}' > "$ACC/sessions/$LSID.lease/owner"
# UNAUTHORIZED duplicate (no token) -> refuse rc 75
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" a@x.com --resume "$LSID" 2>&1)"; rc=$?
[ $rc -eq 75 ] && ok 0 "claude-acct --resume (no token) REFUSED while lease held -> exit 75 (r10 #9)" || ok 1 "--resume with held lease -> 75 (got $rc: $out)"
echo "$out" | grep -q "restart-lease gate" && ok 0 "refusal names the restart-lease reason (r10 #9 / r14 #3)" || ok 1 "refusal reason surfaced (got: $out)"
# WRONG token -> still refused
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" ACCOUNT_BANK_RESUME_LEASE_TOKEN="WRONG" "$HERE/claude-acct" a@x.com --resume "$LSID" 2>&1)"; rc=$?
[ $rc -eq 75 ] && ok 0 "claude-acct --resume with WRONG lease token still refused -> 75 (r13 #1)" || ok 1 "--resume wrong token -> 75 (got $rc: $out)"
# (r13 #1) the AUTHORIZED controller resume (matching lease token) PROCEEDS to the real CLI
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" ACCOUNT_BANK_RESUME_LEASE_TOKEN="LEASE-TOK-123" "$HERE/claude-acct" a@x.com --resume "$LSID" 2>&1)"
echo "$out" | grep -q "args=--resume $LSID" && ok 0 "controller's OWN resume (matching lease token) PROCEEDS despite held lease (r13 #1)" || ok 1 "authorized resume proceeds (got: $out)"
# (r14 #3) lease-gate FAILS CLOSED when sessions.py errors: even WITH the right token, an
# unverifiable gate must REFUSE (rc 75), not fall open. Break sessions.py, keep the lease held.
mv "$T/scripts/sessions.py" "$T/scripts/sessions.py.bak"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" ACCOUNT_BANK_RESUME_LEASE_TOKEN="LEASE-TOK-123" "$HERE/claude-acct" a@x.com --resume "$LSID" 2>&1)"; rc=$?
[ $rc -eq 75 ] && ok 0 "lease-gate FAILS CLOSED (rc 75) when sessions.py errors, even with a token (r14 #3)" || ok 1 "lease-gate fail-closed on error (got $rc: $out)"
mv "$T/scripts/sessions.py.bak" "$T/scripts/sessions.py"
# once the lease is released, any resume proceeds
rm -rf "$ACC/sessions/$LSID.lease"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" a@x.com --resume "$LSID" 2>&1)"
echo "$out" | grep -q "args=--resume $LSID" && ok 0 "--resume proceeds once the lease is released (r10 #9)" || ok 1 "--resume proceeds after lease release (got: $out)"

# (r13 #9) the dedicated attest probe reports resolution via rc, unaffected by an inherited
# marker/config: rc 0 = real binary resolved, rc 67 = not. This is what attest-cutover checks.
out="$(run "$SHIM" --account-bank-attest-probe 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok 0 "attest probe -> rc 0 when the real binary resolves (r13 #9)" || ok 1 "attest probe rc 0 (got $rc)"
out="$(run CLAUDE_ACCT_SHIM=1 "$SHIM" --account-bank-attest-probe 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok 0 "attest probe -> rc 0 even with inherited CLAUDE_ACCT_SHIM=1 (no false 66) (r13 #9)" || ok 1 "attest probe ignores inherited marker (got $rc)"

# (r13 #13) a malformed EPOCH on the default (no marker/config) launch -> epoch fence rc 78, not 64.
printf 'not-json{' > "$ACC/EPOCH"
out="$(run "$SHIM" 2>&1)"; rc=$?
[ $rc -eq 78 ] && ok 0 "malformed EPOCH on default launch -> rc 78 (epoch fence), not 64 (r13 #13)" || ok 1 "malformed EPOCH -> 78 (got $rc: $out)"
python3 -c "import sys,os;sys.path.insert(0,'$HERE');import epoch;epoch.write_epoch('$ACC','v2',11)"

# (r9 #7) claude-acct --back is a pointer transaction (shadow|v2 only). After a rollback
# to v1 it must refuse with rc 78, never commit a new pointer transaction. A repoint was
# committed above (EPOCH v2); flip EPOCH to v1 and assert --back is fenced.
python3 -c "
import sys, os
sys.path.insert(0, '$HERE')
import epoch; epoch.write_epoch('$ACC', 'v1', 9)"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" --back 2>&1)"; rc=$?
[ $rc -eq 78 ] && ok 0 "claude-acct --back REFUSED under EPOCH v1 -> exit 78 (r9 #7)" || ok 1 "claude-acct --back under v1 -> 78 (got $rc: $out)"
# restore v2 so --back works again (proves it is the epoch, not a broken history)
python3 -c "
import sys, os
sys.path.insert(0, '$HERE')
import epoch; epoch.write_epoch('$ACC', 'v2', 10)"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" ACCOUNT_BANK_SCRIPTS_DIR="$T/scripts" "$HERE/claude-acct" --back 2>&1)"; rc=$?
[ $rc -ne 78 ] && ok 0 "claude-acct --back PERMITTED again under EPOCH v2 (r9 #7)" || ok 1 "claude-acct --back under v2 not fenced (got $rc: $out)"

# (r10 #4) with NO ACCOUNT_BANK_SCRIPTS_DIR override, claude-acct resolves its scripts dir
# from ITS OWN location (not a hard-coded dev default). Stage it in a fresh dir with its py
# deps and run --current with the env override UNSET — it must find its siblings and work.
SELFDIR="$T/installed-here"
mkdir -p "$SELFDIR"
cp "$HERE/claude-acct" "$SELFDIR/"
for f in registry.py repoint.py banklock.py epoch.py sessions.py; do cp "$HERE/$f" "$SELFDIR/"; done
# add-account.sh presence not required for --current; registry.py (the primary dep) is.
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" "$SELFDIR/claude-acct" --current 2>&1)"; rc=$?
[ "$out" = "a@x.com" ] && ok 0 "claude-acct resolves scripts from its OWN dir (no env override) (r10 #4)" || ok 1 "claude-acct self-dir resolution (got rc $rc: $out)"

# (r11 #2) claude-acct --add must export the resolved scripts dir so add-account.sh's
# bank_common import works on a clean XDG install. Stage both siblings (add-account.sh +
# bank_common.py — stdlib-only) in a fresh dir; run add-account.sh directly with the env
# UNSET. It must self-resolve bank_common (get PAST the import) and reach the quiesce prompt
# (exit 1 on EOF), NOT fail 64 on a missing bank_common. Distinguishes import-fail (64) from
# self-resolve-works (1).
ADDDIR="$T/xdg-install"
mkdir -p "$ADDDIR"
cp "$HERE/add-account.sh" "$HERE/bank_common.py" "$ADDDIR/"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$ACC" bash "$ADDDIR/add-account.sh" valid@x.com </dev/null 2>&1)"; rc=$?
[ "$rc" != "64" ] && ok 0 "add-account.sh self-resolves bank_common from its own dir (no env, got past import) (r11 #2)" || ok 1 "add-account.sh self-resolve (exit 64 = import failed; got: $out)"
# and claude-acct --add exports ACCOUNT_BANK_SCRIPTS_DIR to the child
grep -q 'export ACCOUNT_BANK_SCRIPTS_DIR="\$SCRIPTS_DIR"' "$HERE/claude-acct" && ok 0 "claude-acct --add exports the resolved scripts dir (r11 #2)" || ok 1 "claude-acct --add exports scripts dir (r11 #2)"
# (r12 sweep-a) add-account.sh EXPORTS its resolved scripts dir so its child python heredocs
# inherit it (they fall back to the legacy path otherwise).
grep -q 'export ACCOUNT_BANK_SCRIPTS_DIR="\$SCRIPTS"' "$HERE/add-account.sh" && ok 0 "add-account.sh exports its resolved scripts dir to children (r12 sweep-a)" || ok 1 "add-account.sh exports scripts dir (r12 sweep-a)"

# (v2 wiring) claude-acct --switch = QuotaBar Switch's forward-repoint. Isolated bank so it
# never perturbs the shared harness epoch/pointer above.
SW="$(mktemp -d)/accounts"; mkdir -p "$SW/homes/s"
python3 -c "import sys; sys.path.insert(0,'$HERE'); import registry, epoch; registry.publish_ready('$SW','s@x.com','$SW/homes/s','uuid-s'); epoch.write_epoch('$SW','shadow',1)"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$SW" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" "$HERE/claude-acct" --switch s@x.com 2>&1)"; rc=$?
ptr="$(readlink "$SW/current" 2>/dev/null)"
{ [ $rc -eq 0 ] && [ "$ptr" = "$SW/homes/s" ]; } && ok 0 "claude-acct --switch repoints current -> READY home under shadow" || ok 1 "claude-acct --switch (rc $rc ptr $ptr: $out)"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$SW" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" "$HERE/claude-acct" --switch nobody@x.com 2>&1)"; rc=$?
[ $rc -eq 65 ] && ok 0 "claude-acct --switch unknown email -> exit 65" || ok 1 "claude-acct --switch unknown -> 65 (got $rc: $out)"
python3 -c "import sys; sys.path.insert(0,'$HERE'); import epoch; epoch.write_epoch('$SW','v1',2)"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$SW" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" "$HERE/claude-acct" --switch s@x.com 2>&1)"; rc=$?
[ $rc -eq 78 ] && ok 0 "claude-acct --switch fenced under v1 epoch -> exit 78" || ok 1 "claude-acct --switch v1 -> 78 (got $rc: $out)"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$SW" ACCOUNT_BANK_SCRIPTS_DIR="$HERE" "$HERE/claude-acct" --switch 2>&1)"; rc=$?
[ $rc -eq 64 ] && ok 0 "claude-acct --switch with no email -> exit 64" || ok 1 "claude-acct --switch no arg -> 64 (got $rc: $out)"
rm -rf "$(dirname "$SW")"

rm -rf "$T"
echo "-- shim: $PASS passed, $FAILS failed"
[ $FAILS -eq 0 ]
