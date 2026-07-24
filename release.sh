#!/usr/bin/env bash
# QuotaBar release builder (MAINTAINER). Builds + verifies the app, zips it, computes the
# SHA256, and PRINTS (never runs) the publish command + the Homebrew Cask fields.
#
#   ./release.sh [version] [cask-file]
#     version    defaults to the built Info.plist CFBundleShortVersionString
#     cask-file  optional path to a Homebrew Cask .rb; if given, its version + sha256 are
#                updated IN PLACE to match this exact build (see the reproducibility note).
#
# It performs NO outward action: no gh, no push, no tag. It only produces the local artifact
# (QuotaBar-<version>.zip) and the exact values you need for the release + Cask. Publishing is
# a separate, manual, reviewed step (the command is printed at the end).
#
# REPRODUCIBILITY: the zip is NOT byte-stable across rebuilds (ad-hoc codesign + zip carry
# timestamps), so its sha256 changes every build. The Cask's sha256 must therefore match the
# EXACT zip you upload. Correct flow: run this ONCE, pass the tap's cask so it is stamped to
# this build, then upload THIS zip. Do not rebuild between stamping the cask and publishing.
set -euo pipefail

cd "$(dirname "$0")"
APP_DIR="app"
DIST="$APP_DIR/dist.noindex/QuotaBar.app"
readonly OWNER="ronit111"
readonly REPO="quotabar"
readonly PLISTBUDDY=/usr/libexec/PlistBuddy
CASK_FILE="${2:-}"

# Build + verify (codesign / plist / arch). Uses the repo's own toolchain, no network.
echo ">> building QuotaBar.app..." >&2
/usr/bin/make -C "$APP_DIR" verify >/dev/null

VERSION="${1:-}"
[ -n "$VERSION" ] || VERSION="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$DIST/Contents/Info.plist")"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release: version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }
readonly TAG="v$VERSION"
readonly ZIP="QuotaBar-$VERSION.zip"
readonly URL="https://github.com/$OWNER/$REPO/releases/download/$TAG/$ZIP"

# Zip the .app with its parent dir preserved (Homebrew Cask expects QuotaBar.app at the root).
echo ">> packaging $ZIP..." >&2
/bin/rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$DIST" "$ZIP"

SHA="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/cut -d' ' -f1)"
SIZE="$(/usr/bin/du -h "$ZIP" | /usr/bin/cut -f1 | /usr/bin/tr -d ' ')"

# Optionally stamp the Cask so its version + sha256 match THIS exact build.
if [ -n "$CASK_FILE" ]; then
  [ -f "$CASK_FILE" ] || { echo "release: cask file not found: $CASK_FILE" >&2; exit 1; }
  /usr/bin/sed -i '' \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \"[0-9a-f]*\"/  sha256 \"$SHA\"/" \
    "$CASK_FILE"
  echo ">> stamped cask: $CASK_FILE (version $VERSION, sha256 $SHA)" >&2
fi

cat <<EOF

=== QuotaBar release artifact (local only) ===
version : $VERSION
tag     : $TAG
zip     : $ZIP  ($SIZE)
sha256  : $SHA
url     : $URL

=== Homebrew Cask fields ===
  version "$VERSION"
  sha256 "$SHA"
  url "$URL"

=== Publish (RUN MANUALLY, after review) ===
gh release create $TAG "$ZIP" \\
  --repo $OWNER/$REPO \\
  --title "QuotaBar $TAG" \\
  --notes "QuotaBar $TAG. Install: brew tap $OWNER/$REPO && brew install --cask $REPO"
EOF
