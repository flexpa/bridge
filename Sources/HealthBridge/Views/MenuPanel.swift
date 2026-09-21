import AppKit
import HealthBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct MenuPanel: View {
    @EnvironmentObject var bridge: BridgeService
    // `--expand` (preview mode) opens every section for design review.
    @State private var showSettings = CommandLine.arguments.contains("--expand")
    @State private var showActivity = CommandLine.arguments.contains("--expand")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView()
            Divider()
            DataSourceSection()
            Divider()
            AgentsSection()
            Divider()
            DisclosureRow(title: "Recent activity", systemImage: "list.bullet.rectangle", isExpanded: $showActivity,
                          badge: bridge.recentEvents.isEmpty ? nil : "\(bridge.recentEvents.count)") {
                ActivityList()
            }
            Divider()
            DisclosureRow(title: "Settings", systemImage: "gearshape", isExpanded: $showSettings) {
                SettingsSection()
            }
            Divider()
            FooterView()
        }
        .frame(width: 360)
        .font(.system(size: 12))
        .tint(FlexpaBrand.accent)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject var bridge: BridgeService

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(BridgeInfo.displayName).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { bridge.settings.serverEnabled },
                set: { on in bridge.update { $0.serverEnabled = on } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(bridge.settings.serverEnabled ? "Stop serving" : "Start serving")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch bridge.serverState {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch bridge.serverState {
        case .running(let port): return "Serving agents on 127.0.0.1:\(port)"
        case .starting: return "Starting…"
        case .stopped: return "Paused. Agents cannot connect."
        case .failed(let message): return message
        }
    }
}

// MARK: - Data source

private struct DataSourceSection: View {
    @EnvironmentObject var bridge: BridgeService
    @State private var importError: String?
    @State private var confirmDisconnect = false
    // `--expand` (preview mode) also opens the backup picker for design review.
    @State private var showBackupPicker = CommandLine.arguments.contains("--expand")
    @EnvironmentObject private var coach: FullDiskAccessCoach

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Data source")

            if let progress = bridge.importProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(progress.phase)…").font(.system(size: 12, weight: .medium))
                        Text("\(progress.records.formatted()) samples · \(progress.workouts) workouts · \(progress.clinicalRecords) clinical records")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else if let status = bridge.providerStatus {
                if status.available {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: status))
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.description).font(.system(size: 12, weight: .medium))
                            if let range = status.dataRange, let count = status.sampleCount {
                                Text("\(count.formatted()) samples · \(dayString(range.start)) → \(dayString(range.end))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if let detail = status.detail {
                                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    actionRow(for: status)
                } else {
                    EmptyDataSourceView(
                        grantAccess: status.kind == "healthkit" && status.authorization != .unavailable
                            ? { Task { await bridge.requestHealthAccess() } } : nil,
                        importBackup: openBackupPicker,
                        importExport: chooseExport,
                        tryDemo: { bridge.update { $0.dataSource = .demo } }
                    )
                }
                if let progress = bridge.exportProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(progress.phase)…").font(.system(size: 12, weight: .medium))
                            Text("\(progress.resources.formatted()) resources written").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else if let report = bridge.lastExport {
                    ExportResultRow(report: report)
                }
                if showBackupPicker || bridge.settings.resumeBackupPicker, bridge.importProgress == nil {
                    BackupPickerView(onDone: {
                        showBackupPicker = false
                        bridge.update { $0.resumeBackupPicker = false }
                    })
                    .onAppear { if bridge.backups.isEmpty { bridge.refreshBackups() } }
                }
            }

            if let error = importError ?? bridge.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .confirmationDialog("Disconnect the imported Health data?", isPresented: $confirmDisconnect) {
            Button("Remove Data", role: .destructive) { Task { await bridge.disconnectImportedData() } }
        } message: {
            Text("Deletes the imported store from this Mac. Agents lose access immediately. Your iPhone backup and any export file are not touched. A backup password saved in the keychain is forgotten.")
        }
    }

    private func icon(for status: ProviderStatus) -> String {
        switch status.kind {
        case "healthkit": return status.available ? "heart.circle.fill" : "heart.slash.circle"
        case "healthExport": return "doc.zipper"
        default: return "sparkles"
        }
    }

    /// One pull-down for the two import paths, the export beside it, and a menu for the store itself.
    @ViewBuilder
    private func actionRow(for status: ProviderStatus) -> some View {
        let busy = bridge.importProgress != nil || bridge.isExporting
        HStack(spacing: 8) {
                if status.kind == "healthkit" {
                    Button(status.authorization == .requested ? "Review Health Access…" : "Grant Health Access…") {
                        Task { await bridge.requestHealthAccess() }
                    }
                }
                Menu {
                    Button("From iPhone Backup…", action: openBackupPicker)
                    Button("From Health Export File…", action: chooseExport)
                } label: {
                    Text("Import…")
                }
                .fixedSize()
                .disabled(busy)
                .help("Replace the imported data with a fresh backup or export")
                Button("Export PHR…", action: chooseExportDestination)
                    .disabled(busy)
                    .help("Write your health data as an HL7 FHIR Personal Health Record (.phr or .sphr)")
                if status.kind == "demo" {
                    Button("Stop Demo") { bridge.update { $0.dataSource = .automatic } }
                }
                Spacer(minLength: 0)
                if bridge.hasImportedExport {
                    Menu {
                        Button("Show Store in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.exportDatabase]) }
                        Divider()
                        Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .disabled(busy)
                    .help("Show or remove the imported Health data")
            }
        }
        .controlSize(.small)
    }

    private func openBackupPicker() {
        showBackupPicker = true
        bridge.refreshBackups()
    }

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Health export"
        panel.message = "Pick export.zip from the Health app, or the unzipped apple_health_export folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .xml, .folder]
        guard runModal(panel) == .OK, let url = panel.url else { return }
        importError = nil
        Task { await bridge.importHealthExport(from: url) }
    }

    /// Presents a panel without letting the popover close underneath it.
    private func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        if let delegate = NSApp.delegate as? AppDelegate {
            return delegate.runModalPanel { panel.runModal() }
        }
        return panel.runModal()
    }

    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.title = "Export Personal Health Record"
        panel.message = "Writes your health data as an HL7 FHIR Personal Health Record. Treat the file as sensitive: it is your complete record."
        panel.nameFieldStringValue = "Health Record \(ISO8601.dayString(Date())).phr"
        panel.allowedContentTypes = [PHRFileTypes.phr]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let model = ExportOptionsModel()
        let accessory = NSHostingView(rootView: ExportOptionsView(model: model, panel: panel))
        accessory.frame = NSRect(x: 0, y: 0, width: 420, height: 96)
        panel.accessoryView = accessory
        guard runModal(panel) == .OK, let url = panel.url else { return }
        importError = nil
        let options = model.exportOptions
        Task { await bridge.exportPHR(to: url, options: options) }
    }

    private func dayString(_ d: Date) -> String {
        d.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

// MARK: - PHR export

/// Uniform type identifiers from the PHR IG's operating-systems page, also declared in Info.plist.
enum PHRFileTypes {
    static let phr = UTType(exportedAs: "org.hl7.fhir.phr", conformingTo: .plainText)
    static let sphr = UTType(exportedAs: "org.hl7.fhir.sphr", conformingTo: .zip)
}

@MainActor
final class ExportOptionsModel: ObservableObject {
    enum Range: String, CaseIterable, Identifiable {
        case everything, year, quarter
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everything: return "Everything"
            case .year: return "Last 12 months"
            case .quarter: return "Last 90 days"
            }
        }
    }

    @Published var format: PHRExportFormat = .phr
    @Published var range: Range = .everything
    @Published var includeClinical = true

    var exportOptions: PHRExportOptions {
        var options = PHRExportOptions(includeClinicalRecords: includeClinical)
        let now = Date()
        switch range {
        case .everything: break
        case .year: options.range = DateInterval(start: Calendar.current.date(byAdding: .year, value: -1, to: now)!, end: now)
        case .quarter: options.range = DateInterval(start: Calendar.current.date(byAdding: .day, value: -90, to: now)!, end: now)
        }
        return options
    }
}

private struct ExportOptionsView: View {
    @ObservedObject var model: ExportOptionsModel
    let panel: NSSavePanel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Format")
                Picker("", selection: $model.format) {
                    Text(".phr — newline-delimited FHIR JSON").tag(PHRExportFormat.phr)
                    Text(".sphr — zip archive around the .phr").tag(PHRExportFormat.sphr)
                }
                .labelsHidden()
            }
            GridRow {
                Text("Range")
                Picker("", selection: $model.range) {
                    ForEach(ExportOptionsModel.Range.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("")
                Toggle("Include clinical records from connected providers", isOn: $model.includeClinical)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: model.format) { _, format in
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.allowedContentTypes = [format == .phr ? PHRFileTypes.phr : PHRFileTypes.sphr]
            panel.nameFieldStringValue = base + "." + format.rawValue
        }
    }
}

private struct ExportResultRow: View {
    @EnvironmentObject var bridge: BridgeService
    let report: PHRExportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(summary, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.url]) }
                Button("Dismiss") { bridge.clearLastExport() }
            }
            .controlSize(.small)
        }
    }

    private var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(report.bytes), countStyle: .file)
        var s = "Exported \(report.resources.formatted()) resources (\(size)) to \(report.url.lastPathComponent)."
        if report.clinicalRecords > 0 { s += " Includes \(report.clinicalRecords) clinical records." }
        return s
    }
}

// MARK: - Empty state

/// Shown when nothing is connected: what the bridge needs and the two ways to provide it.
private struct EmptyDataSourceView: View {
    let grantAccess: (() -> Void)?
    let importBackup: () -> Void
    let importExport: () -> Void
    let tryDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No health data on this Mac yet").font(.system(size: 12, weight: .medium))
                    Text("Macs have no Health app store, so the bridge serves a copy of your iPhone's data. Bring it over in one of two ways.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let grantAccess {
                option(icon: "heart.circle", title: "Health on this Mac",
                       detail: "This Mac has a Health store. Allow the bridge to read it.", button: "Grant Access…", action: grantAccess)
            }
            option(icon: "lock.iphone", title: "Encrypted iPhone backup",
                   detail: "The complete Health store, refreshed every time the phone backs up to this Mac. Needs Full Disk Access and the backup password.",
                   button: "Import…", action: importBackup)
            option(icon: "doc.zipper", title: "Health app export",
                   detail: "On the iPhone: Health → profile picture → Export All Health Data, then AirDrop export.zip here.",
                   button: "Choose File…", action: importExport)
            Button("Try demo data instead", action: tryDemo)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 11))
                .padding(.leading, 2)
        }
    }

    private func option(icon: String, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, action: action).controlSize(.small).fixedSize()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - iPhone backups

private struct BackupPickerView: View {
    @EnvironmentObject var bridge: BridgeService
    let onDone: () -> Void
    @State private var selected: DeviceBackup?
    @State private var password = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iPhone backups on this Mac").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: onDone) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            content
            if let report = bridge.lastBackupImport {
                Text(summary(report)).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var content: some View {
        if bridge.backupsNeedFullDiskAccess {
            fullDiskAccessHelp
        } else if let error = bridge.backupsError {
            Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if bridge.backups.isEmpty {
            noBackups
        } else {
            backupList
            if let selected, selected.isEncrypted {
                passwordForm
            }
        }
    }

    private var fullDiskAccessHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("macOS hides iPhone backups until Flexpa Health Bridge has Full Disk Access.", systemImage: "lock.shield")
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Full Disk Access Settings", action: openFullDiskAccess)
                Button("Try Again") { bridge.refreshBackups() }
            }
            .controlSize(.small)
            Text("Flexpa Health Bridge is already in that list. Flip its switch; a helper window will follow along and bring you back here.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noBackups: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No iPhone backups on this Mac. In Finder, select the iPhone, turn on “Encrypt local backup”, and click Back Up Now.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Refresh") { bridge.refreshBackups() }.controlSize(.small)
        }
    }

    private var backupList: some View {
        ForEach(bridge.backups) { backup in
            BackupRow(backup: backup, isSelected: selected?.id == backup.id) {
                selected = backup
                password = bridge.rememberedBackupPassword(for: backup) ?? ""
                remember = !password.isEmpty
            }
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(startImport)
            Toggle("Remember password in my keychain", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            HStack {
                Button("Import", action: startImport).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
                Button("Cancel", action: onDone)
                Spacer()
            }
            .controlSize(.small)
            Text("Only the two Health database files are decrypted. Keys stay in memory; the password is stored only if you ask.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openFullDiskAccess() {
        FullDiskAccessCoach.shared.begin(bridge: bridge)
    }

    private func summary(_ r: BackupImportReport) -> String {
        var s = "Last import: \(r.samples.formatted()) samples, \(r.workouts) workouts from \(r.backup.deviceName)."
        if !r.unmappedCodes.isEmpty { s += " \(r.unmappedCodes.count) type codes were unknown to this macOS." }
        if !r.uncataloguedCodes.isEmpty { s += " \(r.uncataloguedCodes.count) types are present but not served yet." }
        return s
    }

    private func startImport() {
        guard let selected, !password.isEmpty else { return }
        let pw = password
        let keep = remember
        password = ""
        onDone()
        Task { await bridge.importBackup(selected, password: pw, rememberPassword: keep) }
    }
}

private struct BackupRow: View {
    let backup: DeviceBackup
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(backup.deviceName).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(backup.isEncrypted ? Color.secondary : Color.orange)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!backup.isEncrypted)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = backup.iosVersion { parts.append("iOS \(v)") }
        if let d = backup.date { parts.append(d.formatted(.relative(presentation: .named))) }
        parts.append(backup.isEncrypted ? "encrypted" : "not encrypted, no Health data")
        if !backup.isFinished { parts.append("in progress") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Agents

private struct AgentsSection: View {
    @EnvironmentObject var bridge: BridgeService
    @State private var isPairing = false
    @State private var newName = ""
    @State private var revealed: (pairing: Pairing, token: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Agents")
                Spacer()
                if revealed == nil, !isPairing {
                    Button {
                        newName = suggestedName
                        isPairing = true
                    } label: {
                        Label("Pair Agent", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            }

            if let revealed {
                TokenRevealView(pairing: revealed.pairing, token: revealed.token, port: bridge.settings.port) {
                    self.revealed = nil
                }
            } else if isPairing {
                HStack(spacing: 8) {
                    TextField("Agent name, e.g. Claude Code", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                    Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { isPairing = false }
                }
                .controlSize(.small)
            }

            let active = bridge.pairings.filter { !$0.isRevoked }
            if active.isEmpty, revealed == nil {
                Text("No agents paired. Pair one to give it read access to your health data.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(active) { pairing in
                        PairingRow(pairing: pairing)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var suggestedName: String {
        let taken = Set(bridge.pairings.map(\.name))
        for candidate in ["Claude Code", "Claude Desktop", "Cursor", "Agent"] where !taken.contains(candidate) {
            return candidate
        }
        return "Agent \(bridge.pairings.count + 1)"
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let (pairing, token) = bridge.createPairing(name: name)
        revealed = (pairing, token)
        isPairing = false
        newName = ""
    }
}

private struct PairingRow: View {
    @EnvironmentObject var bridge: BridgeService
    let pairing: Pairing
    @State private var confirmRevoke = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pairing.isBound ? "lock.fill" : "lock.open")
                .foregroundStyle(pairing.isBound ? Color.green : Color.secondary)
                .font(.system(size: 11))
                .frame(width: 14)
                .help(pairing.isBound ? "Token locked to \(pairing.boundDisplayName ?? "one app")" : "Token not yet locked to an app")
            VStack(alignment: .leading, spacing: 1) {
                Text(pairing.name).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                if pairing.isBound {
                    Button("Reset App Binding") { bridge.resetBinding(pairing) }
                }
                Button("Revoke…", role: .destructive) { confirmRevoke = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.vertical, 3)
        .confirmationDialog("Revoke \(pairing.name)?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) { bridge.revoke(pairing) }
        } message: {
            Text("The agent loses access immediately. You can pair it again later.")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let bound = pairing.boundDisplayName { parts.append(bound) }
        if let used = pairing.lastUsedAt {
            parts.append("used \(used.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never used")
        }
        parts.append("\(pairing.tokenPrefix)…")
        return parts.joined(separator: " · ")
    }
}

private struct TokenRevealView: View {
    let pairing: Pairing
    let token: String
    let port: UInt16
    let done: () -> Void
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Token for \(pairing.name). It is shown once.", systemImage: "key.fill")
                .font(.system(size: 11.5, weight: .medium))
            Text(token)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 6) {
                copyButton("Claude Code", MCPClientConfig.claudeCodeCommand(token: token, port: port))
                copyButton("JSON", MCPClientConfig.genericJSON(token: token, port: port))
                copyButton("Claude Desktop", MCPClientConfig.claudeDesktopJSON(token: token, port: port))
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            Text(copied.map { "Copied \($0) config to the clipboard." } ?? "Copy a ready-to-paste config, then add it to your agent.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    private func copyButton(_ label: String, _ text: String) -> some View {
        Button(label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = label
        }
    }
}

// MARK: - Activity

private struct ActivityList: View {
    @EnvironmentObject var bridge: BridgeService

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if bridge.recentEvents.isEmpty {
                Text("No requests yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(bridge.recentEvents.prefix(8)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.at.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Circle().fill(color(event.outcome)).frame(width: 5, height: 5)
                    Text(line(for: event)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let ms = event.durationMs { Text("\(ms) ms").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
            }
            if !bridge.recentEvents.isEmpty {
                HStack {
                    Button("Open Log File") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.auditLog]) }
                    Button("Clear") { bridge.clearAudit() }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    private func color(_ outcome: AuditEvent.Outcome) -> Color {
        switch outcome {
        case .ok: return .green
        case .denied: return .red
        case .error: return .orange
        }
    }

    private func line(for event: AuditEvent) -> String {
        var parts: [String] = []
        if let name = event.pairingName { parts.append(name) } else if let peer = event.peer { parts.append(peer) }
        parts.append(event.tool ?? event.method)
        if !event.summary.isEmpty { parts.append(event.summary) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @EnvironmentObject var bridge: BridgeService
    @State private var portText = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { bridge.settings.bindPairingsToPeer }, set: { v in bridge.update { $0.bindPairingsToPeer = v } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lock each token to the first app that uses it")
                    Text("Verified by macOS code signature. A copied token stops working elsewhere.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { bridge.settings.exposeClinicalRecords }, set: { v in bridge.update { $0.exposeClinicalRecords = v } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share clinical records (FHIR)")
                    Text("Labs, medications, conditions, immunizations from connected providers.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if LaunchAtLogin.isSupported {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Launch at login")
                        Text("Keep the bridge available whenever you are signed in.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: launchAtLogin) { _, on in
                    do { try LaunchAtLogin.set(on); launchError = nil } catch { launchError = error.localizedDescription }
                }
                if let launchError { Text(launchError).font(.system(size: 10.5)).foregroundStyle(.orange) }
            }
            HStack {
                Text("Data source")
                Spacer()
                Picker("", selection: Binding(get: { bridge.settings.dataSource }, set: { v in bridge.update { $0.dataSource = v } })) {
                    Text("Automatic").tag(DataSourcePreference.automatic)
                    Text("HealthKit").tag(DataSourcePreference.healthKit)
                    Text("Health export").tag(DataSourcePreference.healthExport)
                    Text("Demo data").tag(DataSourcePreference.demo)
                }
                .labelsHidden()
                .frame(width: 140)
            }
            HStack {
                Text("Port")
                Spacer()
                TextField("", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitPort)
                    .onAppear { portText = String(bridge.settings.port) }
                Button("Apply", action: commitPort).disabled(UInt16(portText) == bridge.settings.port)
            }
            Text("Agents connect to \(MCPClientConfig.url(port: bridge.settings.port)). Only this Mac can reach it.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .toggleStyle(.switch)
    }

    private func commitPort() {
        guard let p = UInt16(portText), p >= 1024 else {
            portText = String(bridge.settings.port)
            return
        }
        bridge.update { $0.port = p }
    }
}

// MARK: - Footer

private struct FooterView: View {
    var body: some View {
        HStack {
            Button("Quit \(BridgeInfo.displayName)") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
            Spacer()
            Text("v\(BridgeInfo.version)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Shared bits

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }
}

private struct DisclosureRow<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    var badge: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 14)
                    Text(title).font(.system(size: 12, weight: .medium))
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { content() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
