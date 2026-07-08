#!/usr/bin/env bash
# Notarize and staple an already-Developer-ID-signed .app.
#
# No-op (exit 0) unless the notarization credentials are present, so the release workflow can
# call it unconditionally: without a paid Apple Developer account the pipeline still ships an
# ad-hoc build, it just skips this step.
#
# Inputs (env):
#   APP_PATH                path to the signed .app
#   AC_API_KEY_ID           App Store Connect API key id      (notarytool)
#   AC_API_ISSUER_ID        App Store Connect issuer id
#   AC_API_KEY_P8           contents of the AuthKey_*.p8 (PEM text), OR
#   AC_API_KEY_PATH         path to an AuthKey_*.p8 on disk
# notarytool needs a zip/dmg to submit; we zip the .app, submit, then staple the .app itself.
set -euo pipefail

APP="${APP_PATH:?APP_PATH required}"

if [[ -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER_ID:-}" ]]; then
  echo "notarize: no App Store Connect credentials — skipping notarization (ad-hoc release)."
  exit 0
fi

keypath="${AC_API_KEY_PATH:-}"
tmpkey=""
if [[ -z "$keypath" ]]; then
  tmpkey="$(mktemp -t ac_api_key.XXXXXX).p8"
  printf '%s' "${AC_API_KEY_P8:?AC_API_KEY_P8 or AC_API_KEY_PATH required}" > "$tmpkey"
  keypath="$tmpkey"
fi
cleanup() { [[ -n "$tmpkey" ]] && rm -f "$tmpkey"; }
trap cleanup EXIT

zip="$(mktemp -d)/notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$zip"

echo "notarize: submitting to Apple (this can take a few minutes)…"
xcrun notarytool submit "$zip" \
  --key "$keypath" \
  --key-id "$AC_API_KEY_ID" \
  --issuer "$AC_API_ISSUER_ID" \
  --wait

echo "notarize: stapling ticket to the app bundle…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl -a -vvv --type exec "$APP" || true
echo "notarize: done."
