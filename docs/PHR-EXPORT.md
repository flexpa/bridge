# Exporting a Personal Health Record (.phr / .sphr)

Health Bridge can write everything it serves to agents as an HL7 FHIR **Personal Health Record**, the file format
defined by the [Personal Health Records implementation guide](https://build.fhir.org/ig/HL7/personal-health-record-format-ig/en/)
(`hl7.fhir.uv.phr`, currently 1.0.0-ballot2). The export is user-initiated only. There is no MCP tool for it: an
agent must never be able to write your complete record to a path of its choosing.

## What you get

| Extension | Contents |
| --- | --- |
| `.phr` | Newline-delimited JSON, one FHIR R4 resource per line (`application/x-ndjson`). The IG's portable record format. |
| `.sphr` | A DEFLATE zip that holds `<name>.phr` at its root. The IG's container for records with supporting files. |

The file is written with `0600` permissions. Both formats are registered with macOS as `org.hl7.fhir.phr` and
`org.hl7.fhir.sphr`, the identifiers the IG suggests, so Finder labels them.

Line order:

1. `Patient` (`id: me`): birth date and gender from HealthKit's characteristics, plus a name if you gave one.
   HealthKit has no name, so the panel export leaves it out; the CLI takes `--patient-name`.
2. `Composition` (`id: cover`, LOINC 11503-0 *Medical records*): the IG's cover page, with a generated narrative
   that says where the data came from, what range it covers, and how many resources of each kind follow.
3. `Provenance`: you as author, Health Bridge as assembler, and the data source (iPhone backup or Health export)
   as the source entity.
4. `Device` resources, one per distinct source app and hardware name, each written before the first observation
   that references it.
5. `Observation` resources for every sample, one workout group per workout, one sleep episode per night.
6. Clinical records from connected providers, as Health stored them.

## Mapping

Each HealthKit type becomes an `Observation` that claims the IG's PGHD profile, carries the PGHD code
(`http://hl7.org/fhir/uv/phr/CodeSystem/observation-pghd-codes`, the code is HealthKit's short name), the LOINC code
where the IG's [code mapping table](https://build.fhir.org/ig/HL7/personal-health-record-format-ig/en/pghd-code-mapping.html)
lists one, and the UCUM unit the code system declares for that code. `Sources/HealthBridgeCore/PHR/PGHDCodeMap.swift`
is the full table; a test checks that every type in the catalog has an entry.

| HealthKit | Profile | Category | LOINC | Unit | Note |
| --- | --- | --- | --- | --- | --- |
| HeartRate | `pghd-heartrate` | vital-signs | 8867-4 | `/min` | FHIR `heartrate` vital sign |
| RestingHeartRate, WalkingHeartRateAverage, HeartRateRecoveryOneMinute | `pghd-vitalsigns` | vital-signs | | `/min` | |
| HeartRateVariabilitySDNN | `pghd-vitalsigns` | vital-signs | 80404-7 | `ms` | |
| AtrialFibrillationBurden | `pghd-vitalsigns` | vital-signs | | `%` | |
| BloodPressureSystolic + Diastolic | `pghd-bloodpressure` | vital-signs | 85354-9, 8480-6, 8462-4 | `mm[Hg]` | Paired into one panel when start, end and source match; halves left over export alone |
| Low/High HeartRateEvent, IrregularHeartRhythmEvent | `pghd-cardiac-function` | vital-signs | | none | Event with a time and no value |
| OxygenSaturation | `pghd-oxygenSaturation` | vital-signs | 2708-6, 59408-5 | `%` | |
| RespiratoryRate | `pghd-respiratoryrate` | vital-signs | 9279-1 | `/min` | |
| BodyTemperature | `pghd-bodytemperature` | vital-signs | 8310-5 | `Cel` | |
| AppleSleepingWristTemperature | `pghd-vitalsigns` | vital-signs | | `Cel` | |
| BloodGlucose | `pghd-blood-glucose` | vital-signs | 2339-0 | `mmol/L` | mg/dL kept in the `iso21090-PQ-translation` extension; `issued` set |
| PeripheralPerfusionIndex, TimeInDaylight | `pghd-testresult` | exam | | `%`, `min` | The code system files these under lab and test results |
| BodyMass | `pghd-bodyweight` | vital-signs | 29463-7 | `kg` | |
| Height | `pghd-bodyheight` | vital-signs | 8302-2 | `cm` | |
| BodyMassIndex | `pghd-bmi` | vital-signs | 39156-5 | `kg/m2` | |
| BodyFatPercentage, LeanBodyMass, WaistCircumference | `pghd-bodymeasurement` | exam | 41982-0, 91557-9 | `%`, `kg`, `cm` | |
| StepCount | `pghd-activity` | activity | 55423-8 | `{steps}` | |
| FlightsClimbed | `pghd-activity` | activity | | `{flights}` | |
| DistanceWalkingRunning | `pghd-activity` | activity | | `km` | |
| DistanceCycling | `pghd-activity` | activity | 93818-3 | `m` | The IG declares metres here and kilometres for walking |
| DistanceSwimming | `pghd-activity` | activity | 93816-7 | `m` | |
| Active/BasalEnergyBurned | `pghd-activity` | activity | | `kcal` | |
| AppleExerciseTime, AppleStandTime, AppleMoveTime | `pghd-activity` | activity | | `min` | |
| AppleStandHour | `pghd-activity` | activity | | `h` | `1 h` for an hour you stood, `0 h` for an idle hour |
| PhysicalEffort | `pghd-activity` | activity | | `kcal/(kg.h)` | |
| VO2Max | `pghd-activity` | activity | | `mL/kg/min` | |
| RunningPower, RunningSpeed | `pghd-activity` | activity | | `W`, `m/s` | |
| WalkingSpeed, StairAscentSpeed, StairDescentSpeed | `pghd-mobility` | activity | | `m/s` | |
| WalkingStepLength | `pghd-mobility` | activity | | `m` | |
| WalkingAsymmetryPercentage, WalkingDoubleSupportPercentage, AppleWalkingSteadiness | `pghd-mobility` | activity | | `%` | |
| SixMinuteWalkTestDistance | `pghd-mobility` | activity | 64098-7 | `m` | |
| EnvironmentalAudioExposure, HeadphoneAudioExposure | `pghd-hearing` | social-history | | `dB` | |
| Dietary* | `pghd-nutrition` | social-history | 9052-2, 9079-5, 9059-7, 9066-2 | `kcal`, `g`, `mg`, `L` | Water is converted from mL to L |
| MindfulSession | `pghd-mindfulness` | activity | | none | Period only |
| MenstrualFlow | `pghd-reproductive-health` | social-history | | | The profile allows only a Quantity: intensity 0 (none) to 3 (heavy) with HealthKit's label as the unit; *unspecified* becomes `dataAbsentReason` |
| SleepAnalysis | `pghd-sleep` | social-history | | | `valueCodeableConcept` from `sleep-analysis-codes` (inBed, asleepCore, …) |
| one per night | `pghd-sleep-episode` | social-history | | `min`, `%` | See below |
| Workout | `pghd-workout` | activity | | | See below |

Times use the Mac's time zone with an explicit offset. An instant sample gets `effectiveDateTime`; a span gets
`effectivePeriod`. Every observation names the patient as `subject` and `performer` and references its `Device`.

### Identifiers

When the data source keeps HealthKit's object UUID (an iPhone backup import does; a Health export does not), the
UUID becomes the resource `id` and an `identifier` with system `urn:ietf:rfc:3986` and value `urn:uuid:…`.
Otherwise the `id` is a SHA-256 of the sample's type, times, value and source. Either way, exporting the same store
twice yields the same ids, which is what lets a receiving PHR merge repeated exports instead of duplicating them
(the IG's *clone and pull* lifecycle).

### Sleep

Sleep is exported the way `get_sleep` reports it. Every stage segment is a `pghd-sleep` observation, and the
segments that group into one night (gap of four hours or less) are summarized by one `pghd-sleep-episode`
observation whose `effectivePeriod` runs from bedtime to wake and whose components are `totalSleepTime`,
`coreSleepDuration`, `deepSleepDuration`, `remSleepDuration`, the matching percentages, `latencyToSleepOnset`,
`latencyToArising`, `wakeAfterSleepOnset`, `numberOfAwakenings`, `sleepEfficiencyPercentage` and `isMainSleep`
(true for the longest sleep of that wake-up day). `hasMember` lists the segment observations. Overlapping
segments from two devices are unioned, not summed. A night belongs to a date-limited export when it ends inside the
range, and it is then exported whole.

### Workouts

A workout is a `pghd-workout` observation coded with its activity (`running`, `functionalStrengthTraining`, …;
activities the code system does not list become `other` with the name in `code.text`). Its total energy and total
distance are `pghd-activity` observations linked through `hasMember`, exactly as the IG's walking example does; the
distance code follows the sport (cycling → `distanceCycling` in metres, swimming → `distanceSwimming`, else
`distanceWalkingRunning`). Duration, average and maximum heart rate ride along as components.

### Clinical records

FHIR resources that Health received from providers are written as Health stored them. Health Bridge adds
`meta.source` (the provider's FHIR URL) and, when the provider's copy has no patient reference, a `subject`,
`patient` or `beneficiary` pointing at `Patient/me`. Nothing else is rewritten. Turn them off with the checkbox in
the save panel or `--no-clinical`.

### Not exported

Blood type, Fitzpatrick skin type, wheelchair use and activity move mode have no PGHD mapping and are left out.
Sample metadata (heart rate motion context, workout metadata) is not part of the imported store and is not exported.
Types the store holds but the catalog does not serve yet are not exported either.

## Using it

From the panel: **Export PHR…** in the Data source section. Choose `.phr` or `.sphr`, everything or the last
12 months or 90 days, and whether to include clinical records. The export runs in the background with progress in the
panel; **Show in Finder** reveals the file. Every export is written to the audit log.

From a terminal:

```bash
APP="dist/Flexpa Health Bridge.app/Contents/MacOS/HealthBridge"
"$APP" --export-phr ~/Desktop/health-record.phr
"$APP" --export-phr ~/Desktop/health-record.sphr --start 2025-01-01 --end 2025-12-31 --no-clinical
"$APP" --export-phr /tmp/demo.phr --demo --patient-name "Demo Person"
```

`--start` and `--end` take ISO 8601 dates; a bare `--end` day is inclusive. The CLI uses the data source the app
is set to (Settings → Data source), so it exports the same store the agents see.

## Size and speed

Each observation is roughly 900 bytes of JSON, and zip shrinks the file about 25 times. A ten-year store of
2.4 million samples is therefore about 2 GB as `.phr` and under 100 MB as `.sphr`. The exporter streams: it reads
one type at a time in month-sized windows and never holds the store in memory, so the limit is disk space, not RAM.
Use the range options for a smaller file.

## Checking conformance

Validate a small export against the IG package with the HL7 validator:

```bash
"$APP" --export-phr /tmp/check.phr --start 2026-09-01 --end 2026-09-07
# one resource per line → one file per resource
mkdir -p /tmp/check && split -l 1 -a 5 /tmp/check.phr /tmp/check/r- && for f in /tmp/check/r-*; do mv "$f" "$f.json"; done
java -jar validator_cli.jar /tmp/check -version 4.0.1 -ig hl7.fhir.uv.phr#current
```

The IG is a ballot. Its PGHD profiles, code system and unit choices can change between builds; this exporter
tracks `1.0.0-ballot2` and records that version in the cover page so a reader knows which mapping was applied.

## Security

The file is your complete health record in plain text. Keep it where you would keep a medical record, and prefer
`.sphr` if you will move it around. The IG recommends encrypting `.sphr` files with a passphrase or the recipient's
public key before sharing; Health Bridge does not encrypt (use your own tool on the zip). The export is not
reachable over MCP and never runs without a person clicking a button or running the CLI on this Mac.
