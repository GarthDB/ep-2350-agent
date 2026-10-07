#if DEBUG
import AppKit
import AVFoundation
import SwiftUI
import EP2350Core

/// Enabled only by explicit Debug fixture launch arguments or debugger invocation.
@MainActor
@objc(SettingsLayoutFixture)
final class SettingsLayoutFixture: NSObject {
    private static var fixture: SettingsLayoutFixture?
    private static var localizationURL: URL?
    private static var createdLocalizationDirectory = false
    private static var runtimeCopyExpansionEnabled = false
    private let directory: URL
    private let audio = FixtureAudio()
    private let controller: AgentController
    private let host: SettingsWindowController
    private let inputs: FixtureInputs
    private let permissions: FixturePermissions
    private let initialDraft: Configuration?

    private init(expanded: Bool, scenario: String) throws {
        let activity = SettingsLayoutActivity(rawValue: scenario)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EP2350-layout-\(UUID().uuidString)")
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var configuration = Configuration()
        configuration.deviceUID = scenario == "device-unavailable" ? "missing-fixture-device" : "layout-fixture"
        configuration.macWhisperPath = "/usr/bin/true"
        configuration.outputMode = scenario == "foreground" || scenario == "no-destination" ? .foreground : .fixedTarget
        let identity = "org.example." + String(repeating: "expanded-destination-identity.", count: 6) + "editor"
        configuration.targetApplication = scenario == "no-destination" ? nil : TargetApplication(
            bundleID: identity,
            name: String(repeating: "Expanded Destination Application Name ", count: 6)
        )
        configuration.allowedBundleIDs = [identity]
        configuration.slots = (1...8).map {
            SlotMapping(.custom, text: "Fixture action \($0): " + String(
                repeating: "Expanded report-only custom text; never deliver this text. ", count: 3
            ))
        }
        if scenario == "unallowed" {
            var stagedConfiguration = configuration
            stagedConfiguration.allowedBundleIDs = ["org.example.allowed.editor"]
            initialDraft = stagedConfiguration
        } else {
            initialDraft = nil
        }
        if scenario == "repair" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("invalid fixture settings".utf8).write(to: store.url)
        } else {
            try store.save(configuration)
        }
        inputs = FixtureInputs()
        inputs.fail = scenario == "input-error"
        inputs.unavailable = scenario == "device-unavailable"
        permissions = FixturePermissions(scenario: scenario)
        let audio = self.audio
        let inputs = self.inputs
        let permissions = self.permissions
        let transcriber: any Transcribing
        if activity != nil {
            transcriber = SettingsLayoutHeldTranscriber()
        } else {
            transcriber = FixtureTranscriber()
        }
        controller = AgentController(
            store: store, audio: audio, transcriber: transcriber,
            keyboard: FixtureKeyboard(),
            activator: ApplicationActivator(
                running: { _ in [] }, isRunning: { _ in false }, frontmost: { nil },
                requestActivation: { _ in false }
            ),
            frontmost: { nil }, accessibility: { permissions.accessibilityGranted },
            microphoneStatusProvider: { permissions.microphoneStatus },
            microphoneAccessRequester: { false },
            deviceInputs: { try inputs.devices() },
            observeWorkspace: false
        )
        controller.refreshDevices()
        switch scenario {
        case "listening", "tone-normal-listening":
            controller.startCapture()
        case "tone-active":
            controller.setToneTestMode(true)
            controller.startCapture()
        case "tone-paused":
            controller.setToneTestMode(true)
        default:
            break
        }
        if activity != nil {
            controller.startCapture()
        }
        host = SettingsWindowController(controller: controller)
        super.init()
        if expanded, let window = host.window {
            let content = NSHostingView(rootView: SettingsView(
                controller: controller,
                initialTab: Self.initialTab(for: scenario),
                initialDraft: initialDraft
            )
                .environment(\.font, .system(size: 22))
                .environment(\.dynamicTypeSize, .accessibility3))
            content.sizingOptions = [.minSize]
            window.contentView = content
        }
    }

    @objc static func presentExpanded(_ expanded: Bool) -> String {
        present(expanded: expanded, scenario: "default")
    }

    @objc static func presentScenario(_ scenario: String) -> String {
        present(expanded: true, scenario: scenario)
    }

    static func launchFromArguments() -> String? {
        guard fixture == nil else { return nil }
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0 == "--settings-layout-fixture" || $0.hasPrefix("--settings-layout-fixture=")
        }) else { return nil }
        let scenario = argument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? "default"
        return present(expanded: true, scenario: scenario)
    }

    private static func present(expanded: Bool, scenario: String) -> String {
        close()
        do {
            if expanded { try installInterpolationTable() }
            runtimeCopyExpansionEnabled = expanded
            let fixture = try SettingsLayoutFixture(expanded: expanded, scenario: scenario)
            self.fixture = fixture
            fixture.host.present()
            let size = scenario == "tone-history" || scenario == "unallowed" || scenario == "no-destination"
                ? NSSize(width: 1000, height: 800)
                : NSSize(width: 640, height: 480)
            fixture.host.window?.setContentSize(size)
            if scenario == "tone-history" { accumulateHistory() }
            if let activity = SettingsLayoutActivity(rawValue: scenario) {
                fixture.audio.emit(activity)
            }
            return "Isolated fixture window \(fixture.host.window?.windowNumber ?? -1); \(fixture.directory.path)"
        } catch {
            removeInterpolationTableIfOwned()
            return "Fixture failed: \(error.localizedDescription)"
        }
    }

    private static func initialTab(for scenario: String) -> SettingsTab {
        switch scenario {
        case "tone-active", "tone-paused", "tone-history", "tone-normal-listening", "tone-normal-paused", "device-unavailable": .toneTest
        case "actions", "listening", "foreground": .actions
        case "unallowed", "no-destination": .output
        case "mic-not-determined", "mic-denied", "mic-restricted", "accessibility-granted": .safety
        case "repair", "input-error": .audio
        default: .audio
        }
    }

    static func expandRuntimeCopy(_ value: String) -> String {
        guard runtimeCopyExpansionEnabled else { return value }
        let expanded = value.map { character -> String in
            "aeiouAEIOU".contains(character)
                ? String(repeating: String(character), count: 2)
                : String(character)
        }.joined()
        return "⟦\(expanded)⟧"
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
            do {
                for index in 0..<28 {
                    audio.tone(slot: index % 8 + 1)
                    try await Task.sleep(for: .milliseconds(40))
                }
            } catch is CancellationError {
                return
            } catch {
                print("Layout fixture history generation failed: \(error.localizedDescription)")
                return
            }
            controller.pause()
            print("Layout fixture: \(controller.toneTestEvents.count) report-only detections; paused.")
        }
    }

    @objc static func resizeWidth(_ width: Double, height: Double) {
        fixture?.host.window?.setContentSize(NSSize(width: width, height: height))
    }

    @objc static func close() {
        if let fixture {
            fixture.controller.shutdown()
            fixture.host.window?.close()
            do {
                try FileManager.default.removeItem(at: fixture.directory)
            } catch {
                print("Layout fixture cleanup failed: \(error.localizedDescription)")
            }
            self.fixture = nil
        }
        runtimeCopyExpansionEnabled = false
        removeInterpolationTableIfOwned()
    }

    private static func installInterpolationTable() throws {
        guard let resources = Bundle.main.resourceURL else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let localizationDirectory = resources.appendingPathComponent("en.lproj", isDirectory: true)
        let tableURL = localizationDirectory.appendingPathComponent("Localizable.strings")
        let tableData = try interpolationTableData()
        if FileManager.default.fileExists(atPath: tableURL.path) {
            guard try isFixtureInterpolationTable(at: tableURL) else {
                throw CocoaError(.fileWriteFileExists)
            }
            localizationURL = tableURL
            return
        }
        let directoryExisted = FileManager.default.fileExists(atPath: localizationDirectory.path)
        try FileManager.default.createDirectory(at: localizationDirectory, withIntermediateDirectories: true)
        createdLocalizationDirectory = !directoryExisted
        do {
            try tableData.write(to: tableURL, options: .atomic)
            localizationURL = tableURL
        } catch {
            removeInterpolationTableIfOwned()
            throw error
        }
    }

    private static func removeInterpolationTableIfOwned() {
        guard let resources = Bundle.main.resourceURL else { return }
        let tableURL = localizationURL
            ?? resources.appendingPathComponent("en.lproj/Localizable.strings")
        guard FileManager.default.fileExists(atPath: tableURL.path) else { return }
        do {
            guard try isFixtureInterpolationTable(at: tableURL) else {
                print("Layout fixture left changed localization resource untouched: \(tableURL.path)")
                return
            }
            try FileManager.default.removeItem(at: tableURL)
            if createdLocalizationDirectory,
               (try FileManager.default.contentsOfDirectory(atPath: tableURL.deletingLastPathComponent().path)).isEmpty {
                try FileManager.default.removeItem(at: tableURL.deletingLastPathComponent())
            }
            self.localizationURL = nil
            createdLocalizationDirectory = false
        } catch {
            print("Layout fixture localization cleanup failed: \(error.localizedDescription)")
        }
    }

    private static func isFixtureInterpolationTable(at url: URL) throws -> Bool {
        let contents = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil
        ) as? [String: String]
        return contents == interpolationTranslations()
    }

    private static func interpolationTableData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: interpolationTranslations(), format: .binary, options: 0
        )
    }

    private static func interpolationTranslations() -> [String: String] {
        var translations: [String: String] = [:]
        translations["__EP2350_SettingsLayoutFixture"] = "Owned temporary runtime-copy expansion table."
        translations["Global slot %lld | %lld Hz"] = "⟦Global position %1$lld | matched detector frequency %2$lld hertz — expanded format⟧"
        translations["Global slot %ld | %ld Hz"] = "⟦Global position %1$ld | matched detector frequency %2$ld hertz — expanded format⟧"
        translations["Global slot %@ | %@ Hz"] = "⟦Global position %1$@ | matched detector frequency %2$@ hertz — expanded format⟧"
        translations["Global slot %lld, %lld Hz"] = "⟦Global position %1$lld, matched detector frequency %2$lld hertz — expanded format⟧"
        translations["Global slot %ld, %ld Hz"] = "⟦Global position %1$ld, matched detector frequency %2$ld hertz — expanded format⟧"
        translations["Global slot %@, %@ Hz"] = "⟦Global position %1$@, matched detector frequency %2$@ hertz — expanded format⟧"
        translations["Action %lld"] = "⟦Keyboard action for sample %lld — expanded format⟧"
        translations["Action %ld"] = "⟦Keyboard action for sample %ld — expanded format⟧"
        translations["Action %@"] = "⟦Keyboard action for sample %@ — expanded format⟧"
        translations["Text for action %lld"] = "⟦Custom text for sample %lld — expanded format⟧"
        translations["Text for action %ld"] = "⟦Custom text for sample %ld — expanded format⟧"
        translations["Text for action %@"] = "⟦Custom text for sample %@ — expanded format⟧"
        translations["Allow %@"] = "⟦Add output destination %@ to the allowed list — expanded format⟧"
        translations["Most recent %lld detections, newest first. Results stay only in memory."] = "⟦Latest %lld report-only detections, newest first; they remain only in memory — expanded format⟧"
        translations["Exit Tone Test"] = "⟦Exit this report-only tone test — expanded copy⟧"
        translations["Clear Results"] = "⟦Clear report-only results — expanded copy⟧"
        return translations
    }
}

enum SettingsLayoutActivity: String, CaseIterable, Sendable {
    case capturingVoice = "capture-active"
    case transcribing = "transcription-active"
    case capturingAndTranscribing = "capture-transcription-active"
    case queuedOne = "transcription-queued-one"
    case queuedTwo = "transcription-queued-two"

    private var completedUtterances: Int {
        switch self {
        case .capturingVoice: 0
        case .transcribing, .capturingAndTranscribing: 1
        case .queuedOne: 2
        case .queuedTwo: 3
        }
    }

    func emit(to onBlock: @Sendable ([Float]) -> Void) {
        let voice = Array(repeating: Float(0.05), count: AudioConstants.blockSize)
        let silence = Array(repeating: Float(0), count: AudioConstants.blockSize)
        for _ in 0..<completedUtterances {
            for _ in 0..<8 { onBlock(voice) }
            for _ in 0..<16 { onBlock(silence) }
        }
        if self == .capturingVoice || self == .capturingAndTranscribing {
            for _ in 0..<8 { onBlock(voice) }
        }
    }
}

struct SettingsLayoutHeldTranscriber: Transcribing {
    func transcribe(_ samples: [Float], configuration: Configuration) async throws -> String {
        try await Task.sleep(for: .seconds(86_400))
        throw ConfigurationError.invalid("Layout fixture transcription hold expired; no output was produced.")
    }
}

@MainActor
private final class FixturePermissions {
    let microphoneStatus: AVAuthorizationStatus
    let accessibilityGranted: Bool

    init(scenario: String) {
        switch scenario {
        case "mic-not-determined": microphoneStatus = .notDetermined
        case "mic-denied": microphoneStatus = .denied
        case "mic-restricted": microphoneStatus = .restricted
        default: microphoneStatus = .authorized
        }
        accessibilityGranted = scenario == "accessibility-granted"
    }
}

@MainActor
private final class FixtureInputs {
    var fail = false
    var unavailable = false
    func devices() throws -> [AudioInputDevice] {
        if fail {
            throw ConfigurationError.invalid(String(
                repeating: "Fixture input unavailable. Review the selected device and reconnect before resuming. ",
                count: 6
            ))
        }
        if unavailable { return [] }
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
    func emit(_ activity: SettingsLayoutActivity) {
        guard let onBlock else {
            print("Layout fixture activity failed: synthetic audio is not listening.")
            return
        }
        activity.emit(to: onBlock)
    }
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
