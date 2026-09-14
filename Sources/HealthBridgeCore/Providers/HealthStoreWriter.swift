import Foundation

/// Writes a fresh copy of the bridge's SQLite store and swaps it into place
/// when finished. Both importers (Health export, iPhone backup) use it, so the
/// schema lives in one place.
public final class HealthStoreWriter {
    public let destination: URL
    private let temporary: URL
    private let db: SQLiteDatabase
    private let insertSample: SQLiteDatabase.Statement
    private let insertWorkout: SQLiteDatabase.Statement
    private let insertClinical: SQLiteDatabase.Statement
    private let insertCharacteristic: SQLiteDatabase.Statement
    private let insertMeta: SQLiteDatabase.Statement
    private var pending = 0
    private var finished = false

    public static let schema = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE samples (id INTEGER PRIMARY KEY, type TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
        value REAL NOT NULL, unit TEXT NOT NULL, category TEXT, source TEXT, device TEXT, uuid TEXT, data_type_code INTEGER);
    CREATE TABLE workouts (id INTEGER PRIMARY KEY, activity TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
        duration_min REAL, energy_kcal REAL, distance_km REAL, avg_hr REAL, max_hr REAL, source TEXT, uuid TEXT);
    CREATE TABLE characteristics (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE clinical_records (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, resource_type TEXT, display_name TEXT,
        fhir_version TEXT, identifier TEXT, date REAL, source TEXT, source_url TEXT, resource TEXT);
    """

    public init(destination: URL) throws {
        self.destination = destination
        temporary = destination.appendingPathExtension("importing")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: temporary.path + suffix) }
        db = try SQLiteDatabase(path: temporary.path)
        try db.exec(Self.schema)
        insertSample = try db.prepare("INSERT INTO samples (type, start, end, value, unit, category, source, device, uuid, data_type_code) VALUES (?,?,?,?,?,?,?,?,?,?)")
        insertWorkout = try db.prepare("INSERT INTO workouts (activity, start, end, duration_min, energy_kcal, distance_km, avg_hr, max_hr, source, uuid) VALUES (?,?,?,?,?,?,?,?,?,?)")
        insertClinical = try db.prepare("INSERT INTO clinical_records (kind, resource_type, display_name, fhir_version, identifier, date, source, source_url, resource) VALUES (?,?,?,?,?,?,?,?,?)")
        insertCharacteristic = try db.prepare("INSERT OR REPLACE INTO characteristics (key, value) VALUES (?,?)")
        insertMeta = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?,?)")
        try db.exec("BEGIN")
    }

    public func add(_ s: HealthSample, uuid: String? = nil, code: Int? = nil) {
        db.withLock {
            insertSample.reset()
            insertSample.bind(1, s.type)
            insertSample.bind(2, s.start.timeIntervalSince1970)
            insertSample.bind(3, s.end.timeIntervalSince1970)
            insertSample.bind(4, s.value)
            insertSample.bind(5, s.unit)
            insertSample.bind(6, s.categoryValue)
            insertSample.bind(7, s.source)
            insertSample.bind(8, s.device)
            insertSample.bind(9, uuid)
            insertSample.bind(10, code)
            _ = insertSample.step()
        }
        tick()
    }

    public func add(_ w: Workout, uuid: String? = nil) {
        db.withLock {
            insertWorkout.reset()
            insertWorkout.bind(1, w.activityType)
            insertWorkout.bind(2, w.start.timeIntervalSince1970)
            insertWorkout.bind(3, w.end.timeIntervalSince1970)
            insertWorkout.bind(4, w.durationMinutes)
            insertWorkout.bind(5, w.totalEnergyKcal)
            insertWorkout.bind(6, w.totalDistanceKm)
            insertWorkout.bind(7, w.averageHeartRate)
            insertWorkout.bind(8, w.maxHeartRate)
            insertWorkout.bind(9, w.source)
            insertWorkout.bind(10, uuid)
            _ = insertWorkout.step()
        }
        tick()
    }

    public func add(_ r: ClinicalRecord) {
        db.withLock {
            insertClinical.reset()
            insertClinical.bind(1, r.kind.rawValue)
            insertClinical.bind(2, r.fhirResourceType)
            insertClinical.bind(3, r.displayName)
            insertClinical.bind(4, r.fhirVersion)
            insertClinical.bind(5, r.identifier)
            insertClinical.bind(6, r.date?.timeIntervalSince1970)
            insertClinical.bind(7, r.source)
            insertClinical.bind(8, r.sourceURL)
            insertClinical.bind(9, r.resource.isNull ? nil : JSON.string(r.resource))
            _ = insertClinical.step()
        }
        tick()
    }

    public func setCharacteristic(_ key: String, _ value: String) {
        db.withLock {
            insertCharacteristic.reset()
            insertCharacteristic.bind(1, key)
            insertCharacteristic.bind(2, value)
            _ = insertCharacteristic.step()
        }
    }

    public func setMeta(_ key: String, _ value: String) {
        db.withLock {
            insertMeta.reset()
            insertMeta.bind(1, key)
            insertMeta.bind(2, value)
            _ = insertMeta.step()
        }
    }

    private func tick() {
        pending += 1
        if pending >= 20_000 {
            try? db.exec("COMMIT")
            try? db.exec("BEGIN")
            pending = 0
        }
    }

    /// Commits, indexes, and atomically replaces the destination store.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        try db.exec("COMMIT")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_samples_type_start ON samples(type, start)")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_samples_type_end ON samples(type, end)")
        try db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_samples_uuid ON samples(uuid) WHERE uuid IS NOT NULL")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_workouts_start ON workouts(start)")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_clinical_date ON clinical_records(kind, date)")
        setMeta("importedAt", ISO8601.string(from: Date()))
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: destination.path + suffix) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Drops the half-written store.
    public func abandon() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: temporary.path + suffix) }
    }
}
