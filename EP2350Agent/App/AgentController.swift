import AppKit
import AVFoundation
import Observation
import EP2350Core

@MainActor
protocol AudioCapturing {
    func start(device: AudioInputDevice, onBlock: @escaping @Sendable ([Float]) -> Void,
               onError: @escaping @Sendable (String) -> Void) throws
    func stop()
}

extension AudioCaptureService: AudioCapturing {}

private final class FocusSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value = DeliveryTicket(target: nil, focusRevision: 0, generation: 0)
    func update(_ ticket: DeliveryTicket) {
        lock.lock()
        value = ticket
        lock.unlock()
    }
    func read() -> DeliveryTicket {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
@Observable
final class AgentController {
    private(set) var configuration: Configuration
    private(set) var devices: [AudioInputDevice] = []
    private(set) var enabled = false
    private(set) var capturing = false
    private(set) var transcribing = false
    private(set) var level = 0.0
    private(set) var lastError: String?
    private(set) var notice: String?
    private(set) var lastTranscript = ""
    private(set) var lastAction = ""
    private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var accessibilityGranted = false
    private(set) var pendingCount = 0
    private(set) var toneTestMode = false
    private(set) var toneTestEvents: [ToneTestEvent] = []
    static let toneTestEventLimit = 20

    @ObservationIgnored private let store: ConfigurationStore
    @ObservationIgnored private let audio: any AudioCapturing
    @ObservationIgnored private let transcriber: any Transcribing
    @ObservationIgnored private let keyboard: any KeyboardSending
    @ObservationIgnored private let activator: any ApplicationActivating
    @ObservationIgnored private let frontmost: @MainActor () -> AppIdentity?
    @ObservationIgnored private let accessibility: @MainActor () -> Bool
    @ObservationIgnored private let deviceInputs: @MainActor () throws -> [AudioInputDevice]
    @ObservationIgnored private var configurationValid = true
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var focusRevision: UInt64 = 0
    @ObservationIgnored private var utteranceTicket: DeliveryTicket?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: [Request] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var outputBusy = false
    @ObservationIgnored private let focusSnapshot = FocusSnapshot()

    private struct Request: Sendable {
        let samples: [Float]
        let ticket: DeliveryTicket
        let configuration: Configuration
    }

    private enum Output {
        case transcript(String), action(SlotMapping)
    }

    static var defaultStore: ConfigurationStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ConfigurationStore(url: base.appendingPathComponent("TinkAgent/settings.json"))
    }

    init(
        store: ConfigurationStore = AgentController.defaultStore,
        audio: any AudioCapturing = AudioCaptureService(),
        transcriber: any Transcribing = MacWhisperTranscriber(),
        keyboard: any KeyboardSending = ActionRouter(),
        activator: any ApplicationActivating = ApplicationActivator(),
        frontmost: @escaping @MainActor () -> AppIdentity? = AgentController.currentApp,
        accessibility: @escaping @MainActor () -> Bool = { ActionRouter.accessibilityGranted },
        deviceInputs: @escaping @MainActor () throws -> [AudioInputDevice] = { try AudioDeviceService.inputs() },
        observeWorkspace: Bool = true
    ) {
        self.store = store
        self.audio = audio
        self.transcriber = transcriber
        self.keyboard = keyboard
        self.activator = activator
        self.frontmost = frontmost
        self.accessibility = accessibility
        self.deviceInputs = deviceInputs
        do { configuration = try store.load() }
        catch {
            configuration = Configuration()
            configurationValid = false
            lastError = "Settings could not be loaded. Review and explicitly save Settings to replace the invalid file. \(error.localizedDescription)"
        }
        accessibilityGranted = accessibility()
        if observeWorkspace {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.focusChanged() }
                })
            }
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pause()
                    self?.notice = "Paused for system sleep. Resume after waking."
                }
            })
            refreshDevices()
        }
    }

    static func currentApp() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        return AppIdentity(processID: app.processIdentifier, bundleID: bundleID)
    }

    var status: String {
        if toneTestMode { return enabled ? "Tone test listening" : "Tone test paused" }
        if !enabled { return "Paused" }
        if capturing { return transcribing ? "Capturing / transcribing" : "Capturing voice" }
        if transcribing { return "Transcribing\(pendingCount > 0 ? " (\(pendingCount) queued)" : "")" }
        return "Listening"
    }

    var listeningButtonTitle: String {
        if toneTestMode { return enabled ? "Pause Tone Test" : "Resume Tone Test" }
        return enabled ? "Pause Listening" : "Resume Listening"
    }

    var selectedDeviceName: String {
        devices.first(where: { $0.id == configuration.deviceUID })?.name ?? "Input unavailable"
    }

    var outputDestinationLabel: String {
        if toneTestMode { return "Report only - no output" }
        guard configuration.outputMode == .fixedTarget else { return "Output: Foreground app" }
        return "Output: \(configuration.targetApplication?.name ?? "Target unavailable") (fixed)"
    }

    func refreshPermissions() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = accessibility()
        if enabled && microphoneStatus != .authorized {
            failCapture("Microphone permission was revoked. Enable it in System Settings.")
        }
    }

    func refreshDevices() {
        do {
            devices = try deviceInputs()
            if configuration.deviceUID == nil,
               let usb = devices.first(where: { $0.name.localizedCaseInsensitiveContains("USB Audio Device") }) {
                var candidate = configuration
                candidate.deviceUID = usb.id
                if configurationValid {
                    try store.save(candidate)
                    configuration = candidate
                }
            }
            if enabled && !devices.contains(where: { $0.id == configuration.deviceUID }) {
                failCapture("Selected audio device disconnected. Reconnect it or choose another input in Settings.")
            }
        } catch {
            lastError = "Could not enumerate audio inputs: \(error.localizedDescription)"
        }
    }

    func save(_ candidate: Configuration) throws {
        if candidate.outputMode == .fixedTarget,
           let target = candidate.targetApplication, exclusions.contains(target.bundleID) {
            throw ConfigurationError.invalid("EP-2350 Agent and MacWhisper cannot be output targets.")
        }
        try store.save(candidate)
        pause()
        configuration = candidate
        configurationValid = true
        lastError = nil
        notice = "Settings saved. Resume listening to use them."
    }

    func toggle() {
        if enabled || permissionTask != nil { pause(); return }
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let session = self.generation
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard !Task.isCancelled, session == self.generation else { return }
            self.permissionTask = nil
            self.refreshPermissions()
            guard self.microphoneStatus == .authorized else {
                self.lastError = "Microphone access is required. Enable EP-2350 Agent in System Settings > Privacy & Security > Microphone."
                return
            }
            self.refreshDevices()
            self.startCapture()
        }
    }

    func setToneTestMode(_ active: Bool) {
        guard toneTestMode != active else { return }
        pause()
        toneTestMode = active
        notice = active
            ? "Tone test mode: actions and transcription are disabled."
            : "Tone test ended. Normal listening remains paused."
    }

    func toggleToneTest() {
        if toneTestMode && (enabled || permissionTask != nil) {
            pause()
        } else {
            setToneTestMode(true)
            toggle()
        }
    }

    func clearToneTestEvents() {
        toneTestEvents.removeAll()
    }

    func startCapture() {
        guard configurationValid else { return }
        guard let device = devices.first(where: { $0.id == configuration.deviceUID }) else {
            lastError = "Select an available audio input in Settings. The app never falls back to another microphone."
            return
        }
        guard toneTestMode || FileManager.default.isExecutableFile(atPath: configuration.macWhisperPath) else {
            lastError = TranscriptionError.unavailable(configuration.macWhisperPath).localizedDescription
            return
        }
        pause()
        let session = generation
        let processor = SignalProcessor(voiceEnabled: !toneTestMode)
        focusSnapshot.update(ticket())
        let snapshot = focusSnapshot
        enabled = true
        lastError = nil
        notice = nil
        do {
            try audio.start(device: device, onBlock: { [weak self] block in
                let result = processor.process(block)
                let target = snapshot.read()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(result, session: session, target: target) }
                }
            }, onError: { [weak self] message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == session else { return }
                        self.failCapture(message)
                    }
                }
            })
        } catch {
            failCapture(error.localizedDescription)
        }
    }

    func pause() {
        generation &+= 1
        enabled = false
        audio.stop()
        task?.cancel()
        task = nil
        actionTask?.cancel()
        actionTask = nil
        outputBusy = false
        permissionTask?.cancel()
        permissionTask = nil
        pending.removeAll()
        pendingCount = 0
        transcribing = false
        capturing = false
        level = 0
        utteranceTicket = nil
    }

    func shutdown() {
        pause()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        lastTranscript = ""
    }

    func focusChanged() {
        focusRevision &+= 1
        focusSnapshot.update(ticket())
    }

    private func failCapture(_ message: String) {
        pause()
        lastError = message
    }

    private var exclusions: Set<String> {
        [Bundle.main.bundleIdentifier ?? "io.github.garthdb.TinkAgent",
         "io.github.garthdb.TinkAgent", "com.goodsnooze.MacWhisper"]
    }

    private func ticket() -> DeliveryTicket {
        DeliveryTicket(target: frontmost(), focusRevision: focusRevision, generation: generation)
    }

    private func permits(_ ticket: DeliveryTicket) -> Bool {
        !toneTestMode && DeliveryPolicy.allows(
            ticket: ticket, current: frontmost(), focusRevision: focusRevision,
            generation: generation, enabled: enabled, accessibility: accessibility(),
            allowedBundleIDs: configuration.allowedBundleIDs, excludedBundleIDs: exclusions
        )
    }

    private func preparationPermitted(session: UInt64) -> Bool {
        guard enabled, !toneTestMode, generation == session, accessibility() else { return false }
        guard configuration.outputMode == .fixedTarget else { return true }
        guard let target = configuration.targetApplication, !exclusions.contains(target.bundleID) else { return false }
        return configuration.allowedBundleIDs.isEmpty || configuration.allowedBundleIDs.contains(target.bundleID)
    }

    private func prepareOutput(_ original: DeliveryTicket, session: UInt64) async throws -> DeliveryTicket {
        try Task.checkCancellation()
        guard accessibility() else { throw OutputError.permission }
        guard preparationPermitted(session: session) else { throw OutputError.blocked }
        if configuration.outputMode == .foreground {
            guard permits(original) else { throw OutputError.blocked }
            return original
        }
        guard let target = configuration.targetApplication else { throw OutputError.blocked }
        let identity = try await activator.activate(target, permitted: { self.preparationPermitted(session: session) })
        try Task.checkCancellation()
        guard preparationPermitted(session: session), identity.bundleID == target.bundleID,
              frontmost() == identity else { throw OutputError.blocked }
        let prepared = DeliveryTicket(target: identity, focusRevision: focusRevision, generation: session)
        guard permits(prepared) else { throw OutputError.blocked }
        return prepared
    }

    private func send(_ output: Output, ticket: DeliveryTicket, session: UInt64) async throws {
        guard !outputBusy else { throw OutputError.busy }
        outputBusy = true
        defer {
            if generation == session { outputBusy = false }
        }
        let prepared = try await prepareOutput(ticket, session: session)
        switch output {
        case .transcript(let text):
            try await keyboard.type(text, permitted: { self.permits(prepared) })
        case .action(let mapping):
            try await keyboard.perform(mapping, permitted: { self.permits(prepared) })
        }
    }

    func receive(_ result: ProcessingResult, session: UInt64, target: DeliveryTicket) {
        guard enabled, session == generation else { return }
        level = min(1, result.rms * 4)
        if toneTestMode {
            capturing = false
            if let slot = result.slot {
                let mapping = configuration.slots[slot - 1]
                toneTestEvents.insert(ToneTestEvent(slot: slot, mapping: mapping), at: 0)
                if toneTestEvents.count > Self.toneTestEventLimit {
                    toneTestEvents.removeLast(toneTestEvents.count - Self.toneTestEventLimit)
                }
            }
            return
        }
        capturing = result.capturing
        if result.voice.started { utteranceTicket = target }
        if let slot = result.slot {
            let mapping = configuration.slots[slot - 1]
            if mapping.action != .none {
                if actionTask != nil || outputBusy {
                    lastError = OutputError.busy.localizedDescription
                } else {
                    actionTask = Task { [weak self] in
                        guard let self, self.generation == session else { return }
                        do {
                            try await self.send(.action(mapping), ticket: target, session: session)
                            guard !Task.isCancelled, self.generation == session else { return }
                            self.lastAction = "Slot \(slot): \(mapping.action.label)"
                            self.notice = nil
                        } catch is CancellationError {
                            return
                        } catch {
                            guard self.generation == session else { return }
                            self.lastError = error.localizedDescription
                        }
                        guard self.generation == session else { return }
                        self.actionTask = nil
                    }
                }
            }
        }
        if result.voice.finished {
            defer { utteranceTicket = nil }
            if let samples = result.voice.utterance, let target = utteranceTicket {
                enqueue(samples, target: target)
            }
        }
    }

    private func enqueue(_ samples: [Float], target: DeliveryTicket) {
        guard pending.count < 2 else {
            lastError = "Transcription queue is full (one active, two waiting). This utterance was not queued."
            return
        }
        pending.append(Request(samples: samples, ticket: target, configuration: configuration))
        pendingCount = pending.count
        runNext()
    }

    private func runNext() {
        guard task == nil, enabled, !toneTestMode, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        pendingCount = pending.count
        transcribing = true
        let session = generation
        task = Task { [weak self, transcriber] in
            do {
                let text = try await transcriber.transcribe(request.samples, configuration: request.configuration)
                guard let self, !Task.isCancelled, session == self.generation else { return }
                self.lastTranscript = text
                do {
                    try await self.send(.transcript(text), ticket: request.ticket, session: session)
                    guard !Task.isCancelled, session == self.generation else { return }
                    self.notice = "Transcript inserted. Use the microphone Enter action to submit."
                } catch is CancellationError {
                    return
                } catch {
                    guard session == self.generation else { return }
                    self.lastError = error.localizedDescription
                    self.notice = "Transcript not inserted completely. Copy it manually from the menu."
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, session == self.generation else { return }
                self.lastError = error.localizedDescription
            }
            guard let self, session == self.generation else { return }
            self.task = nil
            self.transcribing = false
            self.runNext()
        }
    }

    func copyTranscript() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    func clearTranscript() { lastTranscript = "" }
}
