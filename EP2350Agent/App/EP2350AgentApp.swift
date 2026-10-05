import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AgentController?
    private var settingsWindow: SettingsWindowController?

    func showSettings(controller: AgentController) {
        self.controller = controller
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(controller: controller)
        }
        settingsWindow?.present()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}

@main
struct EP2350AgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = AgentController()

    var body: some Scene {
        MenuBarExtra {
            AgentMenu(controller: controller, openSettings: { delegate.showSettings(controller: controller) })
                .onAppear { delegate.controller = controller }
        } label: {
            Image(systemName: controller.capturing ? "mic.fill" : (controller.enabled ? "mic" : "mic.slash"))
                .accessibilityLabel("EP-2350 Agent: \(controller.status)")
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { delegate.showSettings(controller: controller) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
