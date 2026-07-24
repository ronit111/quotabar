#!/bin/bash
# remove-account: refuse active (51 family), verified deletion (50), cache
# invalidation (52), safe no-op, unsafe-email refusal (1).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
RM="$AB_DIR/remove-account.sh"

# ---- refuse to remove the ACTIVE account (finding 51 guard family) ----
new_env rm_active >/dev/null
set_active a@x.com A
bank_record a@x.com A "" "$FUT" max claude_max
/bin/bash "$RM" a@x.com >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "removing the active account is refused"
assert_file_present "$BANK_DIR/a@x.com.json" "active account record preserved"

# ---- remove a parked account: verified deletion (50) + cache invalidation (52) ----
new_env rm_parked >/dev/null
set_active a@x.com A
bank_record a@x.com A "" "$FUT" max claude_max
bank_record b@x.com B "" "$FUT" pro claude_pro
# seed a usage cache that contains b@x.com
W "$BANK_DIR/.usage-cache.json" <<J
{"accounts":[{"provider":"claude","email":"a@x.com","worst_limit":{"percent":10}},
             {"provider":"claude","email":"b@x.com","worst_limit":{"percent":20}}]}
J
out="$(/bin/bash "$RM" b@x.com 2>&1)"; rc=$?
assert_eq 0 "$rc" "removing a parked account succeeds"
assert_file_absent "$BANK_DIR/b@x.com.json" "bank record verifiably deleted (finding 50)"
assert_contains "Removed banked account: b@x.com" "$out" "reports success only after deletion"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(a.get('email')!='b@x.com' for a in d['accounts']) else 1)" "$BANK_DIR/.usage-cache.json"
assert_eq 0 "$?" "removed account purged from usage cache (finding 52)"

# ---- unsafe email refused (finding 1) ----
new_env rm_unsafe >/dev/null
set_active a@x.com A
/bin/bash "$RM" "../../etc/passwd" >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "remove refuses an unsafe email (path traversal, finding 1)"

# ---- clean no-op for a non-banked account ----
new_env rm_noop >/dev/null
set_active a@x.com A
out="$(/bin/bash "$RM" ghost@x.com 2>&1)"; rc=$?
assert_eq 0 "$rc" "removing a non-banked account is a clean no-op"

# ---- (r12 #7) under EPOCH v2, the no-legacy path is FENCED rc 78 BEFORE it mutates ----
new_env rm_v2 >/dev/null
set_active a@x.com A
python3 -c "import sys;sys.path.insert(0,'$AB_DIR');import epoch;epoch.write_epoch('$BANK_DIR','v2',3)"
# a stray auto_ping entry the BUGGY no-legacy path would have scrubbed under v2
W "$BANK_DIR/.config.json" <<J
{"auto_ping":["ghost@x.com"]}
J
out="$(/bin/bash "$RM" ghost@x.com 2>&1)"; rc=$?
assert_eq 78 "$rc" "(r12 #7) remove under EPOCH v2 is fenced rc 78, before any mutation"
assert_contains "ghost@x.com" "$(cat "$BANK_DIR/.config.json")" \
  "(r12 #7) .config.json auto_ping NOT scrubbed under v2 (no lie 'nothing to remove')"

finish "remove"
