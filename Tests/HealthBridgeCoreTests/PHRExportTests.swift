import XCTest
@testable import HealthBridgeCore

/// The PHR export against the Health export fixture, checked against the IG's PGHD examples.
final class PHRExportTests: XCTestCase {
    var dir: URL!
    var provider: HealthExportProvider!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-phr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("export.sqlite")
        let fixture = Bundle.module.url(forResource: "export", withExtension: nil, subdirectory: "Fixtures")!
        let importer = HealthExportImporter(destination: dbURL, scratch: dir.appendingPathComponent("scratch"))
        _ = try importer.run(source: fixture)
        provider = HealthExportProvider(databaseURL: dbURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func export(_ name: String = "record.phr", options: PHRExportOptions = PHRExportOptions(),
                        provider: HealthDataProvider? = nil) async throws -> (report: PHRExportReport, lines: [JSONValue]) {
        let url = dir.appendingPathComponent(name)
        let exporter = PHRExporter(provider: provider ?? self.provider, scratch: dir.appendingPathComponent("export-scratch-\(UUID().uuidString)"))
        let report = try await exporter.run(to: url, options: options)
        return (report, try Self.lines(of: url))
    }

    private static func lines(of url: URL) throws -> [JSONValue] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map { try JSON.parse(String($0)) }
    }

    private func observations(_ lines: [JSONValue], pghdCode: String) -> [JSONValue] {
        lines.filter { r in
            r["resourceType"]?.stringValue == "Observation"
                && (r["code"]?["coding"]?.arrayValue ?? []).contains { $0["system"]?.stringValue == PHRIG.pghdCodeSystem && $0["code"]?.stringValue == pghdCode }
        }
    }

    private func profile(_ r: JSONValue) -> String? { r["meta"]?["profile"]?[0]?.stringValue }
    private func category(_ r: JSONValue) -> String? { r["category"]?[0]?["coding"]?[0]?["code"]?.stringValue }

    private func coding(_ r: JSONValue, system: String) -> JSONValue? {
        (r["code"]?["coding"]?.arrayValue ?? []).first { $0["system"]?.stringValue == system }
    }

    // MARK: File shape

    func testFileStartsWithPatientCoverPageAndProvenance() async throws {
        let (report, lines) = try await export(options: PHRExportOptions(patientName: "Test Person"))
        XCTAssertEqual(report.format, .phr)
        XCTAssertEqual(report.resources, lines.count)
        XCTAssertGreaterThan(report.bytes, 1000)

        let patient = lines[0]
        XCTAssertEqual(patient["resourceType"]?.stringValue, "Patient")
        XCTAssertEqual(patient["id"]?.stringValue, "me")
        XCTAssertEqual(patient["birthDate"]?.stringValue, "1990-06-15")
        XCTAssertEqual(patient["gender"]?.stringValue, "male")
        XCTAssertEqual(patient["name"]?[0]?["text"]?.stringValue, "Test Person")

        let cover = lines[1]
        XCTAssertEqual(cover["resourceType"]?.stringValue, "Composition")
        XCTAssertEqual(cover["status"]?.stringValue, "final")
        XCTAssertEqual(cover["type"]?["coding"]?[0]?["code"]?.stringValue, "11503-0")
        XCTAssertEqual(cover["subject"]?["reference"]?.stringValue, "Patient/me")
        XCTAssertEqual(cover["title"]?.stringValue, "Personal Health Record for Test Person")
        let sections = cover["section"]?.arrayValue ?? []
        XCTAssertEqual(sections.count, 3, "about, PGHD, clinical")
        XCTAssertTrue(sections[1]["text"]?["div"]?.stringValue?.contains("Steps: 3") ?? false)
        XCTAssertTrue(sections[2]["text"]?["div"]?.stringValue?.contains("labResultRecord: 1") ?? false)

        let provenance = lines[2]
        XCTAssertEqual(provenance["resourceType"]?.stringValue, "Provenance")
        XCTAssertEqual(provenance["target"]?[0]?["reference"]?.stringValue, "Composition/cover")
        XCTAssertEqual(provenance["agent"]?[0]?["who"]?["reference"]?.stringValue, "Patient/me")
        XCTAssertTrue(provenance["entity"]?[0]?["what"]?["display"]?.stringValue?.contains("Health export") ?? false)

        // Every line is a resource with a unique id; every device reference resolves to an earlier line.
        var ids = Set<String>()
        var devices = Set<String>()
        for r in lines {
            let id = try XCTUnwrap(r["id"]?.stringValue)
            XCTAssertNotNil(r["resourceType"]?.stringValue)
            XCTAssertTrue(ids.insert("\(r["resourceType"]!.stringValue!)/\(id)").inserted, "duplicate id \(id)")
            if r["resourceType"]?.stringValue == "Device" { devices.insert("Device/" + id) }
            if let ref = r["device"]?["reference"]?.stringValue {
                XCTAssertTrue(devices.contains(ref), "\(ref) referenced before its Device line")
            }
        }
        XCTAssertEqual(report.devices, devices.count)
        XCTAssertEqual(report.clinicalRecords, 1)
        XCTAssertEqual(report.workouts, 1)
        XCTAssertEqual(report.sleepEpisodes, 1)
    }

    func testPatientWithoutNameHasNoNameElement() async throws {
        let (_, lines) = try await export()
        XCTAssertNil(lines[0]["name"])
        XCTAssertEqual(lines[1]["title"]?.stringValue, "Personal Health Record")
    }

    func testOutputFilePermissionsAreOwnerOnly() async throws {
        let (report, _) = try await export()
        let attrs = try FileManager.default.attributesOfItem(atPath: report.url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    // MARK: Observations

    func testHeartRateFollowsThePGHDHeartRateProfile() async throws {
        let (_, lines) = try await export()
        let hr = observations(lines, pghdCode: "heartRate").filter { $0["component"] == nil }
        XCTAssertEqual(hr.count, 2)
        let first = try XCTUnwrap(hr.first { $0["valueQuantity"]?["value"]?.doubleValue == 72 })
        XCTAssertEqual(profile(first), PGHDProfile.heartRate.url)
        XCTAssertEqual(category(first), "vital-signs")
        XCTAssertEqual(coding(first, system: PHRIG.loinc)?["code"]?.stringValue, "8867-4")
        XCTAssertEqual(first["valueQuantity"]?["code"]?.stringValue, "/min")
        XCTAssertEqual(first["valueQuantity"]?["system"]?.stringValue, PHRIG.ucum)
        XCTAssertEqual(first["effectiveDateTime"]?.stringValue, ISO8601.string(from: ISO8601.exportDate(from: "2026-09-01 07:05:00 -0400")!))
        XCTAssertNil(first["effectivePeriod"])
        XCTAssertEqual(first["subject"]?["reference"]?.stringValue, "Patient/me")
        XCTAssertEqual(first["performer"]?[0]?["reference"]?.stringValue, "Patient/me")
        XCTAssertEqual(first["status"]?.stringValue, "final")
        XCTAssertEqual(first["device"]?["display"]?.stringValue, "Test Watch")
    }

    func testStepsAreActivityWithAPeriodAndLOINC() async throws {
        let (_, lines) = try await export()
        let steps = observations(lines, pghdCode: "stepCount")
        XCTAssertEqual(steps.count, 3)
        let s = try XCTUnwrap(steps.first { $0["valueQuantity"]?["value"]?.doubleValue == 800 })
        XCTAssertEqual(profile(s), PGHDProfile.activity.url)
        XCTAssertEqual(category(s), "activity")
        XCTAssertEqual(coding(s, system: PHRIG.loinc)?["code"]?.stringValue, "55423-8")
        XCTAssertNotNil(s["effectivePeriod"]?["start"])
        XCTAssertNotNil(s["effectivePeriod"]?["end"])
        XCTAssertEqual(s["valueQuantity"]?["code"]?.stringValue, "{steps}")
        XCTAssertEqual(s["device"]?["display"]?.stringValue, "Test Watch")
        // The device carries both the app and the hardware name.
        let device = try XCTUnwrap(lines.first { $0["resourceType"]?.stringValue == "Device" && "Device/\($0["id"]!.stringValue!)" == s["device"]?["reference"]?.stringValue })
        let names = (device["deviceName"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), ["Test Watch", "Apple Watch"])
        XCTAssertEqual(device["manufacturer"]?.stringValue, "Apple Inc.")
        XCTAssertEqual(profile(device), PGHDProfile.device.url)
    }

    func testBodyMassAndDistanceUseTheIGUnits() async throws {
        let (_, lines) = try await export()
        let mass = try XCTUnwrap(observations(lines, pghdCode: "bodyMass").first)
        XCTAssertEqual(profile(mass), PGHDProfile.bodyWeight.url)
        XCTAssertEqual(coding(mass, system: PHRIG.loinc)?["code"]?.stringValue, "29463-7")
        XCTAssertEqual(mass["valueQuantity"]?["value"]?.doubleValue ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(mass["valueQuantity"]?["code"]?.stringValue, "kg")

        let distance = try XCTUnwrap(observations(lines, pghdCode: "distanceWalkingRunning").first { $0["derivedFrom"] == nil })
        XCTAssertEqual(distance["valueQuantity"]?["value"]?.doubleValue ?? 0, 0.8047, accuracy: 0.0001)
        XCTAssertEqual(distance["valueQuantity"]?["code"]?.stringValue, "km")
    }

    func testStandHoursBecomeOneHourStoodOrZero() async throws {
        let (_, lines) = try await export()
        let hours = observations(lines, pghdCode: "appleStandHour").sorted { ($0["effectivePeriod"]?["start"]?.stringValue ?? "") < ($1["effectivePeriod"]?["start"]?.stringValue ?? "") }
        XCTAssertEqual(hours.map { $0["valueQuantity"]?["value"]?.doubleValue }, [1, 0])
        let first = try XCTUnwrap(hours.first)
        XCTAssertEqual(first["valueQuantity"]?["code"]?.stringValue, "h")
        XCTAssertEqual(profile(first), PGHDProfile.activity.url)
    }

    // MARK: Sleep

    func testSleepSegmentsAndOneEpisodePerNight() async throws {
        let (_, lines) = try await export()
        let stages = observations(lines, pghdCode: "sleepAnalysis")
        XCTAssertEqual(stages.count, 5)
        for s in stages {
            XCTAssertEqual(profile(s), PGHDProfile.sleep.url)
            XCTAssertEqual(category(s), "social-history")
            XCTAssertEqual(s["valueCodeableConcept"]?["coding"]?[0]?["system"]?.stringValue, PHRIG.sleepAnalysisCodeSystem)
            XCTAssertNotNil(s["effectivePeriod"])
        }
        XCTAssertEqual(Set(stages.compactMap { $0["valueCodeableConcept"]?["coding"]?[0]?["code"]?.stringValue }),
                       ["inBed", "asleepCore", "asleepDeep", "awake", "asleepREM"])

        let episodes = observations(lines, pghdCode: "sleepEpisode")
        XCTAssertEqual(episodes.count, 1)
        let night = try XCTUnwrap(episodes.first)
        XCTAssertEqual(profile(night), PGHDProfile.sleepEpisode.url)
        XCTAssertEqual(night["effectivePeriod"]?["start"]?.stringValue, ISO8601.string(from: ISO8601.exportDate(from: "2026-08-31 23:00:00 -0400")!))
        XCTAssertEqual(night["effectivePeriod"]?["end"]?.stringValue, ISO8601.string(from: ISO8601.exportDate(from: "2026-09-01 06:00:00 -0400")!))
        XCTAssertEqual(night["hasMember"]?.arrayValue?.count, 5)
        var components: [String: JSONValue] = [:]
        for c in night["component"]?.arrayValue ?? [] {
            components[c["code"]?["coding"]?[0]?["code"]?.stringValue ?? ""] = c
        }
        XCTAssertEqual(components["totalSleepTime"]?["valueQuantity"]?["value"]?.doubleValue, 390)
        XCTAssertEqual(components["coreSleepDuration"]?["valueQuantity"]?["value"]?.doubleValue, 120)
        XCTAssertEqual(components["deepSleepDuration"]?["valueQuantity"]?["value"]?.doubleValue, 60)
        XCTAssertEqual(components["remSleepDuration"]?["valueQuantity"]?["value"]?.doubleValue, 210)
        XCTAssertEqual(components["wakeAfterSleepOnset"]?["valueQuantity"]?["value"]?.doubleValue, 10)
        XCTAssertEqual(components["latencyToSleepOnset"]?["valueQuantity"]?["value"]?.doubleValue, 10)
        XCTAssertEqual(components["latencyToArising"]?["valueQuantity"]?["value"]?.doubleValue, 10)
        XCTAssertEqual(components["numberOfAwakenings"]?["valueInteger"]?.intValue, 1)
        XCTAssertEqual(components["sleepEfficiencyPercentage"]?["valueQuantity"]?["value"]?.doubleValue ?? 0, 390.0 / 420 * 100, accuracy: 0.01)
        XCTAssertEqual(components["isMainSleep"]?["valueBoolean"]?.boolValue, true)
        XCTAssertEqual(components["remSleepPercentage"]?["valueQuantity"]?["code"]?.stringValue, "%")
        for c in night["component"]?.arrayValue ?? [] {
            XCTAssertEqual(c["code"]?["coding"]?[0]?["system"]?.stringValue, PHRIG.sleepEpisodeCodeSystem)
        }
    }

    func testSleepSegmentsCanBeLeftOut() async throws {
        let (report, lines) = try await export(options: PHRExportOptions(includeSleepSegments: false))
        XCTAssertEqual(observations(lines, pghdCode: "sleepAnalysis").count, 0)
        XCTAssertEqual(report.sleepEpisodes, 1)
        XCTAssertNil(observations(lines, pghdCode: "sleepEpisode").first?["hasMember"])
    }

    // MARK: Workouts

    func testWorkoutHasMemberObservationsForDistanceAndEnergy() async throws {
        let (_, lines) = try await export()
        let workouts = lines.filter { profile($0) == PGHDProfile.workout.url }
        XCTAssertEqual(workouts.count, 1)
        let w = try XCTUnwrap(workouts.first)
        XCTAssertEqual(category(w), "activity")
        XCTAssertEqual(coding(w, system: PHRIG.pghdCodeSystem)?["code"]?.stringValue, "running")
        XCTAssertEqual(coding(w, system: PHRIG.pghdCodeSystem)?["display"]?.stringValue, "Running")
        XCTAssertNotNil(w["effectivePeriod"])
        let members = (w["hasMember"]?.arrayValue ?? []).compactMap { $0["reference"]?.stringValue }
        XCTAssertEqual(members.count, 2)

        let wid = w["id"]!.stringValue!
        let energy = try XCTUnwrap(lines.first { $0["id"]?.stringValue == wid + "-energy" })
        XCTAssertTrue(members.contains("Observation/" + wid + "-energy"))
        XCTAssertEqual(energy["valueQuantity"]?["value"]?.doubleValue ?? 0, 312.4, accuracy: 0.01)
        XCTAssertEqual(energy["valueQuantity"]?["code"]?.stringValue, "kcal")
        XCTAssertEqual(energy["derivedFrom"]?[0]?["reference"]?.stringValue, "Observation/" + wid)
        XCTAssertEqual(profile(energy), PGHDProfile.activity.url)

        let distance = try XCTUnwrap(lines.first { $0["id"]?.stringValue == wid + "-distance" })
        XCTAssertEqual(coding(distance, system: PHRIG.pghdCodeSystem)?["code"]?.stringValue, "distanceWalkingRunning")
        XCTAssertEqual(distance["valueQuantity"]?["value"]?.doubleValue ?? 0, 4.989, accuracy: 0.001)

        let components = w["component"]?.arrayValue ?? []
        let byText = Dictionary(uniqueKeysWithValues: components.map { ($0["code"]?["text"]?.stringValue ?? "", $0) })
        XCTAssertEqual(byText["Duration"]?["valueQuantity"]?["value"]?.doubleValue, 31.5)
        XCTAssertEqual(byText["Average heart rate"]?["valueQuantity"]?["value"]?.doubleValue, 152)
        XCTAssertEqual(byText["Maximum heart rate"]?["valueQuantity"]?["value"]?.doubleValue, 178)
        XCTAssertNil(byText["Duration"]?["code"]?["coding"], "an empty coding array is not valid FHIR")
    }

    // MARK: Clinical records

    func testClinicalRecordsPassThroughWithSourceAndSubject() async throws {
        let (_, lines) = try await export()
        let obs = try XCTUnwrap(lines.first { $0["id"]?.stringValue == "obs-1" })
        XCTAssertEqual(obs["resourceType"]?.stringValue, "Observation")
        XCTAssertEqual(obs["meta"]?["source"]?.stringValue, "https://fhir.example.org/Observation/obs-1")
        XCTAssertEqual(obs["subject"]?["reference"]?.stringValue, "Patient/me")
        XCTAssertEqual(obs["valueQuantity"]?["value"]?.doubleValue, 92)
        XCTAssertEqual(obs["code"]?["coding"]?[0]?["code"]?.stringValue, "2345-7", "the provider's resource is not rewritten")
    }

    func testClinicalRecordsCanBeExcluded() async throws {
        let (report, lines) = try await export(options: PHRExportOptions(includeClinicalRecords: false))
        XCTAssertEqual(report.clinicalRecords, 0)
        XCTAssertNil(lines.first { $0["id"]?.stringValue == "obs-1" })
        XCTAssertEqual(lines[1]["section"]?.arrayValue?.count, 2)
    }

    // MARK: Range, determinism, container

    func testRangeLimitsSamplesAndKeepsWholeNights() async throws {
        let start = ISO8601.exportDate(from: "2026-09-02 00:00:00 -0400")!
        let end = ISO8601.exportDate(from: "2026-09-03 00:00:00 -0400")!
        let (report, lines) = try await export(options: PHRExportOptions(range: DateInterval(start: start, end: end)))
        XCTAssertEqual(observations(lines, pghdCode: "stepCount").map { $0["valueQuantity"]?["value"]?.doubleValue }, [500])
        XCTAssertEqual(observations(lines, pghdCode: "heartRate").count, 0)
        XCTAssertEqual(report.sleepEpisodes, 0, "the night ended on the 1st, outside the range")
        XCTAssertEqual(report.workouts, 0)
        XCTAssertEqual(report.clinicalRecords, 0, "an explicit range also applies to clinical records")
        XCTAssertEqual(lines[2]["occurredPeriod"]?["start"]?.stringValue, ISO8601.string(from: start))

        let nightRange = DateInterval(start: ISO8601.exportDate(from: "2026-09-01 05:00:00 -0400")!, end: ISO8601.exportDate(from: "2026-09-01 12:00:00 -0400")!)
        let (r2, l2) = try await export("night.phr", options: PHRExportOptions(range: nightRange))
        XCTAssertEqual(r2.sleepEpisodes, 1)
        XCTAssertEqual(observations(l2, pghdCode: "sleepAnalysis").count, 5, "a night that ends in the range is exported whole")
    }

    func testIdsAreStableAcrossExports() async throws {
        let (_, a) = try await export("a.phr")
        let (_, b) = try await export("b.phr")
        func ids(_ lines: [JSONValue]) -> Set<String> {
            Set(lines.filter { $0["resourceType"]?.stringValue == "Observation" }.compactMap { $0["id"]?.stringValue })
        }
        XCTAssertEqual(ids(a), ids(b))
        XCTAssertGreaterThan(ids(a).count, 15)
    }

    func testSPHRIsAZipContainingThePHR() async throws {
        let url = dir.appendingPathComponent("My Record.sphr")
        let exporter = PHRExporter(provider: provider, scratch: dir.appendingPathComponent("sphr-scratch"))
        let report = try await exporter.run(to: url, options: PHRExportOptions())
        XCTAssertEqual(report.format, .sphr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var magic = Data()
        let handle = try FileHandle(forReadingFrom: url)
        magic = try handle.read(upToCount: 2) ?? Data()
        try handle.close()
        XCTAssertEqual([UInt8](magic), [0x50, 0x4B], "zip signature")

        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", url.path, unpacked.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        let phr = unpacked.appendingPathComponent("My Record.phr")
        XCTAssertTrue(FileManager.default.fileExists(atPath: phr.path), "the container holds <name>.phr at its root")
        let lines = try Self.lines(of: phr)
        XCTAssertEqual(lines.count, report.resources)
        XCTAssertEqual(lines[0]["resourceType"]?.stringValue, "Patient")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sphr-scratch").path), "scratch is removed")
    }

    func testExportRefusesAnEmptySource() async {
        let empty = HealthExportProvider(databaseURL: dir.appendingPathComponent("missing.sqlite"))
        let exporter = PHRExporter(provider: empty, scratch: dir.appendingPathComponent("empty-scratch"))
        do {
            _ = try await exporter.run(to: dir.appendingPathComponent("empty.phr"), options: PHRExportOptions())
            XCTFail("expected an error")
        } catch let error as HealthDataError {
            guard case .unavailable = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("empty.phr").path))
    }

    func testDemoProviderExportsEveryKindOfResource() async throws {
        let (report, lines) = try await export("demo.phr", provider: DemoHealthProvider(days: 10))
        XCTAssertEqual(report.sleepEpisodes, 10)
        XCTAssertGreaterThan(report.workouts, 0)
        XCTAssertEqual(report.clinicalRecords, 3)
        let profiles = Set(lines.compactMap(profile))
        XCTAssertTrue(profiles.isSuperset(of: [PGHDProfile.activity.url, PGHDProfile.heartRate.url, PGHDProfile.vitalSigns.url,
                                                PGHDProfile.oxygenSaturation.url, PGHDProfile.respiratoryRate.url, PGHDProfile.bodyWeight.url,
                                                PGHDProfile.sleep.url, PGHDProfile.sleepEpisode.url, PGHDProfile.workout.url, PGHDProfile.device.url]))
        // Clinical records without a subject are attributed to the patient.
        let immunization = try XCTUnwrap(lines.first { $0["resourceType"]?.stringValue == "Immunization" })
        XCTAssertEqual(immunization["patient"]?["reference"]?.stringValue, "Patient/me")
    }
}

/// Mappings that the fixture does not exercise, checked one sample at a time.
final class PGHDMappingTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-pghd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func at(_ iso: String) -> Date { ISO8601.date(from: iso)! }

    /// A store holding just the given samples and workouts.
    private func provider(samples: [HealthSample], workouts: [Workout] = []) throws -> HealthExportProvider {
        let db = dir.appendingPathComponent("\(UUID().uuidString).sqlite")
        let writer = try HealthStoreWriter(destination: db)
        for s in samples { writer.add(s, uuid: s.uuid) }
        for w in workouts { writer.add(w, uuid: w.uuid) }
        writer.setMeta("sourceKind", "export")
        try writer.finish()
        return HealthExportProvider(databaseURL: db)
    }

    private func exportLines(_ provider: HealthDataProvider, options: PHRExportOptions = PHRExportOptions()) async throws -> [JSONValue] {
        let url = dir.appendingPathComponent("\(UUID().uuidString).phr")
        let exporter = PHRExporter(provider: provider, scratch: dir.appendingPathComponent("scratch-\(UUID().uuidString)"))
        _ = try await exporter.run(to: url, options: options)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { try JSON.parse(String($0)) }
    }

    private func pghd(_ lines: [JSONValue], _ code: String) -> [JSONValue] {
        lines.filter { r in
            (r["code"]?["coding"]?.arrayValue ?? []).contains { $0["system"]?.stringValue == PHRIG.pghdCodeSystem && $0["code"]?.stringValue == code }
        }
    }

    func testEveryCatalogTypeHasAMapping() {
        for t in HealthTypeCatalog.all {
            XCTAssertNotNil(PGHDCodeMap.mapping(for: t.identifier), "no PGHD mapping for \(t.identifier)")
        }
        for (id, m) in PGHDCodeMap.table {
            XCTAssertNotNil(HealthTypeCatalog.byIdentifier[id], "mapping for a type outside the catalog: \(id)")
            XCTAssertFalse(m.display.isEmpty)
            XCTAssertEqual(m.profile.category.code.isEmpty, false, "\(id) maps to a profile without a category")
        }
        XCTAssertTrue(PGHDCodeMap.workoutActivityCodes.isSuperset(of: WorkoutActivityNames.names.values))
    }

    func testBloodPressureHalvesTakenTogetherBecomeOnePanel() async throws {
        let t = at("2026-05-01T08:00:00")
        let later = at("2026-05-02T08:00:00")
        let p = try provider(samples: [
            HealthSample(type: "HKQuantityTypeIdentifierBloodPressureSystolic", start: t, end: t, value: 121, unit: "mmHg", source: "Cuff", uuid: "AAAA-1"),
            HealthSample(type: "HKQuantityTypeIdentifierBloodPressureDiastolic", start: t, end: t, value: 79, unit: "mmHg", source: "Cuff", uuid: "AAAA-2"),
            HealthSample(type: "HKQuantityTypeIdentifierBloodPressureSystolic", start: later, end: later, value: 130, unit: "mmHg", source: "Cuff"),
        ])
        let lines = try await exportLines(p)
        let panels = pghd(lines, "bloodPressure")
        XCTAssertEqual(panels.count, 1)
        let panel = try XCTUnwrap(panels.first)
        XCTAssertEqual(panel["meta"]?["profile"]?[0]?.stringValue, PGHDProfile.bloodPressure.url)
        XCTAssertEqual(panel["code"]?["coding"]?[0]?["code"]?.stringValue, "85354-9")
        XCTAssertNil(panel["valueQuantity"])
        let components = panel["component"]?.arrayValue ?? []
        XCTAssertEqual(components.count, 2)
        guard components.count == 2 else { return }
        XCTAssertEqual(components[0]["code"]?["coding"]?[0]?["code"]?.stringValue, "8480-6")
        XCTAssertEqual(components[0]["valueQuantity"]?["value"]?.doubleValue, 121)
        XCTAssertEqual(components[0]["valueQuantity"]?["code"]?.stringValue, "mm[Hg]")
        XCTAssertEqual(components[1]["code"]?["coding"]?[0]?["code"]?.stringValue, "8462-4")
        XCTAssertEqual(components[1]["valueQuantity"]?["value"]?.doubleValue, 79)
        XCTAssertEqual(panel["identifier"]?.arrayValue?.count, 2)
        XCTAssertEqual(panel["identifier"]?[0]?["value"]?.stringValue, "urn:uuid:aaaa-1")
        XCTAssertEqual(panel["identifier"]?[0]?["system"]?.stringValue, "urn:ietf:rfc:3986")

        // The unpaired systolic reading, the last instant in the store, is exported on its own.
        let lone = try XCTUnwrap(pghd(lines, "bloodPressureSystolic").first)
        XCTAssertEqual(lone["valueQuantity"]?["value"]?.doubleValue, 130)
        XCTAssertEqual(lone["meta"]?["profile"]?[0]?.stringValue, PGHDProfile.vitalSigns.url)
        XCTAssertEqual(lone["code"]?["coding"]?[0]?["code"]?.stringValue, "8480-6")
    }

    func testHealthKitUUIDBecomesTheResourceIdAndIdentifier() async throws {
        let t = at("2026-05-01T08:00:00")
        let p = try provider(samples: [
            HealthSample(type: "HKQuantityTypeIdentifierHeartRate", start: t, end: t, value: 60, unit: "count/min", source: "Watch",
                         uuid: "1D57147F-BE0C-4024-9172-6871A5D70CB3"),
        ])
        let lines = try await exportLines(p)
        let hr = try XCTUnwrap(pghd(lines, "heartRate").first)
        XCTAssertEqual(hr["id"]?.stringValue, "1d57147f-be0c-4024-9172-6871a5d70cb3")
        XCTAssertEqual(hr["identifier"]?[0]?["value"]?.stringValue, "urn:uuid:1d57147f-be0c-4024-9172-6871a5d70cb3")
    }

    func testUnitsAreConvertedToWhatTheIGDeclares() async throws {
        let t = at("2026-05-01T08:00:00")
        let e = at("2026-05-01T09:00:00")
        let p = try provider(samples: [
            HealthSample(type: "HKQuantityTypeIdentifierBloodGlucose", start: t, end: t, value: 90, unit: "mg/dL"),
            HealthSample(type: "HKQuantityTypeIdentifierWalkingSpeed", start: t, end: t, value: 5.4, unit: "km/h"),
            HealthSample(type: "HKQuantityTypeIdentifierDistanceCycling", start: t, end: e, value: 12.5, unit: "km"),
            HealthSample(type: "HKQuantityTypeIdentifierDietaryWater", start: t, end: t, value: 250, unit: "mL"),
            HealthSample(type: "HKQuantityTypeIdentifierWalkingStepLength", start: t, end: t, value: 72, unit: "cm"),
            HealthSample(type: "HKQuantityTypeIdentifierBodyTemperature", start: t, end: t, value: 36.6, unit: "degC"),
            HealthSample(type: "HKQuantityTypeIdentifierBodyMassIndex", start: t, end: t, value: 22.1, unit: "count"),
            HealthSample(type: "HKQuantityTypeIdentifierEnvironmentalAudioExposure", start: t, end: e, value: 61, unit: "dBASPL"),
        ])
        let lines = try await exportLines(p)

        let glucose = try XCTUnwrap(pghd(lines, "bloodGlucose").first)
        XCTAssertEqual(glucose["meta"]?["profile"]?[0]?.stringValue, PGHDProfile.bloodGlucose.url)
        XCTAssertEqual(glucose["valueQuantity"]?["value"]?.doubleValue ?? 0, 90 / 18.0182, accuracy: 0.0001)
        XCTAssertEqual(glucose["valueQuantity"]?["code"]?.stringValue, "mmol/L")
        XCTAssertEqual(glucose["valueQuantity"]?["extension"]?[0]?["url"]?.stringValue, PHRIG.quantityTranslationExtension)
        XCTAssertEqual(glucose["valueQuantity"]?["extension"]?[0]?["valueQuantity"]?["value"]?.doubleValue, 90)
        XCTAssertEqual(glucose["valueQuantity"]?["extension"]?[0]?["valueQuantity"]?["code"]?.stringValue, "mg/dl")
        XCTAssertNotNil(glucose["issued"], "the blood glucose profile requires issued")

        func one(_ code: String) throws -> JSONValue { try XCTUnwrap(pghd(lines, code).first, "no \(code) observation") }
        XCTAssertEqual(try one("walkingSpeed")["valueQuantity"]?["value"]?.doubleValue ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(try one("walkingSpeed")["valueQuantity"]?["code"]?.stringValue, "m/s")
        XCTAssertEqual(try one("distanceCycling")["valueQuantity"]?["value"]?.doubleValue, 12500)
        XCTAssertEqual(try one("distanceCycling")["valueQuantity"]?["code"]?.stringValue, "m")
        XCTAssertEqual(try one("dietaryWater")["valueQuantity"]?["value"]?.doubleValue, 0.25)
        XCTAssertEqual(try one("dietaryWater")["valueQuantity"]?["code"]?.stringValue, "L")
        XCTAssertEqual(try one("dietaryWater")["category"]?[0]?["coding"]?[0]?["code"]?.stringValue, "social-history")
        XCTAssertEqual(try one("walkingStepLength")["valueQuantity"]?["value"]?.doubleValue, 0.72)
        XCTAssertEqual(try one("bodyTemperature")["valueQuantity"]?["code"]?.stringValue, "Cel")
        XCTAssertEqual(try one("bodyTemperature")["code"]?["coding"]?[0]?["code"]?.stringValue, "8310-5")
        XCTAssertEqual(try one("bodyMassIndex")["valueQuantity"]?["code"]?.stringValue, "kg/m2")
        XCTAssertEqual(try one("environmentalAudioExposure")["valueQuantity"]?["code"]?.stringValue, "dB")
        XCTAssertEqual(try one("environmentalAudioExposure")["meta"]?["profile"]?[0]?.stringValue, PGHDProfile.hearing.url)
    }

    func testEventsAndSessionsCarryNoValue() async throws {
        let t = at("2026-05-01T08:00:00")
        let e = at("2026-05-01T08:10:00")
        let p = try provider(samples: [
            HealthSample(type: "HKCategoryTypeIdentifierLowHeartRateEvent", start: t, end: t, value: 0, unit: ""),
            HealthSample(type: "HKCategoryTypeIdentifierMindfulSession", start: t, end: e, value: 0, unit: "", source: "Breathe"),
            HealthSample(type: "HKCategoryTypeIdentifierMenstrualFlow", start: t, end: t, value: 3, unit: "", categoryValue: "medium"),
            HealthSample(type: "HKCategoryTypeIdentifierMenstrualFlow", start: e, end: e, value: 1, unit: "", categoryValue: "unspecified"),
        ])
        let lines = try await exportLines(p)
        let low = try XCTUnwrap(pghd(lines, "lowHeartRateEvent").first)
        XCTAssertEqual(low["meta"]?["profile"]?[0]?.stringValue, PGHDProfile.cardiacFunction.url)
        XCTAssertEqual(low["category"]?[0]?["coding"]?[0]?["code"]?.stringValue, "vital-signs")
        XCTAssertNil(low["valueQuantity"])
        XCTAssertNotNil(low["effectiveDateTime"])

        let mindful = try XCTUnwrap(pghd(lines, "mindfulSession").first)
        XCTAssertEqual(mindful["meta"]?["profile"]?[0]?.stringValue, PGHDProfile.mindfulness.url)
        XCTAssertNil(mindful["valueQuantity"])
        XCTAssertNotNil(mindful["effectivePeriod"])

        let flow = pghd(lines, "menstrualFlow").sorted { ($0["effectiveDateTime"]?.stringValue ?? "") < ($1["effectiveDateTime"]?.stringValue ?? "") }
        XCTAssertEqual(flow.count, 2)
        guard flow.count == 2 else { return }
        XCTAssertEqual(flow[0]["valueQuantity"]?["value"]?.doubleValue, 2)
        XCTAssertEqual(flow[0]["valueQuantity"]?["unit"]?.stringValue, "medium")
        XCTAssertNil(flow[1]["valueQuantity"])
        XCTAssertEqual(flow[1]["dataAbsentReason"]?["coding"]?[0]?["code"]?.stringValue, "unknown")
    }

    func testUnknownWorkoutActivityFallsBackToOther() async throws {
        let t = at("2026-05-01T08:00:00")
        // A store is "available" when it has samples, so give it one.
        let p = try provider(samples: [HealthSample(type: "HKQuantityTypeIdentifierStepCount", start: t, end: t.addingTimeInterval(60), value: 10, unit: "count")],
                             workouts: [
            Workout(activityType: "activity999", start: t, end: t.addingTimeInterval(1800), durationMinutes: 30, source: "Watch"),
            Workout(activityType: "highIntensityIntervalTraining", start: t.addingTimeInterval(7200), end: t.addingTimeInterval(9000), durationMinutes: 30,
                    totalEnergyKcal: 250, source: "Watch", uuid: "W-1"),
        ])
        let lines = try await exportLines(p)
        let workouts = lines.filter { $0["meta"]?["profile"]?[0]?.stringValue == PGHDProfile.workout.url }
            .sorted { ($0["effectivePeriod"]?["start"]?.stringValue ?? "") < ($1["effectivePeriod"]?["start"]?.stringValue ?? "") }
        XCTAssertEqual(workouts.count, 2)
        guard workouts.count == 2 else { return }
        XCTAssertEqual(workouts[0]["code"]?["coding"]?[0]?["code"]?.stringValue, "other")
        XCTAssertEqual(workouts[0]["code"]?["text"]?.stringValue, "Activity999")
        XCTAssertNil(workouts[0]["hasMember"])
        XCTAssertEqual(workouts[1]["code"]?["coding"]?[0]?["code"]?.stringValue, "highIntensityIntervalTraining")
        XCTAssertEqual(workouts[1]["code"]?["coding"]?[0]?["display"]?.stringValue, "High intensity interval training")
        XCTAssertEqual(workouts[1]["id"]?.stringValue, "w-1")
        XCTAssertEqual(workouts[1]["hasMember"]?[0]?["reference"]?.stringValue, "Observation/w-1-energy")
    }

    func testMonthWindowsCoverTheRangeExactlyOnce() {
        let range = DateInterval(start: ISO8601.date(from: "2024-01-15")!, end: ISO8601.date(from: "2024-04-02")!)
        let windows = PHRExporter.windows(range)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first?.start, range.start)
        XCTAssertEqual(windows.last?.end, range.end)
        for (a, b) in zip(windows, windows.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertEqual(PHRExporter.windows(DateInterval(start: range.start, end: range.start)).count, 0)
    }
}
