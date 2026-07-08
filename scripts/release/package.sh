#!/usr/bin/env bash
# Package the built .app into distributable artifacts and emit their checksums.
#
# Produces, under dist/:
#   YouTube-Music-<version>.zip   — ditto zip; what the Homebrew cask downloads
#   YouTube-Music-<version>.dmg   — drag-to-Applications disk image for humans
#   SHA256SUMS.txt                — sha256 of both (the cask needs the zip's)
#
# Inputs (env): APP_PATH, VERSION
set -euo pipefail
cd "$(dirname "$0")/../.."

APP="${APP_PATH:?APP_PATH required}"
VERSION="${VERSION:?VERSION required}"
OUT="dist"
rm -rf "$OUT"; mkdir -p "$OUT"

zip="$OUT/YouTube-Music-${VERSION}.zip"
dmg="$OUT/YouTube-Music-${VERSION}.dmg"

echo "package: zipping app → $zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$zip"

echo "package: building disk image → $dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT   # remove the staging dir even if hdiutil fails
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "YouTube Music" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null

echo "package: checksums → $OUT/SHA256SUMS.txt"
( cd "$OUT" && shasum -a 256 ./*.zip ./*.dmg | sed 's#\./##' > SHA256SUMS.txt )
cat "$OUT/SHA256SUMS.txt"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "zip=$zip"
    echo "dmg=$dmg"
    echo "zip_sha256=$(shasum -a 256 "$zip" | awk '{print $1}')"
  } >> "$GITHUB_OUTPUT"
fi
