#!/usr/bin/env bash
# Wraps dist/Flexpa Health Bridge.app in a signed DMG for download.
#   scripts/make-dmg.sh            → dist/FlexpaHealthBridge-<version>.dmg
# Env: CODESIGN_IDENTITY (Developer ID Application) signs the DMG; omit for an unsigned local DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Flexpa Health Bridge.app"
[ -d "$APP" ] || { echo "build the app first: scripts/build-app.sh --release" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/FlexpaHealthBridge-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Flexpa Health Bridge" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" > /dev/null

if [ -n "${CODESIGN_IDENTITY:-}" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
  SIGN=(codesign --force --timestamp --sign "$CODESIGN_IDENTITY")
  [ -n "${SIGNING_KEYCHAIN:-}" ] && SIGN+=(--keychain "$SIGNING_KEYCHAIN")
  "${SIGN[@]}" "$DMG"
fi
echo "✓ $DMG"
