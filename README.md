# Flexpa Health Bridge

[![CI](https://github.com/flexpa/bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/flexpa/bridge/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/flexpa/bridge?sort=semver)](https://github.com/flexpa/bridge/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small, signed macOS menu bar app that exposes your Apple Health data to AI agents on the same Mac through a
[Model Context Protocol](https://modelcontextprotocol.io) server. Read-only. Loopback only. Every agent is paired
explicitly, and every request is logged.

```
 iPhone / Watch ──iCloud──▶ Health ──▶ HealthKit ──┐
                                                    ├──▶ Health Bridge (menu bar) ──127.0.0.1──▶ Claude Code, Claude Desktop, Cursor …
 Health app export.zip ──▶ import ──▶ SQLite ───────┘        bearer token + code-signature binding
```

## Status: what works today

| Piece | State |
| --- | --- |
| Menu bar app, pairing, audit log, settings | Working |
| MCP server (Streamable HTTP, 10 read-only tools) | Working, tested end to end |
| Per-agent bearer tokens, locked to the first signed app that uses them | Working |
| Health app export import (export.zip → local SQLite) | Working |
| Encrypted iPhone backup import (full Health store, no iOS app) | Working. Verified against a real iOS 26.6 backup: 2.4M samples, 1,071 workouts, ten years of history. See [docs/BACKUP-IMPORT.md](docs/BACKUP-IMPORT.md). |
| Live HealthKit on macOS | **Blocked by Apple.** `HKHealthStore.isHealthDataAvailable()` returns `false` through macOS 27, and there is no Health data store on the Mac. The code path is complete and becomes live when Apple ships one. See [docs/HEALTHKIT-ON-MACOS.md](docs/HEALTHKIT-ON-MACOS.md). |
| Signed, notarized releases + Homebrew | Automated by CI on tag. Needs Flexpa's Developer ID certificate and notary key in repository secrets. See [docs/RELEASING.md](docs/RELEASING.md). |
| iOS companion app for live sync | Designed, not built. See [docs/APP-STORE.md](docs/APP-STORE.md). |

Until Apple turns HealthKit on for the Mac, real data comes from the iPhone in one of two ways:

- **Encrypted Finder backup** (preferred): the complete on-device Health store, refreshed whenever the phone backs up.
  **Import from iPhone Backup…** in the panel. Needs Full Disk Access and the backup password.
- **Health app export**: Health → profile picture → **Export All Health Data** → AirDrop `export.zip` to the Mac →
  **Import Health Export…**. Brings clinical records (FHIR) too.

Both stream into the same SQLite store and serve the same MCP tools.

## Install

```sh
brew install --cask flexpa/tap/flexpa-health-bridge
```

Or download the notarized DMG from [the latest release](https://github.com/flexpa/bridge/releases/latest) and drag
the app to Applications. Requires macOS 14 or later, Apple silicon or Intel.

Then:

1. Click the Flexpa mark in the menu bar.
2. **Import from iPhone Backup…** (needs an encrypted Finder backup and Full Disk Access; the app walks you
   through it) or **Import Health Export…** if you have an `export.zip`.
3. **Pair Agent**, and paste the config it gives you into Claude Code, Claude Desktop, Cursor, or any MCP client.

Ask the agent: *"Call health_status, then summarize my last week of sleep and steps."*

## Quick start (developer)

```bash
make app        # builds dist/Flexpa Health Bridge.app, ad-hoc signed
make run        # launches it; the Flexpa mark appears in the menu bar
make test       # 72 tests: HTTP parser, auth, MCP protocol, backup decryption, import, math
make help       # every target
```

Releases are cut by tagging; see [docs/RELEASING.md](docs/RELEASING.md).

Pair an agent from a terminal instead of the panel:

```bash
"dist/Flexpa Health Bridge.app/Contents/MacOS/HealthBridge" --pair "Claude Code"
# prints a one-time token plus ready-to-paste configs, e.g.
claude mcp add --transport http health-bridge http://127.0.0.1:4271/mcp --header "Authorization: Bearer hkb_…"
```

Then ask the agent: *"Call health_status, then summarize my last week of sleep and steps."*

## Tools

`health_status` · `list_health_types` · `get_samples` · `get_statistics` · `get_latest` · `get_sleep` ·
`get_workouts` · `get_daily_summary` · `get_characteristics` · `get_clinical_records`

Full reference with arguments and examples: [docs/MCP.md](docs/MCP.md).

## Security model in one paragraph

The server binds to `127.0.0.1` only and refuses requests whose `Host` or `Origin` is not loopback (no DNS
rebinding, no browser pages). Every request needs a bearer token created in the app; only a SHA-256 hash is
stored. On the first successful request the bridge identifies the calling process through `libproc` and the
macOS code-signing APIs and **locks the token to that app's signing identity** (Team ID, or Apple platform
identifier). A token copied out of a config file stops working from any other program, and requests from a
different macOS user account can never be verified and are refused. Everything is written to an append-only
audit log you can open from the panel. Details, threat model, and the auth options we considered (including
why not OAuth for v1): [docs/SECURITY.md](docs/SECURITY.md).

## Distribution

Outside the Mac App Store: Developer ID certificate, hardened runtime, notarization, stapled DMG and zip on GitHub
releases, plus a Homebrew cask. Shipping builds carry no entitlements, so no provisioning profile is involved.
Tagging `v*` runs the whole pipeline. See [docs/RELEASING.md](docs/RELEASING.md) for the runbook,
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) for what the scripts do, and [docs/APP-STORE.md](docs/APP-STORE.md)
for why the Mac App Store is the wrong channel for this app and where an App Store release actually belongs.

## Layout

```
Package.swift                 SwiftPM, no Xcode project
Sources/CLibProc              libproc shim: loopback peer port → pid
Sources/HealthBridgeCore      everything testable
  Models/                     type catalog (60+ HealthKit identifiers), samples, sleep, workouts, FHIR records
  Providers/                  HealthKitProvider · HealthExportProvider (+ importer, shared store writer) · DemoHealthProvider
  Backup/                     iPhone backup locator, keybag + AES decryptor, healthdb reader, framework-derived type codes
  Server/                     HTTP/1.1 on Network.framework, peer identification (SecCode)
  MCP/                        JSON-RPC, Streamable HTTP, tool definitions
  Auth/ Audit/                pairings (hashed tokens, binding), JSONL audit log
  BridgeService.swift         composition root observed by the UI
Sources/HealthBridge          SwiftUI MenuBarExtra app + `--pair/--list/--revoke/--import` CLI
Packaging/                    Info.plist, entitlements
scripts/                      build-app.sh, notarize.sh, make-dmg.sh, update-cask.sh, make-icon.swift
Tests/                        XCTest suite: Health export fixture and a synthetic encrypted iPhone backup
docs/                         SECURITY, RELEASING, DISTRIBUTION, APP-STORE, MCP,
                              HEALTHKIT-ON-MACOS, BACKUP-IMPORT, PRIOR-ART, HEALTHD-SHIM
```

State lives in `~/Library/Application Support/HealthBridge/` (`pairings.json`, `settings.json`, `audit.jsonl`,
`health-export.sqlite`), all `0600`. Set `HEALTHBRIDGE_HOME` to relocate it.

## Prior art

Export-based MCP servers, iPhone sync apps, and local-server security patterns we compared against:
[docs/PRIOR-ART.md](docs/PRIOR-ART.md).

## Contributing

Issues and pull requests are welcome. `make test` must pass, and CI runs the same suite plus a release-configuration
bundle build on every pull request. Security issues go through [SECURITY.md](SECURITY.md) rather than the issue
tracker.

## Requirements

macOS 14 or later to run. Xcode 16+ (or Command Line Tools with a recent Swift) to build.

## License

MIT. See [LICENSE](LICENSE).
