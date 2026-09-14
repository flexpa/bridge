import Foundation
import HealthBridgeCore

/// `HealthBridge --pair "Claude Code"` and friends. Writes the same pairings
/// file the running app watches, so a token created here works immediately.
enum CommandLineTool {
    static func runIfRequested(arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        switch first {
        case "--pair", "pair":
            let name = arguments.dropFirst().joined(separator: " ")
            guard !name.isEmpty else { fail("usage: HealthBridge --pair <agent name>") }
            pair(name: name)
        case "--list", "list", "--list-pairings":
            list()
        case "--revoke", "revoke":
            guard let target = arguments.dropFirst().first else { fail("usage: HealthBridge --revoke <pairing id or name>") }
            revoke(target)
        case "--reset-binding", "reset-binding":
            guard let target = arguments.dropFirst().first else { fail("usage: HealthBridge --reset-binding <pairing id or name>") }
            resetBinding(target)
        case "--import", "import":
            guard let path = arguments.dropFirst().first else { fail("usage: HealthBridge --import <export.zip|folder>") }
            importExport(path)
        case "--list-backups", "list-backups":
            listBackups(verbose: arguments.contains("--verbose"))
        case "--import-backup", "import-backup":
            guard let target = arguments.dropFirst().first else { fail("usage: HealthBridge --import-backup <udid|device name|folder> [--remember-password]") }
            importBackup(target, remember: arguments.contains("--remember-password"))
        case "--version", "-v":
            print("\(BridgeInfo.displayName) \(BridgeInfo.version)")
        case "--help", "-h", "help":
            print(usage)
        default:
            return false
        }
        return true
    }

    static let usage = """
    \(BridgeInfo.displayName) \(BridgeInfo.version)

    Run with no arguments to start the menu bar app.

      --pair <name>            Create a pairing and print its one-time token and client config
      --list                   List pairings
      --revoke <id|name>       Revoke a pairing
      --reset-binding <id|name> Let a token be used from a different app again
      --import <path>          Import a Health app export (export.zip or unzipped folder)
      --list-backups           List iPhone backups Finder keeps on this Mac
      --import-backup <udid|name|folder> [--remember-password]
                               Decrypt the Health store out of an encrypted iPhone backup and import it.
                               Password: HEALTHBRIDGE_BACKUP_PASSWORD, the login keychain, or an interactive prompt.
                               The terminal app needs Full Disk Access to see the backup folder.
      --version                Print the version
    """

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    private static func pair(name: String) {
        let store = PairingStore(url: AppPaths.pairings)
        let settings = BridgeSettings.load(from: AppPaths.settings)
        let (pairing, token) = store.create(name: name)
        print("""
        Paired "\(pairing.name)" (\(pairing.id.uuidString.prefix(8))).

        Token (shown once, store it in the agent's config only):
          \(token)

        Claude Code:
          \(MCPClientConfig.claudeCodeCommand(token: token, port: settings.port))

        Generic MCP client JSON:
        \(MCPClientConfig.genericJSON(token: token, port: settings.port))

        The first app that uses this token becomes the only app allowed to use it
        (see Flexpa Health Bridge → Settings → Bind tokens to the first app).
        """)
    }

    private static func list() {
        let store = PairingStore(url: AppPaths.pairings)
        if store.all.isEmpty {
            print("No pairings.")
            return
        }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        for p in store.all {
            let state = p.isRevoked ? "revoked" : "active"
            let bound = p.boundDisplayName.map { " · bound to \($0)" } ?? ""
            let used = p.lastUsedAt.map { " · last used \(f.string(from: $0))" } ?? " · never used"
            print("\(p.id.uuidString.prefix(8))  \(p.name)  [\(state)] \(p.tokenPrefix)…\(bound)\(used) · \(p.requestCount) requests")
        }
    }

    private static func find(_ target: String, in store: PairingStore) -> Pairing? {
        store.all.first { $0.id.uuidString.lowercased().hasPrefix(target.lowercased()) || $0.name.lowercased() == target.lowercased() }
    }

    private static func revoke(_ target: String) {
        let store = PairingStore(url: AppPaths.pairings)
        guard let p = find(target, in: store) else { fail("no pairing matches '\(target)'") }
        store.revoke(id: p.id)
        print("Revoked \(p.name).")
    }

    private static func resetBinding(_ target: String) {
        let store = PairingStore(url: AppPaths.pairings)
        guard let p = find(target, in: store) else { fail("no pairing matches '\(target)'") }
        store.resetBinding(id: p.id)
        print("Reset binding for \(p.name). The next app to use the token will be bound to it.")
    }

    private static func listBackups(verbose: Bool) {
        do {
            if verbose {
                print("Contents of \(BackupLocator.defaultRoot.path):")
                for line in try BackupLocator.inspect() { print("  " + line) }
            }
            let backups = try BackupLocator.listBackups()
            if backups.isEmpty {
                print("No iPhone backups in \(BackupLocator.defaultRoot.path).")
                print("Back up the iPhone with Finder, with \"Encrypt local backup\" turned on.")
                return
            }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            for b in backups {
                let when = b.date.map { f.string(from: $0) } ?? "unknown date"
                let enc = b.isEncrypted ? "encrypted" : "NOT encrypted (no Health data)"
                let done = b.isFinished ? "" : " · in progress"
                print("\(b.udid)  \(b.deviceName) · iOS \(b.iosVersion ?? "?") · \(when) · \(enc)\(done)")
            }
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func importBackup(_ target: String, remember: Bool) {
        let backup: DeviceBackup
        do {
            if FileManager.default.fileExists(atPath: target) {
                backup = try BackupLocator.describe(URL(fileURLWithPath: target))
            } else {
                let all = try BackupLocator.listBackups()
                guard let found = all.first(where: { $0.udid.lowercased().hasPrefix(target.lowercased()) || $0.deviceName.lowercased() == target.lowercased() }) else {
                    fail("no backup matches '\(target)'. Run --list-backups.")
                }
                backup = found
            }
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard backup.isEncrypted else { fail("That backup is not encrypted, so it has no Health data. Turn on \"Encrypt local backup\" in Finder and back up again.") }

        var password = ProcessInfo.processInfo.environment["HEALTHBRIDGE_BACKUP_PASSWORD"]
        var fromKeychain = false
        if password == nil, let saved = BackupPasswordStore.load(udid: backup.udid) { password = saved; fromKeychain = true }
        if password == nil {
            guard let entered = getpass("Backup password for \(backup.deviceName): ") else { fail("no password") }
            password = String(cString: entered)
        }
        guard let password, !password.isEmpty else { fail("empty password") }

        let importer = HealthBackupImporter(destination: AppPaths.exportDatabase,
                                            scratch: AppPaths.importScratch.appendingPathComponent(UUID().uuidString)) { progress in
            let counts = progress.records > 0 ? " \(progress.records.formatted()) samples, \(progress.workouts) workouts" : ""
            FileHandle.standardError.write(Data("\r\(progress.phase)…\(counts)      ".utf8))
        }
        do {
            let report = try importer.run(backup: backup, password: password)
            if remember { try? BackupPasswordStore.save(password, udid: backup.udid) }
            print("")
            print("Imported \(report.samples.formatted()) samples and \(report.workouts) workouts from \(backup.deviceName) (iOS \(backup.iosVersion ?? "?")) in \(Int(report.duration))s.")
            print("Schema fingerprint \(report.schemaFingerprint); \(report.skippedTombstones) deletion tombstones skipped.")
            if !report.uncataloguedCodes.isEmpty {
                let list = report.uncataloguedCodes.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
                print("Types present but not served yet: \(list)")
            }
            if !report.unmappedCodes.isEmpty {
                let list = report.unmappedCodes.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
                print("Unknown type codes (new in this iOS?): \(list)")
            }
            for c in report.typeTableConflicts { print("Type table conflict: \(c)") }
            if fromKeychain { print("Password came from the login keychain.") }
            print("Restart Flexpa Health Bridge (or switch data source) to serve the new data.")
        } catch {
            fail("import failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    private static func importExport(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let importer = HealthExportImporter(destination: AppPaths.exportDatabase,
                                            scratch: AppPaths.importScratch.appendingPathComponent(UUID().uuidString)) { progress in
            FileHandle.standardError.write(Data("\r\(progress.phase): \(progress.records) samples, \(progress.workouts) workouts, \(progress.clinicalRecords) clinical records   ".utf8))
        }
        do {
            let report = try importer.run(source: url)
            print("\nImported \(report.records) samples, \(report.workouts) workouts, \(report.clinicalRecords) clinical records in \(Int(report.duration))s.")
            if let date = report.exportDate { print("Export date: \(date)") }
            if !report.skippedTypes.isEmpty {
                print("Skipped \(report.skippedTypes.values.reduce(0, +)) records of \(report.skippedTypes.count) unsupported types.")
            }
            print("Restart Flexpa Health Bridge (or switch data source) to serve the new data.")
        } catch {
            fail("import failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }
}
