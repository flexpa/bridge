import AppKit
import HealthBridgeCore
import SwiftUI

/// A floating helper that sits beside System Settings while the user turns on
/// Full Disk Access. macOS lets no app flip that switch, but it does list an
/// app after a refused attempt, so the user's whole job is one toggle. The
/// coach shows what to do, watches for the grant, and puts the user back in the
/// backup picker afterwards, across the Quit & Reopen that macOS asks for.
@MainActor
final class FullDiskAccessCoach: ObservableObject {
    static let shared = FullDiskAccessCoach()

    enum Phase: Equatable { case waiting, granted, resumed }

    @Published var phase: Phase = .waiting
    private var panel: NSPanel?
    private var timer: Timer?
    private weak var bridge: BridgeService?

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Opens System Settings on the Full Disk Access pane and shows the coach.
    func begin(bridge: BridgeService, openSettings: Bool = true) {
        self.bridge = bridge
        bridge.update { $0.resumeBackupPicker = true }
        // One more refused attempt guarantees Flexpa Health Bridge is in the list before the pane opens.
        bridge.refreshBackups()
        if openSettings { NSWorkspace.shared.open(Self.settingsURL) }
        phase = .waiting
        show()
        startPolling()
    }

    /// Called at launch. If access arrived through a Quit & Reopen, tell the user where to continue.
    func resumeAfterRelaunchIfNeeded(bridge: BridgeService) {
        guard bridge.settings.resumeBackupPicker else { return }
        self.bridge = bridge
        if Self.hasAccess() {
            phase = .resumed
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.dismiss(clearFlag: false) }
        }
    }

    static func hasAccess() -> Bool {
        (try? BackupLocator.listBackups()) != nil
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .waiting else { return }
                if Self.hasAccess() {
                    self.phase = .granted
                    self.bridge?.refreshBackups()
                    self.timer?.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.dismiss(clearFlag: false) }
                }
            }
        }
    }

    /// Renders the coach window to a PNG for design review (`--preview --coach --snapshot`).
    func writeSnapshot(to path: String) {
        guard let view = panel?.contentView, let layer = view.layer else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        if let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func openSettingsAgain() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    func dismiss(clearFlag: Bool) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        if clearFlag { bridge?.update { $0.resumeBackupPicker = false } }
    }

    private func show() {
        if panel == nil {
            let hosting = NSHostingView(rootView: CoachView(coach: self))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            self.panel = panel
        }
        guard let panel else { return }
        // Bottom centre of the screen that has the pointer, clear of the Dock.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
        }
        panel.orderFrontRegardless()
    }
}

private struct CoachView: View {
    @ObservedObject var coach: FullDiskAccessCoach

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body_).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    statusRow
                    Spacer()
                    if coach.phase == .waiting {
                        Button("Open Settings") { coach.openSettingsAgain() }
                        Button("Cancel") { coach.dismiss(clearFlag: true) }
                    } else {
                        Button("Done") { coach.dismiss(clearFlag: coach.phase == .resumed) }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .padding(8)
    }

    private var title: String {
        switch coach.phase {
        case .waiting: return "Turn on Flexpa Health Bridge in the Full Disk Access list"
        case .granted: return "Full Disk Access is on"
        case .resumed: return "Flexpa Health Bridge can see your iPhone backups now"
        }
    }

    private var body_: String {
        switch coach.phase {
        case .waiting: return "Find Flexpa Health Bridge in the list and flip its switch. If macOS asks, choose Quit & Reopen. This window follows the result."
        case .granted: return "Your backups are loading in the Flexpa Health Bridge panel."
        case .resumed: return "Click the heart in the menu bar. The backup picker is open where you left it."
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch coach.phase {
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting for the switch…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .granted, .resumed:
            Label("Access granted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green)
        }
    }
}
