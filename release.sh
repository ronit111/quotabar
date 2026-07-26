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

# (v101-confirm) The BUILT bundle's version is the authority. An explicit argument may only
# NAME the version that was actually built — it may never relabel it. Before this, the
# argument flowed straight into the tag/zip/Cask while the plist was never consulted, so
# `./release.sh 1.0.1` against a 1.0.0 plist produced QuotaBar-1.0.1.zip containing an app
# that reports 1.0.0 to Finder, to the Cask's version check and to every user.
PLIST_VERSION="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$DIST/Contents/Info.plist")"
PLIST_VERSION="${PLIST_VERSION#v}"
VERSION="${1:-}"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || VERSION="$PLIST_VERSION"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release: version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }
if [ "$VERSION" != "$PLIST_VERSION" ]; then
  echo "release: REFUSING — requested version '$VERSION' does not match the BUILT bundle's" >&2
  echo "  CFBundleShortVersionString '$PLIST_VERSION' ($DIST/Contents/Info.plist)." >&2
  echo "  Bump app/Info.plist (CFBundleShortVersionString and CFBundleVersion) and rebuild;" >&2
  echo "  the zip, tag and Cask must never claim a version the app itself does not report." >&2
  exit 1
fi
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
  # (r15 #10) The sha256 pattern used to require a HEX body ("[0-9a-f]*"), so a cask
  # carrying a non-hex placeholder was silently not replaced — which is exactly what
  # happened in production: the stamp reported success, the placeholder survived, and the
  # published cask disagreed with the uploaded zip. Match any quoted body...
  /usr/bin/sed -i '' \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA\"/" \
    "$CASK_FILE"
  # ...and then PROVE both substitutions landed. `sed` reports success for a pattern that
  # matched nothing, so the exit status says nothing at all about whether the file changed;
  # only reading the result back does. Require EXACTLY ONE line carrying each stamped value:
  # zero means the stamp silently no-op'd (a reformat, a placeholder, a renamed field), and
  # more than one means the cask has duplicate fields and we cannot say which one Homebrew
  # will read. Either way the artifact and the cask would disagree and `brew install` would
  # fail for every user, so fail loudly here instead.
  _vmatch="$(/usr/bin/grep -c "^  version \"$VERSION\"\$" "$CASK_FILE" || true)"
  _smatch="$(/usr/bin/grep -c "^  sha256 \"$SHA\"\$" "$CASK_FILE" || true)"
  if [ "$_vmatch" != "1" ] || [ "$_smatch" != "1" ]; then
    echo "release: cask stamping FAILED — $CASK_FILE was NOT correctly updated." >&2
    echo "  version \"$VERSION\" lines: $_vmatch (want exactly 1)" >&2
    echo "  sha256  \"$SHA\" lines: $_smatch (want exactly 1)" >&2
    echo "  The cask does not match $ZIP. Fix the cask's version/sha256 fields (they must" >&2
    echo "  each appear once, two-space indented) and re-run; do NOT publish this pair." >&2
    exit 1
  fi
  echo ">> stamped cask: $CASK_FILE (version $VERSION, sha256 $SHA) — both fields verified" >&2
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
