import AppKit
import HealthBridgeCore
import SwiftUI

/// `HealthBridge --preview` shows the menu bar panel in a normal window so the
/// design can be reviewed and screenshotted without clicking the status item.
@MainActor
enum PreviewWindow {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let bridge = BridgeService()
        if bridge.settings.serverEnabled { bridge.start() }

        let hosting = NSHostingView(rootView: MenuPanel().environmentObject(bridge).environmentObject(FullDiskAccessCoach.shared))
        let showCoach = CommandLine.arguments.contains("--coach")
        if showCoach {
            // Show the Full Disk Access helper too, for design review, without opening System Settings.
            FullDiskAccessCoach.shared.begin(bridge: bridge, openSettings: false)
        }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 360, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Health Bridge — panel preview"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        // `--snapshot <file.png>` renders the panel off the live view hierarchy and exits.
        let args = CommandLine.arguments
        let snapshotPath = args.firstIndex(of: "--snapshot").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            window.setContentSize(hosting.fittingSize)
            print("preview window id \(window.windowNumber)")
            fflush(stdout)
            guard let snapshotPath else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if showCoach {
                    FullDiskAccessCoach.shared.writeSnapshot(to: snapshotPath.replacingOccurrences(of: ".png", with: "-coach.png"))
                }
                hosting.layoutSubtreeIfNeeded()
                // SwiftUI text lives in layers, so render the layer tree at 2x.
                let bounds = hosting.bounds
                let scale: CGFloat = 2
                let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
                if let layer = hosting.layer,
                   let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: 0, y: bounds.height)
                    ctx.scaleBy(x: 1, y: -1)
                    layer.render(in: ctx)
                    if let image = ctx.makeImage() {
                        let rep = NSBitmapImageRep(cgImage: image)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: snapshotPath))
                            print("snapshot written to \(snapshotPath)")
                        }
                    }
                }
                exit(0)
            }
        }
        app.run()
        exit(0)
    }
}
