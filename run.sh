#!/usr/bin/env bash
# Build and launch the app. Usage: ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

# Secrets.swift is gitignored; the build needs it inside the synchronized
# source folder (Xcode auto-compiles every .swift there).
PHASE=build
if [ ! -f youtube-music-player/Secrets.swift ]; then
  cp Secrets.example.swift youtube-music-player/Secrets.swift
  # Incremental builds miss a just-added synchronized file; clean once so it's seen.
  PHASE="clean build"
fi

xcodebuild -project youtube-music-player.xcodeproj \
  -scheme youtube-music-player -configuration Debug $PHASE

# Ask xcodebuild where it put the .app rather than hardcoding the path.
# Split on " = " so values containing spaces (e.g. "YouTube Music.app") survive.
eval "$(xcodebuild -project youtube-music-player.xcodeproj \
  -scheme youtube-music-player -configuration Debug -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print "DIR=\""$2"\""} / FULL_PRODUCT_NAME =/{print "APP=\""$2"\""}')"

open "$DIR/$APP"
