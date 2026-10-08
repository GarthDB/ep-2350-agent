import Foundation
import AVFoundation
import Testing
import EP2350Core
@testable import EP2350Agent

@MainActor private final class FakeAudio: AudioCapturing {
    var onBlock: (@Sendable ([Float]) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var stops = 0
    var starts = 0
    func start(device: AudioInputDevice, onBlock: @escaping @Sendable ([Float]) -> Void,
               onError: @escaping @Sendable (String) -> Void) throws {
        self.onBlock = onBlock
        self.onError = onError
        starts += 1
    }
    func stop() { stops += 1 }
}

@MainActor private final class FakeAnnouncementPoster: AccessibilityAnnouncementPosting {
    var announcements: [RuntimeAnnouncement] = []
    func post(_ announcement: RuntimeAnnouncement) { announcements.append(announcement) }
}

private actor FakeTranscriber: Transcribing {
    let delay: Duration
    private(set) var calls = 0
    init(delay: Duration) { self.delay = delay }
    func transcribe(_ samples: [Float], configuration: Configuration) async throws -> String {
        calls += 1
        try await Task.sleep(for: delay)
        return "hello\nworld"
    }
}

@MainActor private final class FakeKeyboard: KeyboardSending {
    var texts: [String] = []
    var mappings: [SlotMapping] = []
    var outputDelay: Duration = .zero
    var startedOutputs = 0
    var beforeSending: (@MainActor () -> Void)?
    func perform(_ mapping: SlotMapping, permitted: @escaping @MainActor () -> Bool) async throws {
        startedOutputs += 1
        if outputDelay > .zero { try await Task.sleep(for: outputDelay) }
        try Task.checkCancellation()
        beforeSending?()
        guard permitted() else { throw OutputError.blocked }
        mappings.append(mapping)
    }
    func type(_ text: String, permitted: @escaping @MainActor () -> Bool) async throws {
        startedOutputs += 1
        if outputDelay > .zero { try await Task.sleep(for: outputDelay) }
        try Task.checkCancellation()
        beforeSending?()
        guard permitted() else { throw OutputError.blocked }
        texts.append(text)
    }
}

@MainActor private final class TestEnvironment {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let audio = FakeAudio()
    let keyboard = FakeKeyboard()
    let announcementPoster = FakeAnnouncementPoster()
    let transcriber: FakeTranscriber
    var current: AppIdentity? = AppIdentity(processID: 12, bundleID: "com.apple.Terminal")
    var permission = true
    var microphoneAuthorizationStatus: AVAuthorizationStatus = .authorized
    var microphoneRequestSucceeds = true
    var microphoneRequests = 0
    var connected = true
    var targetProcess: AppIdentity? = AppIdentity(processID: 99, bundleID: "com.mitchellh.ghostty")
    var activationRequests: [AppIdentity] = []
    var activationSucceeds = true
    var activatesImmediately = true
    let device = AudioInputDevice(id: "test-device", name: "USB Audio Device", deviceID: 1)
    var controller: AgentController!

    init(delay: Duration = .milliseconds(20), toneTestMode: Bool = false,
         macWhisperPath: String = "/usr/bin/true", fixedTarget: Bool = false,
         initiallyListening: Bool = true, microphoneStatus: AVAuthorizationStatus = .authorized,
         microphoneRequestSucceeds: Bool = true, transcriberOverride: (any Transcribing)? = nil) throws {
        transcriber = FakeTranscriber(delay: delay)
        microphoneAuthorizationStatus = microphoneStatus
        self.microphoneRequestSucceeds = microphoneRequestSucceeds
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var config = Configuration()
        config.deviceUID = device.id
        config.macWhisperPath = macWhisperPath
        if fixedTarget {
            config.outputMode = .fixedTarget
            config.targetApplication = TargetApplication(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
            config.allowedBundleIDs = ["com.mitchellh.ghostty"]
        }
        try store.save(config)
        let activator = ApplicationActivator(
            running: { [unowned self] bundleID in
                if let target = self.targetProcess, target.bundleID == bundleID { return [target] }
                return []
            },
            isRunning: { [unowned self] in self.targetProcess == $0 },
            frontmost: { [unowned self] in self.current },
            requestActivation: { [unowned self] identity in
                self.activationRequests.append(identity)
                guard self.activationSucceeds else { return false }
                if self.activatesImmediately {
                    self.current = identity
                    self.controller.focusChanged()
                }
                return true
            },
            timeout: .milliseconds(250), pollInterval: .milliseconds(5)
        )
        controller = AgentController(
            store: store, audio: audio, transcriber: transcriberOverride ?? transcriber, keyboard: keyboard,
            activator: activator,
            frontmost: { [unowned self] in self.current }, accessibility: { [unowned self] in self.permission },
            microphoneStatusProvider: { [unowned self] in self.microphoneAuthorizationStatus },
            microphoneAccessRequester: { [unowned self] in
                self.microphoneRequests += 1
                self.microphoneAuthorizationStatus = self.microphoneRequestSucceeds ? .authorized : .denied
                return self.microphoneRequestSucceeds
            },
            deviceInputs: { [unowned self] in self.connected ? [self.device] : [] },
            announcementPoster: announcementPoster, observeWorkspace: false
        )
        controller.refreshDevices()
        controller.setToneTestMode(toneTestMode)
        if initiallyListening { controller.startCapture() }
        guard !initiallyListening || controller.enabled else {
            throw ConfigurationError.invalid(controller.lastError ?? "Mock capture did not start.")
        }
    }
    func cleanup() {
        controller.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
    func utterance() {
        audio.onBlock?(Array(repeating: 0.05, count: 800))
        for _ in 0..<7 { audio.onBlock?(Array(repeating: 0.05, count: 800)) }
        for _ in 0..<16 { audio.onBlock?(Array(repeating: 0, count: 800)) }
    }
    func tone(slot: Int, blocks: Int = 1) {
        for _ in 0..<6 { audio.onBlock?(Array(repeating: 0, count: 800)) }
        let frequency = AudioConstants.frequencies[slot - 1]
        let block = (0..<800).map { Float(0.25 * sin(2 * .pi * frequency * Double($0) / 16_000)) }
        for _ in 0..<blocks { audio.onBlock?(block) }
    }
}

@MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
}

@Test @MainActor func unchangedSaveDoesNotPauseListening() throws {
    let env = try TestEnvironment()
    defer { env.cleanup() }
    let stops = env.audio.stops

    try env.controller.save(env.controller.configuration)

    #expect(env.controller.enabled)
    #expect(env.audio.stops == stops)
}

@Test @MainActor func invalidStoredConfigurationCanBeRepairedWithoutEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("invalid settings".utf8).write(to: store.url)
    let controller = AgentController(
        store: store,
        audio: FakeAudio(),
        transcriber: FakeTranscriber(delay: .zero),
        keyboard: FakeKeyboard(),
        deviceInputs: { [] },
        observeWorkspace: false
    )

    #expect(controller.configurationNeedsRepair)
    let repair = SettingsSavePresentation(
        draft: controller.configuration,
        savedConfiguration: controller.configuration,
        isListening: controller.enabled,
        needsRepair: controller.configurationNeedsRepair
    )
    #expect(repair.state == .repairRequired)
    #expect(repair.canSave)

    try controller.save(controller.configuration)

    #expect(!controller.configurationNeedsRepair)
    #expect(try store.load() == controller.configuration)
}

@Test @MainActor func permissionOnlyMicrophoneRequestDoesNotStartListening() async throws {
    let env = try TestEnvironment(initiallyListening: false, microphoneStatus: .notDetermined)
    defer { env.cleanup() }

    env.controller.requestMicrophonePermission()
    try await Task.sleep(for: .milliseconds(20))

    #expect(env.microphoneRequests == 1)
    #expect(env.controller.microphoneStatus == .authorized)
    #expect(!env.controller.enabled)
    #expect(env.audio.starts == 0)
    #expect(env.keyboard.startedOutputs == 0)
    #expect(env.controller.notice?.contains("Resume listening") == true)

    env.controller.toggle()
    try await Task.sleep(for: .milliseconds(20))
    #expect(env.controller.enabled)
    #expect(env.audio.starts == 1)
}

@Test @MainActor func deniedMicrophonePermissionRequestIsVisible() async throws {
    let env = try TestEnvironment(
        initiallyListening: false,
        microphoneStatus: .notDetermined,
        microphoneRequestSucceeds: false
    )
    defer { env.cleanup() }

    env.controller.requestMicrophonePermission()
    try await Task.sleep(for: .milliseconds(20))

    #expect(env.controller.microphoneStatus == .denied)
    #expect(env.controller.lastError?.contains("Microphone access was not granted") == true)
    #expect(!env.controller.enabled)
    #expect(env.audio.starts == 0)
    #expect(env.keyboard.startedOutputs == 0)
    #expect(env.announcementPoster.announcements == [.microphonePermissionDenied])
}

@Test @MainActor func toneTestAnnouncementIsFixedAndDetectionsRemainReportOnly() async throws {
    let env = try TestEnvironment(
        toneTestMode: true, macWhisperPath: "/missing-macwhisper"
    )
    defer { env.cleanup() }
    var edited = env.controller.configuration
    edited.slots[0] = SlotMapping(.custom, text: "private custom macro")
    try env.controller.save(edited)
    env.controller.startCapture()

    env.tone(slot: 1, blocks: 3)
    try await waitUntil { !env.controller.toneTestEvents.isEmpty }
    #expect(env.announcementPoster.announcements == [.toneTestStarted])
    #expect(env.controller.toneTestEvents[0].mapping.text == "private custom macro")
    #expect(env.announcementPoster.announcements.map(\.message).allSatisfy { !$0.contains("private custom macro") })
    #expect(env.keyboard.startedOutputs == 0)
}

@Test @MainActor func permissionControlsTrackExternalGrantChanges() throws {
    let env = try TestEnvironment(initiallyListening: false, microphoneStatus: .denied)
    defer { env.cleanup() }

    env.permission = false
    env.controller.refreshPermissions()
    let denied = PermissionControlsPresentation(
        microphoneStatus: env.controller.microphoneStatus,
        accessibilityGranted: env.controller.accessibilityGranted
    )
    #expect(denied.microphoneStatus == "Denied")
    #expect(denied.microphoneButtonTitle == "Open Microphone Settings")
    #expect(denied.microphoneAction == .openSettings)
    #expect(denied.accessibilityStatus == "Not granted")
    #expect(denied.accessibilityButtonTitle == "Grant Accessibility")
    #expect(denied.accessibilityAction == .request)

    env.microphoneAuthorizationStatus = .authorized
    env.permission = true
    env.controller.refreshPermissions()
    let granted = PermissionControlsPresentation(
        microphoneStatus: env.controller.microphoneStatus,
        accessibilityGranted: env.controller.accessibilityGranted
    )
    #expect(granted.microphoneStatus == "Granted")
    #expect(granted.microphoneButtonTitle == "Microphone Access Granted")
    #expect(granted.microphoneAction == .none)
    #expect(granted.accessibilityStatus == "Granted")
    #expect(granted.accessibilityButtonTitle == "Open Accessibility Settings")
    #expect(granted.accessibilityAction == .openSettings)
}

@Test @MainActor func settingsSavePresentationTracksEditSaveResumeAndReopen() throws {
    let env = try TestEnvironment()
    defer { env.cleanup() }
    let saved = env.controller.configuration
    let listening = SettingsSavePresentation(
        draft: saved,
        savedConfiguration: saved,
        isListening: env.controller.enabled,
        needsRepair: env.controller.configurationNeedsRepair
    )
    #expect(listening.state == .savedListening)
    #expect(!listening.canSave)

    var edited = saved
    edited.model = "engine:model"
    let unsaved = SettingsSavePresentation(
        draft: edited,
        savedConfiguration: saved,
        isListening: env.controller.enabled,
        needsRepair: env.controller.configurationNeedsRepair
    )
    #expect(unsaved.state == .unsavedChanges)
    #expect(unsaved.canSave)

    try env.controller.save(edited)
    let paused = SettingsSavePresentation(
        draft: edited,
        savedConfiguration: env.controller.configuration,
        isListening: env.controller.enabled,
        needsRepair: env.controller.configurationNeedsRepair
    )
    #expect(paused.state == .savedPaused)
    #expect(!env.controller.enabled)

    env.controller.startCapture()
    let resumed = SettingsSavePresentation(
        draft: edited,
        savedConfiguration: env.controller.configuration,
        isListening: env.controller.enabled,
        needsRepair: env.controller.configurationNeedsRepair
    )
    #expect(resumed.state == .savedListening)

    let reopened = SettingsSavePresentation(
        draft: env.controller.configuration,
        savedConfiguration: env.controller.configuration,
        isListening: env.controller.enabled,
        needsRepair: env.controller.configurationNeedsRepair
    )
    #expect(reopened.state == .savedListening)
    #expect(!reopened.canSave)
}

@Test @MainActor func settingsHeaderUsesSavedDestinationAndCurrentListeningState() throws {
    let env = try TestEnvironment()
    defer { env.cleanup() }
    var draft = env.controller.configuration
    draft.outputMode = .fixedTarget
    draft.targetApplication = TargetApplication(bundleID: "com.mitchellh.ghostty", name: "Ghostty")

    var header = SettingsHeaderPresentation(
        status: env.controller.status,
        destination: env.controller.outputDestinationLabel,
        buttonTitle: env.controller.listeningButtonTitle
    )
    #expect(header.status == "Listening")
    #expect(header.destination == "Output: Foreground app")
    #expect(header.buttonTitle == "Pause Listening")
    #expect(header.buttonAccessibilityLabel.contains("Current status: Listening"))
    #expect(header.buttonAccessibilityLabel.contains("Active output destination: Output: Foreground app"))
    #expect(draft != env.controller.configuration)
    #expect(header.destination == env.controller.outputDestinationLabel)

    env.controller.pause()
    header = SettingsHeaderPresentation(
        status: env.controller.status,
        destination: env.controller.outputDestinationLabel,
        buttonTitle: env.controller.listeningButtonTitle
    )
    #expect(header.status == "Paused")
    #expect(header.buttonTitle == "Resume Listening")
    #expect(header.destination == "Output: Foreground app")
}

@Test func inputLevelAccessibilityValueIsReadableAndBounded() {
    #expect(inputLevelAccessibilityValue(0.375) == "38 percent")
    #expect(inputLevelAccessibilityValue(1.5) == "100 percent")
    #expect(inputLevelAccessibilityValue(-0.5) == "0 percent")
    #expect(inputLevelAccessibilityValue(.nan) == "0 percent")
}

@Test func runtimeAnnouncementGateBoundsRepeatedAnnouncementsPerKind() {
    var gate = RuntimeAnnouncementGate()

    let first = gate.shouldPost(.outputBlocked, at: 10)
    let withinCooldown = gate.shouldPost(.outputBlocked, at: 11.9)
    let afterCooldown = gate.shouldPost(.outputBlocked, at: 12)
    let differentAnnouncement = gate.shouldPost(.accessibilityPermissionDenied, at: 12)

    #expect(first)
    #expect(!withinCooldown)
    #expect(afterCooldown)
    #expect(differentAnnouncement)
}

#if DEBUG
@Test(arguments: SettingsLayoutActivity.allCases)
@MainActor func layoutActivityProducesStableStatusWithoutOutput(_ activity: SettingsLayoutActivity) async throws {
    let env = try TestEnvironment(transcriberOverride: SettingsLayoutHeldTranscriber())
    defer { env.cleanup() }
    let configuration = env.controller.configuration
    let onBlock = try #require(env.audio.onBlock)
    let expected: (status: String, capturing: Bool, transcribing: Bool, queued: Int)
    switch activity {
    case .capturingVoice: expected = ("Capturing voice", true, false, 0)
    case .transcribing: expected = ("Transcribing", false, true, 0)
    case .capturingAndTranscribing: expected = ("Capturing / transcribing", true, true, 0)
    case .queuedOne: expected = ("Transcribing (1 queued)", false, true, 1)
    case .queuedTwo: expected = ("Transcribing (2 queued)", false, true, 2)
    }

    activity.emit(to: onBlock)
    try await waitUntil { env.controller.status == expected.status }
    try await Task.sleep(for: .milliseconds(80))
    #expect(env.controller.status == expected.status)
    #expect(env.controller.capturing == expected.capturing)
    #expect(env.controller.transcribing == expected.transcribing)
    #expect(env.controller.pendingCount == expected.queued)
    #expect(env.controller.lastError == nil)
    #expect(env.controller.lastTranscript.isEmpty)
    #expect(env.controller.lastAction.isEmpty)
    #expect(env.controller.configuration == configuration)
    #expect(env.keyboard.startedOutputs == 0)
    #expect(env.activationRequests.isEmpty)
    #expect(env.microphoneRequests == 0)

    env.controller.shutdown()
    activity.emit(to: onBlock)
    try await Task.sleep(for: .milliseconds(80))
    #expect(env.controller.status == "Paused")
    #expect(!env.controller.capturing)
    #expect(!env.controller.transcribing)
    #expect(env.controller.pendingCount == 0)
    #expect(env.controller.lastTranscript.isEmpty)
    #expect(env.controller.lastError == nil)
    #expect(env.keyboard.startedOutputs == 0)
    #expect(env.activationRequests.isEmpty)
}

@Test func layoutHeldTranscriberCancelsWithoutReturningText() async throws {
    let task = Task {
        try await SettingsLayoutHeldTranscriber().transcribe([0.05], configuration: Configuration())
    }
    await Task.yield()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Fixture transcription must not return text.")
    } catch is CancellationError {
    }
}
#endif

@Test @MainActor func settingsHeaderReportsFixedAndToneTestDestinations() throws {
    let fixed = try TestEnvironment(fixedTarget: true)
    defer { fixed.cleanup() }
    let fixedHeader = SettingsHeaderPresentation(
        status: fixed.controller.status,
        destination: fixed.controller.outputDestinationLabel,
        buttonTitle: fixed.controller.listeningButtonTitle
    )
    #expect(fixedHeader.destination == "Output: Ghostty (fixed)")

    let toneTest = try TestEnvironment(toneTestMode: true, macWhisperPath: "/missing-macwhisper")
    defer { toneTest.cleanup() }
    var testHeader = SettingsHeaderPresentation(
        status: toneTest.controller.status,
        destination: toneTest.controller.outputDestinationLabel,
        buttonTitle: toneTest.controller.listeningButtonTitle
    )
    #expect(testHeader.status == "Tone test listening")
    #expect(testHeader.destination == "Report only - no output")
    #expect(testHeader.buttonTitle == "Pause Tone Test")
    #expect(testHeader.buttonAccessibilityLabel.contains("Active output destination: Report only - no output"))

    toneTest.controller.pause()
    testHeader = SettingsHeaderPresentation(
        status: toneTest.controller.status,
        destination: toneTest.controller.outputDestinationLabel,
        buttonTitle: toneTest.controller.listeningButtonTitle
    )
    #expect(testHeader.status == "Tone test paused")
    #expect(testHeader.buttonTitle == "Resume Tone Test")
}

@Test @MainActor func applicationIdentityPresentationUsesFriendlyNameAndBundleIDFallback() {
    let bundleID = "com.example.uninstalled"
    let unavailable = ApplicationIdentityPresentation(bundleID: bundleID, applicationURL: nil)
    #expect(unavailable.bundleID == bundleID)
    #expect(unavailable.name == bundleID)
    #expect(unavailable.icon == nil)
    #expect(unavailable.removalAccessibilityLabel == "Remove \(bundleID) from allowed apps")

    #expect(ApplicationIdentityPresentation.displayName(
        bundleID: "com.mitchellh.ghostty",
        candidates: ["  ", "Ghostty", "Other Name"]
    ) == "Ghostty")
    #expect(ApplicationIdentityPresentation.displayName(
        bundleID: bundleID,
        candidates: [nil, " \n "]
    ) == bundleID)
}

@Test @MainActor func transcriptDoesNotSubmit() async throws {
    let env = try TestEnvironment()
    defer { env.cleanup() }
    env.utterance()
    try await Task.sleep(for: .milliseconds(150))
    #expect(env.keyboard.texts == ["hello\nworld"])
    #expect(env.keyboard.mappings.isEmpty)
    #expect(env.announcementPoster.announcements == [.transcriptInserted])
    #expect(env.announcementPoster.announcements.map(\.message).allSatisfy { !$0.contains("hello") })
}

@Test @MainActor func focusChangesAwayAndBackBlockDelivery() async throws {
    let env = try TestEnvironment(delay: .milliseconds(150))
    defer { env.cleanup() }
    env.utterance()
    try await Task.sleep(for: .milliseconds(30))
    env.controller.focusChanged()
    env.controller.focusChanged()
    try await Task.sleep(for: .milliseconds(220))
    #expect(env.keyboard.texts.isEmpty)
    #expect(env.controller.lastTranscript == "hello\nworld")
    #expect(env.controller.notice?.contains("not inserted") == true)
    #expect(env.announcementPoster.announcements == [.outputBlocked])
}

@Test @MainActor func accessibilityOutputDenialIsAnnouncedWithoutTranscriptContent() async throws {
    let env = try TestEnvironment()
    defer { env.cleanup() }
    env.permission = false

    env.utterance()
    try await waitUntil { env.controller.lastTranscript == "hello\nworld" }
    try await Task.sleep(for: .milliseconds(20))

    #expect(env.keyboard.texts.isEmpty)
    #expect(env.announcementPoster.announcements == [.accessibilityPermissionDenied])
    #expect(env.announcementPoster.announcements.map(\.message).allSatisfy { !$0.contains("hello") })
}

@Test @MainActor func pauseCancelsPendingOutput() async throws {
    let env = try TestEnvironment(delay: .milliseconds(150))
    defer { env.cleanup() }
    env.utterance()
    try await Task.sleep(for: .milliseconds(30))
    env.controller.pause()
    try await Task.sleep(for: .milliseconds(220))
    #expect(env.keyboard.texts.isEmpty)
    #expect(!env.controller.enabled)
    #expect(!env.controller.transcribing)
}

@Test @MainActor func queueOverflowIsVisibleAndBounded() async throws {
    let env = try TestEnvironment(delay: .seconds(2))
    defer { env.cleanup() }
    for _ in 0..<5 { env.utterance() }
    try await Task.sleep(for: .milliseconds(100))
    #expect(env.controller.pendingCount == 2)
    #expect(env.controller.lastError?.contains("queue is full") == true)
}

@Test @MainActor func deviceDisconnectDoesNotFallback() {
    let env: TestEnvironment
    do { env = try TestEnvironment() } catch { Issue.record(error); return }
    defer { env.cleanup() }
    env.connected = false
    env.controller.refreshDevices()
    #expect(!env.controller.enabled)
    #expect(env.controller.lastError?.contains("disconnected") == true)
    #expect(env.audio.starts == 1)
}

@Test @MainActor func permissionAndAllowedAppsBlockOutput() async throws {
    let env = try TestEnvironment(delay: .milliseconds(60))
    defer { env.cleanup() }
    env.permission = false
    env.utterance()
    try await Task.sleep(for: .milliseconds(150))
    #expect(env.keyboard.texts.isEmpty)
    env.permission = true
    var config = env.controller.configuration
    config.allowedBundleIDs = ["com.apple.Safari"]
    try env.controller.save(config)
    env.controller.startCapture()
    env.utterance()
    try await Task.sleep(for: .milliseconds(150))
    #expect(env.keyboard.texts.isEmpty)
}

@Test @MainActor func tonesUseMappedActions() async throws {
    let env = try TestEnvironment()
    defer { env.cleanup() }
    let block = (0..<800).map { Float(0.25 * sin(2 * .pi * 1500 * Double($0) / 16_000)) }
    env.audio.onBlock?(block)
    try await Task.sleep(for: .milliseconds(80))
    #expect(env.keyboard.mappings == [.init(.enter)])
    #expect(env.keyboard.texts.isEmpty)
}

@Test(arguments: Array(1...8))
@MainActor func toneTestReportsEverySlotWithoutOutput(slot: Int) async throws {
    let env = try TestEnvironment(toneTestMode: true, macWhisperPath: "/missing-macwhisper")
    defer { env.cleanup() }
    env.permission = false
    env.current = nil
    env.tone(slot: slot, blocks: 10)
    env.utterance()
    try await Task.sleep(for: .milliseconds(150))

    #expect(env.controller.toneTestEvents.count == 1)
    let event = try #require(env.controller.toneTestEvents.first)
    #expect(event.slot == slot)
    #expect(event.frequency == Int(AudioConstants.frequencies[slot - 1]))
    #expect(event.mode == (slot <= 4 ? "A" : "B"))
    #expect(event.sampleSlot == (slot - 1) % 4 + 1)
    let expectedLabels = ["A1", "A2", "A3", "A4", "B1", "B2", "B3", "B4"]
    #expect(event.sampleLabel == expectedLabels[slot - 1])
    #expect(event.sample.accessibilityLabel == "Mode \(event.mode), sample \(event.sampleSlot), action")
    #expect(event.mapping == env.controller.configuration.slots[slot - 1])
    #expect(event.summary == "\(expectedLabels[slot - 1]) - \(event.mapping.action.label)")
    #expect(event.details == "Global slot \(slot), \(event.frequency) Hz")
    #expect(env.keyboard.mappings.isEmpty)
    #expect(env.keyboard.texts.isEmpty)
    #expect(await env.transcriber.calls == 0)
    #expect(!env.controller.capturing)
    #expect(!env.controller.transcribing)
    #expect(env.controller.pendingCount == 0)
    #expect(env.controller.lastTranscript.isEmpty)
    #expect(env.controller.status == "Tone test listening")
}

@Test @MainActor func toneTestPresentationCoversEveryListeningState() throws {
    let env = try TestEnvironment()
    defer { env.cleanup() }
    let view = ToneTestView(controller: env.controller, hasUnsavedSettings: false)

    var presentation = view.presentation
    #expect(presentation.state == .normalListening)
    #expect(presentation.guidance.contains("Normal listening and output are active"))
    #expect(presentation.meterLabel == "Normal listening input level")
    #expect(presentation.emptyResultsMessage.contains("not monitoring test tones"))
    #expect(!presentation.guidance.contains("report-only"))
    #expect(presentation.startButtonTitle == "Start Tone Test")

    env.controller.pause()
    presentation = view.presentation
    #expect(presentation.state == .normalPaused)
    #expect(presentation.guidance.contains("Normal listening is paused"))
    #expect(presentation.meterLabel == nil)
    #expect(presentation.idleMeterMessage?.contains("normal listening is paused") == true)

    env.controller.setToneTestMode(true)
    env.controller.startCapture()
    presentation = view.presentation
    #expect(presentation.state == .testing)
    #expect(presentation.guidance.contains("report-only"))
    #expect(presentation.guidance.contains("No keyboard actions"))
    #expect(presentation.meterLabel == "Tone Test input level")
    #expect(presentation.emptyResultsMessage.contains("Play a sample"))
    #expect(presentation.startButtonTitle == "Stop Tone Test")

    env.controller.pause()
    presentation = view.presentation
    #expect(presentation.state == .testPaused)
    #expect(presentation.guidance.contains("Normal listening remains paused"))
    #expect(!presentation.guidance.contains("report-only"))
    #expect(presentation.meterLabel == nil)
    #expect(presentation.idleMeterMessage?.contains("Tone Test is paused") == true)
    #expect(presentation.emptyResultsMessage.contains("Resume Tone Test"))
    #expect(presentation.startButtonTitle == "Resume Tone Test")

    env.controller.setToneTestMode(false)
    #expect(view.presentation.state == .normalPaused)
    #expect(!env.controller.enabled)
}

@Test @MainActor func enteringToneTestCancelsQueuedOutputAndRejectsStaleCallbacks() async throws {
    let env = try TestEnvironment(delay: .seconds(1))
    defer { env.cleanup() }
    for _ in 0..<3 { env.utterance() }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await env.transcriber.calls == 1)
    #expect(env.controller.pendingCount == 2)
    let oldBlock = env.audio.onBlock
    let oldError = env.audio.onError

    env.controller.setToneTestMode(true)
    #expect(!env.controller.enabled)
    env.controller.startCapture()
    oldBlock?(Array(repeating: 0.05, count: 800))
    oldError?("Stale capture failure")
    env.tone(slot: 2)
    env.utterance()
    try await Task.sleep(for: .milliseconds(150))

    #expect(env.controller.enabled)
    #expect(env.controller.lastError == nil)
    #expect(env.controller.toneTestEvents.map(\.slot) == [2])
    #expect(env.controller.pendingCount == 0)
    #expect(!env.controller.transcribing)
    #expect(env.controller.lastTranscript.isEmpty)
    #expect(await env.transcriber.calls == 1)
    #expect(env.keyboard.texts.isEmpty)
    #expect(env.keyboard.mappings.isEmpty)
}

@Test @MainActor func exitingToneTestLeavesNormalListeningPaused() async throws {
    let env = try TestEnvironment(toneTestMode: true)
    defer { env.cleanup() }
    env.tone(slot: 1)
    try await Task.sleep(for: .milliseconds(80))
    let oldBlock = env.audio.onBlock
    env.controller.setToneTestMode(false)
    #expect(!env.controller.enabled)
    #expect(!env.controller.toneTestMode)
    #expect(env.controller.status == "Paused")
    env.tone(slot: 1)
    try await Task.sleep(for: .milliseconds(80))
    #expect(env.keyboard.mappings.isEmpty)

    env.controller.startCapture()
    oldBlock?(Array(repeating: 0.05, count: 800))
    env.tone(slot: 1)
    env.utterance()
    try await Task.sleep(for: .milliseconds(150))
    #expect(env.keyboard.mappings == [.init(.enter)])
    #expect(env.keyboard.texts == ["hello\nworld"])
    #expect(await env.transcriber.calls == 1)
    #expect(env.controller.toneTestEvents.count == 1)
}

@Test @MainActor func toneTestHistoryIsBoundedAndCanBeCleared() async throws {
    let env = try TestEnvironment(toneTestMode: true)
    defer { env.cleanup() }
    for index in 0..<25 {
        env.tone(slot: index % 8 + 1)
        for _ in 0..<6 { env.audio.onBlock?(Array(repeating: 0, count: 800)) }
    }
    try await Task.sleep(for: .milliseconds(150))
    #expect(env.controller.toneTestEvents.count == AgentController.toneTestEventLimit)
    #expect(env.controller.toneTestEvents.map(\.slot) == (5..<25).reversed().map { $0 % 8 + 1 })
    #expect(Set(env.controller.toneTestEvents.map(\.id)).count == 20)
    env.controller.clearToneTestEvents()
    #expect(env.controller.toneTestEvents.isEmpty)
    #expect(env.controller.enabled)
    env.controller.pause()
    #expect(env.controller.toneTestMode)
    #expect(env.controller.status == "Tone test paused")
    #expect(env.keyboard.mappings.isEmpty)
    #expect(await env.transcriber.calls == 0)
}

@Test @MainActor func toneTestSnapshotsSavedCustomMappings() async throws {
    let env = try TestEnvironment(toneTestMode: true)
    defer { env.cleanup() }
    var config = env.controller.configuration
    config.slots[0] = SlotMapping(.custom, text: "first\nmacro")
    try env.controller.save(config)
    env.controller.startCapture()
    env.tone(slot: 1)
    try await Task.sleep(for: .milliseconds(80))

    config.slots[0] = SlotMapping(.custom, text: "second macro")
    try env.controller.save(config)
    #expect(!env.controller.enabled)
    #expect(env.controller.toneTestMode)
    #expect(env.controller.toneTestEvents.first?.mapping.text == "first\nmacro")
    env.controller.startCapture()
    env.tone(slot: 1)
    try await Task.sleep(for: .milliseconds(80))
    #expect(env.controller.toneTestEvents.map(\.mapping) == [config.slots[0], SlotMapping(.custom, text: "first\nmacro")])
    #expect(env.keyboard.texts.isEmpty)
    #expect(env.keyboard.mappings.isEmpty)
    #expect(await env.transcriber.calls == 0)
}

@Test @MainActor func toneTestDisconnectRemainsSafelyPaused() throws {
    let env = try TestEnvironment(toneTestMode: true)
    defer { env.cleanup() }
    env.connected = false
    env.controller.refreshDevices()
    #expect(!env.controller.enabled)
    #expect(env.controller.toneTestMode)
    #expect(env.controller.lastError?.contains("disconnected") == true)
    #expect(env.audio.starts == 1)
}

@Test @MainActor func fixedTargetActivatesOnlyWhenTranscriptIsReady() async throws {
    let env = try TestEnvironment(delay: .milliseconds(100), fixedTarget: true)
    defer { env.cleanup() }
    env.utterance()
    try await waitUntil { env.controller.transcribing }
    #expect(env.activationRequests.isEmpty)
    env.current = AppIdentity(processID: 34, bundleID: "com.apple.Safari")
    env.controller.focusChanged()
    try await waitUntil { !env.keyboard.texts.isEmpty }
    #expect(env.activationRequests == [env.targetProcess].compactMap { $0 })
    #expect(env.current == env.targetProcess)
    #expect(env.keyboard.texts == ["hello\nworld"])
    #expect(env.keyboard.mappings.isEmpty)
    #expect(env.controller.lastError == nil)
    #expect(env.controller.outputDestinationLabel == "Output: Ghostty (fixed)")
}

@Test @MainActor func fixedTargetActionsActivateAndNoneDoesNot() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.tone(slot: 7)
    try await Task.sleep(for: .milliseconds(30))
    #expect(env.activationRequests.isEmpty)
    #expect(env.keyboard.mappings.isEmpty)
    env.tone(slot: 1)
    try await waitUntil { env.keyboard.mappings.count == 1 }
    #expect(env.activationRequests.count == 1)
    #expect(env.keyboard.mappings == [.init(.enter)])
    env.current = AppIdentity(processID: 34, bundleID: "com.apple.TextEdit")
    env.controller.focusChanged()
    env.tone(slot: 2)
    try await waitUntil { env.keyboard.mappings.count == 2 }
    #expect(env.activationRequests.count == 2)
    #expect(env.keyboard.mappings == [.init(.enter), .init(.escape)])
}

@Test @MainActor func alreadyFocusedFixedTargetNeedsNoActivationRequest() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.current = env.targetProcess
    env.controller.focusChanged()
    env.tone(slot: 1)
    try await waitUntil { env.keyboard.mappings.count == 1 }
    #expect(env.activationRequests.isEmpty)
}

@Test @MainActor func closedFixedTargetDoesNotFallbackOrLaunch() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.targetProcess = nil
    env.utterance()
    try await waitUntil { env.controller.notice?.contains("not inserted") == true }
    #expect(env.controller.lastError?.contains("Ghostty is not running") == true)
    #expect(env.controller.lastTranscript == "hello\nworld")
    #expect(env.keyboard.texts.isEmpty)
    #expect(env.activationRequests.isEmpty)
    env.tone(slot: 1)
    try await Task.sleep(for: .milliseconds(30))
    #expect(env.keyboard.mappings.isEmpty)
}

@Test @MainActor func refusedAndTimedOutActivationBlockOutput() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.activationSucceeds = false
    env.tone(slot: 1)
    try await waitUntil { env.controller.lastError?.contains("could not activate") == true }
    env.activationSucceeds = true
    env.activatesImmediately = false
    env.tone(slot: 2)
    try await waitUntil { env.controller.lastError?.contains("in time") == true }
    #expect(env.activationRequests.count == 2)
    #expect(env.keyboard.mappings.isEmpty)
    #expect(env.keyboard.texts.isEmpty)
}

@Test(arguments: ["pause", "settings", "tone-test", "permission", "exit", "restart"])
@MainActor func activationInterruptedNeverDelivers(reason: String) async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.activatesImmediately = false
    env.tone(slot: 1)
    try await waitUntil { env.activationRequests.count == 1 }
    switch reason {
    case "pause": env.controller.pause()
    case "settings":
        var config = env.controller.configuration
        config.outputMode = .foreground
        try env.controller.save(config)
    case "tone-test": env.controller.setToneTestMode(true)
    case "permission": env.permission = false
    case "exit": env.targetProcess = nil
    case "restart":
        env.targetProcess = AppIdentity(processID: 100, bundleID: "com.mitchellh.ghostty")
    default: Issue.record("Unexpected activation interruption fixture")
    }
    env.current = env.targetProcess
    env.controller.focusChanged()
    try await Task.sleep(for: .milliseconds(30))
    #expect(env.keyboard.startedOutputs == 0)
    #expect(env.keyboard.mappings.isEmpty)
    #expect(env.activationRequests.count == 1)
    if reason == "permission" { #expect(env.controller.lastError != nil) }
    if reason == "exit" || reason == "restart" {
        #expect(env.controller.lastError?.contains("exited or restarted") == true)
    }
}

@Test @MainActor func actionsAreRejectedDuringTranscriptActivationAndInsertion() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.activatesImmediately = false
    env.keyboard.outputDelay = .milliseconds(100)
    env.utterance()
    try await waitUntil { env.activationRequests.count == 1 }
    env.tone(slot: 1)
    try await waitUntil { env.controller.lastError?.contains("still being prepared") == true }
    #expect(env.activationRequests.count == 1)
    #expect(env.keyboard.startedOutputs == 0)
    env.current = env.targetProcess
    env.controller.focusChanged()
    try await waitUntil { env.keyboard.startedOutputs == 1 }
    env.tone(slot: 2)
    try await Task.sleep(for: .milliseconds(20))
    #expect(env.keyboard.startedOutputs == 1)
    try await waitUntil { env.keyboard.texts.count == 1 }
    #expect(env.keyboard.mappings.isEmpty)
    #expect(env.activationRequests.count == 1)
}

@Test @MainActor func concurrentActionsCannotActivateTwice() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.activatesImmediately = false
    env.tone(slot: 1)
    env.tone(slot: 2)
    try await waitUntil { env.activationRequests.count == 1 && env.controller.lastError != nil }
    env.current = env.targetProcess
    env.controller.focusChanged()
    try await waitUntil { env.keyboard.mappings.count == 1 }
    #expect(env.activationRequests.count == 1)
    #expect(env.keyboard.mappings == [.init(.enter)])
}

@Test(arguments: ["away", "away-and-back", "restart", "permission"])
@MainActor func fixedTargetDeliveryGuardSurvivesActivation(reason: String) async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.keyboard.beforeSending = {
        switch reason {
        case "away":
            env.current = AppIdentity(processID: 34, bundleID: "com.apple.TextEdit")
            env.controller.focusChanged()
        case "away-and-back":
            env.controller.focusChanged()
            env.controller.focusChanged()
        case "restart":
            env.current = AppIdentity(processID: 100, bundleID: "com.mitchellh.ghostty")
        case "permission": env.permission = false
        default: Issue.record("Unexpected delivery-guard fixture")
        }
    }
    env.utterance()
    try await waitUntil { env.controller.notice?.contains("not inserted") == true }
    #expect(env.activationRequests.count == 1)
    #expect(env.keyboard.texts.isEmpty)
    #expect(env.controller.lastTranscript == "hello\nworld")
    env.keyboard.beforeSending = nil
}

@Test @MainActor func invalidFixedAllowlistCannotBeSavedOrActivate() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    let original = env.controller.configuration
    let stops = env.audio.stops
    var invalid = original
    invalid.allowedBundleIDs = ["com.apple.TextEdit"]
    #expect(throws: ConfigurationError.self) { try env.controller.save(invalid) }
    #expect(env.controller.configuration == original)
    #expect(env.controller.enabled)
    #expect(env.audio.stops == stops)
    #expect(env.activationRequests.isEmpty)
}

@Test @MainActor func fixedTargetToneTestDoesNotActivate() async throws {
    let env = try TestEnvironment(toneTestMode: true, macWhisperPath: "/missing", fixedTarget: true)
    defer { env.cleanup() }
    env.permission = false
    env.tone(slot: 1)
    env.utterance()
    try await waitUntil { env.controller.toneTestEvents.count == 1 }
    #expect(env.activationRequests.isEmpty)
    #expect(env.keyboard.startedOutputs == 0)
    #expect(await env.transcriber.calls == 0)
    #expect(env.controller.outputDestinationLabel == "Report only - no output")
}

@Test @MainActor func pausingTranscriptActivationRetainsTextWithoutDelivery() async throws {
    let env = try TestEnvironment(fixedTarget: true)
    defer { env.cleanup() }
    env.activatesImmediately = false
    env.utterance()
    try await waitUntil { env.activationRequests.count == 1 }
    env.controller.pause()
    env.current = env.targetProcess
    env.controller.focusChanged()
    try await Task.sleep(for: .milliseconds(30))
    #expect(env.controller.lastTranscript == "hello\nworld")
    #expect(env.keyboard.startedOutputs == 0)
}

@Test @MainActor func transcriptDoesNotInterleaveWithAnActionBeingPrepared() async throws {
    let env = try TestEnvironment(delay: .milliseconds(40), fixedTarget: true)
    defer { env.cleanup() }
    env.activatesImmediately = false
    env.utterance()
    try await waitUntil { env.controller.transcribing }
    env.tone(slot: 1)
    try await waitUntil { env.activationRequests.count == 1 }
    try await waitUntil { env.controller.notice?.contains("not inserted") == true }
    #expect(env.keyboard.texts.isEmpty)
    #expect(env.controller.lastTranscript == "hello\nworld")
    env.current = env.targetProcess
    env.controller.focusChanged()
    try await waitUntil { env.keyboard.mappings.count == 1 }
    #expect(env.keyboard.mappings == [.init(.enter)])
    #expect(env.activationRequests.count == 1)
}
