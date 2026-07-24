#!/bin/bash
# run_tests.sh — the regression gate for the account-bank credential system.
#
# Runs every test_*.sh (bash) and test_*.py (python) in this directory against an
# ISOLATED sandbox (temp BANK_DIR/CLAUDE_JSON + stub `claude`/`security`). It never
# touches the real keychain or the live account. Exits NONZERO if any test fails,
# so it can be wired as a pre-review / pre-commit gate.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$HERE/stubs/"* 2>/dev/null || true

fails=0
run() {
  local f="$1" name; name="$(basename "$f")"
  printf '\n=== %s ===\n' "$name"
  case "$f" in
    *.py) python3 "$f" || fails=$((fails + 1)) ;;
    *.sh) /bin/bash "$f" || fails=$((fails + 1)) ;;
  esac
}

# deterministic order
for f in "$HERE"/test_*.py "$HERE"/test_*.sh; do
  [ -e "$f" ] || continue
  run "$f"
done

printf '\n============================================\n'
if [ "$fails" -eq 0 ]; then
  printf 'ALL TEST FILES PASSED\n'
  exit 0
else
  printf '%d TEST FILE(S) FAILED\n' "$fails"
  exit 1
fi
