#!/bin/bash
# Builds and packages the Mac App Store submission.
#
#   ./scripts/appstore.sh 0.1.4
#
# Separate from release.sh because almost nothing is shared: no notarization
# (Apple does its own review), no Sparkle, no GitHub release, no Homebrew, and
# a signed .pkg rather than a zip — the store accepts installer packages only.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: ./scripts/appstore.sh <version>   e.g. 0.1.4" >&2; exit 1; }
case "$VERSION" in v*) echo "appstore.sh: pass 0.1.4, not v0.1.4" >&2; exit 1 ;; esac

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { echo "appstore.sh: $1" >&2; exit 1; }

step "Checking what this needs"

APP_ID="$(security find-identity -v |
  sed -n 's/.*"\(Apple Distribution: [^"]*\)".*/\1/p' | head -1)"
[ -n "$APP_ID" ] || die "no Apple Distribution identity in the keychain"

PKG_ID="$(security find-identity -v |
  sed -n 's/.*"\(3rd Party Mac Developer Installer: [^"]*\)".*/\1/p' | head -1)"
[ -n "$PKG_ID" ] || die "no 3rd Party Mac Developer Installer identity — the .pkg cannot be signed"

PROFILE="${BACKPOCKET_PROFILE:-packaging/Backpocket_Mac_App_Store.provisionprofile}"
[ -f "$PROFILE" ] || die "no provisioning profile at $PROFILE"

git diff --quiet && git diff --cached --quiet ||
  die "working tree is dirty; a submission must be reproducible from a commit"

echo "  app identity: $APP_ID"
echo "  pkg identity: $PKG_ID"
echo "  version:      $VERSION"

step "Building universal, sandboxed, without Sparkle"
VERSION="$VERSION" BUILD_NUMBER="$(git rev-list --count HEAD)" \
BACKPOCKET_UNIVERSAL=1 BACKPOCKET_MAS=1 \
BACKPOCKET_SIGN_IDENTITY="$APP_ID" ./build.sh release

APP=build/Backpocket.app

# Everything below is a rejection the store would otherwise find for us, hours
# later and by email.
step "Checking the bundle against what review rejects"
[ -d "$APP/Contents/Frameworks" ] &&
  die "Frameworks present — the store build must not embed Sparkle"
otool -L "$APP/Contents/MacOS/Backpocket" | grep -qi sparkle &&
  die "the binary still links Sparkle"
[ -f "$APP/Contents/embedded.provisionprofile" ] ||
  die "the provisioning profile did not make it into the bundle"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q app-sandbox ||
  die "the bundle is not sandboxed"
codesign --verify --deep --strict "$APP" || die "signature did not verify"

# Three keys the store checks and the direct build never needed. Each one was
# found the slow way once: upload, wait, read the rejection.
PLIST="$APP/Contents/Info.plist"
for key in LSApplicationCategoryType CFBundleIconName; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 ||
    die "Info.plist has no $key — the store rejects the archive without it"
done
[ -f "$APP/Contents/Resources/Assets.car" ] ||
  die "no compiled asset catalog — the store reads the icon from there, not the .icns"
echo "  no Sparkle, profile embedded, sandboxed, category and icon present, signature verifies"

step "Packaging the installer"
PKG="build/Backpocket-$VERSION.pkg"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$PKG"
pkgutil --check-signature "$PKG" | head -3

cat <<MSG

Built $PKG

Upload it with:
  xcrun altool --upload-app -f "$PKG" -t macos \\
    --apple-id <apple id> --password <app-specific password>

Or open Transporter and drag it in. App Store Connect must already have an app
record for dev.m2na.backpocket, or the upload is rejected as an unknown app.
MSG
