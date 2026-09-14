# Changelog

All notable changes to Flexpa Health Bridge. Format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — unreleased

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

### Notes

- Live HealthKit does not work on macOS: Apple ships no Health data store there. The code path is complete and
  dormant. See [docs/HEALTHKIT-ON-MACOS.md](docs/HEALTHKIT-ON-MACOS.md) for the measurements.

[Unreleased]: https://github.com/flexpa/bridge/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/flexpa/bridge/releases/tag/v0.1.0
