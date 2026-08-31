# Homebrew cask for Backpocket.
#
# Ships to a personal tap (m2na7/homebrew-backpocket) until the project meets
# homebrew-cask notability requirements. To publish:
# fill in version and the sha256 that scripts/release.sh prints, copy into
# the tap's Casks/, then `brew audit --new --cask backpocket`.
#
# auto_updates true, because the app updates itself through Sparkle. Without
# it Homebrew treats a self-updated app as drifted and fights it on upgrade.
cask "backpocket" do
  # PLACEHOLDER — set version and sha256 when publishing a release.
  # Do not ship this file with these values: `brew audit` will reject it.
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/m2na7/Backpocket/releases/download/v#{version}/Backpocket.zip",
      verified: "github.com/m2na7/Backpocket/"
  name "Backpocket"
  desc "Clipboard history and quick notes, merged into a single keystroke"
  homepage "https://github.com/m2na7/Backpocket"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  # A bare symbol already means "this version or newer"; the string form is
  # deprecated and prints a warning on every `brew` command that reads this.
  depends_on macos: :sonoma

  app "Backpocket.app"

  uninstall quit: "dev.m2na.backpocket"

  zap trash: [
    "~/Library/Application Support/Backpocket",
    "~/Library/Caches/dev.m2na.backpocket",
    "~/Library/Preferences/dev.m2na.backpocket.plist",
  ]
end
