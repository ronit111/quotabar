#!/bin/bash
# Email -> path safety (critical finding 1): bank_file_for and every mutator that
# takes an <email> argument reject path traversal / separators.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
new_env email_safety >/dev/null
source "$AB_DIR/lib.sh"; ensure_bank

bank_file_for "a@b.com" >/dev/null 2>&1; assert_eq 0 "$?" "bank_file_for accepts a normal email"
bank_file_for "../evil" >/dev/null 2>&1;   assert_ne 0 "$?" "bank_file_for rejects ../evil"
bank_file_for "a/b@c.com" >/dev/null 2>&1; assert_ne 0 "$?" "bank_file_for rejects slash"
bank_file_for ".config" >/dev/null 2>&1;   assert_ne 0 "$?" "bank_file_for rejects leading dot"
bank_file_for "" >/dev/null 2>&1;          assert_ne 0 "$?" "bank_file_for rejects empty"
bank_file_for "a..b@x.com" >/dev/null 2>&1; assert_ne 0 "$?" "bank_file_for rejects double-dot"

# a would-be traversal target must not create/delete anything outside BANK_DIR
set_active real@x.com A
before_count="$(ls -1 "$BANK_DIR" | wc -l | tr -d ' ')"
/bin/bash "$AB_DIR/swap-account.sh" "../../../tmp/pwn" >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "swap refuses a traversal email"
/bin/bash "$AB_DIR/ping-account.sh" "../../../tmp/pwn" >/dev/null 2>&1; rc=$?
assert_ne 0 "$rc" "ping refuses a traversal email"
after_count="$(ls -1 "$BANK_DIR" | wc -l | tr -d ' ')"
assert_eq "$before_count" "$after_count" "no stray files created from a traversal email"

finish "email_safety"
