#!/usr/bin/env bash
# Notarizes and staples a signed Health Bridge.app (or .dmg).
#
#   scripts/notarize.sh "dist/Flexpa Health Bridge.app"
#
# Credentials, one of:
#   NOTARY_PROFILE   keychain profile created with:
#                    xcrun notarytool store-credentials HealthBridge --apple-id you@flexpa.com --team-id TEAMID
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   App Store Connect API key (.p8); what CI uses,
#                    because it is not tied to one person's Apple ID and does not expire on password change
#   APPLE_ID + TEAM_ID + APP_SPECIFIC_PASSWORD
set -euo pipefail

TARGET="${1:?usage: notarize.sh <path to .app or .dmg>}"
[ -e "$TARGET" ] || { echo "not found: $TARGET" >&2; exit 1; }

AUTH=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
  AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD")
else
  echo "set NOTARY_PROFILE, or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID, or APPLE_ID/TEAM_ID/APP_SPECIFIC_PASSWORD" >&2
  exit 2
fi

SUBMIT="$TARGET"
CLEANUP=""
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
  CLEANUP="$SUBMIT"
  echo "▸ zipping for submission"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "▸ submitting to Apple notary service (waits for the result)"
xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --output-format plist > /tmp/healthbridge-notary.plist
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' /tmp/healthbridge-notary.plist)"
ID="$(/usr/libexec/PlistBuddy -c 'Print :id' /tmp/healthbridge-notary.plist)"
echo "  submission $ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$ID" "${AUTH[@]}"
  exit 1
fi

echo "▸ stapling ticket"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

if [[ "$TARGET" == *.app ]]; then
  echo "▸ Gatekeeper assessment"
  spctl --assess --type execute --verbose=2 "$TARGET"
fi
[ -n "$CLEANUP" ] && rm -rf "$(dirname "$CLEANUP")"
echo "✓ notarized and stapled: $TARGET"
