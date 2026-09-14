import AppKit
import Foundation
import HealthBridgeCore

// Command-line mode (pairing from a terminal or a script) exits before AppKit starts.
if CommandLineTool.runIfRequested(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(0)
}

if CommandLine.arguments.contains("--preview") {
    MainActor.assumeIsolated { PreviewWindow.run() }
}

// Menu bar accessory: no Dock icon, no main window. Also covers `swift run`, which has no Info.plist.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
