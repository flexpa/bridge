# HealthKit on macOS: what we measured

The premise for this project was "HealthKit on the Mac is a normal entitlement; the Mac pulls Health data from
iPhone and Watch through iCloud." Half of that is true today.

## Evidence (macOS 26.4.1, build 25E253, Xcode 26 / Swift 6.3, 2026-09-14)

| Check | Result |
| --- | --- |
| `import HealthKit` compiles and links for `arm64-apple-macosx` | Yes. The framework ships in `/System/Library/Frameworks/HealthKit.framework`, `CFBundleSupportedPlatforms = [MacOSX]`. |
| `HKHealthStore.isHealthDataAvailable()` in an unsigned binary | `false` |
| Same, signed with an Apple Development certificate and `com.apple.developer.healthkit` | Process killed at launch (SIGKILL, exit 137): restricted entitlement without a provisioning profile. Expected. |
| A Health app in `/System/Applications` | None |
| `healthd` or any health daemon running | None |
| `~/Library/Health` | Does not exist |
| Private frameworks present | `HealthDaemon.framework`, `HealthKitAdditions.framework`, `SleepHealth.framework`, `CardioHealth.framework` and others exist, so the plumbing is being built, but nothing is populated or exposed. |

## Why signing does not change the answer, and why the hidden override does not either

A fair objection: the probe above never ran with a valid provisioning profile, so maybe the store is gated on the
HealthKit entitlement. And the framework has an override switch, so maybe a user could flip it. We checked the
framework itself in `lldb` on macOS 26.4.1 and then tested both ideas.

```
+[HKHealthStore isHealthDataAvailable]
  → [_HKBehavior sharedBehavior] isiPad ? (require SDK ≥ iPadOS 17) : fall through
  → +[_HKBehavior isDeviceSupported] → +[_HKBehavior _isDeviceSupported]
      → MGGetBoolAnswer("healthkit")                     MobileGestalt device capability
          true  → supported
          false → +[_HKBehavior _isAppleInternalInstall]
                    = os_variant_has_internal_diagnostics("com.apple.HealthKit")
                    true  → honor NSUserDefaults kHKInternalSettingsOverrideDeviceSupported
                    false → not supported
```

Nothing in that path reads entitlements, the code signature, or a provisioning profile. Measured on this Mac
(`Mac17,6`):

| Check | Result |
| --- | --- |
| `MGGetBoolAnswer("healthkit")` | `0` (for comparison `wifi` = 1, `bluetooth` = 1) |
| `os_variant_has_internal_diagnostics("com.apple.HealthKit")` | `0`, so the override key is never read on a customer install |
| `defaults write com.flexpa.hkprobe kHKInternalSettingsOverrideDeviceSupported -bool YES` then run | still `false`; query fails `com.apple.healthkit` code 1, "Health data is unavailable on this device" |
| Force the capability result to `1` in the debugger (register write after the MobileGestalt call), then run a real `HKSampleQuery` and `requestAuthorization` | `isHealthDataAvailable` reports `true`, then both calls fail with `NSCocoaErrorDomain` 4099, "Couldn't communicate with a helper application" |
| launchd services or processes for a HealthKit daemon | none in the system or user domain; only Screen Time's `digitalhealth-idswake` matches the word |

The last two rows are the point. Even with the gate defeated, `HKHealthStore` opens an XPC connection to the
HealthKit daemon, and there is no daemon on macOS to answer. A signed, entitled, provisioned build would launch and
then land on the same error. Projects that claim native macOS HealthKit access (for example RyanLisse/Vitalink) guard
on `isHealthDataAvailable()` and throw; their own troubleshooting notes list "HealthKit not available" as the
expected failure on a Mac, and the System Settings Health pane their README mentions does not exist.

## Could we register our own daemon?

Yes at the launchd level, and it still does not help. With the gate forced open, `HKHealthStore` connects to the
mach service `com.apple.healthd.server` in the user's launchd domain through `NSXPCConnection`. We registered a
throwaway LaunchAgent that vends that name (launchd accepts a `com.apple.` name from a user agent), ran the probe, and
watched HealthKit connect to our process: 5,231 connections in about two seconds, each one invalidated as soon as the
client called a selector our dummy interface did not declare (the client-side error changes from 4099, no service, to
4097, connection invalidated). The agent was removed afterwards.

To keep those connections alive you would implement Apple's private XPC surface. The runtime lists 158 `HK*` client
and server protocols; the front door alone, `HKHealthStoreServerInterface`, has 53 methods, and queries, authorization,
health records, and workouts each have their own server protocols with 13 to 20 methods and NSSecureCoding class
allowlists. That is a reimplementation of `healthd` against an undocumented protocol that changes every OS release, and
it would still have no data: the samples live on the iPhone, and nothing syncs them to a Mac. A fake `healthd` is a
database we fill ourselves behind a private API, which is what the bridge's own SQLite store already is behind a public
one. The only party it would serve is other Mac software that calls HealthKit, and there is none, because HealthKit
does not work on the Mac.

Conclusion: on the current macOS release there is no Health data store to read. The framework is present so that
Mac Catalyst and shared code compile; the store reports unavailable. iCloud does not sync Health data to the
Mac because there is no consumer of it there.

## What this means for the bridge

* `HealthKitProvider` is fully implemented against the public API (`HKSampleQuery`, `HKStatisticsCollectionQuery`,
  characteristics, workouts via `allStatistics`, `HKClinicalRecord` FHIR payloads). It reports
  `authorization: unavailable` today and needs no changes when Apple ships Health for Mac.
* `HealthExportProvider` gives real data now. The Health app's **Export All Health Data** zip contains
  `export.xml` (every sample, workout, and characteristic) plus `clinical-records/*.json` (FHIR R4). The importer
  streams it into SQLite; a multi-year export with millions of rows imports in a minute or two.
* The MCP tool surface is identical across providers, so agents and prompts written against export data keep
  working against live HealthKit.

## What the Mac's HealthKit framework is still good for

The framework cannot reach a store, but it knows Apple's internal type codes. `-[HKObjectType code]` (private) returns
the integer used as `samples.data_type` in the on-device database: steps 7, heart rate 5, body mass 3, sleep 63,
workouts 79, time in daylight 279. The backup importer asks the framework for every identifier's code at import time,
which is how it stays correct across iOS releases without a hand-maintained table. See `docs/BACKUP-IMPORT.md`.

## If the data must be live

1. **Mac (future):** ship this app as is; flip on when `isHealthDataAvailable()` becomes true.
2. **iPhone app in the App Store:** the same `HealthBridgeCore` compiles for iOS with small changes (no libproc,
   no menu bar). Review Guideline 5.1.3 applies. A phone-resident MCP server needs a reachability story
   (Tailscale, Bonjour on the LAN) and is out of scope here.
3. **Third-party sync apps** exist that push HealthKit to a server; that moves PHI off-device and is not what
   this project is for.

## Re-checking

```bash
cat > /tmp/probe.swift <<'SWIFT'
import HealthKit
print(HKHealthStore.isHealthDataAvailable())
SWIFT
swiftc /tmp/probe.swift -framework HealthKit -o /tmp/probe && /tmp/probe
```
