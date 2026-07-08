# Homebrew cask template for distributing this fork's builds.
#
# This is a STARTING POINT, not a live cask. To use it:
#   1. Create a tap repo you own, e.g. `brianruggieri/homebrew-youtube-music-macos`.
#   2. Copy this file into that repo as `Casks/youtube-music-macos.rb`.
#   3. On each release, update `version` and `sha256` (the release job can automate this —
#      see docs/RELEASING.md → "Homebrew cask"). The sha256 is the zip's, in SHA256SUMS.txt.
#
# The `zap`/`xattr` postflight below handles the ad-hoc (un-notarized) tier: it strips the
# quarantine bit so users don't have to run `xattr -cr` by hand. Once you notarize, that
# postflight becomes unnecessary (but is harmless).
cask "youtube-music-macos" do
  version "1.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/brianruggieri/yt-music-mac/releases/download/v#{version}/YouTube-Music-#{version}.zip"
  name "YouTube Music"
  desc "Native macOS YouTube Music with a light theme, visualizer, and media keys"
  homepage "https://github.com/brianruggieri/yt-music-mac"

  depends_on macos: ">= :sonoma"

  app "YouTube Music.app"

  # Ad-hoc tier only: clear quarantine so Gatekeeper lets an un-notarized app launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/YouTube Music.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/-xjemm.youtube-music-player.plist",
    "~/Library/Application Support/YouTube Music",
    "~/Library/Caches/-xjemm.youtube-music-player",
  ]
end
