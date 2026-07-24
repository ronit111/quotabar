#!/bin/bash
# testlib.sh — shared helpers + isolated environment for account-bank tests.
#
# SAFETY: every test runs against a TEMP BANK_DIR / CLAUDE_JSON / stub keychain
# and a stub `claude`/`security` under KEYCHAIN_ACCOUNT=tester. Nothing here ever
# touches the real login keychain, the real ~/.claude/accounts, or the live
# active account. `new_env` wipes and recreates the sandbox for each test.

AB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$(cd "$(dirname "${BASH_SOURCE[0]}")/stubs" && pwd)"

_T_PASS=0
_T_FAIL=0

pass() { _T_PASS=$((_T_PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { _T_FAIL=$((_T_FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() { # <expected> <actual> <name>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected [$1] got [$2])"; fi
}
assert_ne() { # <not-expected> <actual> <name>
  if [ "$1" != "$2" ]; then pass "$3"; else fail "$3 (got forbidden value [$2])"; fi
}
assert_file_absent() { if [ ! -e "$1" ]; then pass "$2"; else fail "$2 ($1 exists)"; fi; }
assert_file_present() { if [ -e "$1" ]; then pass "$2"; else fail "$2 ($1 missing)"; fi; }
assert_contains() { case "$2" in *"$1"*) pass "$3";; *) fail "$3 ([$2] lacks [$1])";; esac; }

# summarize; return nonzero if any failed
finish() {
  printf '  -- %s: %d passed, %d failed\n' "${1:-suite}" "$_T_PASS" "$_T_FAIL"
  [ "$_T_FAIL" -eq 0 ]
}

FUT=$(( ($(date +%s) + 36000) * 1000 ))     # a far-future expiry (ms)
PAST=$(( ($(date +%s) - 3600) * 1000 ))     # an expired timestamp (ms)

# new_env <name> — fresh sandbox. Exports BANK_DIR, CLAUDE_JSON, stub bins.
#
# FAIL HARD (r3 #19): every fixture-setup step is checked, and ANY failure aborts
# the whole test process (a diagnostic to stderr + `exit 1`). The old version
# ignored rm/mkdir/chmod failures and returned success because its final `echo`
# succeeded — so a suite whose sandbox never got created could still "pass" every
# rejection/absence assertion vacuously (a missing BANK_DIR trivially satisfies
# assert_file_absent, and a stub that can't be reached reads as "credential
# rejected"). new_env is always called in the test's own shell (never in a
# command substitution — verified by grep), so `exit 1` here terminates the test
# and run_tests.sh counts it as a failed file.
_new_env_die() { printf '  FATAL new_env: %s\n' "$1" >&2; exit 1; }
new_env() {
  local base="${TMPDIR:-/tmp}/acctbank-tests/$$-${1:-env}-$RANDOM"
  rm -rf "$base"           || _new_env_die "rm -rf $base failed"
  mkdir -p "$base"         || _new_env_die "mkdir -p $base failed"
  [ -d "$base" ]           || _new_env_die "$base not a directory after mkdir"
  export BANK_DIR="$base/bank"
  mkdir -p "$BANK_DIR"     || _new_env_die "mkdir -p BANK_DIR ($BANK_DIR) failed"
  [ -d "$BANK_DIR" ]       || _new_env_die "BANK_DIR ($BANK_DIR) missing after mkdir"
  chmod 700 "$BANK_DIR"    || _new_env_die "chmod 700 BANK_DIR failed"
  export CLAUDE_JSON="$base/claude.json"
  export STUB_KC_FILE="$base/kc.json"
  export ACCOUNT_BANK_SECURITY_BIN="$STUBS/security"
  export ACCOUNT_BANK_CLAUDE_BIN="$STUBS/claude"
  # the stubs MUST exist and be executable, or "credential rejected"/"binary
  # unresolved" outcomes could be produced by a missing stub, not by the code.
  [ -x "$ACCOUNT_BANK_SECURITY_BIN" ] || _new_env_die "security stub not executable ($ACCOUNT_BANK_SECURITY_BIN)"
  [ -x "$ACCOUNT_BANK_CLAUDE_BIN" ]   || _new_env_die "claude stub not executable ($ACCOUNT_BANK_CLAUDE_BIN)"
  export KEYCHAIN_ACCOUNT="tester"
  export STUB_KC_MODE="normal"
  unset STUB_CLAUDE_MODE
  echo "$base"
}

# (r4 #9) fixture helpers FAIL HARD. A fixture write that silently fails leaves the
# sandbox in a state where a REJECTION test passes vacuously — e.g. set_active whose
# keychain write failed but whose metadata write succeeded would let a "wrong
# credential rejected" assertion pass because the credential is simply missing, not
# because the code rejected it. Every write is checked and any failure aborts the
# whole test process (diagnostic + exit 1), exactly like new_env.
_fixture_die() { printf '  FATAL fixture: %s\n' "$1" >&2; exit 1; }

# W <file> — write STDIN to <file>, FAIL HARD on any write failure. (r4 #9) Direct
# `printf ... > "$FILE"` fixture writes in test files swallow a failed redirect, so
# a rejection/absence assertion could pass because the fixture never landed rather
# than because the code rejected it. Route fixture-state writes through W so a
# failed write aborts the whole test process instead of passing vacuously. (Content
# may be deliberately malformed — that is the test's subject; W only asserts the
# bytes were written, not that they are valid.)
W() { local f="${1:?W: missing target}"; cat > "$f" || _fixture_die "fixture write to $f failed"; }

# set_active <email> <accessToken> [refresh] [expiry] [subtype] [orgtype]
# writes the stub keychain blob AND ~/.claude.json oauthAccount.
set_active() {
  local email="$1" at="$2" rt="${3:-r-$2}" exp="${4:-$FUT}" sub="${5:-max}" org="${6:-claude_max}"
  [ -n "${STUB_KC_FILE:-}" ] || _fixture_die "set_active: STUB_KC_FILE unset (new_env not run?)"
  [ -n "${CLAUDE_JSON:-}" ]  || _fixture_die "set_active: CLAUDE_JSON unset (new_env not run?)"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":%s,"subscriptionType":"%s"}}' \
    "$at" "$rt" "$exp" "$sub" > "$STUB_KC_FILE" || _fixture_die "set_active: keychain write to $STUB_KC_FILE failed"
  [ -s "$STUB_KC_FILE" ] || _fixture_die "set_active: keychain file $STUB_KC_FILE empty after write"
  printf '{"oauthAccount":{"emailAddress":"%s","organizationType":"%s"}}' "$email" "$org" > "$CLAUDE_JSON" \
    || _fixture_die "set_active: metadata write to $CLAUDE_JSON failed"
  [ -s "$CLAUDE_JSON" ] || _fixture_die "set_active: metadata file $CLAUDE_JSON empty after write"
}

# bank_record <email> <accessToken> [refresh] [expiry] [subtype] [orgtype] [status]
bank_record() {
  local email="$1" at="$2" rt="${3:-r-$2}" exp="${4:-$FUT}" sub="${5:-pro}" org="${6:-claude_pro}" st="${7:-ok}"
  [ -n "${BANK_DIR:-}" ] && [ -d "$BANK_DIR" ] || _fixture_die "bank_record: BANK_DIR unset/missing (new_env not run?)"
  cat > "$BANK_DIR/$email.json" <<J || _fixture_die "bank_record: write to $BANK_DIR/$email.json failed"
{"email":"$email","status":"$st","banked_at":"2026-07-19T00:00:00Z","banked_at_epoch":1,
 "claudeAiOauth":{"accessToken":"$at","refreshToken":"$rt","expiresAt":$exp,"subscriptionType":"$sub"},
 "oauthAccount":{"emailAddress":"$email","organizationType":"$org"}}
J
  [ -s "$BANK_DIR/$email.json" ] || _fixture_die "bank_record: $BANK_DIR/$email.json empty after write"
}

kc_now() { cat "$STUB_KC_FILE" 2>/dev/null; }
claude_json_email() { python3 -c "import json,sys;print((json.load(open(sys.argv[1])).get('oauthAccount') or {}).get('emailAddress',''))" "$CLAUDE_JSON" 2>/dev/null; }
fp_of() { printf '%s' "$1" | python3 "$AB_DIR/bank_common.py" --fingerprint; }
