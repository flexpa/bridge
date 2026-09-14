import Foundation

public struct BackupImportReport: Sendable, Equatable {
    public var backup: DeviceBackup
    public var samples: Int
    public var workouts: Int
    public var skippedTombstones: Int
    public var unmappedCodes: [Int: Int]
    public var uncataloguedCodes: [Int: Int]
    public var schemaFingerprint: String
    public var typeTableConflicts: [String]
    public var duration: TimeInterval
}

/// Pulls the Health store out of an encrypted iPhone backup and writes it to the
/// bridge's SQLite store. Decrypted files exist only in a 0700 scratch folder
/// for the duration of the import; keys exist only in memory.
public final class HealthBackupImporter {
    public static let healthDomain = "HealthDomain"
    public static let securePath = "Health/healthdb_secure.sqlite"
    public static let plainPath = "Health/healthdb.sqlite"

    private let destination: URL
    private let scratch: URL
    private let codes: TypeCodeTable
    private let progress: @Sendable (ImportProgress) -> Void

    public init(destination: URL, scratch: URL, codes: TypeCodeTable = .fromFramework(),
                progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) {
        self.destination = destination
        self.scratch = scratch
        self.codes = codes
        self.progress = progress
    }

    public func run(backup: DeviceBackup, password: String) throws -> BackupImportReport {
        let started = Date()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        report("Unlocking backup")
        let decryptor = try BackupDecryptor(backup: backup)
        decryptor.progress = { [progress] phase in progress(ImportProgress(phase: phase, records: 0, workouts: 0, clinicalRecords: 0, skippedTypes: 0)) }
        try decryptor.unlock(password: password)

        report("Reading manifest")
        let manifest = scratch.appendingPathComponent("Manifest.db")
        try decryptor.decryptManifest(to: manifest)
        let files = try decryptor.files(inManifest: manifest, domain: Self.healthDomain, pathPrefix: "Health/healthdb")
        guard let secure = files.first(where: { $0.relativePath == Self.securePath }) else {
            throw HealthDataError.unavailable("This backup has no Health database. Make sure the backup is encrypted and finished.")
        }

        report("Decrypting Health database")
        let secureURL = scratch.appendingPathComponent("healthdb_secure.sqlite")
        try decryptor.decrypt(secure, to: secureURL)
        for sidecar in ["-wal", "-shm"] {
            if let f = files.first(where: { $0.relativePath == Self.securePath + sidecar }) {
                try? decryptor.decrypt(f, to: scratch.appendingPathComponent("healthdb_secure.sqlite" + sidecar))
            }
        }
        var plainURL: URL? = nil
        if let plain = files.first(where: { $0.relativePath == Self.plainPath }) {
            let url = scratch.appendingPathComponent("healthdb.sqlite")
            try? decryptor.decrypt(plain, to: url)
            plainURL = url
        }

        report("Reading samples")
        let reader = try HealthDBReader(secureDatabase: secureURL, plainDatabase: plainURL, codes: codes)
        let writer = try HealthStoreWriter(destination: destination)
        var samples = 0, workouts = 0, tombstones = 0
        var unmapped: [Int: Int] = [:], uncatalogued: [Int: Int] = [:]
        do {
            for (code, count) in try reader.typeCounts() {
                guard let identifier = codes.identifier(for: code) else { unmapped[code] = count; continue }
                if identifier == TypeCodeTable.workoutIdentifier { continue }
                guard HealthTypeCatalog.byIdentifier[identifier] != nil else { uncatalogued[code] = count; continue }
                try reader.forEachSample(code: code) { raw in
                    if raw.isTombstone { tombstones += 1; return }
                    guard let sample = HealthDBMapper.sample(from: raw) else { return }
                    writer.add(sample, uuid: raw.uuid, code: code)
                    samples += 1
                    if samples % 20_000 == 0 { report("Reading samples", samples: samples, workouts: workouts) }
                }
            }
            report("Reading workouts", samples: samples, workouts: workouts)
            for raw in try reader.workouts() {
                writer.add(HealthDBMapper.workout(from: raw), uuid: raw.uuid)
                workouts += 1
            }
        } catch {
            writer.abandon()
            throw error
        }

        report("Finishing", samples: samples, workouts: workouts)
        writer.setMeta("sourceKind", "backup")
        writer.setMeta("deviceName", backup.deviceName)
        writer.setMeta("deviceUDID", backup.udid)
        writer.setMeta("iosVersion", backup.iosVersion ?? "")
        writer.setMeta("backupDate", backup.date.map(ISO8601.string) ?? "")
        writer.setMeta("schemaFingerprint", reader.schema.fingerprint)
        writer.setMeta("recordCount", String(samples))
        writer.setMeta("workoutCount", String(workouts))
        writer.setMeta("tombstoneCount", String(tombstones))
        writer.setMeta("unmappedCodes", JSON.string(.object(Dictionary(uniqueKeysWithValues: unmapped.map { (String($0.key), JSONValue.number(Double($0.value))) }))))
        writer.setMeta("uncataloguedCodes", JSON.string(.object(Dictionary(uniqueKeysWithValues: uncatalogued.map { (String($0.key), JSONValue.number(Double($0.value))) }))))
        writer.setMeta("uncataloguedNames", JSON.string(.object(Dictionary(uniqueKeysWithValues: uncatalogued.keys.compactMap { code in
            codes.identifier(for: code).map { (String(code), JSONValue.string($0)) }
        }))))
        try writer.finish()

        let conflicts = codes.conflicts.map { "code \($0.0): framework says \($0.1), seed says \($0.2)" }
        return BackupImportReport(backup: backup, samples: samples, workouts: workouts, skippedTombstones: tombstones,
                                  unmappedCodes: unmapped, uncataloguedCodes: uncatalogued, schemaFingerprint: reader.schema.fingerprint,
                                  typeTableConflicts: conflicts, duration: Date().timeIntervalSince(started))
    }

    private func report(_ phase: String, samples: Int = 0, workouts: Int = 0) {
        progress(ImportProgress(phase: phase, records: samples, workouts: workouts, clinicalRecords: 0, skippedTypes: 0))
    }
}
