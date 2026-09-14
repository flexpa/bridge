import Foundation

/// A Finder (MobileSync) backup of an iOS device found on this Mac.
public struct DeviceBackup: Identifiable, Sendable, Equatable {
    public var id: String { udid }
    public var udid: String
    public var directory: URL
    public var deviceName: String
    public var productType: String?
    public var iosVersion: String?
    public var date: Date?
    public var isEncrypted: Bool
    public var isFinished: Bool
    public var backupVersion: String?
}

public enum BackupLocatorError: Error, LocalizedError, Sendable {
    case needsFullDiskAccess(URL)
    case notABackup(URL)

    public var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess(let url):
            return "macOS blocked access to \(url.path). Grant Flexpa Health Bridge Full Disk Access in System Settings → Privacy & Security, then try again."
        case .notABackup(let url):
            return "\(url.lastPathComponent) is not an iPhone backup folder (no Manifest.plist)."
        }
    }
}

/// Finds iPhone backups where Finder keeps them. Reading that folder needs
/// Full Disk Access; the error says so instead of pretending there are none.
public enum BackupLocator {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    }

    public static func listBackups(root: URL = defaultRoot) throws -> [DeviceBackup] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { throw BackupLocatorError.needsFullDiskAccess(root) }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) { throw BackupLocatorError.needsFullDiskAccess(root) }
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return [] }
            throw error
        }
        return entries.compactMap { try? describe($0) }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Raw view of the backup folder for diagnostics: every entry, hidden ones included, with why it was or was not a backup.
    public static func inspect(root: URL = defaultRoot) throws -> [String] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey], options: [])
        } catch let error as NSError where (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError) || (error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM)) {
            throw BackupLocatorError.needsFullDiskAccess(root)
        }
        return entries.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate.map { ISO8601.string(from: $0) } ?? "?"
            guard values?.isDirectory == true else {
                return "\(url.lastPathComponent)  file, \(values?.fileSize ?? 0) bytes, modified \(modified)"
            }
            let children = (try? fm.contentsOfDirectory(atPath: url.path))?.count ?? -1
            do {
                let b = try describe(url)
                return "\(url.lastPathComponent)  backup: \(b.deviceName), iOS \(b.iosVersion ?? "?"), encrypted \(b.isEncrypted), finished \(b.isFinished), \(children) entries, modified \(modified)"
            } catch {
                return "\(url.lastPathComponent)  folder, \(children) entries, modified \(modified), not a backup: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
    }

    /// Reads Manifest.plist and Status.plist for one backup folder.
    public static func describe(_ directory: URL) throws -> DeviceBackup {
        let manifestURL = directory.appendingPathComponent("Manifest.plist")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw BackupLocatorError.notABackup(directory) }
        let manifest = try readPlist(manifestURL)
        let lockdown = manifest["Lockdown"] as? [String: Any] ?? [:]
        var status: [String: Any] = [:]
        if let s = try? readPlist(directory.appendingPathComponent("Status.plist")) { status = s }
        return DeviceBackup(
            udid: lockdown["UniqueDeviceID"] as? String ?? directory.lastPathComponent,
            directory: directory,
            deviceName: lockdown["DeviceName"] as? String ?? "iPhone",
            productType: lockdown["ProductType"] as? String,
            iosVersion: lockdown["ProductVersion"] as? String,
            date: (status["Date"] as? Date) ?? (manifest["Date"] as? Date),
            isEncrypted: manifest["IsEncrypted"] as? Bool ?? false,
            isFinished: (status["SnapshotState"] as? String).map { $0.lowercased() == "finished" } ?? true,
            backupVersion: manifest["Version"] as? String
        )
    }

    static func readPlist(_ url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            throw BackupLocatorError.needsFullDiskAccess(url)
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw BackupLocatorError.notABackup(url.deletingLastPathComponent())
        }
        return plist
    }
}

/// Remembers a backup password in the login keychain, per device, only when the user asks.
public enum BackupPasswordStore {
    static let service = "com.flexpa.HealthBridge.backup-password"

    public static func save(_ password: String, udid: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: udid,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "Flexpa Health Bridge: iPhone backup password"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw HealthDataError.internalError("keychain save failed (\(status))") }
    }

    public static func load(udid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: udid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func forget(udid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: udid,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
