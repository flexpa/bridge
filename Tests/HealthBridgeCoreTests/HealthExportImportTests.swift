import XCTest
@testable import HealthBridgeCore

final class HealthExportImportTests: XCTestCase {
    var dbURL: URL!
    var provider: HealthExportProvider!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("export.sqlite")
        let fixture = Bundle.module.url(forResource: "export", withExtension: nil, subdirectory: "Fixtures")!
        let importer = HealthExportImporter(destination: dbURL, scratch: dir.appendingPathComponent("scratch"))
        let report = try importer.run(source: fixture)
        XCTAssertEqual(report.records, 14)  // 14 top-level catalog records; unknown type and workout-nested record are skipped
        XCTAssertEqual(report.workouts, 1)
        XCTAssertEqual(report.clinicalRecords, 1)
        XCTAssertEqual(report.skippedTypes["HKQuantityTypeIdentifierSomethingUnknown"], 1)
        XCTAssertEqual(report.exportDate, "2026-09-10 09:15:00 -0400")
        provider = HealthExportProvider(databaseURL: dbURL)
    }

    func testStatusAndTypes() async {
        let status = await provider.status()
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.kind, "healthExport")
        XCTAssertEqual(status.sampleCount, 14)
        XCTAssertTrue(status.supportsClinicalRecords)
        XCTAssertNotNil(status.dataRange)
        let types = await provider.availableTypes().map(\.identifier)
        XCTAssertTrue(types.contains("HKQuantityTypeIdentifierStepCount"))
        XCTAssertTrue(types.contains("HKCategoryTypeIdentifierSleepAnalysis"))
        XCTAssertFalse(types.contains("HKQuantityTypeIdentifierSomethingUnknown"))
    }

    func testUnitsAreCanonicalized() async throws {
        let mass = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierBodyMass"]!
        let latest = try await provider.latestSample(of: mass)
        XCTAssertEqual(latest?.unit, "kg")
        XCTAssertEqual(latest!.value, 80.0, accuracy: 0.01)
        let dist = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierDistanceWalkingRunning"]!
        let d = try await provider.latestSample(of: dist)
        XCTAssertEqual(d!.value, 0.8047, accuracy: 0.001)
        XCTAssertEqual(d?.unit, "km")
        XCTAssertEqual(d?.source, "Test Watch")
    }

    func testSamplesAndStatistics() async throws {
        let steps = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierStepCount"]!
        let range = DateInterval(start: ISO8601.exportDate(from: "2026-09-01 00:00:00 -0400")!, end: ISO8601.exportDate(from: "2026-09-03 00:00:00 -0400")!)
        let samples = try await provider.samples(of: steps, in: range, limit: 10, ascending: true)
        XCTAssertEqual(samples.map(\.value), [800, 1200, 500])
        XCTAssertEqual(samples.first?.device, "Apple Watch")
        let stats = try await provider.statistics(of: steps, in: range, interval: .day)
        // Bucket boundaries follow the local calendar; totals must still add up.
        XCTAssertEqual(stats.reduce(0) { $0 + ($1.sum ?? 0) }, 2500, accuracy: 0.01)

        let hr = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierHeartRate"]!
        let hrSamples = try await provider.samples(of: hr, in: nil, limit: 100, ascending: true)
        // Includes the heart-rate Record nested inside the Workout? No: nested Records are skipped to avoid duplicates.
        XCTAssertEqual(hrSamples.count, 2)
    }

    func testSleepIsGroupedIntoANight() async throws {
        let segments = try await provider.sleepSegments(in: DateInterval(start: .distantPast, end: .distantFuture))
        XCTAssertEqual(segments.count, 5)
        let nights = HealthMath.nights(from: segments, includeSegments: false)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].inBedMinutes, 420)
        XCTAssertEqual(nights[0].deepMinutes, 60)
        XCTAssertEqual(nights[0].remMinutes, 210)
        XCTAssertEqual(nights[0].awakeMinutes, 10)
        XCTAssertEqual(nights[0].asleepMinutes, 390)
    }

    func testStandHoursAreLabelled() async throws {
        let stand = HealthTypeCatalog.byIdentifier["HKCategoryTypeIdentifierAppleStandHour"]!
        let samples = try await provider.samples(of: stand, in: nil, limit: 10, ascending: true)
        XCTAssertEqual(samples.map(\.categoryValue), ["stood", "idle"])
        XCTAssertEqual(samples.map(\.value), [0, 1])
    }

    func testWorkoutUsesStatisticsChildren() async throws {
        let workouts = try await provider.workouts(in: nil, activityType: nil, limit: 10)
        XCTAssertEqual(workouts.count, 1)
        let w = workouts[0]
        XCTAssertEqual(w.activityType, "running")
        XCTAssertEqual(w.durationMinutes, 31.5)
        XCTAssertEqual(w.totalEnergyKcal!, 312.4, accuracy: 0.01)
        XCTAssertEqual(w.totalDistanceKm!, 4.989, accuracy: 0.001)
        XCTAssertEqual(w.averageHeartRate, 152)
        XCTAssertEqual(w.maxHeartRate, 178)
        let filtered = try await provider.workouts(in: nil, activityType: "Running", limit: 10)
        XCTAssertEqual(filtered.count, 1)
        let none = try await provider.workouts(in: nil, activityType: "yoga", limit: 10)
        XCTAssertEqual(none.count, 0)
    }

    func testCharacteristics() async throws {
        let c = try await provider.characteristics()
        XCTAssertEqual(c.dateOfBirth, "1990-06-15")
        XCTAssertEqual(c.biologicalSex, "male")
        XCTAssertEqual(c.bloodType, "oPositive")
        XCTAssertEqual(c.fitzpatrickSkinType, "notSet")
        XCTAssertGreaterThan(c.ageYears ?? 0, 30)
    }

    func testClinicalRecordsLoadFHIRFiles() async throws {
        let records = try await provider.clinicalRecords(kind: nil, since: nil, limit: 10)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.kind, .labResultRecord)
        XCTAssertEqual(r.fhirResourceType, "Observation")
        XCTAssertEqual(r.displayName, "Glucose")
        XCTAssertEqual(r.fhirVersion, "4.0.1")
        XCTAssertEqual(r.sourceURL, "https://fhir.example.org/Observation/obs-1")
        XCTAssertEqual(r.resource["valueQuantity"]?["value"]?.doubleValue, 92)
        let filtered = try await provider.clinicalRecords(kind: .medicationRecord, since: nil, limit: 10)
        XCTAssertEqual(filtered.count, 0)
    }

    func testDailySummaryViaTool() async throws {
        let args = ToolArgs(["date": "2026-09-01"])
        let result = try await HealthTools.getDailySummary.handler(args, provider, BridgeSettings())
        let day = result["days"]?[0]
        XCTAssertEqual(day?["date"]?.stringValue, "2026-09-01")
        XCTAssertEqual(day?["steps"]?.doubleValue ?? 0, 2000, accuracy: 0.01)
        XCTAssertEqual(day?["standHours"]?.doubleValue, 1)
        XCTAssertEqual(day?["workouts"]?.arrayValue?.count, 1)
        XCTAssertEqual(day?["sleepAsleepMinutes"]?.doubleValue, 390)
        XCTAssertEqual(day?["heartRateAverage"]?.doubleValue, 80)
        XCTAssertEqual(day?["bodyMassKg"]?.doubleValue ?? 0, 80, accuracy: 0.01)
    }

    func testDatabaseFilePermissions() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }
}
