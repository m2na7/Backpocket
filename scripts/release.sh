#!/bin/bash
# Cuts a release from this machine: build, sign, notarize, staple, package,
# sign the appcast, and publish to GitHub.
#
#   ./scripts/release.sh 0.1.0
#
# CI could do this, and release.yml still can — but macOS runners bill ten
# minutes for every one on a private repository, so until this repo is public
# the local path is the cheap one. It produces the same artifacts.
#
# Prerequisites, each checked below rather than assumed:
#   - a "Developer ID Application" identity in the keychain
#   - notarytool credentials stored under the profile named here
#     (xcrun notarytool store-credentials backpocket --apple-id … --team-id …)
#   - the Sparkle signing key in the login keychain
#   - gh authenticated as the account owning the repository
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
PROFILE="${NOTARY_PROFILE:-backpocket}"
TOOLS=.build/artifacts/sparkle/Sparkle/bin

if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/release.sh <version>   e.g. 0.1.0" >&2
  exit 1
fi
case "$VERSION" in v*) echo "release.sh: pass 0.1.0, not v0.1.0" >&2; exit 1 ;; esac

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { echo "release.sh: $1" >&2; exit 1; }

step "Checking what this needs"

# Every one of these fails later and more confusingly if left to chance —
# after a build, or worse, after a partial upload.
IDENTITY="$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[ -n "$IDENTITY" ] || die "no Developer ID Application identity in the keychain"

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 ||
  die "no notarytool profile '$PROFILE' — see 'xcrun notarytool store-credentials'"

git diff --quiet && git diff --cached --quiet ||
  die "working tree is dirty; a release must be reproducible from a commit"

[ -x "$TOOLS/generate_appcast" ] || die "Sparkle tools missing — run 'swift build'"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

echo "  identity: $IDENTITY"
echo "  repo:     $REPO"
echo "  version:  $VERSION"

step "Building universal, signed, stripped"
# BUILD_NUMBER must increase for Sparkle to see a release as newer; the commit
# count does that on its own and needs no bookkeeping.
VERSION="$VERSION" \
BUILD_NUMBER="$(git rev-list --count HEAD)" \
BACKPOCKET_UNIVERSAL=1 \
BACKPOCKET_PUBLISHING=1 \
BACKPOCKET_SIGN_IDENTITY="$IDENTITY" \
  ./build.sh release

lipo -archs build/Backpocket.app/Contents/MacOS/Backpocket | grep -q x86_64 ||
  die "binary is not universal"
codesign --verify --deep --strict build/Backpocket.app || die "signature did not verify"

step "Notarizing (a few minutes)"
# Notarization takes a zip, but the ticket is stapled to the .app — so this
# zip is only a vehicle and is rebuilt afterwards to carry the ticket.
rm -f build/Backpocket.zip
ditto -c -k --sequesterRsrc --keepParent build/Backpocket.app build/Backpocket.zip
xcrun notarytool submit build/Backpocket.zip \
  --keychain-profile "$PROFILE" --wait || die "notarization failed"
xcrun stapler staple build/Backpocket.app || die "stapling failed"

rm -f build/Backpocket.zip
ditto -c -k --sequesterRsrc --keepParent build/Backpocket.app build/Backpocket.zip

# What a user's Mac actually asks before opening it. Catches a staple that
# silently did not take.
spctl -a -vvv -t install build/Backpocket.app 2>&1 | grep -q "accepted" ||
  die "Gatekeeper would reject this build"

step "Packaging symbols and appcast"
rm -f build/Backpocket.dSYM.zip
ditto -c -k --sequesterRsrc --keepParent build/Backpocket.app.dSYM build/Backpocket.dSYM.zip

rm -rf build/appcast && mkdir -p build/appcast
cp build/Backpocket.zip build/appcast/
"$TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  build/appcast
cp build/appcast/appcast.xml build/appcast.xml
grep -q 'edSignature' build/appcast.xml || die "appcast has no signature"

step "Publishing"
# Annotated and explicitly messaged. A bare `git tag` is lightweight until
# tag.gpgsign is set, at which point git wants to sign it and stops for a
# message it was never given — after notarization has already been paid for.
git tag -a "v$VERSION" -m "Backpocket v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" \
  --title "v$VERSION" \
  --generate-notes \
  build/Backpocket.zip build/Backpocket.dSYM.zip build/appcast.xml

cat <<EOF

Released v$VERSION.

  sha256 (for the Homebrew cask):
  $(shasum -a 256 build/Backpocket.zip | cut -d' ' -f1)

One step is left and nothing does it for you: upload build/appcast.xml to the
Cloudflare Worker. Until it is there, no installed copy learns this release
exists.
EOF
