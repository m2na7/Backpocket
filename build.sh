#!/bin/bash
# Assembles and signs build/Backpocket.app.
# SPM only produces a bare binary; the bundle is put together here.
#
# Signing prefers a stable identity: TCC keys the accessibility grant to the
# app's designated requirement, and an ad-hoc requirement is the literal code
# hash — so ad-hoc builds silently lose the permission on EVERY rebuild while
# System Settings still shows the toggle on. Any Apple Development identity
# in the keychain is team-anchored and survives rebuilds, so one is picked up
# automatically. Override or force ad-hoc ("-") explicitly:
#
#   security find-identity -v -p codesigning
#   BACKPOCKET_SIGN_IDENTITY="Apple Development: You (TEAMID)" ./build.sh
#
# Release knobs (all optional, used by CI):
#   VERSION / BUILD_NUMBER  — stamped into the copied Info.plist; the repo's
#                             template plist stays unstamped.
#   BACKPOCKET_UNIVERSAL=1  — build arm64 + x86_64 into one binary.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="build/Backpocket.app"
IDENTITY="${BACKPOCKET_SIGN_IDENTITY:-}"

# Only "Apple Development" is matched: CI keychains carry "Developer ID
# Application" certs whose signing the release workflow owns itself.
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"

# Notarization rejects an app whose executable lacks the hardened runtime or a
# secure timestamp, and `codesign` adds neither on its own. Apple only ever
# sees a Developer ID build, so both are scoped to that identity: --timestamp
# calls Apple's timestamp server, and an everyday local build should not fail
# because that server is slow or unreachable.
#
# The nested Sparkle bundles below already ask for the hardened runtime
# unconditionally, which is why only the timestamp is added to them.
HARDENED=()
TIMESTAMP=()
case "$IDENTITY" in
  "Developer ID Application:"*)
    HARDENED=(--options runtime)
    TIMESTAMP=(--timestamp)
    ;;
esac

ARCH_FLAGS=()
if [ "${BACKPOCKET_UNIVERSAL:-0}" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# Sparkle links as @rpath/Sparkle.framework/..., and SwiftPM only emits an
# @loader_path rpath — enough while the binary sits beside the framework in
# .build, useless once it moves into a bundle. Without this the app dies at
# launch with a dyld "Library not loaded" and no other clue.
LINK_FLAGS=(-Xlinker -rpath -Xlinker @executable_path/../Frameworks)

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${LINK_FLAGS[@]}" --product Backpocket
# With --arch flags the bin path moves to .build/apple/Products; asking
# swift build keeps this script agnostic to that layout.
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${LINK_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Backpocket"

# The dSYM goes too, not just the bundle: a leftover one from an earlier
# build sits next to an app it no longer matches, and symbolicating against
# the wrong dSYM yields confident nonsense rather than an error.
rm -rf "$APP" "$APP.dSYM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Backpocket"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The App Store build carries no updater, so the keys that configure one are
# noise at best and a review question at worst. Removed from the copy; the
# repository's template keeps them for the direct-download build.
if [ "${BACKPOCKET_MAS:-0}" = "1" ]; then
  for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  done
fi

# ditto rather than cp: a framework is a tree of symlinks (Versions/Current,
# the top-level aliases) and copying those as regular files produces a bundle
# that codesign rejects.
if [ -d "$BIN_DIR/Sparkle.framework" ] && [ "${BACKPOCKET_MAS:-0}" != "1" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
fi
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Icon is generated separately; tolerate its absence.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

# The App Store build carries the profile that says which team and certificate
# are allowed to ship this bundle id. Its absence is fatal rather than a
# warning: an upload without it is rejected after the package is built, and
# finding that out at the upload step wastes the whole run.
if [ "${BACKPOCKET_MAS:-0}" = "1" ]; then
  PROFILE_SRC="${BACKPOCKET_PROFILE:-packaging/Backpocket_Mac_App_Store.provisionprofile}"
  if [ ! -f "$PROFILE_SRC" ]; then
    echo "build.sh: no provisioning profile at $PROFILE_SRC" >&2
    echo "build.sh: download the Mac App Store profile, or set BACKPOCKET_PROFILE." >&2
    exit 1
  fi
  cp "$PROFILE_SRC" "$APP/Contents/embedded.provisionprofile"
fi

# The menu-bar mark is a monochrome Retina template image, separate from the
# full-color application icon. MenuBarIcon loads it from the finished bundle.
if [ -f Resources/MenuBarIconTemplate@2x.png ]; then
  cp Resources/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/"
fi

# Release binaries ship stripped, with the symbols kept beside the bundle.
#
# SwiftPM leaves DWARF in the linked binary, which for this app is more than
# half its size — a menu-bar utility's download size is the first thing a
# visitor sees. Order matters and is not interchangeable: the dSYM has to be
# extracted BEFORE stripping (afterwards there is nothing left to extract),
# and signing has to come after (stripping edits the binary and invalidates
# any signature). The signing step at the end of this script is what closes
# that.
#
# Keep the .dSYM for anything you ship. A stripped binary's crash report is a
# list of addresses; symbolicating it needs the exact dSYM for that exact
# build, and it cannot be regenerated later from source.
#
# Debug builds are left alone — LLDB wants those symbols.
if [ "$CONFIG" = "release" ]; then
  dsymutil "$APP/Contents/MacOS/Backpocket" -o "$APP.dSYM"
  strip -x "$APP/Contents/MacOS/Backpocket"
fi

# Stamp release versions into the copy only (Set first — the keys exist in
# the template — Add as a fallback if they ever go away).
PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST" ||
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST" ||
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST"
fi

# A published build must not carry the placeholder feed. Every installed copy
# asks the URL baked into it at build time, so a wrong one cannot be corrected
# by a later release — those users keep asking the dead address forever and
# the only fix is telling them to download again by hand.
#
# Fatal only when publishing, which the release workflow declares. Compiling
# the release configuration is not the same act: CI does it on every pull
# request to prove the bundle still assembles, and failing that would block
# every change until the appcast host exists. Those builds get the warning,
# which is the part that has to be impossible to miss either way.
# Skipped for the App Store build, which deliberately has no feed: Apple
# ships those updates.
if [ "$CONFIG" = "release" ] && [ "${BACKPOCKET_MAS:-0}" != "1" ]; then
  for key in SUFeedURL SUPublicEDKey; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
    case "$value" in
      REPLACE_ME*|"")
        echo "build.sh: $key is still a placeholder." >&2
        if [ "${BACKPOCKET_PUBLISHING:-0}" = "1" ]; then
          echo "build.sh: refusing to publish a build that cannot update." >&2
          exit 1
        fi
        ;;
    esac
  done
fi

# Nested code is signed first, innermost outwards. Signing the outer bundle
# does NOT sign what is inside it — `--deep` used to paper over that and is
# deprecated for good reason — and a framework whose XPC services are
# unsigned fails Gatekeeper on the user's machine, not here.
#
# Sparkle's helpers are separate bundles by design: the updater has to
# outlive the app it is replacing, so it cannot be code inside it.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  for nested in \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/Updater.app" \
    "$FW/Versions/B/Autoupdate"; do
    [ -e "$nested" ] && codesign --force --options runtime "${TIMESTAMP[@]}" \
      --sign "$IDENTITY" "$nested"
  done
  codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$FW"
fi

# BACKPOCKET_SANDBOX=1 signs with Resources/Backpocket.entitlements, for the
# App Store variant. Off by default: the free build must stay byte-identical,
# so the unsandboxed path below is the plain `codesign` it always was.
# The App Store requires the sandbox, so BACKPOCKET_MAS implies it rather than
# asking the caller to remember both.
if [ "${BACKPOCKET_SANDBOX:-0}" = "1" ] || [ "${BACKPOCKET_MAS:-0}" = "1" ]; then
  codesign --force "${HARDENED[@]}" "${TIMESTAMP[@]}" --sign "$IDENTITY" \
    --entitlements Resources/Backpocket.entitlements "$APP"
  echo "Built $APP ($CONFIG, signed: $IDENTITY, sandboxed)"
else
  codesign --force "${HARDENED[@]}" "${TIMESTAMP[@]}" --sign "$IDENTITY" "$APP"
  echo "Built $APP ($CONFIG, signed: $IDENTITY)"
fi
