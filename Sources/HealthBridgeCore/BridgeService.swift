import Combine
import Foundation
import Network

public enum ServerState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    public var isRunning: Bool { if case .running = self { return true } else { return false } }
}

/// Composes providers, auth, audit, and the HTTP/MCP server. The menu bar UI
/// observes this object; everything it exposes is main-actor state.
@MainActor
public final class BridgeService: ObservableObject {
    @Published public private(set) var settings: BridgeSettings
    @Published public private(set) var serverState: ServerState = .stopped
    @Published public private(set) var pairings: [Pairing] = []
    @Published public private(set) var recentEvents: [AuditEvent] = []
    @Published public private(set) var providerStatus: ProviderStatus?
    @Published public private(set) var healthKitAvailable: Bool = HealthKitProvider.isAvailable
    @Published public private(set) var importProgress: ImportProgress?
    @Published public private(set) var lastImport: ImportReport?
    @Published public private(set) var lastBackupImport: BackupImportReport?
    @Published public private(set) var backups: [DeviceBackup] = []
    @Published public private(set) var backupsError: String?
    @Published public private(set) var backupsNeedFullDiskAccess = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var exportProgress: PHRExportProgress?
    @Published public private(set) var lastExport: PHRExportReport?

    public let pairingStore: PairingStore
    public let audit: AuditLog
    private let healthKit = HealthKitProvider()
    private let export: HealthExportProvider
    private let demo = DemoHealthProvider()
    private let settingsURL: URL
    private var server: HTTPServer?
    private var mcp: MCPServer?
    private let providerBox = ProviderBox()
    private let settingsBox = SettingsBox()

    public init(supportDirectory: URL = AppPaths.supportDirectory) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        settingsURL = supportDirectory.appendingPathComponent("settings.json")
        settings = BridgeSettings.load(from: settingsURL)
        pairingStore = PairingStore(url: supportDirectory.appendingPathComponent("pairings.json"))
        audit = AuditLog(url: supportDirectory.appendingPathComponent("audit.jsonl"))
        export = HealthExportProvider(databaseURL: supportDirectory.appendingPathComponent("health-export.sqlite"))
        pairings = pairingStore.all
        recentEvents = audit.recent.reversed()
        settingsBox.value = settings
        providerBox.value = selectProvider()

        pairingStore.onChange = { [weak self] list in
            Task { @MainActor in self?.pairings = list }
        }
        audit.onAppend = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.recentEvents.insert(event, at: 0)
                if self.recentEvents.count > 100 { self.recentEvents.removeLast(self.recentEvents.count - 100) }
            }
        }
        Task { await refreshProviderStatus() }
    }

    // MARK: Provider selection

    public var activeProvider: HealthDataProvider { providerBox.value }

    private func selectProvider() -> HealthDataProvider {
        switch settings.dataSource {
        case .healthKit: return healthKit
        case .healthExport: return export
        case .demo: return demo
        case .automatic:
            if HealthKitProvider.isAvailable { return healthKit }
            if export.hasData { return export }
            return healthKit  // reports "unavailable" honestly
        }
    }

    public func refreshProviderStatus() async {
        let provider = activeProvider
        providerStatus = await provider.status()
        healthKitAvailable = HealthKitProvider.isAvailable
    }

    public var hasImportedExport: Bool { export.hasData }

    // MARK: Server lifecycle

    public func start() {
        guard !serverState.isRunning else { return }
        serverState = .starting
        let mcp = MCPServer(
            provider: { [providerBox] in providerBox.value },
            settings: { [settingsBox] in settingsBox.value },
            pairings: pairingStore,
            audit: audit
        )
        self.mcp = mcp
        let server = HTTPServer(port: settings.port) { request, ctx in
            await mcp.handle(request, ctx)
        }
        self.server = server
        do {
            try server.start { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.serverState = .running(port: server.port)
                    case .failed(let error): self.serverState = .failed(Self.describe(error))
                    case .cancelled: if case .running = self.serverState { self.serverState = .stopped }
                    default: break
                    }
                }
            }
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        mcp = nil
        serverState = .stopped
    }

    public func restart() {
        stop()
        if settings.serverEnabled { start() }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port is already in use. Choose another port."
        }
        return error.localizedDescription
    }

    // MARK: Settings

    public func update(_ change: (inout BridgeSettings) -> Void) {
        var s = settings
        change(&s)
        let portChanged = s.port != settings.port
        let enabledChanged = s.serverEnabled != settings.serverEnabled
        let sourceChanged = s.dataSource != settings.dataSource
        settings = s
        settingsBox.value = s
        s.save(to: settingsURL)
        if sourceChanged {
            providerBox.value = selectProvider()
            Task { await refreshProviderStatus() }
        }
        if portChanged || enabledChanged {
            if s.serverEnabled { restart() } else { stop() }
        }
    }

    // MARK: Pairings

    /// Returns the plaintext token exactly once.
    public func createPairing(name: String) -> (Pairing, String) {
        let (p, token) = pairingStore.create(name: name)
        audit.append(AuditEvent(outcome: .ok, pairingName: p.name, pairingID: p.id, method: "pairing", summary: "created"))
        return (p, token)
    }

    public func revoke(_ pairing: Pairing) {
        pairingStore.revoke(id: pairing.id)
        audit.append(AuditEvent(outcome: .ok, pairingName: pairing.name, pairingID: pairing.id, method: "pairing", summary: "revoked"))
    }

    public func delete(_ pairing: Pairing) {
        pairingStore.delete(id: pairing.id)
    }

    public func resetBinding(_ pairing: Pairing) {
        pairingStore.resetBinding(id: pairing.id)
        audit.append(AuditEvent(outcome: .ok, pairingName: pairing.name, pairingID: pairing.id, method: "pairing", summary: "binding reset"))
    }

    public func rename(_ pairing: Pairing, to name: String) {
        pairingStore.rename(id: pairing.id, to: name)
    }

    // MARK: HealthKit

    public func requestHealthAccess() async {
        do {
            try await healthKit.requestAuthorization()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshProviderStatus()
    }

    // MARK: Import

    public var isImporting: Bool { importProgress != nil }

    public func importHealthExport(from source: URL) async {
        guard !isImporting else { return }
        importProgress = ImportProgress(phase: "Starting", records: 0, workouts: 0, clinicalRecords: 0, skippedTypes: 0)
        lastError = nil
        let destination = AppPaths.exportDatabase
        let scratch = AppPaths.importScratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result: Result<ImportReport, Error> = await Task.detached(priority: .userInitiated) { [destination, scratch] in
            let importer = HealthExportImporter(destination: destination, scratch: scratch) { progress in
                Task { @MainActor [weak self] in self?.importProgress = progress }
            }
            do { return .success(try importer.run(source: source)) } catch { return .failure(error) }
        }.value
        importProgress = nil
        switch result {
        case .success(let report):
            lastImport = report
            export.reload()
            if settings.dataSource == .automatic || settings.dataSource == .healthExport {
                providerBox.value = selectProvider()
            }
            audit.append(AuditEvent(outcome: .ok, method: "import",
                                    summary: "\(report.records) samples, \(report.workouts) workouts, \(report.clinicalRecords) clinical records"))
        case .failure(let error):
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            audit.append(AuditEvent(outcome: .error, method: "import", summary: lastError ?? "failed"))
        }
        await refreshProviderStatus()
    }

    // MARK: Disconnect

    /// Deletes the imported Health store from this Mac. Agents lose access at once. The iPhone
    /// backup or export file it came from stays where it is; a backup password saved in the
    /// keychain for that device is forgotten.
    public func disconnectImportedData() async {
        guard !isImporting, !isExporting else { return }
        let udid = export.meta("deviceUDID")
        do {
            try export.removeStore()
            if let udid, !udid.isEmpty { BackupPasswordStore.forget(udid: udid) }
            lastImport = nil
            lastBackupImport = nil
            lastError = nil
            providerBox.value = selectProvider()
            audit.append(AuditEvent(outcome: .ok, method: "disconnect", summary: "imported Health data removed from this Mac"))
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            audit.append(AuditEvent(outcome: .error, method: "disconnect", summary: lastError ?? "failed"))
        }
        await refreshProviderStatus()
    }

    // MARK: PHR export

    public var isExporting: Bool { exportProgress != nil }

    /// Writes the active data source as an HL7 Personal Health Record (`.phr` NDJSON or `.sphr` zip).
    public func exportPHR(to destination: URL, options: PHRExportOptions) async {
        guard !isExporting, !isImporting else { return }
        exportProgress = PHRExportProgress(phase: "Starting", resources: 0)
        lastError = nil
        let provider = activeProvider
        let scratch = AppPaths.exportScratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result: Result<PHRExportReport, Error> = await Task.detached(priority: .userInitiated) { [provider, scratch] in
            let exporter = PHRExporter(provider: provider, scratch: scratch) { progress in
                Task { @MainActor [weak self] in self?.exportProgress = progress }
            }
            do { return .success(try await exporter.run(to: destination, options: options)) } catch { return .failure(error) }
        }.value
        exportProgress = nil
        switch result {
        case .success(let report):
            lastExport = report
            audit.append(AuditEvent(outcome: .ok, method: "export-phr",
                                    summary: "\(report.resources) resources to \(destination.lastPathComponent)"))
        case .failure(let error):
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            audit.append(AuditEvent(outcome: .error, method: "export-phr", summary: lastError ?? "failed"))
        }
    }

    public func clearLastExport() { lastExport = nil }

    // MARK: iPhone backups

    /// Lists Finder backups. Sets `backupsNeedFullDiskAccess` when macOS refuses to show the folder.
    public func refreshBackups() {
        do {
            backups = try BackupLocator.listBackups()
            backupsError = nil
            backupsNeedFullDiskAccess = false
        } catch let error as BackupLocatorError {
            backups = []
            if case .needsFullDiskAccess = error { backupsNeedFullDiskAccess = true }
            backupsError = error.errorDescription
        } catch {
            backups = []
            backupsError = error.localizedDescription
        }
    }

    public func rememberedBackupPassword(for backup: DeviceBackup) -> String? {
        BackupPasswordStore.load(udid: backup.udid)
    }

    public func importBackup(_ backup: DeviceBackup, password: String, rememberPassword: Bool) async {
        guard !isImporting else { return }
        importProgress = ImportProgress(phase: "Starting", records: 0, workouts: 0, clinicalRecords: 0, skippedTypes: 0)
        lastError = nil
        let destination = AppPaths.exportDatabase
        let scratch = AppPaths.importScratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result: Result<BackupImportReport, Error> = await Task.detached(priority: .userInitiated) { [destination, scratch] in
            let importer = HealthBackupImporter(destination: destination, scratch: scratch) { progress in
                Task { @MainActor [weak self] in self?.importProgress = progress }
            }
            do { return .success(try importer.run(backup: backup, password: password)) } catch { return .failure(error) }
        }.value
        importProgress = nil
        switch result {
        case .success(let report):
            lastBackupImport = report
            if rememberPassword { try? BackupPasswordStore.save(password, udid: backup.udid) } else { BackupPasswordStore.forget(udid: backup.udid) }
            export.reload()
            if settings.dataSource == .automatic || settings.dataSource == .healthExport {
                providerBox.value = selectProvider()
            }
            var summary = "\(report.samples) samples, \(report.workouts) workouts from \(backup.deviceName)"
            if !report.unmappedCodes.isEmpty { summary += ", \(report.unmappedCodes.count) unknown type codes" }
            audit.append(AuditEvent(outcome: .ok, method: "import-backup", summary: summary))
        case .failure(let error):
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            audit.append(AuditEvent(outcome: .error, method: "import-backup", summary: lastError ?? "failed"))
        }
        await refreshProviderStatus()
    }

    public func clearAudit() {
        audit.clear()
        recentEvents = []
    }
}

/// Reference boxes so the (non-main-actor) server can read the current
/// provider and settings without hopping actors.
final class ProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: HealthDataProvider = DemoHealthProvider(days: 1)
    var value: HealthDataProvider {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = BridgeSettings()
    var value: BridgeSettings {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

// MARK: - Client configuration snippets

public enum MCPClientConfig {
    public static func url(port: UInt16) -> String { "http://127.0.0.1:\(port)\(BridgeInfo.mcpPath)" }

    public static func claudeCodeCommand(token: String, port: UInt16) -> String {
        "claude mcp add --transport http health-bridge \(url(port: port)) --header \"Authorization: Bearer \(token)\""
    }

    public static func genericJSON(token: String, port: UInt16) -> String {
        """
        {
          "mcpServers": {
            "health-bridge": {
              "type": "http",
              "url": "\(url(port: port))",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    public static func cursorJSON(token: String, port: UInt16) -> String {
        """
        {
          "mcpServers": {
            "health-bridge": {
              "url": "\(url(port: port))",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    /// Claude Desktop only launches stdio servers from its config file; mcp-remote bridges to HTTP.
    public static func claudeDesktopJSON(token: String, port: UInt16) -> String {
        """
        {
          "mcpServers": {
            "health-bridge": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(url(port: port))", "--header", "Authorization: Bearer \(token)"]
            }
          }
        }
        """
    }

    public static func curlExample(token: String, port: UInt16) -> String {
        """
        curl -s \(url(port: port)) \\
          -H "Authorization: Bearer \(token)" \\
          -H "Content-Type: application/json" \\
          -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
        """
    }
}
