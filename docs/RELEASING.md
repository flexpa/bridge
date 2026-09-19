# Releasing

A release is a tag. CI builds a universal binary, signs it with Flexpa's Developer ID, notarizes it, staples the
ticket, publishes a draft GitHub release with a DMG, a zip, and checksums, then bumps the Homebrew cask.

## One-time setup

`scripts/setup-signing.sh` walks through all of it and checks each step with Apple as you go:

```bash
scripts/setup-signing.sh cert      # private key + CSR, then builds and imports the .p12
scripts/setup-signing.sh notary    # App Store Connect API key, verified against Apple
scripts/setup-signing.sh secrets   # pushes all six secrets to the repo
scripts/setup-signing.sh verify    # what is in place
```

Flexpa's team is **Flexpa USA Inc. (29GCN65AP9)**. Secrets and keys land in `~/.flexpa-signing`, mode 600, outside
the repository. Back that directory up: the notary `.p8` can be downloaded from Apple exactly once.

**One role gate to know about.** Only the Apple Developer **Account Holder** can create a Developer ID
certificate. Admins cannot, and this is a role restriction rather than a UI one: the App Store Connect API's
`POST /v1/certificates` with `certificateType: DEVELOPER_ID_APPLICATION` enforces the same rule, so scripting
around the portal does not help. If *Developer ID Application* does not appear in the certificate list, either the
account holder creates it once and hands over the `.p12`, they transfer the role, or they enable a
[cloud-managed Developer ID certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
which Admins can then use.

Everything after that one step runs in CI. The certificate is created once, lives in a repository secret, and no
release ever needs a Mac of yours.

The rest of this section describes what those commands do, for when you would rather do it by hand.

### 1. Developer ID certificate

In [Certificates, IDs & Profiles](https://developer.apple.com/account/resources/certificates/list), create a
**Developer ID Application** certificate. Generate the CSR in Keychain Access, download the certificate, and
double-click to install it. Then export it *with its private key* as a `.p12` with a strong password:

```bash
security find-identity -v -p codesigning        # confirm: Developer ID Application: Flexpa USA Inc. (29GCN65AP9)
# Keychain Access → My Certificates → right-click the cert → Export → .p12
base64 -i DeveloperID.p12 | pbcopy              # this string goes in the MACOS_CERTIFICATE_P12 secret
```

No App ID and no provisioning profile are needed. Shipping builds carry no entitlements, because HealthKit has no
data store on macOS and everything else works under the hardened runtime without one.

### 2. Notarization key

App Store Connect → Users and Access → **Integrations** → App Store Connect API → generate a key with the
**Developer** role. Download the `.p8` once; it cannot be downloaded again. Note the Key ID and the Issuer ID.

A key is better than an Apple ID and app-specific password here: it belongs to the team rather than a person, and
it survives password changes and staff turnover.

### 3. Repository secrets

`Settings → Secrets and variables → Actions`:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Flexpa USA Inc. (29GCN65AP9)` |
| `NOTARY_PRIVATE_KEY` | contents of the `.p8`, including the BEGIN/END lines |
| `NOTARY_KEY_ID` | the key's ID |
| `NOTARY_ISSUER_ID` | the issuer UUID |
| `HOMEBREW_TAP_TOKEN` | fine-grained PAT with contents write on `flexpa/homebrew-tap` only; omit to skip the cask step |

### 4. Homebrew tap (once)

CI never creates repositories, so that the tap token can stay scoped to a single repo:

```bash
gh repo create flexpa/homebrew-tap --public --description "Homebrew tap for Flexpa"
```

## Cutting a release

1. Bump `BridgeInfo.version` in `Sources/HealthBridgeCore/MCP/MCPServer.swift`. CI refuses a tag that disagrees
   with it, so the version a user sees in the panel always matches the tag they downloaded.
2. Move the `CHANGELOG.md` entries from Unreleased into the new version with today's date.
3. Commit, then tag and push:

```bash
git commit -am "chore: release 0.1.0"
git tag -a v0.1.0 -m "Flexpa Health Bridge 0.1.0"
git push origin master --follow-tags
```

4. Watch the run: `gh run watch`.
5. The release is created as a **draft**. Download the DMG, install it on a Mac that has never seen the app,
   check that Gatekeeper opens it without warnings, then publish:

```bash
gh release view v0.1.0 --json assets --jq '.assets[].name'
gh release edit v0.1.0 --draft=false
```

6. Publishing the release triggers the cask workflow, which downloads the published DMG, takes its
   checksum from the file the public actually gets, and pushes the cask. Confirm:
   `brew update && brew info --cask flexpa/tap/flexpa-health-bridge`.

## Cutting one by hand

If CI is unavailable:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Flexpa USA Inc. (29GCN65AP9)"
export NOTARY_KEY_PATH=~/keys/notary.p8 NOTARY_KEY_ID=XXXXXXXXXX NOTARY_ISSUER_ID=xxxxxxxx-...
make release                                    # universal, signed, hardened runtime
scripts/notarize.sh "dist/Flexpa Health Bridge.app"
make dmg
scripts/notarize.sh dist/FlexpaHealthBridge-*.dmg
gh release create v0.1.0 --draft --generate-notes dist/FlexpaHealthBridge-*.dmg dist/FlexpaHealthBridge-*.zip
make cask
```

## Verifying a published build

Anyone can check what they downloaded:

```bash
shasum -a 256 FlexpaHealthBridge-0.1.0.dmg          # compare with SHA256SUMS.txt on the release
spctl --assess --type execute --verbose=2 "/Applications/Flexpa Health Bridge.app"
# → accepted, source=Notarized Developer ID
codesign -dv --verbose=4 "/Applications/Flexpa Health Bridge.app" 2>&1 | grep -E 'TeamIdentifier|flags'
# → TeamIdentifier=<Flexpa's team>, flags=0x10000(runtime)
xcrun stapler validate "/Applications/Flexpa Health Bridge.app"
```

## Runner image

The workflows pin `macos-15`. The bridge reads HealthKit's type catalog and canonical units from the SDK on the
build machine, so a newer image picks up new health types automatically. Bump the two `runs-on:` lines together
after a macOS release, and watch for the type-table test, which fails if the SDK stops answering.
