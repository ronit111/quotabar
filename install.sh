#!/usr/bin/env bash
# QuotaBar installer.
#   1. Installs the account-bank scripts to ~/.local/share/quotabar/account-bank
#      (override with QUOTABAR_SCRIPTS_DIR / XDG_DATA_HOME).
#   2. Builds and installs the QuotaBar.app menu bar app to /Applications.
#
# Nothing here touches your accounts, keychain, or Claude Code config. The app
# and scripts only act when you use them. Re-running this script is safe.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
SCRIPTS_DEST="${QUOTABAR_SCRIPTS_DIR:-$XDG_DATA/quotabar/account-bank}"

echo "==> Installing account-bank scripts to: $SCRIPTS_DEST"
mkdir -p "$SCRIPTS_DEST"
/usr/bin/ditto "$REPO_DIR/scripts" "$SCRIPTS_DEST"
rm -rf "$SCRIPTS_DEST/__pycache__"
chmod +x "$SCRIPTS_DEST"/*.sh "$SCRIPTS_DEST"/*.py 2>/dev/null || true

echo "==> Building and installing QuotaBar.app"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi
make -C "$REPO_DIR/app" install

cat <<'NOTES'

==> Done.

QuotaBar.app is in /Applications and the scripts are installed. Two things to know:

1. First launch is Gatekeeper-blocked (the app is ad-hoc signed, not notarized).
   Right-click QuotaBar.app in /Applications -> Open -> Open, once. After that it
   launches normally. Or clear the quarantine flag:
       xattr -dr com.apple.quarantine /Applications/QuotaBar.app

2. Fast account swaps need a one-time Keychain authorization so the scripts can
   read Claude Code's credential item without a password prompt each time:
       security set-generic-password-partition-list \
         -s "Claude Code-credentials" -a "$USER" -k "" -S "apple:,apple-tool:"
   (This grants Apple-signed tools -- including /usr/bin/security -- access to
   that one item. It does not expose the secret; it just stops the repeated GUI
   prompt. You will be asked for your login password once to apply it.)

Add accounts: run `/login` in Claude Code for each account. With the SessionStart
hook enabled (optional, see README), the next session banks it automatically;
otherwise bank it once with:
    bash ~/.local/share/quotabar/account-bank/bank-account.sh

Set QuotaBar to launch at login from its menu (the auto features only run while
it is open). The app's runtime data lives in ~/.local/share/quotabar and its log
in ~/Library/Logs/QuotaBar.log -- both outside this repo.
NOTES
