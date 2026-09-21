import AppKit
import Combine
import HealthBridgeCore
import SwiftUI

/// Owns the status item and the panel popover. AppKit rather than SwiftUI's
/// `MenuBarExtra` window style, because that window keeps the size of the
/// tallest content it has shown and lets the panel drift away from the icon.
/// `NSPopover` anchors to the status item and resizes with the content.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let bridge = BridgeService()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if bridge.settings.serverEnabled { bridge.start() }
        FullDiskAccessCoach.shared.resumeAfterRelaunchIfNeeded(bridge: bridge)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = FlexpaBrand.menuBarImage(paused: !bridge.serverState.isRunning)
            button.toolTip = BridgeInfo.displayName
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let root = MenuPanel()
            .environmentObject(bridge)
            .environmentObject(FullDiskAccessCoach.shared)
        let hosting = NSHostingController(rootView: root)
        // Report the SwiftUI layout size as preferredContentSize so the popover tracks it.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        bridge.$serverState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.statusItem.button?.image = FlexpaBrand.menuBarImage(paused: !state.isRunning)
                self?.statusItem.button?.toolTip = state.isRunning
                    ? "\(BridgeInfo.displayName): serving agents"
                    : "\(BridgeInfo.displayName): paused"
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Text fields in the panel need the app active to take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Right-click: a small menu for the things people want without opening the panel.
    private func showContextMenu() {
        let menu = NSMenu()
        let serving = NSMenuItem(title: bridge.settings.serverEnabled ? "Pause Serving Agents" : "Resume Serving Agents",
                                 action: #selector(toggleServing), keyEquivalent: "")
        serving.target = self
        menu.addItem(serving)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(BridgeInfo.displayName)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // left-click goes back to the popover
    }

    @objc private func toggleServing() {
        bridge.update { $0.serverEnabled.toggle() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        // Hand focus back to whatever the user was doing, unless one of our panels is still up:
        // hiding the app would take a modal save or open panel down with the popover.
        if NSApp.modalWindow == nil { NSApp.hide(nil) }
    }

    /// Runs a modal open or save panel with the popover pinned open. The popover is transient, so
    /// without this the first click inside the panel closes the popover behind it, and the panel
    /// disappears with the rest of the app.
    func runModalPanel<T>(_ body: () -> T) -> T {
        let previous = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = previous }
        return body()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.stop()
        return .terminateNow
    }
}
