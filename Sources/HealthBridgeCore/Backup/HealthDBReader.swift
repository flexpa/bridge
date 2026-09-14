import Foundation

/// What the reader learned about a `healthdb_secure.sqlite` before touching data.
public struct HealthDBSchema: Sendable, Equatable {
    public var tables: [String: [String]]  // table → columns
    public var hasWorkoutActivities: Bool
    public var hasLegacyWorkouts: Bool
    public var hasWorkoutStatistics: Bool
    public var hasObjectsType: Bool
    public var hasOriginalUnit: Bool
    public var hasUnitStrings: Bool
    public var hasDataProvenances: Bool
    public var fingerprint: String

    public func has(_ table: String, _ column: String? = nil) -> Bool {
        guard let cols = tables[table] else { return false }
        guard let column else { return true }
        return cols.contains(column)
    }
}

public struct HealthDBReport: Sendable, Equatable {
    public var samples: Int
    public var workouts: Int
    public var skippedTombstones: Int
    /// Codes present in the database that the type table could not name, with row counts.
    public var unmappedCodes: [Int: Int]
    /// Codes that were named but are outside the bridge's catalog; stored raw under `hk:<code>`.
    public var uncataloguedCodes: [Int: Int]
    public var schemaFingerprint: String
    public var typeTableConflicts: [String]
}

/// Reads Apple Health's on-device database (as found in an encrypted iPhone
/// backup) into the bridge's model. The schema is not documented by Apple and
/// changes between iOS versions, so the reader introspects `sqlite_master`
/// first and degrades feature by feature instead of assuming a layout.
public final class HealthDBReader {
    private let db: SQLiteDatabase
    private let codes: TypeCodeTable
    public let schema: HealthDBSchema

    /// Seconds between the Unix epoch and Core Data's reference date (2001-01-01).
    static let coreDataEpochOffset: TimeInterval = 978_307_200

    /// Opens `healthdb_secure.sqlite`; attaches `healthdb.sqlite` as `hdb` for source names when given.
    public init(secureDatabase: URL, plainDatabase: URL?, codes: TypeCodeTable) throws {
        db = try SQLiteDatabase(path: secureDatabase.path)
        if let plainDatabase, FileManager.default.fileExists(atPath: plainDatabase.path) {
            let escaped = plainDatabase.path.replacingOccurrences(of: "'", with: "''")
            try? db.exec("ATTACH DATABASE '\(escaped)' AS hdb")
        }
        self.codes = codes
        schema = try Self.introspect(db)
        guard schema.has("samples", "data_type"), schema.has("samples", "start_date"), schema.has("objects", "data_id") else {
            throw HealthDataError.internalError("This does not look like a Health database: missing samples/objects tables. Tables: \(schema.tables.keys.sorted().prefix(12).joined(separator: ", "))")
        }
    }

    static func introspect(_ db: SQLiteDatabase) throws -> HealthDBSchema {
        let names = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", row: { $0.string(0) ?? "" })
        var tables: [String: [String]] = [:]
        for name in names where !name.hasPrefix("sqlite_") {
            let cols = try db.query("PRAGMA table_info(\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\")", row: { $0.string(1) ?? "" })
            tables[name] = cols
        }
        let flat = tables.keys.sorted().map { "\($0)(\(tables[$0]!.joined(separator: ",")))" }.joined(separator: ";")
        let fingerprint = String(format: "%08x", flat.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 })
        return HealthDBSchema(
            tables: tables,
            hasWorkoutActivities: tables["workout_activities"] != nil,
            hasLegacyWorkouts: tables["workouts"]?.contains("activity_type") ?? false,
            hasWorkoutStatistics: tables["workout_statistics"] != nil,
            hasObjectsType: tables["objects"]?.contains("type") ?? false,
            hasOriginalUnit: tables["quantity_samples"]?.contains("original_unit") ?? false,
            hasUnitStrings: tables["unit_strings"] != nil,
            hasDataProvenances: tables["data_provenances"] != nil,
            fingerprint: fingerprint
        )
    }

    // MARK: Inventory

    /// (code, rows) for every data type present.
    public func typeCounts() throws -> [(Int, Int)] {
        try db.query("SELECT data_type, COUNT(*) FROM samples GROUP BY data_type ORDER BY data_type",
                     row: { ($0.int(0) ?? -1, $0.int(1) ?? 0) })
    }

    /// Source names by `data_provenances` row, when the plain database is attached.
    private lazy var sourceNames: [Int: String] = {
        guard schema.hasDataProvenances else { return [:] }
        var out: [Int: String] = [:]
        let sql = "SELECT p.ROWID, s.name FROM data_provenances p LEFT JOIN hdb.sources s ON s.ROWID = p.source_id"
        if let rows = try? db.query(sql, row: { ($0.int(0) ?? -1, $0.string(1)) }) {
            for (id, name) in rows { if let name { out[id] = name } }
        }
        return out
    }()

    private lazy var unitStrings: [Int: String] = {
        guard schema.hasUnitStrings else { return [:] }
        var out: [Int: String] = [:]
        if let rows = try? db.query("SELECT ROWID, unit_string FROM unit_strings", row: { ($0.int(0) ?? -1, $0.string(1)) }) {
            for (id, s) in rows { if let s { out[id] = s } }
        }
        return out
    }()

    // MARK: Samples

    public struct RawSample: Sendable {
        public var code: Int
        public var identifier: String?
        public var uuid: String?
        public var start: Date
        public var end: Date
        public var quantity: Double?
        public var originalQuantity: Double?
        public var originalUnit: String?
        public var categoryValue: Int?
        public var source: String?
        public var isTombstone: Bool
    }

    /// Streams every sample of one type in start-date order.
    public func forEachSample(code: Int, _ body: (RawSample) throws -> Void) throws {
        // Resolve lookup tables before taking the connection lock: they query the same connection.
        let units = unitStrings
        let sources = sourceNames
        var sql = """
        SELECT s.start_date, s.end_date, o.uuid, o.provenance\(schema.hasObjectsType ? ", o.type" : ", NULL")
        """
        if schema.has("quantity_samples") {
            sql += ", q.quantity"
            sql += schema.has("quantity_samples", "original_quantity") ? ", q.original_quantity" : ", NULL"
            sql += schema.hasOriginalUnit ? ", q.original_unit" : ", NULL"
        } else {
            sql += ", NULL, NULL, NULL"
        }
        sql += schema.has("category_samples", "value") ? ", c.value" : ", NULL"
        sql += " FROM samples s JOIN objects o ON o.data_id = s.data_id"
        if schema.has("quantity_samples") { sql += " LEFT JOIN quantity_samples q ON q.data_id = s.data_id" }
        if schema.has("category_samples") { sql += " LEFT JOIN category_samples c ON c.data_id = s.data_id" }
        sql += " WHERE s.data_type = ? ORDER BY s.start_date"

        let stmt = try db.prepare(sql)
        try db.withLock {
            stmt.bind(1, code)
            while stmt.step() {
                let objType = stmt.int(4)
                let sample = RawSample(
                    code: code,
                    identifier: codes.identifier(for: code),
                    uuid: stmt.uuidString(2),
                    start: Self.date(stmt.double(0)),
                    end: Self.date(stmt.double(1)),
                    quantity: stmt.double(5),
                    originalQuantity: stmt.double(6),
                    originalUnit: stmt.int(7).flatMap { units[$0] },
                    categoryValue: stmt.int(8),
                    source: stmt.int(3).flatMap { sources[$0] },
                    // In healthdb, objects.type 1 is a live object; 2 marks a deletion tombstone.
                    isTombstone: objType == 2
                )
                try body(sample)
            }
        }
    }

    static func date(_ coreData: Double?) -> Date {
        Date(timeIntervalSince1970: (coreData ?? 0) + coreDataEpochOffset)
    }

    // MARK: Workouts

    public struct RawWorkout: Sendable {
        public var uuid: String?
        public var activityType: Int
        public var start: Date
        public var end: Date
        public var durationSeconds: Double
        public var energyKcal: Double?
        public var distanceMeters: Double?
        public var averageHeartRate: Double?
        public var maxHeartRate: Double?
        public var source: String?
    }

    public func workouts() throws -> [RawWorkout] {
        guard let workoutCode = codes.code(for: TypeCodeTable.workoutIdentifier) else { return [] }
        var out: [RawWorkout] = []
        if schema.hasWorkoutActivities {
            // iOS 16+: one workout row in samples/objects, activities and statistics in side tables.
            let owner = schema.has("workout_activities", "owner_id") ? "owner_id" : "workout_id"
            let sql = """
            SELECT s.data_id, s.start_date, s.end_date, o.uuid, o.provenance,
                   (SELECT activity_type FROM workout_activities a WHERE a.\(owner) = s.data_id ORDER BY a.ROWID LIMIT 1),
                   (SELECT SUM(duration) FROM workout_activities a WHERE a.\(owner) = s.data_id)
            FROM samples s JOIN objects o ON o.data_id = s.data_id
            WHERE s.data_type = ?\(schema.hasObjectsType ? " AND (o.type IS NULL OR o.type != 2)" : "")
            ORDER BY s.start_date
            """
            let rows = try db.query(sql, bind: { $0.bind(1, workoutCode) }, row: { s -> (Int, RawWorkout) in
                let start = Self.date(s.double(1)), end = Self.date(s.double(2))
                return (s.int(0) ?? -1, RawWorkout(uuid: s.uuidString(3), activityType: s.int(5) ?? 3000, start: start, end: end,
                                                   durationSeconds: s.double(6) ?? end.timeIntervalSince(start),
                                                   source: s.int(4).flatMap { sourceNames[$0] }))
            })
            let stats = schema.hasWorkoutStatistics ? try workoutStatistics(ownerColumn: owner) : [:]
            for (dataID, var w) in rows {
                if let st = stats[dataID] {
                    w.energyKcal = st.energy
                    w.distanceMeters = st.distance
                    w.averageHeartRate = st.avgHR
                    w.maxHeartRate = st.maxHR
                }
                out.append(w)
            }
        } else if schema.hasLegacyWorkouts {
            let cols = schema.tables["workouts"] ?? []
            func col(_ name: String) -> String { cols.contains(name) ? "w.\(name)" : "NULL" }
            let sql = """
            SELECT s.start_date, s.end_date, o.uuid, o.provenance, w.activity_type, \(col("duration")),
                   \(col("total_energy_burned")), \(col("total_distance"))
            FROM samples s JOIN objects o ON o.data_id = s.data_id JOIN workouts w ON w.data_id = s.data_id
            WHERE s.data_type = ? ORDER BY s.start_date
            """
            out = try db.query(sql, bind: { $0.bind(1, workoutCode) }, row: { s in
                let start = Self.date(s.double(0)), end = Self.date(s.double(1))
                return RawWorkout(uuid: s.uuidString(2), activityType: s.int(4) ?? 3000, start: start, end: end,
                                  durationSeconds: s.double(5) ?? end.timeIntervalSince(start), energyKcal: s.double(6),
                                  distanceMeters: s.double(7), source: s.int(3).flatMap { sourceNames[$0] })
            })
        }
        return out
    }

    private struct WorkoutStats { var energy: Double?; var distance: Double?; var avgHR: Double?; var maxHR: Double? }

    /// Per-workout totals from `workout_statistics`, keyed by the workout's data_id.
    private func workoutStatistics(ownerColumn: String) throws -> [Int: WorkoutStats] {
        let cols = schema.tables["workout_statistics"] ?? []
        let key = cols.contains("workout_activity_id") ? "workout_activity_id" : (cols.contains("owner_id") ? "owner_id" : "workout_id")
        let joinsActivities = key == "workout_activity_id"
        let sql = joinsActivities
            ? "SELECT a.\(ownerColumn), st.data_type, st.quantity, \(cols.contains("average") ? "st.average" : "NULL"), \(cols.contains("maximum") ? "st.maximum" : "NULL") FROM workout_statistics st JOIN workout_activities a ON a.ROWID = st.workout_activity_id"
            : "SELECT st.\(key), st.data_type, st.quantity, \(cols.contains("average") ? "st.average" : "NULL"), \(cols.contains("maximum") ? "st.maximum" : "NULL") FROM workout_statistics st"
        var out: [Int: WorkoutStats] = [:]
        let energy = codes.code(for: "HKQuantityTypeIdentifierActiveEnergyBurned")
        let distances = Set(["DistanceWalkingRunning", "DistanceCycling", "DistanceSwimming", "DistanceWheelchair", "DistanceDownhillSnowSports"]
            .compactMap { codes.code(for: "HKQuantityTypeIdentifier" + $0) })
        let heartRate = codes.code(for: "HKQuantityTypeIdentifierHeartRate")
        for (owner, type, qty, avg, mx) in try db.query(sql, row: { ($0.int(0) ?? -1, $0.int(1) ?? -1, $0.double(2), $0.double(3), $0.double(4)) }) {
            var st = out[owner] ?? WorkoutStats()
            if type == energy { st.energy = (st.energy ?? 0) + (qty ?? 0) }
            else if distances.contains(type) { st.distance = (st.distance ?? 0) + (qty ?? 0) }
            else if type == heartRate { st.avgHR = avg ?? st.avgHR; st.maxHR = max(st.maxHR ?? 0, mx ?? 0) == 0 ? nil : max(st.maxHR ?? 0, mx ?? 0) }
            out[owner] = st
        }
        return out
    }
}

extension SQLiteDatabase.Statement {
    /// `objects.uuid` is a 16-byte blob; render it as a canonical UUID string.
    func uuidString(_ col: Int32) -> String? {
        guard let data = blob(col) else { return string(col) }
        guard data.count == 16 else { return nil }
        return data.withUnsafeBytes { raw -> String in
            let b = raw.bindMemory(to: UInt8.self)
            let u = uuid_t(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
            return UUID(uuid: u).uuidString
        }
    }
}

// MARK: - Mapping raw rows to the bridge's model

public enum HealthDBMapper {
    /// Converts a raw database row into a catalog sample, or nil when the type is not in the catalog.
    public static func sample(from raw: HealthDBReader.RawSample) -> HealthSample? {
        guard let identifier = raw.identifier, let type = HealthTypeCatalog.byIdentifier[identifier] else { return nil }
        switch type.kind {
        case .quantity:
            if let oq = raw.originalQuantity, let ou = raw.originalUnit {
                // The source's own unit, e.g. "lb" from a scale app. Convert by string table.
                let (v, u) = UnitConversion.canonicalize(value: oq, unit: ou, type: type)
                return HealthSample(type: identifier, start: raw.start, end: raw.end, value: v, unit: u, source: raw.source)
            }
            guard let q = raw.quantity else { return nil }
            // HealthKit's canonical storage unit, as reported by the framework, converted with HealthKit's own unit math.
            if let (v, u) = CanonicalUnits.convertStored(q, identifier: identifier, to: type.unit) {
                return HealthSample(type: identifier, start: raw.start, end: raw.end, value: v, unit: u, source: raw.source)
            }
            return HealthSample(type: identifier, start: raw.start, end: raw.end, value: q, unit: type.unit, source: raw.source)
        case .category:
            let value = raw.categoryValue ?? 0
            var label: String? = nil
            if identifier == "HKCategoryTypeIdentifierSleepAnalysis" {
                label = SleepStage(rawCategoryValue: value)?.rawValue
            } else if identifier == "HKCategoryTypeIdentifierAppleStandHour" {
                label = value == 0 ? "stood" : "idle"
            }
            return HealthSample(type: identifier, start: raw.start, end: raw.end, value: Double(value), unit: "", categoryValue: label, source: raw.source)
        }
    }

    public static func workout(from raw: HealthDBReader.RawWorkout) -> Workout {
        Workout(activityType: WorkoutActivityNames.names[UInt(max(raw.activityType, 0))] ?? "activity\(raw.activityType)",
                start: raw.start, end: raw.end, durationMinutes: raw.durationSeconds / 60,
                totalEnergyKcal: raw.energyKcal, totalDistanceKm: raw.distanceMeters.map { $0 / 1000 },
                averageHeartRate: raw.averageHeartRate, maxHeartRate: raw.maxHeartRate, source: raw.source)
    }
}
