import Foundation

public enum DataSourcePreference: String, Codable, Sendable, CaseIterable {
    /// Live HealthKit when the Mac has it, otherwise the imported export.
    case automatic
    case healthKit
    case healthExport
    case demo
}

public struct BridgeSettings: Codable, Equatable, Sendable {
    public static let defaultPort: UInt16 = 4271

    public var port: UInt16 = BridgeSettings.defaultPort
    public var serverEnabled = true
    /// Bind each pairing to the code-signing identity of the first process
    /// that uses it, and refuse the token from anything else afterwards.
    public var bindPairingsToPeer = true
    public var dataSource: DataSourcePreference = .automatic
    /// Allow `clinical_records` to return FHIR resources.
    public var exposeClinicalRecords = true
    /// Set while the user is granting Full Disk Access so the next launch
    /// reopens the backup picker where they left off.
    public var resumeBackupPicker = false

    public init() {}

    public static func load(from url: URL) -> BridgeSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(BridgeSettings.self, from: data) else { return BridgeSettings() }
        return s
    }

    public func save(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("HealthBridge: failed to save settings: \(error)")
        }
    }
}

public enum AppPaths {
    public static let bundleIdentifier = "com.flexpa.HealthBridge"

    /// `HEALTHBRIDGE_HOME` overrides the state directory (tests, side-by-side instances).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["HEALTHBRIDGE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HealthBridge", isDirectory: true)
    }

    public static var settings: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var pairings: URL { supportDirectory.appendingPathComponent("pairings.json") }
    public static var auditLog: URL { supportDirectory.appendingPathComponent("audit.jsonl") }
    public static var exportDatabase: URL { supportDirectory.appendingPathComponent("health-export.sqlite") }
    public static var importScratch: URL { supportDirectory.appendingPathComponent("import", isDirectory: true) }
    public static var exportScratch: URL { supportDirectory.appendingPathComponent("export", isDirectory: true) }
}
