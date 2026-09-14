import CommonCrypto
import Foundation
import SQLite3
@testable import HealthBridgeCore

/// Builds a small encrypted iPhone backup with the real on-disk layout so the
/// keybag, manifest, and file decryption paths are exercised end to end.
enum SyntheticBackup {
    struct Built {
        var directory: URL
        var password: String
        var udid: String
    }

    static let stepsCode = 7, heartRateCode = 5, bodyMassCode = 3, sleepCode = 63, standHourCode = 70, workoutCode = 79
    static let unknownCode = 9999

    /// `legacyWorkouts` picks the pre-iOS-16 `workouts` table layout instead of `workout_activities`.
    static func build(in root: URL, password: String = "correct horse battery staple", legacyWorkouts: Bool = false,
                      encrypted: Bool = true, codes: TypeCodeTable) throws -> Built {
        let fm = FileManager.default
        let udid = "00008120-000A1B2C3D4E5F60"
        let dir = root.appendingPathComponent(udid, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Plaintext databases.
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        let secureDB = plain.appendingPathComponent("healthdb_secure.sqlite")
        let mainDB = plain.appendingPathComponent("healthdb.sqlite")
        try makeHealthDB(secure: secureDB, main: mainDB, legacyWorkouts: legacyWorkouts, codes: codes)

        // Keys.
        let classKey = randomBytes(32)
        let manifestFileKey = randomBytes(32)
        let secureFileKey = randomBytes(32)
        let mainFileKey = randomBytes(32)
        let salt = randomBytes(20), dpsl = randomBytes(20)
        let iterations = 1000, dpic = 1000
        let k1 = try Crypto.pbkdf2(password: Data(password.utf8), salt: dpsl, rounds: dpic, algorithm: kCCPRFHmacAlgSHA256, length: 32)
        let passcodeKey = try Crypto.pbkdf2(password: k1, salt: salt, rounds: iterations, algorithm: kCCPRFHmacAlgSHA1, length: 32)
        let protectionClass = 3

        var keybag = Data()
        func tlv(_ tag: String, _ value: Data) { keybag.append(Data(tag.utf8)); keybag.append(be32(value.count)); keybag.append(value) }
        func int4(_ v: Int) -> Data { be32(v) }
        tlv("VERS", int4(4)); tlv("TYPE", int4(1)); tlv("UUID", randomBytes(16)); tlv("HMCK", randomBytes(40))
        tlv("WRAP", int4(1)); tlv("SALT", salt); tlv("ITER", int4(iterations)); tlv("DPWT", int4(0)); tlv("DPIC", int4(dpic)); tlv("DPSL", dpsl)
        // A class we cannot unwrap (device-wrapped only), then the one we use.
        tlv("UUID", randomBytes(16)); tlv("CLAS", int4(1)); tlv("WRAP", int4(1)); tlv("KTYP", int4(0)); tlv("WPKY", randomBytes(40))
        tlv("UUID", randomBytes(16)); tlv("CLAS", int4(protectionClass)); tlv("WRAP", int4(3)); tlv("KTYP", int4(0))
        tlv("WPKY", Crypto.aesWrap(kek: passcodeKey, raw: classKey)!)

        func fileKeyBlob(_ key: Data) -> Data {
            var blob = Data([UInt8(protectionClass & 0xff), UInt8((protectionClass >> 8) & 0xff), 0, 0])
            blob.append(Crypto.aesWrap(kek: classKey, raw: key)!)
            return blob
        }

        // Manifest.db with the two Health files.
        let manifestPlain = root.appendingPathComponent("Manifest.plain.db")
        try? fm.removeItem(at: manifestPlain)
        let mdb = try SQLiteDatabase(path: manifestPlain.path)
        try mdb.exec("CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)")
        try mdb.exec("CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB)")
        func addFile(_ path: String, plaintext: URL, key: Data) throws {
            let id = sha1Hex(Data(("HealthDomain-" + path).utf8))
            let size = try fm.attributesOfItem(atPath: plaintext.path)[.size] as? Int ?? 0
            let archiver = NSKeyedArchiver(requiringSecureCoding: false)
            archiver.setClassName("MBFile", for: MBFileStub.self)
            archiver.encode(MBFileStub(size: size, encryptionKey: fileKeyBlob(key), protectionClass: protectionClass), forKey: "root")
            archiver.finishEncoding()
            let blob = archiver.encodedData
            let stmt = try mdb.prepare("INSERT INTO Files VALUES (?, 'HealthDomain', ?, 1, ?)")
            mdb.withLock {
                stmt.bind(1, id); stmt.bind(2, path)
                blob.withUnsafeBytes { p in _ = sqlite3_bind_blob(stmtHandle(stmt), 3, p.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                _ = stmt.step()
            }
            let sub = dir.appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            let target = sub.appendingPathComponent(id)
            if encrypted { try Crypto.aesCBCEncryptFile(source: plaintext, destination: target, key: key) } else { try fm.copyItem(at: plaintext, to: target) }
        }
        try addFile("Health/healthdb_secure.sqlite", plaintext: secureDB, key: secureFileKey)
        try addFile("Health/healthdb.sqlite", plaintext: mainDB, key: mainFileKey)
        try mdb.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try mdb.exec("PRAGMA journal_mode = DELETE")
        if encrypted {
            try Crypto.aesCBCEncryptFile(source: manifestPlain, destination: dir.appendingPathComponent("Manifest.db"), key: manifestFileKey)
        } else {
            try fm.copyItem(at: manifestPlain, to: dir.appendingPathComponent("Manifest.db"))
        }

        var manifest: [String: Any] = [
            "IsEncrypted": encrypted,
            "Version": "10.0",
            "Date": Date(timeIntervalSinceNow: -3600),
            "Lockdown": ["DeviceName": "Josh's iPhone", "ProductVersion": "26.4", "ProductType": "iPhone17,1", "UniqueDeviceID": udid, "BuildVersion": "23E224"],
        ]
        if encrypted {
            manifest["BackupKeyBag"] = keybag
            manifest["ManifestKey"] = fileKeyBlob(manifestFileKey)
        }
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0).write(to: dir.appendingPathComponent("Manifest.plist"))
        let status: [String: Any] = ["SnapshotState": "finished", "Date": Date(timeIntervalSinceNow: -3500), "IsFullBackup": true, "Version": "3.3"]
        try PropertyListSerialization.data(fromPropertyList: status, format: .binary, options: 0).write(to: dir.appendingPathComponent("Status.plist"))
        return Built(directory: dir, password: password, udid: udid)
    }

    // MARK: Health database fixture

    static let coreDataOffset = 978_307_200.0
    static func cd(_ iso: String) -> Double { ISO8601.date(from: iso)!.timeIntervalSince1970 - coreDataOffset }

    static func makeHealthDB(secure: URL, main: URL, legacyWorkouts: Bool, codes: TypeCodeTable) throws {
        try? FileManager.default.removeItem(at: secure)
        try? FileManager.default.removeItem(at: main)
        let m = try SQLiteDatabase(path: main.path)
        try m.exec("""
        CREATE TABLE sources (ROWID INTEGER PRIMARY KEY, name TEXT, bundle_id TEXT, product_type TEXT);
        INSERT INTO sources VALUES (1, 'Josh’s Apple Watch', 'com.apple.health.watch', 'Watch7,1');
        INSERT INTO sources VALUES (2, 'Withings', 'com.withings.wiScaleNG', NULL);
        """)
        let db = try SQLiteDatabase(path: secure.path)
        try db.exec("""
        CREATE TABLE samples (data_id INTEGER PRIMARY KEY, start_date REAL, end_date REAL, data_type INTEGER);
        CREATE TABLE objects (data_id INTEGER PRIMARY KEY, uuid BLOB, provenance INTEGER, type INTEGER, creation_date REAL);
        CREATE TABLE quantity_samples (data_id INTEGER PRIMARY KEY, quantity REAL, original_quantity REAL, original_unit INTEGER);
        CREATE TABLE category_samples (data_id INTEGER PRIMARY KEY, value INTEGER);
        CREATE TABLE unit_strings (ROWID INTEGER PRIMARY KEY, unit_string TEXT);
        CREATE TABLE data_provenances (ROWID INTEGER PRIMARY KEY, sync_provenance INTEGER, origin_product_type TEXT, origin_build TEXT,
            local_product_type TEXT, local_build TEXT, source_id INTEGER, device_id INTEGER, contributor_id INTEGER, source_version TEXT, tz_name TEXT);
        INSERT INTO unit_strings VALUES (1, 'count'); INSERT INTO unit_strings VALUES (2, 'count/min'); INSERT INTO unit_strings VALUES (3, 'lb');
        INSERT INTO unit_strings VALUES (4, 'count/s');
        INSERT INTO data_provenances VALUES (1, 0, 'Watch7,1', '23S', 'iPhone17,1', '23E', 1, 1, 0, '26.4', 'America/Toronto');
        INSERT INTO data_provenances VALUES (2, 0, 'Withings', '1', 'iPhone17,1', '23E', 2, 2, 0, '1', 'America/Toronto');
        """)
        var next = 1
        func obj(_ type: Int, _ start: String, _ end: String, prov: Int = 1, tombstone: Bool = false) throws -> Int {
            let id = next; next += 1
            let uuid = UUID()
            var bytes = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: uuid.uuid) { bytes = Array($0) }
            try db.exec("INSERT INTO samples VALUES (\(id), \(cd(start)), \(cd(end)), \(type))")
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            try db.exec("INSERT INTO objects VALUES (\(id), X'\(hex)', \(prov), \(tombstone ? 2 : 1), \(cd(start)))")
            return id
        }
        func qty(_ id: Int, _ q: Double, original: Double? = nil, unit: Int? = nil) throws {
            try db.exec("INSERT INTO quantity_samples VALUES (\(id), \(q), \(original.map { String($0) } ?? "NULL"), \(unit.map { String($0) } ?? "NULL"))")
        }
        // Steps: three samples on Sept 1 and 2 (local).
        try qty(try obj(stepsCode, "2026-09-01T07:00:00", "2026-09-01T07:30:00"), 800, original: 800, unit: 1)
        try qty(try obj(stepsCode, "2026-09-01T09:00:00", "2026-09-01T09:20:00"), 1200, original: 1200, unit: 1)
        try qty(try obj(stepsCode, "2026-09-02T10:00:00", "2026-09-02T10:10:00"), 500, original: 500, unit: 1)
        // A deleted step sample (tombstone) that must be skipped.
        try qty(try obj(stepsCode, "2026-09-02T11:00:00", "2026-09-02T11:10:00", tombstone: true), 99999, original: 99999, unit: 1)
        // Heart rate: one with the source's original unit, one stored only in HealthKit's canonical count/s.
        try qty(try obj(heartRateCode, "2026-09-01T07:05:00", "2026-09-01T07:05:00"), 1.2, original: 72, unit: 2)
        try qty(try obj(heartRateCode, "2026-09-01T12:00:00", "2026-09-01T12:00:00"), 88.0 / 60.0)
        // Resting heart rate as the phone actually stores it: original unit count/s (1.1 is 66 bpm).
        if let rhr = codes.code(for: "HKQuantityTypeIdentifierRestingHeartRate") {
            try qty(try obj(rhr, "2026-09-01T06:35:00", "2026-09-01T06:35:00"), 1.1, original: 1.1, unit: 4)
        }
        // Body mass from a scale, in pounds.
        try qty(try obj(bodyMassCode, "2026-09-01T06:30:00", "2026-09-01T06:30:00", prov: 2), 80.0, original: 176.37, unit: 3)
        // SpO2 stored as a fraction with no original unit.
        if let spo2 = codes.code(for: "HKQuantityTypeIdentifierOxygenSaturation") {
            try qty(try obj(spo2, "2026-09-01T06:40:00", "2026-09-01T06:40:00"), 0.97)
        }
        // Sleep stages.
        for (value, s, e) in [(0, "2026-08-31T23:00:00", "2026-09-01T06:00:00"), (3, "2026-08-31T23:10:00", "2026-09-01T01:10:00"),
                              (4, "2026-09-01T01:10:00", "2026-09-01T02:10:00"), (2, "2026-09-01T02:10:00", "2026-09-01T02:20:00"),
                              (5, "2026-09-01T02:20:00", "2026-09-01T05:50:00")] {
            try db.exec("INSERT INTO category_samples VALUES (\(try obj(sleepCode, s, e)), \(value))")
        }
        // Stand hours.
        try db.exec("INSERT INTO category_samples VALUES (\(try obj(standHourCode, "2026-09-01T07:00:00", "2026-09-01T08:00:00")), 0)")
        try db.exec("INSERT INTO category_samples VALUES (\(try obj(standHourCode, "2026-09-01T08:00:00", "2026-09-01T09:00:00")), 1)")
        // Something this Mac's framework has never heard of.
        try qty(try obj(unknownCode, "2026-09-01T07:00:00", "2026-09-01T07:00:00"), 1)
        // A workout.
        let w = try obj(workoutCode, "2026-09-01T17:00:00", "2026-09-01T17:31:30")
        let energy = codes.code(for: "HKQuantityTypeIdentifierActiveEnergyBurned")!
        let distance = codes.code(for: "HKQuantityTypeIdentifierDistanceWalkingRunning")!
        if legacyWorkouts {
            try db.exec("CREATE TABLE workouts (data_id INTEGER PRIMARY KEY, activity_type INTEGER, duration REAL, total_energy_burned REAL, total_distance REAL, total_basal_energy_burned REAL)")
            try db.exec("INSERT INTO workouts VALUES (\(w), 37, 1890, 312.4, 4989.0, 40)")
        } else {
            try db.exec("CREATE TABLE workout_activities (ROWID INTEGER PRIMARY KEY, owner_id INTEGER, activity_type INTEGER, start_date REAL, end_date REAL, duration REAL, uuid BLOB)")
            try db.exec("INSERT INTO workout_activities VALUES (1, \(w), 37, \(cd("2026-09-01T17:00:00")), \(cd("2026-09-01T17:31:30")), 1890, NULL)")
            try db.exec("CREATE TABLE workout_statistics (ROWID INTEGER PRIMARY KEY, workout_activity_id INTEGER, data_type INTEGER, quantity REAL, minimum REAL, maximum REAL, average REAL)")
            try db.exec("INSERT INTO workout_statistics VALUES (1, 1, \(energy), 312.4, NULL, NULL, NULL)")
            try db.exec("INSERT INTO workout_statistics VALUES (2, 1, \(distance), 4989.0, NULL, NULL, NULL)")
            try db.exec("INSERT INTO workout_statistics VALUES (3, 1, \(heartRateCode), NULL, 110, 178, 152)")
        }
        // Fold the WAL into the main files so they can be encrypted as single files.
        for d in [db, m] {
            try d.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            try d.exec("PRAGMA journal_mode = DELETE")
        }
    }

    // MARK: helpers

    static func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }

    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    static func sha1Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func stmtHandle(_ s: SQLiteDatabase.Statement) -> OpaquePointer? { s.rawHandle }
}
