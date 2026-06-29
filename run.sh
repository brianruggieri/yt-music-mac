#!/usr/bin/env bash
# Build and launch YouTube Music for macOS.
set -euo pipefail
cd "$(dirname "$0")"

# Secrets.swift is in the synchronized source group, so the build needs it to exist.
# ponytail: copy the example (placeholder Discord ID) if the user hasn't made their own.
if [[ ! -f youtube-music-player/Secrets.swift ]]; then
	echo "Secrets.swift missing — copying from Secrets.example.swift"
	cp Secrets.example.swift youtube-music-player/Secrets.swift
fi

# Wipe derived data first: Xcode caches the synchronized-group file list, so a stale
# build/ silently drops newly-added source files (ImportLauncher.swift et al.).
rm -rf build

xcodebuild \
	-project youtube-music-player.xcodeproj \
	-scheme youtube-music-player \
	-configuration Release \
	-derivedDataPath build \
	build

open "build/Build/Products/Release/YouTube Music.app"
