import AppKit
import SwiftUI
import Testing
import EP2350Core
@testable import EP2350Agent

@Test @MainActor func settingsWindowRemainsResizableWithRealSettingsContent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = AgentController(
        store: ConfigurationStore(url: directory.appendingPathComponent("settings.json")),
        frontmost: { nil },
        accessibility: { false },
        microphoneStatusProvider: { .denied },
        microphoneAccessRequester: { false },
        deviceInputs: { [] },
        observeWorkspace: false
    )
    defer { controller.shutdown() }
    let windowController = SettingsWindowController(controller: controller)
    let window = try #require(windowController.window)
    let contentView = try #require(window.contentView as? NSHostingView<SettingsView>)
    defer { window.close() }
    contentView.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))

    #expect(window.styleMask.contains(.resizable))
    #expect(contentView.sizingOptions == [.minSize])
    #expect(window.contentMinSize.width >= 640)
    #expect(window.contentMinSize.height >= 480)
    for size in [NSSize(width: 1000, height: 800), NSSize(width: 640, height: 480)] {
        window.setContentSize(size)
        contentView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.styleMask.contains(.resizable))
        #expect(contentView.bounds.size == size)
    }
    window.close()
    #expect(windowController.window === window)
    #expect(window.styleMask.contains(.resizable))
}
