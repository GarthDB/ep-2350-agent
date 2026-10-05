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

@Test @MainActor func toneTestEmptyResultsWrapAtExpandedTextSize() {
    let message = "No Tone Test results. Normal listening is active; this tab is not monitoring test tones."
    let content = ToneTestEmptyResultsView(message: message)
        .font(.system(size: 22))
        .frame(width: 360, alignment: .leading)
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.height > 44)
}

@Test @MainActor func toneTestExpandedControlsStackInsteadOfTruncating() {
    func height(at width: CGFloat) -> CGFloat {
        let controls = ToneTestControlsView(
            startTitle: "Resume Tone Test",
            isTesting: true,
            canClear: true,
            exitTitle: "[Exit Tone Test expanded wording]",
            clearTitle: "[Clear Results expanded wording]",
            toggle: {},
            exit: {},
            clear: {}
        )
        .font(.system(size: 22))
        .frame(width: width)
        let host = NSHostingView(rootView: controls)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width + 1)
        return host.fittingSize.height
    }

    let narrowHeight = height(at: 568)
    let wideHeight = height(at: 1400)
    #expect(narrowHeight >= wideHeight * 3)
    #expect(wideHeight > 0)
}

@Test @MainActor func settingsLongErrorPreservesTabViewportAtMinimumSize() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let message = String(
        repeating: "Fixture input unavailable. Review the selected device and reconnect before resuming. ",
        count: 6
    )
    let controller = AgentController(
        store: ConfigurationStore(url: directory.appendingPathComponent("settings.json")),
        frontmost: { nil },
        accessibility: { false },
        microphoneStatusProvider: { .denied },
        microphoneAccessRequester: { false },
        deviceInputs: { throw ConfigurationError.invalid(message) },
        observeWorkspace: false
    )
    defer { controller.shutdown() }
    let host = NSHostingView(rootView: SettingsView(controller: controller)
        .environment(\.font, .system(size: 22))
        .environment(\.dynamicTypeSize, .accessibility3))
    host.sizingOptions = [.minSize]
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    defer { window.close() }
    controller.refreshDevices()
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()

    func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    let views = scrollViews(in: host)
    let errorScroll = try #require(views.first {
        $0.frame.height <= 81 && ($0.documentView?.frame.height ?? 0) > 80
    })
    let document = try #require(errorScroll.documentView)
    let viewport = errorScroll.contentView
    #expect(host.fittingSize.height <= 480)
    #expect(views.contains { $0.contentView.bounds.height >= 100 })
    #expect(document.frame.width <= viewport.bounds.width + 1)
    let bottom = document.frame.height - viewport.bounds.height
    viewport.scroll(to: NSPoint(x: 0, y: bottom))
    errorScroll.reflectScrolledClipView(viewport)
    #expect(abs(viewport.bounds.minY - bottom) < 1)
    viewport.scroll(to: .zero)
    errorScroll.reflectScrolledClipView(viewport)
    #expect(abs(viewport.bounds.minY) < 1)
}

@Test(arguments: [false, true])
@MainActor func toneTestScrollsAllContentAtExpandedTextSize(testMode: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
    var configuration = Configuration()
    configuration.deviceUID = "layout-input"
    try store.save(configuration)
    let controller = AgentController(
        store: store,
        frontmost: { nil },
        accessibility: { false },
        microphoneStatusProvider: { .denied },
        microphoneAccessRequester: { false },
        deviceInputs: {
            [AudioInputDevice(
                id: "layout-input",
                name: String(repeating: "Expanded Synthetic Audio Input Name ", count: 4),
                deviceID: 0
            )]
        },
        observeWorkspace: false
    )
    defer { controller.shutdown() }
    controller.setToneTestMode(testMode)
    let host = NSHostingView(rootView:
        ToneTestView(controller: controller, hasUnsavedSettings: false)
            .environment(\.font, .system(size: 22))
            .environment(\.dynamicTypeSize, .accessibility3)
    )
    host.sizingOptions = [.minSize]
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 220),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()

    func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    let views = scrollViews(in: host)
    #expect(views.count == 1)
    let scroll = try #require(views.first)
    let document = try #require(scroll.documentView)
    let viewport = scroll.contentView
    #expect(host.fittingSize.height <= 220)
    #expect(scroll.frame.height <= 220)
    #expect(viewport.bounds.height > 0)
    #expect(document.frame.height > viewport.bounds.height)
    #expect(document.frame.width <= viewport.bounds.width + 1)

    let bottom = document.frame.height - viewport.bounds.height
    viewport.scroll(to: NSPoint(x: 0, y: bottom))
    scroll.reflectScrolledClipView(viewport)
    #expect(abs(viewport.bounds.minY - bottom) < 1)
    viewport.scroll(to: .zero)
    scroll.reflectScrolledClipView(viewport)
    #expect(abs(viewport.bounds.minY) < 1)
}
