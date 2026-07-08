#!/usr/bin/env bash
# Bump the app's version in the Xcode project and (optionally) tag the release.
#
# Usage:
#   scripts/release/bump-version.sh 1.2.0            # set MARKETING_VERSION=1.2.0, bump build +1
#   scripts/release/bump-version.sh 1.2.0 --tag      # …then commit and create tag v1.2.0
#
# The release workflow ALSO injects the version from the pushed tag at build time, so this
# script is a convenience for keeping the checked-in project in sync + minting the tag.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:?usage: bump-version.sh <marketing-version> [--tag]}"
PBX="youtube-music-player.xcodeproj/project.pbxproj"

cur_build="$(grep -m1 -E 'CURRENT_PROJECT_VERSION = ' "$PBX" | grep -oE '[0-9]+' | head -1)"
next_build=$(( cur_build + 1 ))

/usr/bin/sed -i.bak -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" "$PBX"
/usr/bin/sed -i.bak -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${next_build};/g" "$PBX"
rm -f "${PBX}.bak"

echo "bump-version: MARKETING_VERSION=${VERSION}, CURRENT_PROJECT_VERSION=${next_build}"

if [[ "${2:-}" == "--tag" ]]; then
  git add "$PBX"
  git commit -m "Release v${VERSION}"
  git tag -a "v${VERSION}" -m "YouTube Music for macOS v${VERSION}"
  echo "bump-version: committed and tagged v${VERSION}. Push with:  git push && git push origin v${VERSION}"
fi
