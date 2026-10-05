import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(controller: AgentController) {
        let content = NSHostingView(rootView: SettingsView(controller: controller))
        content.sizingOptions = [.minSize]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EP-2350 Agent Settings"
        window.identifier = NSUserInterfaceItemIdentifier("EP2350Settings")
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController requires an AgentController")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
