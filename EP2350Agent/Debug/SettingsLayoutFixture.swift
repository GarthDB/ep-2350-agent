#if DEBUG
import AppKit
import SwiftUI
import EP2350Core

/// Invoked explicitly from LLDB; never used by normal application startup.
@MainActor
@objc(SettingsLayoutFixture)
final class SettingsLayoutFixture: NSObject {
    private static var fixture: SettingsLayoutFixture?
    private let directory: URL
    private let audio = FixtureAudio()
    private let controller: AgentController
    private let host: SettingsWindowController
    private let inputs: FixtureInputs

    private init(expanded: Bool) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EP2350-layout-\(UUID().uuidString)")
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var configuration = Configuration()
        configuration.deviceUID = "layout-fixture"
        configuration.outputMode = .fixedTarget
        let identity = "org.example." + String(repeating: "expanded-destination-identity.", count: 6) + "editor"
        configuration.targetApplication = TargetApplication(
            bundleID: identity,
            name: String(repeating: "Expanded Destination Application Name ", count: 6)
        )
        configuration.allowedBundleIDs = [identity]
        configuration.slots = (1...8).map {
            SlotMapping(.custom, text: "Fixture action \($0): " + String(
                repeating: "Expanded report-only custom text; never deliver this text. ", count: 3
            ))
        }
        try store.save(configuration)
        inputs = FixtureInputs()
        let audio = self.audio
        let inputs = self.inputs
        controller = AgentController(
            store: store, audio: audio, transcriber: FixtureTranscriber(),
            keyboard: FixtureKeyboard(),
            activator: ApplicationActivator(
                running: { _ in [] }, isRunning: { _ in false }, frontmost: { nil },
                requestActivation: { _ in false }
            ),
            frontmost: { nil }, accessibility: { false },
            microphoneStatusProvider: { .authorized },
            microphoneAccessRequester: { false },
            deviceInputs: { try inputs.devices() },
            observeWorkspace: false
        )
        host = SettingsWindowController(controller: controller)
        super.init()
        if expanded, let window = host.window {
            let content = NSHostingView(rootView: SettingsView(controller: controller)
                .environment(\.font, .system(size: 22))
                .environment(\.dynamicTypeSize, .accessibility3))
            content.sizingOptions = [.minSize]
            window.contentView = content
        }
    }

    @objc static func presentExpanded(_ expanded: Bool) -> String {
        close()
        do {
            let fixture = try SettingsLayoutFixture(expanded: expanded)
            self.fixture = fixture
            fixture.host.present()
            fixture.host.window?.setContentSize(NSSize(width: 640, height: 480))
            return "Isolated fixture window \(fixture.host.window?.windowNumber ?? -1); \(fixture.directory.path)"
        } catch {
            return "Fixture failed: \(error.localizedDescription)"
        }
    }

    @objc static func showError(_ visible: Bool) {
        guard let fixture else { return }
        fixture.inputs.fail = visible
        fixture.controller.refreshDevices()
    }

    @objc static func accumulateHistory() {
        guard let fixture else { return }
        fixture.inputs.fail = false
        fixture.controller.refreshDevices()
        fixture.controller.setToneTestMode(true)
        fixture.controller.startCapture()
        let controller = fixture.controller
        let audio = fixture.audio
        Task { @MainActor in
            for index in 0..<28 {
                audio.tone(slot: index % 8 + 1)
                try await Task.sleep(for: .milliseconds(40))
            }
            controller.pause()
            print("Layout fixture: \(controller.toneTestEvents.count) report-only detections; paused.")
        }
    }

    @objc static func resizeWidth(_ width: Double, height: Double) {
        fixture?.host.window?.setContentSize(NSSize(width: width, height: height))
    }

    @objc static func close() {
        guard let fixture else { return }
        fixture.controller.shutdown()
        fixture.host.window?.close()
        do {
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            print("Layout fixture cleanup failed: \(error.localizedDescription)")
        }
        self.fixture = nil
    }
}

@MainActor
private final class FixtureInputs {
    var fail = false
    func devices() throws -> [AudioInputDevice] {
        if fail {
            throw ConfigurationError.invalid(String(
                repeating: "Fixture input unavailable. Review the selected device and reconnect before resuming. ",
                count: 6
            ))
        }
        return [AudioInputDevice(
            id: "layout-fixture",
            name: String(repeating: "Expanded Synthetic Audio Input Name ", count: 4),
            deviceID: 0
        )]
    }
}

@MainActor
private final class FixtureAudio: AudioCapturing {
    private var onBlock: (@Sendable ([Float]) -> Void)?
    func start(device: AudioInputDevice, onBlock: @escaping @Sendable ([Float]) -> Void,
               onError: @escaping @Sendable (String) -> Void) throws {
        self.onBlock = onBlock
    }
    func stop() { onBlock = nil }
    func tone(slot: Int) {
        for _ in 0..<6 { onBlock?(Array(repeating: 0, count: 800)) }
        let frequency = AudioConstants.frequencies[slot - 1]
        onBlock?((0..<800).map { Float(0.25 * sin(2 * .pi * frequency * Double($0) / 16_000)) })
    }
}

private struct FixtureTranscriber: Transcribing {
    func transcribe(_ samples: [Float], configuration: Configuration) async throws -> String {
        throw ConfigurationError.invalid("Layout fixture must not transcribe.")
    }
}

@MainActor
private struct FixtureKeyboard: KeyboardSending {
    func perform(_ mapping: SlotMapping, permitted: @escaping @MainActor () -> Bool) async throws {
        throw ConfigurationError.invalid("Layout fixture must not send actions.")
    }
    func type(_ text: String, permitted: @escaping @MainActor () -> Bool) async throws {
        throw ConfigurationError.invalid("Layout fixture must not type text.")
    }
}
#endif
