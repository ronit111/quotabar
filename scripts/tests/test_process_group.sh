#!/bin/bash
# run_with_timeout kills the WHOLE process group (findings 2, 22): a grandchild of
# the timed command must NOT survive the timeout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/testlib.sh"
new_env pgroup >/dev/null
source "$AB_DIR/lib.sh"

marker="${BANK_DIR}/gc-marker"
rm -f "$marker"
cat > "${BANK_DIR}/gc.sh" <<INNER
#!/bin/bash
( sleep 3; echo survived > "$marker" ) &
sleep 30
INNER
chmod +x "${BANK_DIR}/gc.sh"

run_with_timeout 1 /bin/bash "${BANK_DIR}/gc.sh"; rc=$?
assert_eq 124 "$rc" "timed command returns 124 on timeout"
sleep 4
assert_file_absent "$marker" "grandchild killed with the group (marker never written)"

# a fast command returns cleanly with its own rc and clean stdout capture
out="$(run_with_timeout 5 printf 'clean')"; rc=$?
assert_eq 0 "$rc" "fast command rc 0"
assert_eq "clean" "$out" "stdout capture is clean under set -m"

finish "process_group"
