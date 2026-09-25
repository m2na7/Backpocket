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

# Untracked files count: SwiftPM compiles every source under Sources/ and
# build.sh copies every .lproj, tracked or not.
[ -z "$(git status --porcelain)" ] ||
  die "working tree is dirty or has untracked files; a submission must be reproducible from a commit"

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

# The signature has to claim the same application identifier the profile
# grants, and nothing in the payload may carry quarantine. Both are refused
# after the upload finishes, which is the slowest way to learn either.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q application-identifier ||
  die "the signature has no application-identifier — it will not match the profile"
[ "$(xattr -r "$APP" 2>/dev/null | grep -c quarantine)" = "0" ] ||
  die "something in the bundle still carries com.apple.quarantine"
echo "  no Sparkle, profile embedded, sandboxed, category and icon present, signature verifies"

step "Packaging the installer"

# The store ships this stripped binary, so its crash reports symbolicate only
# against this build's dSYM, and the next build of either variant deletes
# it. Archived beside the package, once its UUIDs prove it is this binary's:
# a dSYM from another build yields confident nonsense rather than an error.
[ -d "$APP.dSYM" ] || die "no dSYM at $APP.dSYM — was this a release build?"
BIN_UUIDS="$(dwarfdump --uuid "$APP/Contents/MacOS/Backpocket" | awk '{print $2, $3}' | sort)"
DSYM_UUIDS="$(dwarfdump --uuid "$APP.dSYM" | awk '{print $2, $3}' | sort)"
[ -n "$BIN_UUIDS" ] && [ "$BIN_UUIDS" = "$DSYM_UUIDS" ] ||
  die "the dSYM does not match the binary — crash reports could not be symbolicated"
DSYM_ZIP="build/Backpocket-$VERSION-mas.dSYM.zip"
rm -f "$DSYM_ZIP"
ditto -c -k --norsrc --noextattr --noqtn --zlibCompressionLevel 9 --keepParent "$APP.dSYM" "$DSYM_ZIP"

PKG="build/Backpocket-$VERSION.pkg"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$PKG"
pkgutil --check-signature "$PKG" | head -3

cat <<MSG

Built $PKG
  and $DSYM_ZIP, its symbols:
$(printf '%s\n' "$BIN_UUIDS" | sed 's/^/    /')

Keep the two together: crash reports from this build cannot be symbolicated
without the symbols, and they cannot be made again from source.

Upload it with:
  xcrun altool --upload-app -f "$PKG" -t macos \\
    --apple-id <apple id> --password <app-specific password>

Or open Transporter and drag it in. App Store Connect must already have an app
record for dev.m2na.backpocket, or the upload is rejected as an unknown app.
MSG
