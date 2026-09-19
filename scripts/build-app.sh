#!/usr/bin/env bash
# Builds Health Bridge.app from the SwiftPM package. No Xcode project needed.
#
#   scripts/build-app.sh                 # debug build, ad-hoc signed, for local use
#   scripts/build-app.sh --release       # optimized, still ad-hoc unless CODESIGN_IDENTITY is set
#   scripts/build-app.sh --release --universal
#
# Environment:
#   CODESIGN_IDENTITY     "Developer ID Application: Flexpa Inc (TEAMID)"; default "-" (ad-hoc)
#   VERSION / BUILD_NUMBER override the bundle version (defaults: BridgeInfo.version, git commit count)
#
# Optional, and not needed to ship: HealthKit has no data store on macOS, so release
# builds carry no entitlements and therefore need no provisioning profile.
#   HEALTHKIT_ENTITLEMENT=1  request com.apple.developer.healthkit
#   PROVISIONING_PROFILE     path to a Developer ID .provisionprofile granting it (required with the above)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG=debug
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --debug) CONFIG=debug ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="${VERSION:-$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/HealthBridgeCore/MCP/MCPServer.swift)}"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
APP="$ROOT/dist/Flexpa Health Bridge.app"

echo "▸ swift build ($CONFIG$([ "$UNIVERSAL" = 1 ] && echo ', universal'))"
if [ "$UNIVERSAL" = 1 ]; then
  swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product HealthBridge
  BIN="$ROOT/.build/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/HealthBridge"
else
  swift build -c "$CONFIG" --product HealthBridge
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/HealthBridge"
fi
[ -x "$BIN" ] || { echo "binary not found at $BIN" >&2; exit 1; }

echo "▸ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HealthBridge"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [ ! -f Packaging/AppIcon.icns ]; then
  echo "▸ rendering icon"
  swift scripts/make-icon.swift Packaging/AppIcon.icns
fi
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_ARGS=(--force --sign "$IDENTITY" --identifier com.flexpa.HealthBridge)
# CI keeps the Developer ID in a keychain outside the default search list so no other step
# can sign with it; name it explicitly here.
[ -n "${SIGNING_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
if [ "$IDENTITY" = "-" ]; then
  echo "▸ codesign (ad-hoc, local use only)"
else
  echo "▸ codesign ($IDENTITY)"
  # Hardened runtime and a secure timestamp are both required for notarization.
  SIGN_ARGS+=(--timestamp --options runtime)
fi

if [ "${HEALTHKIT_ENTITLEMENT:-0}" = "1" ]; then
  if [ "$IDENTITY" = "-" ]; then
    echo "  HEALTHKIT_ENTITLEMENT needs a real identity: macOS kills an ad-hoc binary carrying a restricted entitlement." >&2
    exit 1
  fi
  if [ -z "${PROVISIONING_PROFILE:-}" ]; then
    echo "  HEALTHKIT_ENTITLEMENT=1 requires PROVISIONING_PROFILE (a Developer ID profile granting HealthKit)." >&2
    exit 1
  fi
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  SIGN_ARGS+=(--entitlements Packaging/HealthKit.entitlements)
  echo "  including the HealthKit entitlement and embedded provisioning profile"
fi

codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "✓ $APP"
echo "  version $VERSION ($BUILD_NUMBER)"
