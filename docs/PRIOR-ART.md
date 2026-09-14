# Prior art: Apple Health to agents, and how others get data off the iPhone

Surveyed 2026-09-14. Links are to the repositories; stars and dates are as seen that day.

## 1. Apple Health MCP servers

All of the general-purpose ones read the Health app's `export.xml`. None reads HealthKit live on a Mac,
because none can.

| Project | Stack | Data source | Transport / auth | Notes |
| --- | --- | --- | --- | --- |
| [davidmosiah/apple-health-mcp](https://github.com/davidmosiah/apple-health-mcp) | TypeScript, MIT | `export.xml` / `.zip` / folder, streamed at ~33 ms per MB, memoised after first read | stdio; optional loopback HTTP on 3000; no auth | Tools: connection status, data inventory, daily and weekly summary, list records, list workouts, reimport. "Privacy mode" returns aggregates by default. Good tool vocabulary. |
| [neiltron/apple-health-mcp](https://github.com/neiltron/apple-health-mcp) | local-first | export files in place | stdio | Sleep, workouts, activity, heart. |
| [the-momentum/apple-health-mcp-server](https://github.com/the-momentum/apple-health-mcp-server) | Python, FastMCP, DuckDB, MIT | `export.xml` | stdio | Natural-language record search over DuckDB. Superseded by Open Wearables (below). |
| [PhilipAD/health-export-mcp](https://github.com/PhilipAD/health-export-mcp) | Node, zero dependencies, MIT | `.health-cache.json` written by the paid **MetricBridge** iOS app | stdio; optional `PAIRING_SECRET`; minisign-signed releases | 190 metrics, 14 tools including trends, compare periods, correlate metrics, cycle context, intraday. Closest thing to a product. |
| [salgado/apple-watch-health-mcp](https://github.com/salgado/apple-watch-health-mcp) | Python, Elasticsearch | sample step data | stdio | Demo. |
| [RyanLisse/Vitalink](https://github.com/RyanLisse/Vitalink) | Swift, MIT, 1 commit (Jan 2026) | claims live HealthKit on macOS 26 | stdio | **Does not work.** We read the source: every path guards on `isHealthDataAvailable()` and throws "HealthKit not available"; the only test is a placeholder; the README points at a System Settings Health pane that does not exist on macOS. Treat as aspirational. |

Adjacent: [davidmosiah/fitbitmcp](https://github.com/davidmosiah/fitbitmcp) and
[google-health-mcp](https://github.com/davidmosiah/google-health-mcp) (OAuth to vendor clouds),
[Frenck12/whoop-mcp-server](https://glama.ai/mcp/servers/@Frenck12/whoop-mcp-server), and
[the-momentum/open-wearables](https://github.com/the-momentum/open-wearables) (MIT, 2.5k stars): a self-hosted
FastAPI + Postgres platform that unifies Garmin, Whoop, Oura, Fitbit, Polar, Suunto and Strava, ships an iOS SDK that
pushes HealthKit data to the server, and exposes an MCP server.

## 2. Export parsers

The `export.xml` streaming problem is well trodden. Our importer follows the same shape (streaming parser, batched
SQLite transactions, canonical units).

- [dogsheep/healthkit-to-sqlite](https://github.com/dogsheep/healthkit-to-sqlite): Simon Willison's original (2019),
  Python, one table per record type. [Write-up](https://simonwillison.net/2019/Jul/22/healthkit-sqlite/).
- [jshrake/healthkit-to-sqlite](https://github.com/jshrake/healthkit-to-sqlite): Rust CLI.
- [BRO3886/healthsync](https://github.com/BRO3886/healthsync): Go, constant ~10 MB memory on 950 MB exports, 1000-row batches, pure-Go SQLite.
- [alxdrcirilo/apple-health-parser](https://github.com/alxdrcirilo/apple-health-parser): Python analysis and plotting.

## 3. Getting live data off the iPhone

This is the part that matters for a Flexpa companion app. Three patterns exist.

### 3a. Commercial exporter apps push to wherever you point them

- **Health Auto Export** (HealthyApps, subscription). Exports 150+ metrics as JSON, CSV, GPX to iCloud Drive, Dropbox,
  Google Drive, a REST API, MQTT, Home Assistant, Calendar, Email. Its **Sync to Mac** feature moves data through
  **iCloud Drive** (`iCloud Drive/Auto Export/AutoSync`) to a Mac viewer app, and Apple approved it. That is a data
  point on Guideline 5.1.3(ii): user-directed files in the user's own iCloud Drive appear to pass review, even though
  the rule says health data may not be stored in iCloud. Storing it in the developer's CloudKit container is the
  clearer violation. Docs: [Sync to Mac](https://help.healthyapps.dev/en/health-auto-export/sync-to-mac/),
  [JSON format](https://help.healthyapps.dev/en/health-auto-export/export-format) (top level `data.{metrics, workouts,
  stateOfMind, medications, symptoms, cycleTracking, ecg, heartRateNotifications}`, dates as `yyyy-MM-dd HH:mm:ss Z`,
  the same stamp format as `export.xml`). Receivers people have written:
  [irvinlim/apple-health-ingester](https://github.com/irvinlim/apple-health-ingester) (Go → InfluxDB),
  [joeecarter/health-import-server](https://github.com/joeecarter/health-import-server),
  [HealthyApps/health-auto-export-server](https://github.com/HealthyApps/health-auto-export-server) (Grafana),
  [po4yka/apple-health-export-automation-backup](https://github.com/po4yka/apple-health-export-automation-backup)
  (FastAPI → InfluxDB → Grafana, AI weekly reports).
- **MetricBridge** (Philip D'Souza, one-time purchase, [App Store](https://apps.apple.com/app/id6784185201)). Exports
  190 metrics as JSON to iCloud Drive, a local folder, a **LAN HTTP or WebSocket endpoint**, or a webhook with a token.
  Background auto-export fires when new samples arrive. Pairs with health-export-mcp above.

Implication: the Mac bridge could accept Health Auto Export or MetricBridge pushes on the LAN today. Users who
already own one of those apps would get live data without a Flexpa iOS app.

### 3b. Open-source iOS sync apps

| Project | Direction and transport | Sync engine | Security | Status |
| --- | --- | --- | --- | --- |
| [mneves75/ai-health-sync-ios](https://github.com/mneves75/ai-health-sync-ios) | **iPhone is the server**: runs a TLS 1.3 HTTP server; Mac CLI discovers it over Bonjour | Manual `healthsync fetch`; no background delivery yet | QR code carries host, port, certificate fingerprint, short-lived pairing code; then bearer token; CLI refuses non-private IP ranges | Apache-2.0, v1.0 Feb 2026, 43 stars, 39 tests |
| [leafhao/health-tracker](https://github.com/leafhao/health-tracker) | **Mac/NAS is the receiver**; first sync over LAN, daily syncs via S3/WebDAV as an encrypted buffer | HealthKit background delivery + anchored queries; Shortcuts triggers (arrive home, Wi-Fi, charging); idempotent ingest | End-to-end: receiver X25519/HPKE key + Ed25519 identity, phone Ed25519 identity; plaintext only on iPhone and in the receiver's SQLite; loopback REST "agent API" hides raw metadata and routes | MIT, v0.1 beta |
| [kempu/HealthBeat](https://github.com/kempu/HealthBeat) | iPhone writes straight to **MySQL** over the wire protocol | Observer queries (immediate), BGProcessingTask (~15 min), manual; UUID dedupe with INSERT IGNORE; 85 quantity + 22 category types, workouts with routes, ECG, BP pairs, audiograms, activity summaries | MySQL auth only | MIT, tiny, but the sync engine is the reference others fork |
| [domonkospapp/FreeReps](https://github.com/domonkospapp/FreeReps) | iPhone (HealthBeat fork, on the App Store) pushes to a Go server over **Tailscale** | Full backfill then incremental; observer + BGProcessingTask; Live Activity progress | Identity and TLS from the tailnet, no passwords | MIT, 188 commits, Postgres + TimescaleDB, MCP tools (`get_health_metrics`, `get_workouts`, `get_sleep_data`, `get_metric_stats`, `get_correlation`, `compare_periods`, `list_available_metrics`), stdio or SSE via mcp-proxy, Oura merge with source priority |
| [StanfordSpezi/SpeziHealthKit](https://github.com/StanfordSpezi/SpeziHealthKit) | library | Background delivery, bulk collection, query property wrappers, FHIR mapping | n/a | MIT, Stanford BDHG, CI, DOI |
| [StanfordBDHG/HealthGPT](https://github.com/StanfordBDHG/HealthGPT) | agent **on the phone**: OpenAI, on-device Llama 3 8B, or a LAN "fog node" | Reads 14 days of aggregates via SpeziHealthKit | n/a | MIT, TestFlight, experimental |

[Artem Novichkov's post](https://artemnovichkov.com/blog/using-model-context-protocol-in-ios-apps) embeds an MCP
server inside an iOS app, but the client is the same app. Nobody has shipped a phone-resident MCP server that a
desktop agent talks to, because iOS suspends it.

### 3c. What this says about the Flexpa companion

1. **Direction.** Mac (or receiver) as server, phone as client, as in health-tracker and FreeReps. The phone-as-server
   design (ai-health-sync) fights iOS background limits.
2. **Sync engine.** HealthBeat's trio is the proven recipe: observer queries with background delivery, a
   BGProcessingTask safety net, manual sync, and HealthKit UUID deduplication. SpeziHealthKit is a maintained
   alternative base with FHIR mapping, which suits Flexpa.
3. **Pairing.** ai-health-sync's QR payload (host, port, certificate fingerprint, short-lived code) is the right
   shape. health-tracker's key exchange (receiver public key never leaves the pairing screen) is the right property.
4. **Off-LAN.** health-tracker shows a blind relay: the cloud holds ciphertext only, the receiver decrypts. That is
   the pattern for an optional Flexpa relay. Health Auto Export shows Apple tolerates user-directed iCloud Drive files.
5. **Interim.** Accepting Health Auto Export and MetricBridge webhooks costs a parser and buys live data now.

## 4. Local server security prior art

- The MCP spec's [Streamable HTTP security warning](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports):
  servers MUST validate `Origin`, SHOULD bind to 127.0.0.1, SHOULD authenticate every connection, and session IDs
  SHOULD be cryptographically secure. Health Bridge does all four. Most export-based MCP servers rely on stdio and
  have no auth at all, which is fine for stdio and wrong for HTTP.
- [GodModeAI2025/AppleMCP issue #9](https://github.com/GodModeAI2025/AppleMCP/issues/9) proposes exactly our
  mechanism for a Unix-socket MCP server that fronts Mail and Voice Memos: `LOCAL_PEERPID` or `LOCAL_PEERTOKEN`, then
  `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`, 403 on mismatch. It lists the same costs we hit:
  signing becomes mandatory for clients, PID reuse is a race, and `curl` testing breaks. Our answers: bind on first
  use instead of pinning a fixed identity, allow but do not bind ad-hoc binaries, expose a reset.
  [dhkts1/teamclaude-rs PR #263](https://github.com/dhkts1/teamclaude-rs/pull/263) implements peer signature checks
  before handing over a socket.
- Apple DTS in [forum thread 744791](https://developer.apple.com/forums/thread/744791): prefer declarative code-signing
  requirements on XPC listeners; programmatic checks belong to services reachable outside the app's namespace; audit
  tokens beat PIDs. TCP loopback has no audit token, which is why we map port to pid. A Unix-socket transport plus a
  stdio shim would let us use `LOCAL_PEERTOKEN`; that is a v2 option, traded against shipping a shim.
  Background: [Audit tokens explained](https://knight.sc/reverse%20engineering/2020/03/20/audit-tokens-explained.html),
  [HackTricks on XPC connecting-process checks](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-proces-abuse/macos-ipc-inter-process-communication/macos-xpc/macos-xpc-connecting-process-check/index.html).

## 5. What is not out there

Nothing surveyed combines a notarized Mac menu bar app, Streamable HTTP MCP with per-agent tokens bound to code
signatures, a visible audit log, and FHIR clinical records from the export. Ideas worth borrowing into our tool set:
`compare_periods`, `get_correlation`, trend summaries, a data inventory call, and an aggregate-only privacy mode.

## 6. Agent bridges that talk to an iPhone

Asked separately: does anything let a desktop agent talk to iOS directly? Four kinds exist, and one of them
already carries health data.

| Project | How the agent reaches the phone | What it can do | Health data? |
| --- | --- | --- | --- |
| [OpenClaw iOS app](https://docs.openclaw.ai/platforms/ios) (App Store) | Phone is a "node": WebSocket to a Gateway on a Mac, Linux or Windows machine; Bonjour on the LAN, unicast DNS-SD over a tailnet, or manual host and port; QR or setup-code pairing; bearer tokens, plain-HTTP LAN links are restricted | Screen snapshot, camera, location, talk mode, voice wake | **Yes, narrowly:** an opt-in, read-only HealthKit aggregate for the current calendar day, gated by iOS consent and by Gateway authorization. Camera and screen need the app in the foreground; background is best effort via refresh and silent push. |
| [jfarcand/mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) (Apache-2.0, 221 stars), [teddyoweh/iphone-mcp](https://glama.ai/mcp/servers/teddyoweh/iphone-mcp), [iphone-mirror-mcp](https://mcpservers.org/servers/nickatnight96/iphone-mirror-mcp) | macOS **iPhone Mirroring**: capture the mirrored window, Apple Vision OCR or a CoreML detector to find targets, inject input through Accessibility or a virtual HID | 33 tools: describe screen, tap, swipe, type, launch app, record reusable "skills"; fail-closed permissions, sensitive apps blockable | Only what is on screen. The agent can open the Health app and read charts visually. No structured data, and the register of limitations flags Health as needing special flows. |
| [mobile-next/mobile-mcp](https://github.com/mobile-next/mobile-mcp), [UgeeCodes/iOS-agent-bridge](https://github.com/UgeeCodes/iOS-agent-bridge) (MIT) | Developer tooling: XCUITest instrumentation (WebDriverAgent, now iOS Device Kit) over USB or CoreDevice tunnels; needs Xcode, Developer Mode, a signing identity | Accessibility-tree snapshots compressed to a few hundred tokens, taps, swipes, typing, launch, lock | UI only. Built for QA automation, not data access. |
| Agent on the phone: [StanfordBDHG/HealthGPT](https://github.com/StanfordBDHG/HealthGPT); MCP server in-app per [Artem Novichkov](https://artemnovichkov.com/blog/using-model-context-protocol-in-ios-apps); the official [swift-sdk NetworkTransport](https://github.com/modelcontextprotocol/swift-sdk/blob/main/Sources/MCP/Base/Transports/NetworkTransport.swift) runs a TCP MCP server on iOS | n/a, the client is also on the phone or on the LAN while the app is open | Full HealthKit through the app's own grant | Yes, but only while the app is in the foreground. iOS suspends the listener otherwise. |

Apple's own bridge does not exist yet. Strings in the iOS 26.1 and macOS 26.1 betas (September 2025) tie MCP into
App Intents, which would let external agents call app actions system-wide
([9to5Mac](https://9to5mac.com/2025/09/22/macos-tahoe-26-1-beta-1-mcp-integration/),
[AppleInsider](https://appleinsider.com/articles/25/09/22/ios-26-could-get-a-major-ai-boost-with-the-model-context-protocol)).
At WWDC 2026 Apple shipped MCP only for Xcode (the `mcpbridge` binary in Xcode 26.3 and 27), not for App Intents or
end users ([The Omni Group, July 2026](https://www.omnigroup.com/blog/omni-roadmap-2026-post-wwdc-update)). When it
does ship, a Flexpa iOS app could expose Health-reading App Intents and inherit Apple's consent UI instead of running
its own listener.

Takeaway for Flexpa: the only shipped bridge that hands an agent structured health data from an iPhone is the
OpenClaw node, and it stops at one day of aggregates. Every other route either scrapes the screen or needs a
developer-signed test harness. The companion-app design in section 3c is still the gap.

## 7. Prior art for the backup approach

Nobody has shipped "decrypt the Finder backup, read the Health store, serve it to agents" as one product, but every
piece exists in the open, and the forensic community has mapped the database for years.

**Backup decryption (all reimplement the same iphone-dataprotection research).**

| Project | Language, license | Notes |
| --- | --- | --- |
| [jsharkey13/iphone_backup_decrypt](https://github.com/jsharkey13/iphone_backup_decrypt) | Python, 383 stars, active Sept 2026 | Reference implementation. Two-stage PBKDF2 (SHA-256 with DPSL/DPIC, then SHA-1 with SALT/ITER), class-key unwrap, Manifest.db then per-file keys. Its changelog notes the Health database once needed twice its size in RAM; ours streams. |
| [avibrazil/iOSbackup](https://github.com/avibrazil/iOSbackup) | Python, 282 stars | Friendlier API, "compatible with iOS 26". |
| [dunhamsteve/ios](https://github.com/dunhamsteve/ios) | Go, 152 stars | Files and keychain from backups. |
| [novkostya/ios-backup-crypt](https://github.com/novkostya/ios-backup-crypt) | Go, MIT, Aug 2026 | Library form. |
| [agordon/iOS_backup_decode](https://github.com/agordon/iOS_backup_decode) | scripts | Older; libimobiledevice backups. |

Our `BackupDecryptor` follows the same format and was validated against a synthetic backup built with the real
on-disk layout. A run against a real backup is still the missing proof.

**Reading `healthdb_secure.sqlite`.**

| Project | What it contributes | Where it stops |
| --- | --- | --- |
| [christophhagen/HealthDB](https://github.com/christophhagen/HealthDB) (Swift, 13 stars, iOS 16 and 17, no license) | The closest thing to our reader: quantity, category, workouts with activities and statistics, ECG, routes, sleep schedules. | Hardcodes `data_type` codes in a bidirectional enum and says so: "Sample types internally use integer IDs, so it's difficult to figure out all assignments." Expects an already-decrypted file. |
| [abrignoni/iLEAPP](https://github.com/abrignoni/iLEAPP) (Python, MIT, 1.3k stars, active) | Forensic parser used in court. Its `health.py` documents the joins we rely on: `objects.provenance → data_provenances.ROWID → healthdb.sources`, `workout_activities.owner_id → workouts.data_id`, `workout_statistics.workout_activity_id`, and the filter `objects.type != 2` for deletions. Also the fact that heart rate is stored as count per second (`quantity * 60`). | Hardcoded codes (2 height, 3 weight, 5 heart rate, 7 steps, 63 sleep, 70 stand, 118 resting HR, 173 headphone audio, 256 wrist temperature). Unit conversions hand-written per query. |
| [mac4n6/APOLLO](https://github.com/mac4n6/APOLLO) (Python, 651 stars) | SQL modules for steps, distance, flights, heart rate, weight, workouts. | Same hardcoding. |
| [Forensic timeline investigation of Apple Health app on iOS](https://pmc.ncbi.nlm.nih.gov/articles/PMC13534974/) (2026, peer reviewed) | Documents schema reorganisations at iOS 13.3.1, 13.4.1, 15.3.1, 16.1.2, and 17.3, including the iOS 16 move to `workouts_latest` and the iOS 17.3 five-stage sleep. | Confirms the drift problem; offers no mechanism to track it. |
| [DFIR Review: Apple Watch data in healthdb_secure.sqlite](https://dfir.pubpub.org/pub/xqvcn3hj) | Case study on heart rate and activity extraction. | |

**What is new in ours.** Every prior reader hardcodes Apple's integer codes and Apple's storage units, and every author
complains about it. Health Bridge asks the HealthKit framework on the Mac for both: `-[HKObjectType code]` for the
`data_type` integer and `-[HKQuantityType canonicalUnit]` for the unit `quantity` is stored in. Cross-checked on
2026-09-14: every code iLEAPP and HealthDB hardcode matches what the framework returns (height 2, weight 3, heart rate
5, steps 7, sleep 63, stand 70, resting HR 118, headphone audio 173, wrist temperature 256, BMI 0, daylight 279), and
the framework's canonical units explain the forensic folklore (heart rate `count/s`, resting heart rate `count/min`,
HRV `ms`, SpO2 as a fraction). Because the macOS SDK gains new types the same year iOS does, the tables track Apple
without a maintainer.
