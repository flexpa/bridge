import Foundation

/// Serves data imported from a Health app export (Health → profile →
/// Export All Health Data → export.zip). Works on today's macOS, where the
/// live HealthKit store does not exist.
public final class HealthExportProvider: HealthDataProvider, @unchecked Sendable {
    public let kind = "healthExport"

    private let databaseURL: URL
    private var db: SQLiteDatabase?
    private let lock = NSLock()

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            db = try? SQLiteDatabase(path: databaseURL.path)
        }
    }

    public var hasData: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        return ((try? db.scalar("SELECT COUNT(*) FROM samples")) ?? 0) > 0
    }

    /// Re-opens the database after an import replaced it.
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        db = FileManager.default.fileExists(atPath: databaseURL.path) ? try? SQLiteDatabase(path: databaseURL.path) : nil
    }

    private func requireDB() throws -> SQLiteDatabase {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw HealthDataError.unavailable("No Health export has been imported. Import one from the Flexpa Health Bridge menu.") }
        return db
    }

    public func meta(_ key: String) -> String? {
        guard let db = try? requireDB() else { return nil }
        return (try? db.query("SELECT value FROM meta WHERE key = ?", bind: { $0.bind(1, key) }, row: { $0.string(0) }))?.first ?? nil
    }

    // MARK: HealthDataProvider

    public func status() async -> ProviderStatus {
        guard let db = try? requireDB() else {
            return ProviderStatus(kind: kind, description: "Health export (none imported)", available: false, authorization: .notApplicable,
                                  detail: "Export from the Health app on iPhone (profile picture → Export All Health Data), AirDrop the zip to this Mac, and import it from the Flexpa Health Bridge menu.")
        }
        let count = Int((try? db.scalar("SELECT COUNT(*) FROM samples")) ?? 0)
        let minStart = (try? db.scalar("SELECT MIN(start) FROM samples")) ?? nil
        let maxEnd = (try? db.scalar("SELECT MAX(end) FROM samples")) ?? nil
        var range: DateInterval? = nil
        if let minStart, let maxEnd, maxEnd >= minStart {
            range = DateInterval(start: Date(timeIntervalSince1970: minStart), end: Date(timeIntervalSince1970: maxEnd))
        }
        let clinical = Int((try? db.scalar("SELECT COUNT(*) FROM clinical_records")) ?? 0)
        if meta("sourceKind") == "backup" {
            let device = meta("deviceName") ?? "iPhone"
            let backupDate = meta("backupDate").flatMap { ISO8601.date(from: $0) }
            let day = backupDate.map { $0.formatted(.dateTime.year().month(.abbreviated).day()) }
            let ios = meta("iosVersion").map { " (iOS \($0))" } ?? ""
            var detail = backupDate.map { "Full Health store from the encrypted iPhone backup made \($0.formatted(.relative(presentation: .named)))\(ios). Back up again and re-import to refresh." }
            if let names = meta("uncataloguedNames").flatMap({ try? JSON.parse($0) })?.objectValue, !names.isEmpty {
                let list = names.values.compactMap(\.stringValue).map { $0.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "").replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "").replacingOccurrences(of: "HKDataTypeIdentifier", with: "") }.sorted()
                detail = (detail ?? "") + " Present but not served yet: \(list.prefix(8).joined(separator: ", "))\(list.count > 8 ? ", and \(list.count - 8) more" : "")."
            }
            if let unmapped = meta("unmappedCodes").flatMap({ try? JSON.parse($0) })?.objectValue, !unmapped.isEmpty {
                detail = (detail ?? "") + " \(unmapped.count) type codes were unknown to this macOS: \(unmapped.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.joined(separator: ", "))."
            }
            return ProviderStatus(kind: kind, description: "\(device) backup" + (day.map { " from \($0)" } ?? ""), available: count > 0,
                                  authorization: .notApplicable, detail: detail,
                                  supportsClinicalRecords: clinical > 0, dataRange: range, sampleCount: count)
        }
        let exportDate = meta("exportDate").flatMap(ISO8601.exportDate)
        let exportDay = exportDate.map { $0.formatted(.dateTime.year().month(.abbreviated).day()) }
        return ProviderStatus(kind: kind, description: "Health export" + (exportDay.map { " from \($0)" } ?? ""), available: count > 0,
                              authorization: .notApplicable,
                              detail: exportDate.map { "Snapshot from the Health app, exported \($0.formatted(.relative(presentation: .named))). Re-import to refresh." },
                              supportsClinicalRecords: clinical > 0, dataRange: range, sampleCount: count)
    }

    public func availableTypes() async -> [HealthDataType] {
        guard let db = try? requireDB() else { return [] }
        let ids = (try? db.query("SELECT DISTINCT type FROM samples", row: { $0.string(0) ?? "" })) ?? []
        return ids.compactMap { HealthTypeCatalog.byIdentifier[$0] }.sorted { $0.name < $1.name }
    }

    public func requestAuthorization() async throws {}

    public func samples(of type: HealthDataType, in range: DateInterval?, limit: Int, ascending: Bool) async throws -> [HealthSample] {
        let db = try requireDB()
        let order = ascending ? "ASC" : "DESC"
        let sql = """
        SELECT start, end, value, unit, category, source, device FROM samples
        WHERE type = ? AND end >= ? AND start < ?
        ORDER BY start \(order) LIMIT ?
        """
        return try db.query(sql, bind: { s in
            s.bind(1, type.identifier)
            s.bind(2, range?.start.timeIntervalSince1970 ?? -1e12)
            s.bind(3, range?.end.timeIntervalSince1970 ?? 1e12)
            s.bind(4, limit == Int.max ? 1_000_000_000 : limit)
        }, row: { s in
            HealthSample(type: type.identifier, start: Date(timeIntervalSince1970: s.double(0) ?? 0),
                         end: Date(timeIntervalSince1970: s.double(1) ?? 0), value: s.double(2) ?? 0, unit: s.string(3) ?? type.unit,
                         categoryValue: s.string(4), source: s.string(5), device: s.string(6))
        })
    }

    public func statistics(of type: HealthDataType, in range: DateInterval, interval: StatisticsInterval) async throws -> [StatisticsBucket] {
        let list = try await samples(of: type, in: range, limit: Int.max, ascending: true)
        return HealthMath.buckets(for: list, type: type, range: range, interval: interval)
    }

    public func latestSample(of type: HealthDataType) async throws -> HealthSample? {
        try await samples(of: type, in: nil, limit: 1, ascending: false).first
    }

    public func sleepSegments(in range: DateInterval) async throws -> [SleepSegment] {
        let type = HealthTypeCatalog.byIdentifier["HKCategoryTypeIdentifierSleepAnalysis"]!
        return try await samples(of: type, in: range, limit: Int.max, ascending: true).compactMap { s in
            guard let stage = SleepStage(rawCategoryValue: Int(s.value)) else { return nil }
            return SleepSegment(start: s.start, end: s.end, stage: stage, source: s.source)
        }
    }

    public func workouts(in range: DateInterval?, activityType: String?, limit: Int) async throws -> [Workout] {
        let db = try requireDB()
        var sql = "SELECT activity, start, end, duration_min, energy_kcal, distance_km, avg_hr, max_hr, source FROM workouts WHERE start >= ? AND start < ?"
        if activityType != nil { sql += " AND LOWER(activity) = LOWER(?)" }
        sql += " ORDER BY start DESC LIMIT ?"
        var list: [Workout] = try db.query(sql, bind: { s in
            s.bind(1, range?.start.timeIntervalSince1970 ?? -1e12)
            s.bind(2, range?.end.timeIntervalSince1970 ?? 1e12)
            var next: Int32 = 3
            if let activityType { s.bind(next, activityType); next += 1 }
            s.bind(next, limit)
        }, row: { s in
            Workout(activityType: s.string(0) ?? "other", start: Date(timeIntervalSince1970: s.double(1) ?? 0),
                    end: Date(timeIntervalSince1970: s.double(2) ?? 0), durationMinutes: s.double(3) ?? 0, totalEnergyKcal: s.double(4),
                    totalDistanceKm: s.double(5), averageHeartRate: s.double(6), maxHeartRate: s.double(7), source: s.string(8))
        })
        // On-device workouts rarely carry heart-rate statistics in the store; derive them from the samples in the window.
        let hrSQL = "SELECT AVG(value), MAX(value) FROM samples WHERE type = 'HKQuantityTypeIdentifierHeartRate' AND start >= ? AND start < ?"
        for i in list.indices where list[i].averageHeartRate == nil {
            let w = list[i]
            let row = try db.query(hrSQL, bind: { $0.bind(1, w.start.timeIntervalSince1970); $0.bind(2, w.end.timeIntervalSince1970) },
                                   row: { ($0.double(0), $0.double(1)) }).first
            if let (avg, mx) = row, let avg {
                list[i].averageHeartRate = avg.rounded()
                list[i].maxHeartRate = mx
            }
        }
        return list
    }

    public func characteristics() async throws -> Characteristics {
        let db = try requireDB()
        let rows = try db.query("SELECT key, value FROM characteristics", row: { ($0.string(0) ?? "", $0.string(1) ?? "") })
        var dict: [String: String] = [:]
        for (k, v) in rows { dict[k] = v }
        var c = Characteristics()
        if let dob = dict["HKCharacteristicTypeIdentifierDateOfBirth"], !dob.isEmpty {
            c.dateOfBirth = dob
            if let d = ISO8601.date(from: dob) { c.ageYears = Calendar.current.dateComponents([.year], from: d, to: Date()).year }
        }
        c.biologicalSex = dict["HKCharacteristicTypeIdentifierBiologicalSex"].map { Self.strip($0, "HKBiologicalSex") }
        c.bloodType = dict["HKCharacteristicTypeIdentifierBloodType"].map { Self.strip($0, "HKBloodType") }
        c.fitzpatrickSkinType = dict["HKCharacteristicTypeIdentifierFitzpatrickSkinType"].map { Self.strip($0, "HKFitzpatrickSkinType") }
        c.wheelchairUse = dict["HKCharacteristicTypeIdentifierWheelchairUse"].map { Self.strip($0, "HKWheelchairUse") }
        c.activityMoveMode = dict["HKCharacteristicTypeIdentifierActivityMoveMode"].map { Self.strip($0, "HKActivityMoveMode") }
        return c
    }

    private static func strip(_ value: String, _ prefix: String) -> String {
        let s = value.replacingOccurrences(of: prefix, with: "")
        guard let f = s.first else { return value }
        return f.lowercased() + s.dropFirst()
    }

    public func clinicalRecords(kind: ClinicalRecordKind?, since: Date?, limit: Int) async throws -> [ClinicalRecord] {
        let db = try requireDB()
        var sql = "SELECT kind, resource_type, display_name, fhir_version, identifier, date, source, resource, source_url FROM clinical_records WHERE 1=1"
        if kind != nil { sql += " AND kind = ?" }
        if since != nil { sql += " AND date >= ?" }
        sql += " ORDER BY date DESC LIMIT ?"
        return try db.query(sql, bind: { s in
            var i: Int32 = 1
            if let kind { s.bind(i, kind.rawValue); i += 1 }
            if let since { s.bind(i, since.timeIntervalSince1970); i += 1 }
            s.bind(i, limit)
        }, row: { s in
            ClinicalRecord(kind: ClinicalRecordKind(rawValue: s.string(0) ?? "") ?? .clinicalNoteRecord,
                           displayName: s.string(2) ?? "", fhirResourceType: s.string(1) ?? "Unknown", fhirVersion: s.string(3),
                           identifier: s.string(4), sourceURL: s.string(8), source: s.string(6),
                           date: s.double(5).map { Date(timeIntervalSince1970: $0) },
                           resource: s.string(7).flatMap { try? JSON.parse($0) } ?? .null)
        })
    }
}

// MARK: - Import

public struct ImportProgress: Sendable, Equatable {
    public var phase: String
    public var records: Int
    public var workouts: Int
    public var clinicalRecords: Int
    public var skippedTypes: Int
}

public struct ImportReport: Sendable, Equatable {
    public var records: Int
    public var workouts: Int
    public var clinicalRecords: Int
    public var skippedTypes: [String: Int]
    public var exportDate: String?
    public var duration: TimeInterval
}

/// Streams a Health export into a fresh SQLite file, then swaps it into place.
public final class HealthExportImporter: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let destination: URL
    private let scratch: URL
    private let progress: @Sendable (ImportProgress) -> Void

    private var writer: HealthStoreWriter!
    private var exportRoot: URL!
    private var recordCount = 0
    private var workoutCount = 0
    private var clinicalCount = 0
    private var skipped: [String: Int] = [:]
    private var exportDate: String?
    private var sinceReport = 0
    private var parseError: Error?

    // Workout under construction.
    private var currentWorkout: [String: String]?
    private var currentWorkoutStats: [(type: String, sum: Double?, avg: Double?, max: Double?, unit: String)] = []

    public init(destination: URL, scratch: URL, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) {
        self.destination = destination
        self.scratch = scratch
        self.progress = progress
    }

    /// `source` is an export.zip, a folder containing export.xml, or export.xml itself.
    public func run(source: URL) throws -> ImportReport {
        let started = Date()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        report(phase: "Unpacking")
        let xml = try locateExportXML(source)
        exportRoot = xml.deletingLastPathComponent()

        report(phase: "Preparing database")
        writer = try HealthStoreWriter(destination: destination)

        report(phase: "Importing")
        guard let parser = XMLParser(contentsOf: xml) else { writer.abandon(); throw HealthDataError.internalError("cannot open export.xml") }
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        if let parseError { writer.abandon(); throw parseError }
        if !ok, let err = parser.parserError, recordCount == 0 {
            writer.abandon()
            throw HealthDataError.internalError("XML parse failed: \(err.localizedDescription)")
        }

        report(phase: "Indexing")
        writer.setMeta("sourceKind", "export")
        writer.setMeta("exportDate", exportDate ?? "")
        writer.setMeta("sourceFile", source.lastPathComponent)
        writer.setMeta("recordCount", String(recordCount))
        try writer.finish()
        writer = nil

        return ImportReport(records: recordCount, workouts: workoutCount, clinicalRecords: clinicalCount, skippedTypes: skipped,
                            exportDate: exportDate, duration: Date().timeIntervalSince(started))
    }

    private func report(phase: String) {
        progress(ImportProgress(phase: phase, records: recordCount, workouts: workoutCount, clinicalRecords: clinicalCount,
                                skippedTypes: skipped.values.reduce(0, +)))
    }

    private func locateExportXML(_ source: URL) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw HealthDataError.invalidArgument("\(source.path) does not exist")
        }
        if !isDir.boolValue {
            if source.pathExtension.lowercased() == "xml" { return source }
            if source.pathExtension.lowercased() == "zip" {
                let dest = scratch.appendingPathComponent("unzipped", isDirectory: true)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-x", "-k", source.path, dest.path]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { throw HealthDataError.internalError("could not unzip \(source.lastPathComponent)") }
                return try locateExportXML(dest)
            }
            throw HealthDataError.invalidArgument("Expected export.zip, export.xml, or a folder")
        }
        // Folder: look for export.xml at depth ≤ 3.
        if let e = fm.enumerator(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in e where url.lastPathComponent == "export.xml" {
                return url
            }
        }
        throw HealthDataError.invalidArgument("No export.xml found inside \(source.lastPathComponent)")
    }

    // MARK: XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                       attributes attrs: [String: String]) {
        switch name {
        case "Record":
            if currentWorkout == nil { handleRecord(attrs) }
        case "Workout":
            currentWorkout = attrs
            currentWorkoutStats = []
        case "WorkoutStatistics":
            if currentWorkout != nil {
                currentWorkoutStats.append((attrs["type"] ?? "", attrs["sum"].flatMap(Double.init), attrs["average"].flatMap(Double.init),
                                            attrs["maximum"].flatMap(Double.init), attrs["unit"] ?? ""))
            }
        case "ClinicalRecord":
            handleClinical(attrs)
        case "ExportDate":
            exportDate = attrs["value"]
        case "Me":
            for (k, v) in attrs { writer.setCharacteristic(k, v) }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "Workout", let w = currentWorkout {
            handleWorkout(w)
            currentWorkout = nil
            currentWorkoutStats = []
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        // Recorded; `run` decides whether partial data is acceptable.
        if recordCount == 0 { parseError = error }
    }

    private func commitIfNeeded() {
        sinceReport += 1
        if sinceReport >= 20_000 {
            sinceReport = 0
            report(phase: "Importing")
        }
    }

    private func handleRecord(_ a: [String: String]) {
        guard let typeID = a["type"] else { return }
        guard let type = HealthTypeCatalog.byIdentifier[typeID] else {
            skipped[typeID, default: 0] += 1
            return
        }
        guard let startS = a["startDate"], let endS = a["endDate"],
              let start = ISO8601.exportDate(from: startS), let end = ISO8601.exportDate(from: endS) else { return }

        var value: Double = 0
        var unit = a["unit"] ?? type.unit
        var category: String? = nil
        let rawValue = a["value"] ?? ""

        switch type.kind {
        case .quantity:
            guard let v = Double(rawValue) else { return }
            (value, unit) = UnitConversion.canonicalize(value: v, unit: unit, type: type)
        case .category:
            unit = ""
            if typeID == "HKCategoryTypeIdentifierSleepAnalysis" {
                guard let stage = SleepStage(exportValue: rawValue) else { return }
                value = Double(stage.rawCategoryValue)
                category = stage.rawValue
            } else if typeID == "HKCategoryTypeIdentifierAppleStandHour" {
                let stood = rawValue.hasSuffix("Stood")
                value = stood ? 0 : 1
                category = stood ? "stood" : "idle"
            } else if let n = Int(rawValue) {
                value = Double(n)
            } else {
                // e.g. HKCategoryValueMenstrualFlowMedium → medium; HKCategoryValueNotApplicable → notApplicable
                var s = rawValue
                for prefix in ["HKCategoryValue" + type.identifier.replacingOccurrences(of: "HKCategoryTypeIdentifier", with: ""), "HKCategoryValue"] {
                    s = s.replacingOccurrences(of: prefix, with: "")
                }
                category = s.isEmpty ? nil : s.prefix(1).lowercased() + s.dropFirst()
                value = Self.categoryNumeric(typeID: typeID, label: category ?? "")
            }
        }

        writer.add(HealthSample(type: typeID, start: start, end: end, value: value, unit: unit, categoryValue: category,
                                source: a["sourceName"], device: a["device"].flatMap(Self.deviceName)))
        recordCount += 1
        commitIfNeeded()
    }

    private static func categoryNumeric(typeID: String, label: String) -> Double {
        if typeID == "HKCategoryTypeIdentifierMenstrualFlow" {
            switch label.lowercased() {
            case "unspecified": return 1
            case "light": return 2
            case "medium": return 3
            case "heavy": return 4
            case "none": return 5
            default: return 0
            }
        }
        return 0
    }

    /// The export's `device` attribute is a description string; pull out `name:`.
    static func deviceName(_ raw: String) -> String? {
        for part in raw.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "name" {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func handleWorkout(_ a: [String: String]) {
        guard let startS = a["startDate"], let endS = a["endDate"],
              let start = ISO8601.exportDate(from: startS), let end = ISO8601.exportDate(from: endS) else { return }
        let activity = WorkoutActivityNames.name(forExportValue: a["workoutActivityType"] ?? "HKWorkoutActivityTypeOther")
        var duration = Double(a["duration"] ?? "") ?? end.timeIntervalSince(start) / 60
        if a["durationUnit"] == "s" { duration /= 60 } else if a["durationUnit"] == "hr" { duration *= 60 }

        var energy = Double(a["totalEnergyBurned"] ?? "")
        var distance = Double(a["totalDistance"] ?? "")
        if let raw = distance, let unit = a["totalDistanceUnit"], unit != "km" {
            distance = UnitConversion.canonicalize(value: raw, unit: unit, type: HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierDistanceWalkingRunning"]!).0
        }
        var avgHR: Double? = nil, maxHR: Double? = nil
        for s in currentWorkoutStats {
            switch s.type {
            case "HKQuantityTypeIdentifierActiveEnergyBurned":
                if energy == nil, let sum = s.sum { energy = UnitConversion.canonicalize(value: sum, unit: s.unit, type: HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierActiveEnergyBurned"]!).0 }
            case "HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierDistanceCycling", "HKQuantityTypeIdentifierDistanceSwimming":
                if distance == nil, let sum = s.sum { distance = UnitConversion.canonicalize(value: sum, unit: s.unit, type: HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierDistanceWalkingRunning"]!).0 }
            case "HKQuantityTypeIdentifierHeartRate":
                avgHR = s.avg
                maxHR = s.max
            default: break
            }
        }
        writer.add(Workout(activityType: activity, start: start, end: end, durationMinutes: duration, totalEnergyKcal: energy,
                           totalDistanceKm: distance, averageHeartRate: avgHR, maxHeartRate: maxHR, source: a["sourceName"]))
        workoutCount += 1
        commitIfNeeded()
    }

    private func handleClinical(_ a: [String: String]) {
        guard let typeID = a["type"] else { return }
        let kindName = typeID.replacingOccurrences(of: "HKClinicalTypeIdentifier", with: "")
        let kind = ClinicalRecordKind(rawValue: kindName.prefix(1).lowercased() + kindName.dropFirst()) ?? .clinicalNoteRecord
        var resource: JSONValue = .null
        var resourceType = "Unknown"
        var displayName = kindName
        if let rel = a["resourceFilePath"] {
            let trimmed = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
            let url = exportRoot.appendingPathComponent(trimmed)
            if let data = try? Data(contentsOf: url), let parsed = try? JSON.parse(data) {
                resource = parsed
                resourceType = parsed["resourceType"]?.stringValue ?? resourceType
                displayName = Self.displayName(for: parsed) ?? displayName
            }
        }
        let date = a["receivedDate"].flatMap(ISO8601.exportDate) ?? Self.fhirDate(resource)
        writer.add(ClinicalRecord(kind: kind, displayName: displayName, fhirResourceType: resourceType, fhirVersion: a["fhirVersion"],
                                  identifier: a["identifier"], sourceURL: a["sourceURL"], source: a["sourceName"], date: date, resource: resource))
        clinicalCount += 1
        commitIfNeeded()
    }

    static func displayName(for resource: JSONValue) -> String? {
        for key in ["code", "medicationCodeableConcept", "vaccineCode", "type"] {
            if let text = resource[key]?["text"]?.stringValue { return text }
            if let display = resource[key]?["coding"]?[0]?["display"]?.stringValue { return display }
        }
        if let text = resource["text"]?["div"]?.stringValue { return text.prefix(80).description }
        return nil
    }

    static func fhirDate(_ resource: JSONValue) -> Date? {
        for key in ["effectiveDateTime", "issued", "onsetDateTime", "recordedDate", "authoredOn", "occurrenceDateTime", "performedDateTime", "dateWritten", "date"] {
            if let s = resource[key]?.stringValue, let d = ISO8601.date(from: s) { return d }
        }
        if let s = resource["effectivePeriod"]?["start"]?.stringValue, let d = ISO8601.date(from: s) { return d }
        return nil
    }
}
