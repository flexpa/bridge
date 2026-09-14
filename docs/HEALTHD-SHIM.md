# Design note: a `healthd`-compatible shim for the Mac

Status: idea, not scheduled. Recorded because it keeps coming up and the measurements are worth keeping.

## The idea

macOS ships the HealthKit client framework but no daemon behind it. A Mac agent could implement the daemon side of
Apple's own XPC interface, fed by the store the bridge already fills from iPhone backups. Then HealthKit-calling code
on the Mac would work unchanged, and if Apple later ships Health for the Mac, their daemon takes over and the shim
steps aside. The user's data path, the bridge's store, and the MCP tools would not change either way.

## What we measured (macOS 26.4.1)

- `HKHealthStore` connects to the mach service `com.apple.healthd.server` in the user's launchd domain through
  `NSXPCConnection`, wrapped by the private `_HKXPCConnection`.
- launchd accepts a user LaunchAgent that vends that name. HealthKit connected to our stand-in 5,231 times in about two
  seconds and invalidated each connection when it called a selector the stand-in did not implement.
- The client stops before connecting unless `isHealthDataAvailable()` is true. That call is a MobileGestalt capability
  check, `healthkit`, which is false on every Mac. Only code that skips the check (ours) would reach a shim. So a shim
  does not make third-party HealthKit apps work on the Mac; it only serves callers that already know they are on a Mac.
- The surface to implement: 158 `HK*` client and server protocols in the runtime. The front door,
  `HKHealthStoreServerInterface`, has 53 methods. Queries, anchors, statistics, authorization, health records, and
  workouts each have their own server protocol with 13 to 20 methods and NSSecureCoding class allowlists.

## The gate

If this is ever built, it must be gated so it never competes with Apple:

1. Register under our own name first (`com.flexpa.healthbridge.healthd`), never `com.apple.healthd.server`, while the
   MobileGestalt `healthkit` flag is false. Our own clients are pointed at our name.
2. If a future macOS turns the flag on, the bridge's provider selection already prefers real HealthKit and the shim is
   not started. No unregistering race, no fight over a name.
3. Only if there is a real consumer that hardcodes Apple's name would name compatibility matter, and that consumer does
   not exist today.

## Why it is not scheduled

The bridge already achieves the seamless-handover property through its provider interface: the `HealthKitProvider` is
written and dormant, and the backup and export providers fill in until Apple's flag flips. The shim would buy the same
handover for an audience of one, our own process, at the cost of reimplementing an undocumented protocol that changes
every September. Revisit when either (a) a Mac app other than ours calls HealthKit and skips the availability check, or
(b) Apple documents the interface.

## If someone wants the research spike anyway

A bounded week, on a branch that never ships in the bridge:

1. Point the client at our name: swizzle `_HKXPCConnection initWithMachServiceName:options:` in a test harness.
2. Declare `HKHealthStoreServerInterface` on an `NSXPCListener` and log every selector and argument class the client
   sends for `initialize`, `requestAuthorization`, one `HKSampleQuery`, and one `HKStatisticsCollectionQuery`.
3. Answer the minimum set from the bridge's SQLite store and see whether `HKQuantitySample` objects round-trip through
   the client's NSSecureCoding allowlist.
4. Write down what broke and how many methods were actually needed. Decide then.
