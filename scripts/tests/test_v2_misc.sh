#!/bin/bash
# (r13 #11 + #12) small v2 fixes: unified BANK_DIR resolution (swiftbar-render vs lib.sh) and
# list-accounts skipping v2 control-plane JSON. Hermetic: temp bank, no real accounts.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB="$(cd "$HERE/.." && pwd)"
PASS=0; FAILS=0
ok() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $2"; else FAILS=$((FAILS+1)); echo "  FAIL $2"; fi; }

# --- (r13 #11 / r15 #4) ONE bank-dir resolution rule everywhere ---
# BANK_DIR -> ACCOUNT_BANK_DIR -> ~/.claude/accounts, and never the XDG data dir. This was
# four separate copies of the order; usage.py and reconcile.py carried a SHORTER one that
# ignored ACCOUNT_BANK_DIR entirely, so a user setting only the documented variable had the
# shell mutators on their custom bank while the poller and reconciler used the default one.
# All of them now call bank_common.resolve_bank_dir, so assert BEHAVIOUR, not source text.
_res() {  # <BANK_DIR> <ACCOUNT_BANK_DIR> -> what the shared resolver returns
  env -i HOME="${HOME}" PATH="/usr/bin:/bin" BANK_DIR="$1" ACCOUNT_BANK_DIR="$2" \
    python3 -c 'import sys; sys.path.insert(0, sys.argv[1])
import bank_common; print(bank_common.resolve_bank_dir())' "$AB"
}
_modres() {  # <module> <BANK_DIR> <ACCOUNT_BANK_DIR> -> that module''s resolved BANK_DIR
  env -i HOME="${HOME}" PATH="/usr/bin:/bin" BANK_DIR="$2" ACCOUNT_BANK_DIR="$3" \
    python3 -c 'import sys, importlib; sys.path.insert(0, sys.argv[1])
print(importlib.import_module(sys.argv[2]).BANK_DIR)' "$AB" "$1"
}
[ "$(_res /tmp/explicit /tmp/convention)" = "/tmp/explicit" ] \
  && ok 0 "BANK_DIR outranks ACCOUNT_BANK_DIR (r15 #4)" || ok 1 "BANK_DIR outranks ACCOUNT_BANK_DIR (r15 #4)"
[ "$(_res '' /tmp/convention)" = "/tmp/convention" ] \
  && ok 0 "ACCOUNT_BANK_DIR is honoured when BANK_DIR is unset (r15 #4)" || ok 1 "ACCOUNT_BANK_DIR honoured (r15 #4)"
[ "$(_res '' '')" = "$HOME/.claude/accounts" ] \
  && ok 0 "neither set -> ~/.claude/accounts, never the XDG dir (r13 #11)" || ok 1 "default is ~/.claude/accounts (r13 #11)"
for _m in usage reconcile; do
  [ "$(_modres "$_m" '' /tmp/convention)" = "/tmp/convention" ] \
    && ok 0 "$_m.py honours ACCOUNT_BANK_DIR (r15 #4 — it used to ignore it)" \
    || ok 1 "$_m.py honours ACCOUNT_BANK_DIR (r15 #4), got $(_modres "$_m" '' /tmp/convention)"
  [ "$(_modres "$_m" /tmp/explicit /tmp/convention)" = "/tmp/explicit" ] \
    && ok 0 "$_m.py gives BANK_DIR precedence (r15 #4)" || ok 1 "$_m.py BANK_DIR precedence (r15 #4)"
done
# lib.sh is the shell half of the same rule; it must agree with the Python resolver.
_libres="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR=/tmp/convention \
  bash -c '. "$0/lib.sh" >/dev/null 2>&1; printf "%s" "$BANK_DIR"' "$AB")"
[ "$_libres" = "/tmp/convention" ] \
  && ok 0 "lib.sh resolves to the SAME dir as bank_common (r13 #11 / r15 #4)" \
  || ok 1 "lib.sh agrees with bank_common (got: $_libres)"
grep -q 'XDG_DATA' "$AB/swiftbar-render.py" && ok 1 "swiftbar must NOT default to the XDG dir" || ok 0 "swiftbar no longer reads the XDG dir (r13 #11)"
# functional: swiftbar reads the config under ACCOUNT_BANK_DIR (not XDG). Point ACCOUNT_BANK_DIR
# at a fixture with auto_ping ON for a@x.com; feed a doc with a@x.com; the toggle must reflect it.
T="$(mktemp -d)"; FIX="$T/accounts"; mkdir -p "$FIX"
printf '{"auto_ping":["a@x.com"]}' > "$FIX/.config.json"
DOC='{"active_email":"a@x.com","accounts":[{"provider":"claude","email":"a@x.com","active":true,"worst_limit":{"percent":10,"kind":"5h","resets_at":null},"status":"ok"}]}'
out="$(printf '%s' "$DOC" | env -i HOME="$T" PATH="/usr/bin:/bin" ACCOUNT_BANK_DIR="$FIX" python3 "$AB/swiftbar-render.py" 2>&1)"
# auto_ping ON for a@x.com -> the dropdown offers to DISABLE it (proof it read $FIX/.config.json)
echo "$out" | grep -qi "auto-ping: on" && ok 0 "swiftbar reads .config.json under ACCOUNT_BANK_DIR (auto-ping shown ON) (r13 #11)" || ok 1 "swiftbar read the ACCOUNT_BANK_DIR config (got: $(echo "$out" | tr '\n' '|' | head -c 300))"

# --- (r13 #12) list-accounts skips v2 control-plane JSON ---
LB="$T/lb-accounts"; mkdir -p "$LB"
cat > "$LB/real@x.com.json" <<J
{"email":"real@x.com","status":"ok","banked_at":"2026-01-01T00:00:00Z","banked_at_epoch":1,
 "claudeAiOauth":{"accessToken":"R","refreshToken":"rR","expiresAt":9999999999999,"subscriptionType":"max"},
 "oauthAccount":{"emailAddress":"real@x.com","organizationType":"claude_max"}}
J
printf '{"real@x.com":{"home":"/h","ready":true}}' > "$LB/registry.json"
printf '{}' > "$LB/sessions.json"
printf '{"ts":1}' > "$LB/archiver.status.json"
out="$(env -i HOME="$T" PATH="/usr/bin:/bin" BANK_DIR="$LB" ACCOUNT_BANK_DIR="$LB" bash "$AB/list-accounts.sh" 2>&1)"
echo "$out" | grep -q "real@x.com" && ok 0 "list-accounts shows the real account (r13 #12)" || ok 1 "list-accounts shows real account (got: $out)"
echo "$out" | grep -qE "registry|sessions|archiver.status" && ok 1 "list-accounts must NOT render control-plane files" || ok 0 "list-accounts does NOT render control-plane JSON as accounts (r13 #12)"

# --- (r14 #1) add-account.sh RE-VERIFIES the credential AFTER the verification turn ---
grep -q "post-turn identity changed" "$AB/add-account.sh" && ok 0 "add-account re-verifies credential after the turn (r14 #1)" || ok 1 "add-account post-turn re-verify (r14 #1)"
grep -q "r2.uuid != r.uuid" "$AB/add-account.sh" && ok 0 "add-account requires the SAME uuid post-turn before publish (r14 #1)" || ok 1 "add-account uuid re-check (r14 #1)"

# --- (r14 #2) the credential path invokes /usr/bin/security absolutely, never bare `security` ---
grep -q '/usr/bin/security' "$AB/seedflow.py" && ok 0 "seedflow uses absolute /usr/bin/security (r14 #2)" || ok 1 "seedflow absolute security (r14 #2)"
grep -q '/usr/bin/security' "$AB/add-account.sh" && ok 0 "add-account uses absolute /usr/bin/security (r14 #2)" || ok 1 "add-account absolute security (r14 #2)"
# no BARE ["security",...] / ["security","-i"] left on the credential path
grep -qE '\["security"' "$AB/seedflow.py" "$AB/add-account.sh" && ok 1 "a bare security[] invocation survives" || ok 0 "no bare security[] invocation on the credential path (r14 #2)"
# resolvers no longer fall back to PATH for a credential-bearing tool
grep -q 'shutil.which("security")' "$AB/reconcile.py" "$AB/usage.py" && ok 1 "a PATH security fallback survives" || ok 0 "reconcile/usage drop the PATH security fallback (r14 #2)"

# --- (release-eve) list_bank_emails keeps EMAIL-shaped basenames, structurally ---
# The old hand-enumerated skip list mirrored bank_common.V2_CONTROL_JSON and drifted the
# moment that set grew: a NEW control file would render as a phantom account. A bank record
# is named after its account, so '@' in the basename is the invariant. Includes control-plane
# names that do NOT exist yet (the drift case the old list could never cover).
LE="$T/le-accounts"; mkdir -p "$LE"
for _e in real@x.com "second.user+tag@y.co.uk"; do printf '{}' > "$LE/$_e.json"; done
for _c in registry sessions archiver.status attestation quotabar.runtime \
          future.control epoch.state some-new-v3-thing .config; do printf '{}' > "$LE/$_c.json"; done
_LE_OUT="$(env BANK_DIR="$LE" ACCOUNT_BANK_DIR="$LE" /bin/bash -c 'source "$1/lib.sh"; list_bank_emails' _ "$AB" 2>&1)"
printf '%s\n' "$_LE_OUT" | grep -qx 'real@x.com' && ok 0 "list_bank_emails lists a real account (release-eve)" || ok 1 "list_bank_emails lists real@x.com (got: $_LE_OUT)"
printf '%s\n' "$_LE_OUT" | grep -qx 'second.user+tag@y.co.uk' && ok 0 "list_bank_emails lists a plus-addressed account (release-eve)" || ok 1 "list_bank_emails lists the +tag account (got: $_LE_OUT)"
printf '%s\n' "$_LE_OUT" | grep -qE 'registry|sessions|archiver.status|attestation|quotabar.runtime' && ok 1 "list_bank_emails must skip every known control-plane file" || ok 0 "list_bank_emails skips the known control-plane JSON (release-eve)"
printf '%s\n' "$_LE_OUT" | grep -qE 'future.control|epoch.state|some-new-v3-thing|^.config$' && ok 1 "list_bank_emails must skip FUTURE (unenumerated) non-email JSON" || ok 0 "list_bank_emails skips future non-email JSON — cannot drift (release-eve)"
[ "$(printf '%s\n' "$_LE_OUT" | grep -c '@')" = "2" ] && ok 0 "list_bank_emails returns exactly the two email records (release-eve)" || ok 1 "list_bank_emails returns only the email records (got: $_LE_OUT)"

rm -rf "$T"
echo "-- v2_misc: $PASS passed, $FAILS failed"
[ $FAILS -eq 0 ]
