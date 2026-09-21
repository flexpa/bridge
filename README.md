# Flexpa Health Bridge

[![CI](https://github.com/flexpa/bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/flexpa/bridge/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/flexpa/bridge?sort=semver)](https://github.com/flexpa/bridge/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small macOS menu bar app that exposes your Apple Health data to AI agents on the same Mac through a
[Model Context Protocol](https://modelcontextprotocol.io) server. Read-only. Loopback only. Every agent is paired
explicitly, and every request is logged.

```
 iPhone / Watch ──iCloud──▶ Health ──▶ HealthKit ──┐
                                                    ├──▶ Health Bridge (menu bar) ──127.0.0.1──▶ Claude Code, Claude Desktop, Cursor …
 Health app export.zip ──▶ import ──▶ SQLite ───────┘        bearer token + code-signature binding
```

> ### This is a research project
>
> Flexpa built this to answer one question: **can an agent read a person's Apple Health data on a Mac, safely,
> without sending it anywhere?** The answer turned out to be yes, but not the way we expected. Apple does not ship
> a Health data store on macOS, so the bridge reads the iPhone's own store out of an encrypted local backup
> instead. [docs/HEALTHKIT-ON-MACOS.md](docs/HEALTHKIT-ON-MACOS.md) records how we proved that, down to the
> disassembly.
>
> Treat it accordingly:
>
> - It is **not a supported Flexpa product**. There is no SLA, no roadmap commitment, and no guarantee that the
>   next version keeps today's interfaces.
> - It handles **your complete medical history**. Read [docs/SECURITY.md](docs/SECURITY.md) before you pair
>   anything with it, and understand that an agent you pair can read all of it.
> - It has **not had an external security audit**. It has had adversarial review, a threat model, and a test
>   suite. That is not the same thing.
> - It reads Apple's backup format through **private, undocumented APIs**. Apple can change them in any release.
>
> Published under MIT so others can check the findings and reuse the parts. Issues and pull requests welcome.

## Status: what works today

| Piece | State |
| --- | --- |
| Menu bar app, pairing, audit log, settings | Working |
| MCP server (Streamable HTTP, 10 read-only tools) | Working, tested end to end |
| Per-agent bearer tokens, locked to the first signed app that uses them | Working |
| Health app export import (export.zip → local SQLite) | Working |
| PHR export (`.phr` / `.sphr`, HL7 FHIR Personal Health Record with PGHD profiles) | Working. Panel button and `--export-phr`. See [docs/PHR-EXPORT.md](docs/PHR-EXPORT.md). |
| Encrypted iPhone backup import (full Health store, no iOS app) | Working. Verified against a real iOS 26.6 backup: 2.4M samples, 1,071 workouts, ten years of history. See [docs/BACKUP-IMPORT.md](docs/BACKUP-IMPORT.md). |
| Live HealthKit on macOS | **Blocked by Apple.** `HKHealthStore.isHealthDataAvailable()` returns `false` through macOS 27, and there is no Health data store on the Mac. The code path is complete and becomes live when Apple ships one. See [docs/HEALTHKIT-ON-MACOS.md](docs/HEALTHKIT-ON-MACOS.md). |
| Signed, notarized releases + Homebrew | Pipeline written and tested, **no release published yet**. Needs Flexpa's Developer ID certificate and notary key in repository secrets. See [docs/RELEASING.md](docs/RELEASING.md). |
| iOS companion app for live sync | Designed, not built. See [docs/APP-STORE.md](docs/APP-STORE.md). |

Until Apple turns HealthKit on for the Mac, real data comes from the iPhone in one of two ways:

- **Encrypted Finder backup** (preferred): the complete on-device Health store, refreshed whenever the phone backs up.
  **Import from iPhone Backup…** in the panel. Needs Full Disk Access and the backup password.
- **Health app export**: Health → profile picture → **Export All Health Data** → AirDrop `export.zip` to the Mac →
  **Import Health Export…**. Brings clinical records (FHIR) too.

Both stream into the same SQLite store and serve the same MCP tools.

## Install

Building from source is the only way to install it today. Requires macOS 14 or later and a recent Swift toolchain
(Xcode 16+ or the Command Line Tools).

```sh
git clone https://github.com/flexpa/bridge.git
cd bridge
make app                                    # → dist/Flexpa Health Bridge.app, ad-hoc signed
cp -R "dist/Flexpa Health Bridge.app" /Applications/
open "/Applications/Flexpa Health Bridge.app"
```

The Flexpa mark appears in the menu bar. Then:

1. **Import from iPhone Backup…** (needs an encrypted Finder backup and Full Disk Access; the app walks you
   through it) or **Import Health Export…** if you have an `export.zip`.
2. **Pair Agent**, and paste the config it gives you into Claude Code, Claude Desktop, Cursor, or any MCP client.

Ask the agent: *"Call health_status, then summarize my last week of sleep and steps."*

Once the first release is published there will also be a notarized DMG on the
[releases page](https://github.com/flexpa/bridge/releases/latest) and a Homebrew cask:

```sh
brew install --cask flexpa/tap/flexpa-health-bridge
```

**Export PHR…** writes the same data as an [HL7 FHIR Personal Health Record](docs/PHR-EXPORT.md): a `.phr` file
(one FHIR resource per line, using the IG's Patient Generated Health Data profiles) or a `.sphr` zip, for import
into any PHR that reads the format. From a terminal: `HealthBridge --export-phr ~/Desktop/record.phr`.

## Installing this as an agent

If you are an AI agent setting this up on your user's Mac, follow these steps in order. They are written to be
run without a human at the keyboard, except where a step says otherwise.

**1. Build and install.** From any directory:

```sh
git clone https://github.com/flexpa/bridge.git && cd bridge
make test                                   # should report 0 failures
make app
cp -R "dist/Flexpa Health Bridge.app" /Applications/
open "/Applications/Flexpa Health Bridge.app"
```

Install into `/Applications` rather than running it out of `dist/`. macOS grants Full Disk Access to a path, and
rebuilding in place makes the user re-grant it.

**2. Give the user the data-source step.** You cannot do this part. Importing needs Full Disk Access, which only a
human can grant in System Settings, and an encrypted backup password that is not yours to have. Tell the user:

> Open the Flexpa mark in the menu bar → **Import from iPhone Backup…**, and follow it. You will need your
> iPhone's encrypted backup password. If you have an `export.zip` from the Health app instead, use
> **Import Health Export…**.

Wait for them. `HealthBridge --list-backups` shows what backups the Mac already has. If it answers
`macOS blocked access to …`, the program you ran it from has no Full Disk Access; that is a System Settings
step for the user, not a bug.

**3. Pair yourself.** Use the name your user knows you by:

```sh
"/Applications/Flexpa Health Bridge.app/Contents/MacOS/HealthBridge" --pair "Claude Code"
```

It prints a token once, plus a ready-to-paste command and JSON for MCP clients. For Claude Code that is:

```sh
claude mcp add --transport http health-bridge http://127.0.0.1:4271/mcp --header "Authorization: Bearer hkb_…"
```

**4. Do not test the token with `curl`.** This is the one trap. The first program that uses a token becomes the
only program allowed to use it, which is the point of the design. A `curl` probe binds the token to `curl` and
your real client is then refused. Let your MCP client make the first request. If you have already burned one:

```sh
"/Applications/Flexpa Health Bridge.app/Contents/MacOS/HealthBridge" --reset-binding "Claude Code"
```

**5. Confirm it works** by calling the `health_status` tool through the MCP connection, not over HTTP by hand. A
healthy reply names the active data source and the date range it covers.

Useful to know while you work:

- The app must be running. The server is in the menu bar app, not a daemon; nothing answers if the user quits it.
- Default address is `http://127.0.0.1:4271/mcp`. An unauthenticated request correctly returns `401`.
- `--list` shows every pairing, what each token bound to, and how many requests it has served.
- Set `HEALTHBRIDGE_HOME` to a scratch directory to experiment without touching the user's real state.
- Binding strength depends on how you are packaged. A signed app binds to its Team ID. An agent that runs under
  an interpreter binds to the interpreter, so any script the user runs satisfies it. An ad-hoc or unsigned binary
  binds to nothing. [docs/SECURITY.md](docs/SECURITY.md) is honest about which one you are.

## Quick start (developer)

```bash
make app        # builds dist/Flexpa Health Bridge.app, ad-hoc signed
make run        # launches it; the Flexpa mark appears in the menu bar
make test       # HTTP parser, auth, MCP protocol, backup decryption, import, PHR export, math
make help       # every target
```

Releases are cut by tagging; see [docs/RELEASING.md](docs/RELEASING.md).

## Tools

`health_status` · `list_health_types` · `get_samples` · `get_statistics` · `get_latest` · `get_sleep` ·
`get_workouts` · `get_daily_summary` · `get_characteristics` · `get_clinical_records`

Full reference with arguments and examples: [docs/MCP.md](docs/MCP.md).

## Security model in one paragraph

The server binds to `127.0.0.1` only and refuses requests whose `Host` or `Origin` is not loopback (no DNS
rebinding, no browser pages). Every request needs a bearer token created in the app; only a SHA-256 hash is
stored. On the first successful request the bridge identifies the calling process through `libproc` and the
macOS code-signing APIs and **locks the token to that app's signing identity** (Team ID, or Apple platform
identifier). How much that is worth depends on the agent: it is strong for a signed app with its own Team ID,
weaker for an agent running under a shared interpreter, and worth nothing for an ad-hoc binary — the doc says so
per case rather than claiming one guarantee. Requests from a different macOS user account can never be verified
and are refused. Everything is written to an append-only audit log you can open from the panel. Details, threat
model, and the auth options we considered (including why not OAuth for v1): [docs/SECURITY.md](docs/SECURITY.md).

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
  PHR/                        HealthKit → PGHD code map, FHIR resource builders, streaming .phr/.sphr exporter
  Auth/ Audit/                pairings (hashed tokens, binding), JSONL audit log
  BridgeService.swift         composition root observed by the UI
Sources/HealthBridge          AppKit status item + SwiftUI panel, and the `--pair/--list/--import/--export-phr` CLI
Packaging/                    Info.plist, entitlements
scripts/                      build-app.sh, notarize.sh, make-dmg.sh, update-cask.sh, setup-signing.sh, make-icon.swift
Tests/                        XCTest suite: Health export fixture and a synthetic encrypted iPhone backup
docs/                         SECURITY, RELEASING, DISTRIBUTION, APP-STORE, MCP, PHR-EXPORT,
                              HEALTHKIT-ON-MACOS, BACKUP-IMPORT, PRIOR-ART, HEALTHD-SHIM
```

State lives in `~/Library/Application Support/HealthBridge/` (`pairings.json`, `settings.json`, `audit.jsonl`,
`health-export.sqlite`), all `0600`. Set `HEALTHBRIDGE_HOME` to relocate it. **Disconnect…** in the data source
menu (or `--disconnect`) deletes the imported store; the backup or export it came from is not touched.

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

MIT. See [LICENSE](LICENSE). This is research code, provided as-is and without warranty.
