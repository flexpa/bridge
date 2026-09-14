# The App Store question

"Ship it on the App Store" means two different projects depending on which store. The short version: the **iOS
companion app is the App Store target**, and the Mac App Store is a poor fit for the bridge itself.

## Mac App Store: three real blockers

The Mac App Store requires the App Sandbox. That single requirement breaks three things the bridge depends on.

**1. The security model stops working.** Pairing tokens are bound to the calling process's code-signing identity,
which the bridge establishes with `proc_pidinfo` over the caller's sockets and `SecCodeCopyGuestWithAttributes`.
A sandboxed process cannot inspect other processes that way. Without it, a token copied out of an agent's config
file works from any program on the machine, which is exactly the attack the binding exists to stop. See
[SECURITY.md](SECURITY.md).

**2. Private API is an automatic rejection.** Guideline 2.5.1 forbids it, and the bridge deliberately calls two
private selectors: `-[HKObjectType code]` for Apple's internal type integers and `-[HKQuantityType canonicalUnit]`
for the unit each quantity is stored in. Those calls are what keep the backup reader correct across iOS releases
without a hand-maintained table — the exact problem every other open-source reader has. A Mac App Store build
would fall back to the seed tables and inherit that maintenance burden. See [BACKUP-IMPORT.md](BACKUP-IMPORT.md).

**3. Full Disk Access is not available to sandboxed apps.** There is no entitlement for it. A sandboxed build
would have to ask the user to select the backup folder in an open panel and keep a security-scoped bookmark.
That may work for `~/Library/Application Support/MobileSync/Backup`, but it is unverified, and it turns a
one-switch flow into a file-picker hunt.

Loopback serving itself is fine on the Mac App Store with `com.apple.security.network.server`.

**Conclusion:** Developer ID and notarization, which is what the release workflow already does, is the right
distribution channel for the Mac app. Direct download and Homebrew reach the developer audience that runs local
agents. Revisit only if Apple makes peer code-signature checks available to sandboxed apps.

## iOS: the App Store target that matters

HealthKit only has a data store on the iPhone, so live health data requires an iOS app. That work is already
designed as a node in the Flexpa monorepo — see `docs/decisions/11-healthkit-bridge.md` on the
`feat/healthkit-bridge` branch — and it has somewhere to land: `apps/app` is already on the App Store as **Flexpa**
(`ascAppId` 6761062773), already declares health data in its privacy manifest, and already ships through EAS.

What it adds: a Swift Expo module that reads HealthKit with background delivery and anchored queries, and pushes
incremental batches to the Mac bridge over the local network. The Mac stays the gateway; the phone is a push-only
node.

### What App Review will look at

- **Guideline 5.1.3 (Health and Health Research).** The app must have a clear health purpose, must not write false
  data into HealthKit, and **may not store health data in iCloud**. The direct-to-Mac design satisfies that: data
  moves phone → Mac over the LAN and stops there. Any future Flexpa-hosted sync must be a separate, explicit
  opt-in, never the default.
- **Purpose strings.** `NSHealthShareUsageDescription`, `NSHealthClinicalHealthRecordsShareUsageDescription`, and
  `NSLocalNetworkUsageDescription` all need to say plainly what the data is used for and where it goes.
- **Privacy nutrition label.** Health data, linked to the user, app functionality only, not used for tracking.
- **A reviewer needs to be able to test it.** They will not have a Mac running the bridge. Ship a demonstrable
  path that works without one: an in-app view of what would be shared, or a loopback self-test.

Expect at least one round trip. Budget for it.

### Suggested sequence

1. Ship the Mac bridge (Developer ID, Homebrew). Backup import already gives it real data.
2. Build the iOS module behind a feature flag; validate on a development build.
3. TestFlight — up to 10,000 external testers, lighter Beta App Review — with Flexpa customers.
4. Submit to the App Store once the sync engine has survived real phones.

Full design, milestones, and open questions are in the monorepo decision record.
