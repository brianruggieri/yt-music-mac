#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) Release "YouTube Music.app".
#
# Signing is decided by the caller via env vars, so this one script serves both tiers:
#   • Unsigned / ad-hoc (no Apple Developer account): SIGN_IDENTITY unset → CODE_SIGN_IDENTITY="-",
#     signing not required. This mirrors upstream (0xjemm) — users clear the quarantine bit with
#     `xattr -cr` on first launch.
#   • Developer ID (paid account): export SIGN_IDENTITY="Developer ID Application: … (TEAMID)"
#     and DEVELOPMENT_TEAM=TEAMID before calling. Hardened Runtime is enabled so the artifact
#     can be notarized downstream (Hardened Runtime is a notarization prerequisite).
#
# Inputs (env):
#   MARKETING_VERSION       e.g. 1.2.0   (defaults to the value already in the project)
#   BUILD_NUMBER            e.g. 42      (defaults to the value already in the project)
#   SIGN_IDENTITY           Developer ID identity string, or unset for ad-hoc
#   DEVELOPMENT_TEAM        Apple Team ID (required when SIGN_IDENTITY is set)
#   KEYCHAIN                path to the temporary keychain holding the cert (signed tier only)
# Output:
#   Prints the absolute path of the built .app on the last line (also writes it to
#   $GITHUB_OUTPUT as app_path when running in Actions).
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT="youtube-music-player.xcodeproj"
SCHEME="youtube-music-player"
CONFIG="Release"
DERIVED="build/release"

args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -derivedDataPath "$DERIVED"
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
)

[[ -n "${MARKETING_VERSION:-}" ]] && args+=("MARKETING_VERSION=${MARKETING_VERSION}")
[[ -n "${BUILD_NUMBER:-}" ]] && args+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "build-app: Developer ID tier — signing as '${SIGN_IDENTITY}', Hardened Runtime on."
  args+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM required when SIGN_IDENTITY is set}"
    ENABLE_HARDENED_RUNTIME=YES
  )
  [[ -n "${KEYCHAIN:-}" ]] && args+=(OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN}")
else
  echo "build-app: unsigned/ad-hoc tier — CODE_SIGN_IDENTITY='-' (users run 'xattr -cr')."
  args+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=YES
  )
fi

rm -rf "$DERIVED"
xcodebuild "${args[@]}" build

# `|| true`: a missing products dir makes find exit non-zero, which under `set -e` would abort
# here with a raw error before the friendly message below can run.
APP="$(/usr/bin/find "$DERIVED/Build/Products/$CONFIG" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
if [[ -z "$APP" ]]; then
  echo "build-app: ERROR — no .app produced under $DERIVED/Build/Products/$CONFIG" >&2
  exit 1
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
echo "build-app: built $APP"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "app_path=$APP" >> "$GITHUB_OUTPUT"
echo "$APP"
