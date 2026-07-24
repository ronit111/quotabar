#!/bin/bash
# usage.py: always-write-cache (32), ONLY-mode skips non-targets (33), malformed
# record surfaced as an explicit error (35).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"

# force fast network failure + no codex (fake HOME)
common_env() {
  export FAKEHOME="$BANK_DIR/../fakehome"; rm -rf "$FAKEHOME"; mkdir -p "$FAKEHOME"
  export ACCOUNT_BANK_CLAUDE_URL="http://127.0.0.1:9/usage"
  export ACCOUNT_BANK_CODEX_URL="http://127.0.0.1:9/usage"
  export ACCOUNT_BANK_TOTAL_DEADLINE="8"
}
run_usage() { HOME="$FAKEHOME" python3 "$AB_DIR/usage.py" 2>/dev/null; }

# ---- finding 35: malformed bank record surfaced as a visible error entry ----
new_env us_malformed >/dev/null; common_env
set_active a@x.com A
printf '{ not json' | W "$BANK_DIR/c@x.com.json"
out="$(run_usage)"
echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=[a for a in d['accounts'] if a.get('email')=='c@x.com']
sys.exit(0 if (c and c[0].get('error','').startswith('invalid bank record')) else 1)"
assert_eq 0 "$?" "malformed record surfaced as an explicit error, not hidden (finding 35)"

# ---- finding 32: cache is ALWAYS written, even when every account errors ----
new_env us_cache >/dev/null; common_env
set_active a@x.com A
bank_record b@x.com B "" "$FUT" pro claude_pro
rm -f "$BANK_DIR/.usage-cache.json"
run_usage >/dev/null
assert_file_present "$BANK_DIR/.usage-cache.json" "cache written even when all polls errored (finding 32)"

# ---- finding 33: ONLY mode does not poll/refresh non-targets ----
new_env us_only >/dev/null; common_env
set_active a@x.com A
# a parked EXPIRED account with no cache: in ONLY mode it must be a placeholder,
# never trigger a refresh turn.
bank_record b@x.com B "" "$PAST" pro claude_pro
out="$(ACCOUNT_BANK_ONLY="a@x.com" run_usage)"
echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=[a for a in d['accounts'] if a.get('email')=='b@x.com']
# non-target present but explicitly skipped (never refreshed)
sys.exit(0 if (b and 'ONLY mode' in str(b[0].get('error',''))) else 1)"
assert_eq 0 "$?" "ONLY mode serves a placeholder for non-targets, never refreshes them (finding 33)"

finish "usage_modes"
