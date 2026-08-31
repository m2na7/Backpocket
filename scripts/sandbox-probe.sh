#!/bin/bash
# Builds scripts/sandbox-probe.swift into a signed app bundle and runs it.
# BACKPOCKET_SANDBOX=1 signs it with Resources/Backpocket.entitlements, so the
# probe runs under exactly the sandbox the App Store build would.
#
#   ./scripts/sandbox-probe.sh                       unsandboxed baseline
#   BACKPOCKET_SANDBOX=1 ./scripts/sandbox-probe.sh  sandboxed
#
# Extra arguments are forwarded to the probe (a path to stat, --try-network,
# --try-login-item).
set -e
cd "$(dirname "$0")/.."

OUT="${PROBE_DIR:-build/SandboxProbe}"
APP="$OUT/SandboxProbe.app"
# Overridable so a receiver probe can run as a genuinely different app, with
# its own container, rather than sharing the sender's.
ID="${PROBE_BUNDLE_ID:-dev.m2na.backpocketprobe}"

IDENTITY="${BACKPOCKET_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>SandboxProbe</string>
	<key>CFBundleExecutable</key><string>SandboxProbe</string>
	<key>CFBundleIdentifier</key><string>$ID</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

swiftc -O scripts/sandbox-probe.swift -o "$APP/Contents/MacOS/SandboxProbe"

if [ "${BACKPOCKET_SANDBOX:-0}" = "1" ]; then
  codesign --force --sign "$IDENTITY" \
    --entitlements Resources/Backpocket.entitlements "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi

# Run the executable directly so its stdout comes back here; the sandbox is
# applied at exec from the signature either way.
exec "$APP/Contents/MacOS/SandboxProbe" "$@"
