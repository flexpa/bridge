# Importing the Health store from an iPhone backup

The Mac cannot read HealthKit, but an **encrypted** Finder backup of the iPhone contains the complete Health store.
Health Bridge can decrypt just the two Health files out of that backup and import them. No iOS app, no App Store, no
cloud. Freshness is the backup cadence: Finder can back up over Wi-Fi when the phone is charging near the Mac, so
roughly daily.

## What the user does

1. Connect the iPhone to the Mac once. In Finder → iPhone → General, choose **Back up all of the data on your iPhone to
   this Mac** and turn on **Encrypt local backup**. Apple only includes Health data in encrypted backups. Turn on
   **Show this iPhone when on Wi-Fi** for automatic backups.
2. Grant Health Bridge **Full Disk Access** (System Settings → Privacy & Security). macOS protects the
   `~/Library/Application Support/MobileSync/Backup` folder behind it. The panel links there when the folder is blocked.
3. In the panel: **Import from iPhone Backup…**, pick the device, enter the backup password, optionally remember it in the
   login keychain. Import takes a minute or two for a multi-year store, most of it key derivation and decryption.

Re-importing after each backup refreshes everything. A future incremental mode can use the HealthKit UUIDs the import
keeps on every row.

## What the bridge does

```
Manifest.plist ──BackupKeyBag──▶ PBKDF2-SHA256 (DPSL/DPIC) → PBKDF2-SHA1 (SALT/ITER) → passcode key
                                  └─▶ AES key-unwrap (RFC 3394) of each protection-class key
ManifestKey ──▶ unwrap with class key ──▶ AES-256-CBC (zero IV) ──▶ Manifest.db
Manifest.db: Files WHERE domain = 'HealthDomain' AND relativePath LIKE 'Health/healthdb%'
  file blob (NSKeyedArchiver MBFile) ──▶ EncryptionKey (class + wrapped key), Size
<udid>/<fileID[0:2]>/<fileID> ──▶ AES-256-CBC streamed ──▶ healthdb_secure.sqlite, healthdb.sqlite
```

All of it is CommonCrypto. Keys live only in memory inside `BackupDecryptor`; decrypted files live only in a `0700`
scratch folder that is deleted when the import ends, whether it succeeds or fails.

## Version flexibility

Apple does not document `healthdb_secure.sqlite`, and it changes between iOS versions. Two things keep the importer
from hardcoding a moment in time.

**Type codes come from the framework, not from us.** `samples.data_type` is an integer. Every `HKObjectType` on the
Mac carries the same integer in a private `code` property, so the importer asks the HealthKit framework for the code of
every identifier it knows (about 200) at import time. New iOS types land in the macOS SDK the same year, and the table
follows. A ten-entry seed verified on macOS 26.4 is the fallback if the private property ever disappears, and any
disagreement between seed and framework is reported rather than resolved silently. Verified values: steps 7, heart
rate 5, body mass 3, distance 8, active energy 10, sleep 63, stand hour 70, workout 79, HRV 139, time in daylight 279.

**The schema is introspected, not assumed.** `HealthDBReader` reads `sqlite_master` first and switches on what it
finds: `workout_activities` + `workout_statistics` (iOS 16 and later) versus the legacy `workouts` table, whether
`objects.type` exists to mark deletion tombstones, whether `quantity_samples.original_unit` and `unit_strings` are
present, and whether `data_provenances` can be joined to `healthdb.sqlite` for source names. Missing optional pieces
degrade a feature; a missing `samples` or `objects` table fails with a message that names the tables it did find.

**Units come from the framework too.** `quantity_samples.quantity` is stored in the type's canonical HealthKit unit,
and those are not what you would guess: heart rate is `count/s` (72 bpm is stored as 1.2) while resting heart rate is
`count/min`; HRV is `ms`; SpO2 is a fraction. The private `-[HKQuantityType canonicalUnit]` returns the exact unit for
every type, and HealthKit's own unit arithmetic converts to the catalog unit. A twenty-entry seed verified on macOS
26.4 is the fallback. When a sample also carries the source's original quantity and unit (a scale app writing pounds),
those are used instead.

**Reporting.** Every import records the schema fingerprint, the iOS version, and three lists: codes with no name,
codes with a name but outside the served catalog, and tombstones skipped. Those show up in the panel so a new iOS
release is a visible line, not a silent gap. When a user also has an `export.xml` from the same phone, matching on
timestamps and values is the planned validation for unit and code assumptions.

## Security notes

The backup password decrypts the entire phone backup, including the keychain inside it. The bridge:

- unwraps only the class keys it needs and only the two Health files, never the rest of the backup;
- never writes derived keys anywhere;
- stores the password only when asked, in the login keychain under the device's UDID, and removes it when asked;
- deletes the decrypted databases immediately after import;
- needs Full Disk Access to see the backup folder at all, and asks for it explicitly.

## Not yet covered

- Clinical records (FHIR) in the backup. Use the Health app export for those; both sources can be imported in turn.
- Characteristics (date of birth, sex). Same.
- Incremental merge. Each import replaces the store; UUIDs are stored so a merge can be added.
