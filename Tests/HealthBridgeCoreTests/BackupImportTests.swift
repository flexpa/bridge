import XCTest
@testable import HealthBridgeCore

final class TypeCodeTableTests: XCTestCase {
    func testFrameworkCodesMatchVerifiedSeed() {
        let table = TypeCodeTable.fromFramework()
        XCTAssertEqual(table.code(for: "HKQuantityTypeIdentifierStepCount"), 7)
        XCTAssertEqual(table.code(for: "HKQuantityTypeIdentifierHeartRate"), 5)
        XCTAssertEqual(table.code(for: "HKQuantityTypeIdentifierBodyMass"), 3)
        XCTAssertEqual(table.code(for: "HKCategoryTypeIdentifierSleepAnalysis"), 63)
        XCTAssertEqual(table.code(for: TypeCodeTable.workoutIdentifier), 79)
        XCTAssertEqual(table.identifier(for: 279), "HKQuantityTypeIdentifierTimeInDaylight")
        XCTAssertTrue(table.conflicts.isEmpty, "framework disagrees with seed: \(table.conflicts)")
        XCTAssertGreaterThan(table.derivedFromFramework.count, 150, "expected the framework to answer for most identifiers")
        // Every catalog type the framework knows has a code.
        for t in HealthTypeCatalog.all {
            XCTAssertNotNil(table.code(for: t.identifier), "no code for \(t.identifier)")
        }
    }

    func testCanonicalUnitsComeFromTheFramework() {
        XCTAssertEqual(CanonicalUnits.unitString(for: "HKQuantityTypeIdentifierHeartRate"), "count/s")
        XCTAssertEqual(CanonicalUnits.unitString(for: "HKQuantityTypeIdentifierRestingHeartRate"), "count/min")
        XCTAssertEqual(CanonicalUnits.unitString(for: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"), "ms")
        XCTAssertEqual(CanonicalUnits.unitString(for: "HKQuantityTypeIdentifierBodyMass"), "kg")
        XCTAssertEqual(CanonicalUnits.unitString(for: "HKQuantityTypeIdentifierDistanceWalkingRunning"), "m")
        let bpm = CanonicalUnits.convertStored(1.2, identifier: "HKQuantityTypeIdentifierHeartRate", to: "count/min")
        XCTAssertEqual(bpm!.0, 72, accuracy: 0.0001)
        let km = CanonicalUnits.convertStored(1500, identifier: "HKQuantityTypeIdentifierDistanceWalkingRunning", to: "km")
        XCTAssertEqual(km!.0, 1.5, accuracy: 0.0001)
        let pct = CanonicalUnits.convertStored(0.97, identifier: "HKQuantityTypeIdentifierOxygenSaturation", to: "%")
        XCTAssertEqual(pct!.0, 97, accuracy: 0.0001)
        for t in HealthTypeCatalog.all where t.kind == .quantity {
            XCTAssertNotNil(CanonicalUnits.unit(for: t.identifier), "no canonical unit for \(t.identifier)")
        }
    }

    func testHealthKitUnitArithmeticIsSafeAndCorrect() {
        XCTAssertNil(HealthKitUnits.unit("furlongs per fortnight"), "bad unit strings must return nil, not throw")
        XCTAssertNil(HealthKitUnits.unit(""))
        XCTAssertNotNil(HealthKitUnits.unit("count/min"))
        XCTAssertEqual(HealthKitUnits.convert(1.1, from: "count/s", to: "count/min")!, 66, accuracy: 0.0001)
        XCTAssertEqual(HealthKitUnits.convert(1, from: "mi", to: "km")!, 1.609344, accuracy: 0.000001)
        XCTAssertEqual(HealthKitUnits.convert(0.5, from: "%", to: "%")!, 0.5)
        XCTAssertNil(HealthKitUnits.convert(1, from: "kg", to: "km"), "incompatible dimensions return nil")
        let rhr = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierRestingHeartRate"]!
        let (v, u) = UnitConversion.canonicalize(value: 1.1, unit: "count/s", type: rhr)
        XCTAssertEqual(v, 66, accuracy: 0.0001)
        XCTAssertEqual(u, "count/min")
    }

    func testSeedOnlyFallback() {
        let table = TypeCodeTable.seedOnly
        XCTAssertEqual(table.identifier(for: 7), "HKQuantityTypeIdentifierStepCount")
        XCTAssertTrue(table.derivedFromFramework.isEmpty)
    }
}

final class BackupImportTests: XCTestCase {
    var root: URL!
    let codes = TypeCodeTable.fromFramework()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hb-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testLocatorDescribesSyntheticBackup() throws {
        let built = try SyntheticBackup.build(in: root.appendingPathComponent("Backup"), codes: codes)
        let list = try BackupLocator.listBackups(root: root.appendingPathComponent("Backup"))
        XCTAssertEqual(list.count, 1)
        let b = list[0]
        XCTAssertEqual(b.udid, built.udid)
        XCTAssertEqual(b.deviceName, "Josh's iPhone")
        XCTAssertEqual(b.iosVersion, "26.4")
        XCTAssertTrue(b.isEncrypted)
        XCTAssertTrue(b.isFinished)
        XCTAssertNotNil(b.date)
    }

    func testLocatorReportsMissingFolderAsEmpty() throws {
        XCTAssertEqual(try BackupLocator.listBackups(root: root.appendingPathComponent("nope")).count, 0)
    }

    func testWrongPasswordIsRejectedBeforeAnyFileIsRead() throws {
        let built = try SyntheticBackup.build(in: root.appendingPathComponent("Backup"), codes: codes)
        let backup = try BackupLocator.describe(built.directory)
        let decryptor = try BackupDecryptor(backup: backup)
        XCTAssertThrowsError(try decryptor.unlock(password: "not it")) { error in
            guard case BackupDecryptError.wrongPassword? = error as? BackupDecryptError else { return XCTFail("\(error)") }
        }
    }

    func testUnencryptedBackupIsRefused() throws {
        let built = try SyntheticBackup.build(in: root.appendingPathComponent("Backup"), encrypted: false, codes: codes)
        let backup = try BackupLocator.describe(built.directory)
        XCTAssertFalse(backup.isEncrypted)
        XCTAssertThrowsError(try BackupDecryptor(backup: backup)) { error in
            guard case BackupDecryptError.notEncrypted? = error as? BackupDecryptError else { return XCTFail("\(error)") }
        }
    }

    func testManifestAndFileDecryptionRoundTrip() throws {
        let built = try SyntheticBackup.build(in: root.appendingPathComponent("Backup"), codes: codes)
        let backup = try BackupLocator.describe(built.directory)
        let decryptor = try BackupDecryptor(backup: backup)
        try decryptor.unlock(password: built.password)
        let manifest = root.appendingPathComponent("Manifest.db")
        try decryptor.decryptManifest(to: manifest)
        let files = try decryptor.files(inManifest: manifest, domain: "HealthDomain", pathPrefix: "Health/healthdb")
        XCTAssertEqual(Set(files.map(\.relativePath)), ["Health/healthdb_secure.sqlite", "Health/healthdb.sqlite"])
        let secure = files.first { $0.relativePath == HealthBackupImporter.securePath }!
        XCTAssertNotNil(secure.size)
        XCTAssertNotNil(secure.encryptionKey)
        let out = root.appendingPathComponent("secure.sqlite")
        try decryptor.decrypt(secure, to: out)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int, secure.size)
        // It is a real SQLite file with the expected tables.
        let db = try SQLiteDatabase(path: out.path)
        let count = try db.scalar("SELECT COUNT(*) FROM samples")
        XCTAssertEqual(count, 18)
    }

    func testReaderIntrospectsSchema() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let secure = plain.appendingPathComponent("s.sqlite"), main = plain.appendingPathComponent("m.sqlite")
        try SyntheticBackup.makeHealthDB(secure: secure, main: main, legacyWorkouts: false, codes: codes)
        let reader = try HealthDBReader(secureDatabase: secure, plainDatabase: main, codes: codes)
        XCTAssertTrue(reader.schema.hasWorkoutActivities)
        XCTAssertFalse(reader.schema.hasLegacyWorkouts)
        XCTAssertTrue(reader.schema.hasObjectsType)
        XCTAssertTrue(reader.schema.hasOriginalUnit)
        XCTAssertTrue(reader.schema.hasUnitStrings)
        XCTAssertEqual(reader.schema.fingerprint.count, 8)
        let counts = Dictionary(uniqueKeysWithValues: try reader.typeCounts())
        XCTAssertEqual(counts[7], 4)   // three live steps + one tombstone
        XCTAssertEqual(counts[9999], 1)
        var seen: [HealthDBReader.RawSample] = []
        try reader.forEachSample(code: 3) { seen.append($0) }
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].originalUnit, "lb")
        XCTAssertEqual(seen[0].source, "Withings")
        XCTAssertEqual(seen[0].uuid?.count, 36)
    }

    func testReaderRejectsNonHealthDatabase() throws {
        let other = root.appendingPathComponent("other.sqlite")
        let db = try SQLiteDatabase(path: other.path)
        try db.exec("CREATE TABLE t (x)")
        XCTAssertThrowsError(try HealthDBReader(secureDatabase: other, plainDatabase: nil, codes: codes))
    }

    func testFullImportServesTheDataThroughTheProvider() async throws {
        let built = try SyntheticBackup.build(in: root.appendingPathComponent("Backup"), codes: codes)
        let backup = try BackupLocator.describe(built.directory)
        let store = root.appendingPathComponent("store.sqlite")
        var phases: [String] = []
        let lock = NSLock()
        let importer = HealthBackupImporter(destination: store, scratch: root.appendingPathComponent("scratch"), codes: codes) { p in
            lock.lock(); phases.append(p.phase); lock.unlock()
        }
        let report = try importer.run(backup: backup, password: built.password)
        XCTAssertEqual(report.samples, 15)          // 3 steps + 2 HR + resting HR + mass + SpO2 + 5 sleep + 2 stand; tombstone excluded
        XCTAssertEqual(report.workouts, 1)
        XCTAssertEqual(report.skippedTombstones, 1)
        XCTAssertEqual(report.unmappedCodes, [9999: 1])
        XCTAssertTrue(report.uncataloguedCodes.isEmpty)
        XCTAssertTrue(phases.contains("Unlocking backup"))
        XCTAssertTrue(phases.contains("Finishing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scratch").path), "decrypted files must be gone")

        let provider = HealthExportProvider(databaseURL: store)
        let status = await provider.status()
        XCTAssertTrue(status.available)
        XCTAssertTrue(status.description.contains("Josh's iPhone backup"))
        XCTAssertEqual(status.sampleCount, 15)

        let steps = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierStepCount"]!
        let range = DateInterval(start: ISO8601.date(from: "2026-09-01")!, end: ISO8601.date(from: "2026-09-03")!)
        let stats = try await provider.statistics(of: steps, in: range, interval: .day)
        XCTAssertEqual(stats.reduce(0) { $0 + ($1.sum ?? 0) }, 2500, accuracy: 0.01)

        let mass = try await provider.latestSample(of: HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierBodyMass"]!)
        XCTAssertEqual(mass!.value, 80.0, accuracy: 0.01)
        XCTAssertEqual(mass?.unit, "kg")
        XCTAssertEqual(mass?.source, "Withings")

        let spo2 = try await provider.latestSample(of: HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierOxygenSaturation"]!)
        XCTAssertEqual(spo2!.value, 97, accuracy: 0.01)
        XCTAssertEqual(spo2?.unit, "%")

        let resting = try await provider.latestSample(of: HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierRestingHeartRate"]!)
        XCTAssertEqual(resting!.value, 66, accuracy: 0.0001)   // stored as count/s, served as count/min
        XCTAssertEqual(resting?.unit, "count/min")

        let hr = try await provider.samples(of: HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierHeartRate"]!, in: nil, limit: 10, ascending: true)
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr[0].value, 72, accuracy: 0.0001)   // from the source's original unit
        XCTAssertEqual(hr[1].value, 88, accuracy: 0.0001)   // from canonical count/s via the framework
        XCTAssertEqual(hr.map(\.unit), ["count/min", "count/min"])
        XCTAssertEqual(hr.first?.source, "Josh’s Apple Watch")

        let nights = HealthMath.nights(from: try await provider.sleepSegments(in: DateInterval(start: .distantPast, end: .distantFuture)), includeSegments: false)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].deepMinutes, 60)
        XCTAssertEqual(nights[0].asleepMinutes, 390)

        let workouts = try await provider.workouts(in: nil, activityType: nil, limit: 10)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].activityType, "running")
        XCTAssertEqual(workouts[0].durationMinutes, 31.5)
        XCTAssertEqual(workouts[0].totalEnergyKcal!, 312.4, accuracy: 0.01)
        XCTAssertEqual(workouts[0].totalDistanceKm!, 4.989, accuracy: 0.001)
        XCTAssertEqual(workouts[0].averageHeartRate, 152)
        XCTAssertEqual(workouts[0].maxHeartRate, 178)

        // The legacy path has no statistics rows; heart rate then comes from samples inside the workout window.
        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let legacy = try SyntheticBackup.build(in: legacyRoot, legacyWorkouts: true, codes: codes)
        let legacyStore = root.appendingPathComponent("legacy.sqlite")
        _ = try HealthBackupImporter(destination: legacyStore, scratch: root.appendingPathComponent("scratch2"), codes: codes)
            .run(backup: try BackupLocator.describe(legacy.directory), password: legacy.password)
        let legacyProvider = HealthExportProvider(databaseURL: legacyStore)
        let legacyWorkouts = try await legacyProvider.workouts(in: nil, activityType: nil, limit: 5)
        XCTAssertNil(legacyWorkouts[0].averageHeartRate, "no heart-rate samples fall inside the 17:00 workout in the fixture")

        // UUIDs survive into the store for future incremental merges.
        let db = try SQLiteDatabase(path: store.path)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM samples WHERE uuid IS NOT NULL"), 15)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM samples WHERE data_type_code = 7"), 3)
    }

    func testLegacyWorkoutTableIsAlsoRead() throws {
        let built = try SyntheticBackup.build(in: root.appendingPathComponent("Backup"), legacyWorkouts: true, codes: codes)
        let backup = try BackupLocator.describe(built.directory)
        let store = root.appendingPathComponent("store.sqlite")
        let report = try HealthBackupImporter(destination: store, scratch: root.appendingPathComponent("scratch"), codes: codes)
            .run(backup: backup, password: built.password)
        XCTAssertEqual(report.workouts, 1)
        let db = try SQLiteDatabase(path: store.path)
        let rows = try db.query("SELECT activity, duration_min, energy_kcal, distance_km FROM workouts", row: { ($0.string(0), $0.double(1), $0.double(2), $0.double(3)) })
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, "running")
        XCTAssertEqual(rows[0].1!, 31.5, accuracy: 0.01)
        XCTAssertEqual(rows[0].2!, 312.4, accuracy: 0.01)
        XCTAssertEqual(rows[0].3!, 4.989, accuracy: 0.001)
    }

    func testMapperUnitRules() {
        let raw = HealthDBReader.RawSample(code: 3, identifier: "HKQuantityTypeIdentifierBodyMass", uuid: nil, start: Date(), end: Date(),
                                           quantity: 80, originalQuantity: nil, originalUnit: nil, categoryValue: nil, source: nil, isTombstone: false)
        let s = HealthDBMapper.sample(from: raw)!
        XCTAssertEqual(s.value, 80)
        XCTAssertEqual(s.unit, "kg")
        let hr = HealthDBReader.RawSample(code: 5, identifier: "HKQuantityTypeIdentifierHeartRate", uuid: nil, start: Date(), end: Date(),
                                          quantity: 1.0, originalQuantity: nil, originalUnit: nil, categoryValue: nil, source: nil, isTombstone: false)
        XCTAssertEqual(HealthDBMapper.sample(from: hr)!.value, 60, accuracy: 0.0001)
        let distance = HealthDBReader.RawSample(code: 8, identifier: "HKQuantityTypeIdentifierDistanceWalkingRunning", uuid: nil, start: Date(), end: Date(),
                                                quantity: 1500, originalQuantity: nil, originalUnit: nil, categoryValue: nil, source: nil, isTombstone: false)
        XCTAssertEqual(HealthDBMapper.sample(from: distance)!.value, 1.5, accuracy: 0.0001)
        XCTAssertEqual(HealthDBMapper.sample(from: distance)!.unit, "km")
        let unknown = HealthDBReader.RawSample(code: 1, identifier: nil, uuid: nil, start: Date(), end: Date(), quantity: 1, originalQuantity: nil,
                                               originalUnit: nil, categoryValue: nil, source: nil, isTombstone: false)
        XCTAssertNil(HealthDBMapper.sample(from: unknown))
    }
}
