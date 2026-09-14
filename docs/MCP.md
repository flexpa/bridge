# MCP reference

Endpoint: `http://127.0.0.1:4271/mcp` (port configurable). Transport: Streamable HTTP, JSON responses
(no server-initiated SSE stream; `GET` returns 405). Protocol versions: 2025-06-18, 2025-03-26, 2024-11-05.
Every request needs `Authorization: Bearer hkb_…`.

## Client configuration

Claude Code:
```bash
claude mcp add --transport http health-bridge http://127.0.0.1:4271/mcp --header "Authorization: Bearer hkb_…"
```

Cursor / VS Code / generic (`mcp.json`):
```json
{ "mcpServers": { "health-bridge": {
    "type": "http", "url": "http://127.0.0.1:4271/mcp",
    "headers": { "Authorization": "Bearer hkb_…" } } } }
```

Claude Desktop (stdio only, so bridge with `mcp-remote`):
```json
{ "mcpServers": { "health-bridge": {
    "command": "npx",
    "args": ["-y", "mcp-remote", "http://127.0.0.1:4271/mcp", "--header", "Authorization: Bearer hkb_…"] } } }
```

The panel's **Pair Agent** flow copies each of these with the token filled in.

## Conventions

* `type` arguments accept a HealthKit identifier (`HKQuantityTypeIdentifierStepCount`), a short alias
  (`stepCount`, `step_count`), or a display name (`Steps`). `list_health_types` shows all of them.
* Dates: ISO 8601 (`2026-09-14T08:00:00-04:00`), `YYYY-MM-DD` (local midnight), or `now`, `today`, `yesterday`.
  `end` is exclusive and defaults to now. Output timestamps are in the user's time zone.
* Every tool returns `structuredContent` (an object) and the same JSON as text. Tool failures come back as
  `isError: true` with a plain-language message, never as protocol errors.
* Units are the catalog's canonical units (`count`, `km`, `kcal`, `min`, `count/min`, `ms`, `%`, `kg`, `cm`,
  `degC`, `mmHg`, `mg/dL`, …). Imported data is converted (`lb→kg`, `mi→km`, `degF→degC`).

## Tools

### `health_status`
No arguments. Returns data source kind (`healthkit`, `healthExport`, `demo`), availability, authorization state,
date coverage, sample count, `availableTypes`, whether clinical records are exposed, time zone, and current time.
Call this first.

### `list_health_types`
`category?` (activity, vitals, body, heart, respiratory, sleep, nutrition, mobility, hearing, mindfulness,
reproductive, other), `only_available?` (bool). Returns identifier, alias, name, kind, unit, aggregation
(`cumulative` sum vs `discrete` average), description.

### `get_samples`
`type` (required), `start?`, `end?`, `limit?` (1–2000, default 100), `order?` (`asc`|`desc`, default desc).
Raw samples with `start`, `end`, `value`, `unit`, `categoryValue`, `source`, `device`, `metadata`.

### `get_statistics`
`type` (required), `start?` (default 30 days ago), `end?`, `interval?` (`hour`|`day`|`week`|`month`, default day;
hourly limited to 31 days). Calendar-aligned buckets. Cumulative types: `sum` and `total`. Discrete types:
`average`, `min`, `max` and `overallAverage`. Samples spanning a boundary are split proportionally.

### `get_latest`
`types` (1–25). Most recent sample per type, or `null`.

### `get_sleep`
`start?` (default 14 days), `end?` (max 366 days), `include_segments?`. Nights keyed by wake-up date with
`bedtime`, `wakeTime`, `inBedMinutes`, `asleepMinutes`, `awakeMinutes`, `coreMinutes`, `deepMinutes`,
`remMinutes`, `unspecifiedMinutes`, optional `segments`. Segments separated by more than 4 hours start a new night.

### `get_workouts`
`start?` (default 30 days), `end?`, `activity_type?` (`running`, `cycling`, `functionalStrengthTraining`, …),
`limit?` (default 50). Duration, energy, distance, average and max heart rate, source.

### `get_daily_summary`
`date?` or `start?`/`end?` (max 92 days; default last 7 days). One row per day: `steps`, `distanceKm`,
`activeEnergyKcal`, `exerciseMinutes`, `standHours`, `flightsClimbed`, `restingHeartRate`, `heartRateAverage`,
`heartRateMin`, `heartRateMax`, `hrvSDNN`, `respiratoryRate`, `oxygenSaturation`, `sleepAsleepMinutes`,
`sleepInBedMinutes`, `bodyMassKg`, `workouts[]`. The most useful single call for "how was my week".

### `get_characteristics`
No arguments. `dateOfBirth`, `ageYears`, `biologicalSex`, `bloodType`, `fitzpatrickSkinType`, `wheelchairUse`,
`activityMoveMode`.

### `get_clinical_records`
`kind?` (`allergyRecord`, `conditionRecord`, `coverageRecord`, `immunizationRecord`, `labResultRecord`,
`medicationRecord`, `procedureRecord`, `vitalSignRecord`, `clinicalNoteRecord`), `since?`, `limit?` (default 50),
`include_resources?` (default true). Each record: `kind`, `displayName`, `fhirResourceType`, `fhirVersion`,
`identifier`, `sourceURL`, `source`, `date`, and `resource` (the FHIR JSON as stored by Health). Disabled when
**Share clinical records** is off in the panel.

## Example

```bash
TOKEN=hkb_…
curl -s http://127.0.0.1:4271/mcp -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_daily_summary","arguments":{"start":"yesterday","end":"now"}}}'
```

## Errors

| HTTP | Meaning |
| --- | --- |
| 401 + `WWW-Authenticate: Bearer` | No, malformed, unknown, or revoked token |
| 403 | Token bound to a different app, unverifiable peer, non-loopback `Host`/`Origin`, session from another pairing |
| 404 | Wrong path, or an expired `Mcp-Session-Id` (re-initialize) |
| 405 | `GET` (no server stream) or other methods |
| 400 | JSON parse error (`-32700`) |
