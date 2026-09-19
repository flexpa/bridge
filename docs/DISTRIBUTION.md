# Distribution outside the Mac App Store

Developer ID + hardened runtime + notarization is Apple's sanctioned path for direct download.

**Shipping builds carry no entitlements**, so there is no provisioning profile to manage. HealthKit has no data
store on macOS (see [HEALTHKIT-ON-MACOS.md](HEALTHKIT-ON-MACOS.md)), the bridge reads iPhone backups instead, and
everything it does — the loopback server, peer identification, Full Disk Access — works under the hardened runtime
with an empty entitlement set. When Apple ships Health for the Mac, add the *restricted* HealthKit entitlement by
building with `HEALTHKIT_ENTITLEMENT=1 PROVISIONING_PROFILE=…`, which is when a Developer ID provisioning profile
becomes necessary.

Releases are cut by CI. See [RELEASING.md](RELEASING.md) for the one-time account setup and the per-release steps;
this file covers what the scripts do and how to verify the result by hand.

## One-time setup (human, Apple Developer account)

1. **Developer ID Application certificate.** Certificates, IDs & Profiles → Certificates → `+` → *Developer ID
   Application*. Create the CSR in Keychain Access on the signing Mac. Download and double-click to install.
   Verify: `security find-identity -v -p codesigning` lists `Developer ID Application: Flexpa USA Inc. (29GCN65AP9)`.
2. **App ID** `com.flexpa.HealthBridge` with the **HealthKit** capability enabled, including *Clinical Health
   Records*.
3. **Developer ID provisioning profile** — *only if* you turn on `HEALTHKIT_ENTITLEMENT=1`. Profiles → `+` →
   *Developer ID* (under Distribution) → pick the App ID → pick the Developer ID certificate → download
   `HealthBridge.provisionprofile`. Keep it out of git (`*.provisionprofile` is ignored). Not needed for normal releases.
4. **Notarization credentials.** An app-specific password for the Apple ID that belongs to the team, stored once:
   ```bash
   xcrun notarytool store-credentials HealthBridge --apple-id the release Apple ID --team-id TEAMID
   ```

## Build, sign, notarize, package

```bash
export CODESIGN_IDENTITY="Developer ID Application: Flexpa USA Inc. (29GCN65AP9)"
export NOTARY_PROFILE=HealthBridge

make release          # swift build (arm64 + x86_64), bundle, embed profile, codesign --options runtime
make notarize         # zip → notarytool submit --wait → stapler staple → spctl assess
make dmg              # dist/FlexpaHealthBridge-<version>.dmg with an Applications alias, signed
scripts/notarize.sh dist/FlexpaHealthBridge-*.dmg   # notarize and staple the DMG too
```

Version comes from `BridgeInfo.version`; override with `VERSION=0.2.0 BUILD_NUMBER=42`.

What the scripts do that is easy to get wrong by hand:

* `--options runtime` (hardened runtime) and `--timestamp` are required for notarization.
* Restricted entitlements never go in an ad-hoc build: AMFI kills the process at launch. The script refuses that
  combination rather than producing a bundle that cannot run.
* With `HEALTHKIT_ENTITLEMENT=1`, `Contents/embedded.provisionprofile` must be present before signing so it is sealed.
* The DMG is signed and notarized separately; Gatekeeper checks the container users actually download.

## Hosting

Upload the stapled DMG to the download host (for example `https://flexpa.com/downloads/HealthBridge-0.1.0.dmg`)
and publish its SHA-256 next to it. Because the ticket is stapled, first launch works offline. Gatekeeper shows
"Apple checked it for malicious software" rather than a warning.

## Verifying a download

```bash
spctl --assess --type execute --verbose=2 "/Applications/Flexpa Health Bridge.app"   # accepted, source=Notarized Developer ID
codesign -dv --entitlements - "/Applications/Flexpa Health Bridge.app"   # empty entitlement set, by design
xcrun stapler validate "/Applications/Flexpa Health Bridge.app"
```

## What still needs a human on the user's Mac

* Approving the Health access sheet when HealthKit becomes available on macOS.
* Choosing the Health export file for import.
* Approving *Launch at login* if macOS prompts.

## Updates

No auto-updater in v0.1. Options: Sparkle (EdDSA-signed appcast, well understood, adds a dependency), or a
version check against a static JSON on flexpa.com that opens the download page. Either fits the hardened
runtime.
