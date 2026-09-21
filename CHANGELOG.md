# Changelog

All notable changes to Flexpa Health Bridge. Format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **PHR export.** The panel's **Export PHR…** button and `HealthBridge --export-phr <file>` write the active data
  source as an HL7 FHIR Personal Health Record following the
  [Personal Health Records IG](https://build.fhir.org/ig/HL7/personal-health-record-format-ig/en/) (1.0.0-ballot2):
  a `.phr` file (newline-delimited JSON, one resource per line) or a `.sphr` zip around it. Every HealthKit type in
  the catalog maps to the IG's Patient Generated Health Data profile, code and unit; blood pressure halves are paired
  into panels, each night becomes a sleep episode with stage components, workouts group their energy and distance
  totals, and provider clinical records pass through with `meta.source`. A Patient, a Composition cover page,
  a Provenance record and one Device per data source lead the file. Ids are HealthKit UUIDs where the store keeps
  them and stable hashes otherwise, so repeated exports merge. Options: date range, clinical records on or off,
  sleep segments on or off, patient name (CLI). Streams, so a multi-million-sample store never sits in memory.
  See [docs/PHR-EXPORT.md](docs/PHR-EXPORT.md).
- `.phr` and `.sphr` are declared to macOS as `org.hl7.fhir.phr` and `org.hl7.fhir.sphr`.
- **Disconnect.** The data source menu (⋯) and `HealthBridge --disconnect` delete the imported Health store from
  the Mac, so agents lose access at once. The backup or export it came from is untouched; a backup password saved
  in the keychain for that device is forgotten.

### Fixed

- The import and export file panels no longer vanish on the first click: the popover stayed transient under a modal
  panel, closed, and hid the app with the panel.
- Samples and workouts now carry HealthKit's object UUID (`uuid`) when the data source has it, visible in
  `get_samples` and `get_workouts` output.

## [0.1.0] — 2026-09-19

First public release.

### Added

- **Menu bar app** serving a read-only [Model Context Protocol](https://modelcontextprotocol.io) endpoint on
  `127.0.0.1`, with ten tools over Apple Health data: status, type catalog, samples, statistics, latest values,
  sleep, workouts, daily summaries, profile characteristics, and FHIR clinical records.
- **Per-agent bearer tokens**, hashed at rest and bound on first use to the calling process's code-signing
  identity, so a token copied out of an agent's config stops working elsewhere.
- **Encrypted iPhone backup import**: decrypts only the two Health database files out of a Finder backup and
  imports the complete on-device store, including deletions and HealthKit UUIDs. Verified against a real
  iOS 26.6 backup of 2.4 million samples.
- **Health app export import** (`export.zip`), including clinical records as FHIR.
- **Demo data source** for evaluating the tool surface without connecting real data.
- HealthKit type codes and storage units are read from the HealthKit framework at runtime rather than hardcoded,
  so the mapping tracks new iOS releases without a maintainer.
- Append-only audit log of every request, allowed or refused, visible in the panel.
- A Full Disk Access helper window that follows the grant and returns you to where you were.
- Command line: `--pair`, `--list`, `--revoke`, `--reset-binding`, `--import`, `--list-backups`, `--import-backup`.

### Security

- Import rejects a `resourceFilePath` that escapes the export directory. A crafted Health export could
  otherwise read arbitrary JSON off disk and serve it back as a clinical record.
- Loopback matching is exact. The previous prefix test accepted any hostname beginning `127.`, which is the
  DNS-rebinding vector the Host and Origin checks exist to stop.
- Chunked request bodies are bounded before decoding, so an unauthenticated local socket cannot exhaust memory.
- The backup manifest is decoded with secure coding on and a closed class list.

### Notes

- Live HealthKit does not work on macOS: Apple ships no Health data store there. The code path is complete and
  dormant. See [docs/HEALTHKIT-ON-MACOS.md](docs/HEALTHKIT-ON-MACOS.md) for the measurements.

[Unreleased]: https://github.com/flexpa/bridge/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/flexpa/bridge/releases/tag/v0.1.0
