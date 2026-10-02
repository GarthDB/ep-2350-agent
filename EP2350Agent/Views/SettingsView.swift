import AppKit
import AVFoundation
import Combine
import SwiftUI
import EP2350Core

struct PermissionControlsPresentation: Equatable {
    enum MicrophoneAction: Equatable {
        case request, openSettings, none
    }

    enum AccessibilityAction: Equatable {
        case request, openSettings
    }

    let microphoneStatus: String
    let microphoneButtonTitle: String
    let microphoneAction: MicrophoneAction
    let accessibilityStatus: String
    let accessibilityButtonTitle: String
    let accessibilityAction: AccessibilityAction

    init(microphoneStatus: AVAuthorizationStatus, accessibilityGranted: Bool) {
        switch microphoneStatus {
        case .authorized:
            self.microphoneStatus = "Granted"
            microphoneButtonTitle = "Microphone Access Granted"
            microphoneAction = .none
        case .notDetermined:
            self.microphoneStatus = "Not requested"
            microphoneButtonTitle = "Request Microphone Access"
            microphoneAction = .request
        case .denied:
            self.microphoneStatus = "Denied"
            microphoneButtonTitle = "Open Microphone Settings"
            microphoneAction = .openSettings
        case .restricted:
            self.microphoneStatus = "Restricted"
            microphoneButtonTitle = "Microphone Access Restricted"
            microphoneAction = .none
        @unknown default:
            self.microphoneStatus = "Unavailable"
            microphoneButtonTitle = "Microphone Access Unavailable"
            microphoneAction = .none
        }

        self.accessibilityStatus = accessibilityGranted ? "Granted" : "Not granted"
        accessibilityButtonTitle = accessibilityGranted
            ? "Open Accessibility Settings"
            : "Grant Accessibility"
        accessibilityAction = accessibilityGranted ? .openSettings : .request
    }
}

struct SettingsSavePresentation: Equatable {
    enum State: Equatable {
        case unsavedChanges
        case repairRequired
        case savedListening
        case savedPaused
    }

    let state: State

    init(draft: Configuration, savedConfiguration: Configuration, isListening: Bool, needsRepair: Bool) {
        if draft != savedConfiguration {
            state = .unsavedChanges
        } else if needsRepair {
            state = .repairRequired
        } else {
            state = isListening ? .savedListening : .savedPaused
        }
    }

    var message: String {
        switch state {
        case .unsavedChanges:
            "Unsaved changes. Saving pauses capture and cancels pending output."
        case .repairRequired:
            "Settings need repair. Save to replace the invalid settings file."
        case .savedListening:
            "Settings saved. Listening."
        case .savedPaused:
            "Settings saved. Paused. Resume listening to apply."
        }
    }

    var canSave: Bool {
        state == .unsavedChanges || state == .repairRequired
    }
}

struct SettingsHeaderPresentation: Equatable {
    let status: String
    let destination: String
    let buttonTitle: String

    var buttonAccessibilityLabel: String {
        "\(buttonTitle). Current status: \(status). Active output destination: \(destination)."
    }
}

struct ApplicationIdentityPresentation {
    let bundleID: String
    let name: String
    let icon: NSImage?

    @MainActor
    init(bundleID: String) {
        self.init(
            bundleID: bundleID,
            applicationURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        )
    }

    @MainActor
    init(bundleID: String, applicationURL: URL?) {
        self.bundleID = bundleID
        guard let applicationURL else {
            name = bundleID
            icon = nil
            return
        }

        let bundle = Bundle(url: applicationURL)
        name = Self.displayName(
            bundleID: bundleID,
            candidates: [
                bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                applicationURL.deletingPathExtension().lastPathComponent
            ]
        )
        icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    var removalAccessibilityLabel: String {
        "Remove \(name) from allowed apps"
    }

    static func displayName(bundleID: String, candidates: [String?]) -> String {
        for candidate in candidates {
            guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                continue
            }
            return name
        }
        return bundleID
    }
}

private struct ApplicationIdentityView: View {
    let identity: ApplicationIdentityPresentation

    var body: some View {
        HStack(spacing: 8) {
            if let icon = identity.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name)
                if identity.name != identity.bundleID {
                    Text(identity.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct SettingsView: View {
    let controller: AgentController
    @State private var draft = Configuration()
    @State private var error: String?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var presentation: SettingsSavePresentation {
        SettingsSavePresentation(
            draft: draft,
            savedConfiguration: controller.configuration,
            isListening: controller.enabled,
            needsRepair: controller.configurationNeedsRepair
        )
    }

    private var permissionControls: PermissionControlsPresentation {
        PermissionControlsPresentation(
            microphoneStatus: controller.microphoneStatus,
            accessibilityGranted: controller.accessibilityGranted
        )
    }

    var headerPresentation: SettingsHeaderPresentation {
        SettingsHeaderPresentation(
            status: controller.status,
            destination: controller.outputDestinationLabel,
            buttonTitle: controller.listeningButtonTitle
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("EP-2350 Agent", systemImage: "mic")
                    .font(.title2.bold())
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(headerPresentation.status)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Current listening status: \(headerPresentation.status)")
                    Text(headerPresentation.destination)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Active output destination: \(headerPresentation.destination)")
                    Button(headerPresentation.buttonTitle) { controller.toggle() }
                        .accessibilityLabel(headerPresentation.buttonAccessibilityLabel)
                }
            }
            TabView {
                audioTab.tabItem { Label("Audio", systemImage: "waveform") }
                ToneTestView(controller: controller, hasUnsavedSettings: draft != controller.configuration)
                    .tabItem { Label("Tone Test", systemImage: "waveform.badge.magnifyingglass") }
                transcriptionTab.tabItem { Label("MacWhisper", systemImage: "text.bubble") }
                actionsTab.tabItem { Label("Actions", systemImage: "button.programmable") }
                outputTab.tabItem { Label("Output", systemImage: "scope") }
                safetyTab.tabItem { Label("Safety", systemImage: "lock") }
                setupTab.tabItem { Label("Setup", systemImage: "cable.connector") }
            }
            if let message = error ?? controller.lastError {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("Error: \(message)")
            }
            HStack {
                Text(presentation.message)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save Settings") {
                    do {
                        try controller.save(draft)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!presentation.canSave)
            }
        }
        .padding(20)
        .frame(width: 660, height: 580)
        .onAppear {
            controller.refreshDevices()
            controller.refreshPermissions()
            draft = controller.configuration
            error = nil
        }
        .onReceive(refresh) { _ in
            controller.refreshDevices()
            controller.refreshPermissions()
        }
    }

    private var audioTab: some View {
        Form {
            Picker("Input device", selection: Binding(
                get: { draft.deviceUID ?? "" },
                set: { draft.deviceUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("Choose an input").tag("")
                if let uid = draft.deviceUID, !controller.devices.contains(where: { $0.id == uid }) {
                    Text("Selected input unavailable").tag(uid)
                }
                ForEach(controller.devices) { device in Text(device.name).tag(device.id) }
            }
            ProgressView(value: controller.level)
                .accessibilityLabel("Input level")
            Text("The level meter runs while listening. Connect the microphone's analog line-out to a USB audio adapter; this app captures audio, not USB button events.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Voice starts with sound and ends after 800 ms of quiet. Utterances are limited to 30 seconds. Button tones are excluded.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var transcriptionTab: some View {
        Form {
            TextField("mw executable", text: $draft.macWhisperPath)
            Button("Choose Executable...") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.showsHiddenFiles = true
                panel.directoryURL = URL(fileURLWithPath: "/Applications/MacWhisper.app/Contents/MacOS")
                if panel.runModal() == .OK, let url = panel.url { draft.macWhisperPath = url.path }
            }
            TextField("Model override", text: $draft.model, prompt: Text("MacWhisper's current model"))
            TextField("Language override", text: $draft.language, prompt: Text("MacWhisper's current language"))
            Text("Leave model and language blank to use MacWhisper's selections. A model override uses engine:model-id; language uses an ISO code such as en, or auto.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Install/download models in MacWhisper. This app does not change its settings or add transcriptions to its history. MacWhisper controls whether its selected engine is local or cloud-based.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var actionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Green selects a slot; white fires it. Orange selects mode A or B.")
                    .foregroundStyle(.secondary)
                ForEach(0..<8, id: \.self) { index in
                    let sample = PhysicalSample(globalSlot: index + 1)
                    if index == 0 || index == 4 {
                        Text(index == 0 ? "Mode A - no mode LED" : "Mode B - first mode LED")
                            .font(.headline).padding(.top, 8)
                    }
                    HStack {
                        Text(sample.label)
                        Text("Global slot \(index + 1) | \(Int(AudioConstants.frequencies[index])) Hz")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Action \(index + 1)", selection: $draft.slots[index].action) {
                            ForEach(ButtonAction.allCases, id: \.self) { action in
                                Text(action.label).tag(action)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(sample.accessibilityLabel)
                        .frame(width: 230)
                    }
                    if draft.slots[index].action == .custom {
                        TextField("Text for action \(index + 1)", text: $draft.slots[index].text)
                    }
                }
            }
            .padding()
        }
    }

    private var safetyTab: some View {
        Form {
            LabeledContent("Microphone", value: permissionControls.microphoneStatus)
            LabeledContent("Accessibility", value: permissionControls.accessibilityStatus)
            HStack {
                Button(permissionControls.microphoneButtonTitle) {
                    switch permissionControls.microphoneAction {
                    case .request:
                        controller.requestMicrophonePermission()
                    case .openSettings:
                        openPrivacySettings("Microphone")
                    case .none:
                        break
                    }
                }
                .disabled(permissionControls.microphoneAction == .none)
                Button(permissionControls.accessibilityButtonTitle) {
                    switch permissionControls.accessibilityAction {
                    case .request:
                        ActionRouter.requestAccessibility()
                    case .openSettings:
                        openPrivacySettings("Accessibility")
                    }
                }
            }
            Text("If a rebuilt app still appears untrusted, remove its old entry in System Settings > Privacy & Security > Accessibility, then add the app currently running here: \(Bundle.main.bundleURL.path)")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Allowed output destinations (empty allows any app except EP-2350 Agent and MacWhisper)")
            ForEach(draft.allowedBundleIDs, id: \.self) { bundleID in
                let identity = ApplicationIdentityPresentation(bundleID: bundleID)
                HStack {
                    ApplicationIdentityView(identity: identity)
                    Spacer()
                    Button("Remove") { draft.allowedBundleIDs.removeAll { $0 == bundleID } }
                        .accessibilityLabel(identity.removalAccessibilityLabel)
                }
            }
            Button("Add Application...") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.applicationBundle]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                if panel.runModal() == .OK, let url = panel.url {
                    if let id = Bundle(url: url)?.bundleIdentifier {
                        if !draft.allowedBundleIDs.contains(id) { draft.allowedBundleIDs.append(id) }
                    } else { error = "The selected app has no bundle identifier." }
                }
            }
            Text("Speech is inserted without Enter. Foreground mode requires unchanged focus throughout capture and transcription. Fixed-target mode activates the selected app before output. In both modes, switching away during insertion stops remaining output, even if you switch back. Transcripts stay in memory until cleared or quit.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else {
            error = "Could not open System Settings. Open Privacy & Security > \(pane) manually."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            error = "Could not open System Settings. Open Privacy & Security > \(pane) manually."
            return
        }
        error = nil
    }

    private var outputTab: some View {
        Form {
            Picker("Output mode", selection: $draft.outputMode) {
                ForEach(OutputMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if draft.outputMode == .fixedTarget {
                if let target = draft.targetApplication {
                    let identity = ApplicationIdentityPresentation(bundleID: target.bundleID)
                    LabeledContent("Target application") {
                        ApplicationIdentityView(identity: identity)
                    }
                    if !draft.allowedBundleIDs.isEmpty && !draft.allowedBundleIDs.contains(target.bundleID) {
                        Text("This target is not in Allowed apps. Add it before saving.")
                            .foregroundStyle(.red)
                        Button("Allow \(identity.name)") { draft.allowedBundleIDs.append(target.bundleID) }
                    }
                } else {
                    Text("Choose the app that should receive all transcripts and keyboard actions.")
                }
                Button("Choose Target Application...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.applicationBundle]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url {
                        if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                                ?? url.deletingPathExtension().lastPathComponent
                            draft.targetApplication = TargetApplication(bundleID: id, name: name)
                            error = nil
                        } else {
                            error = "The selected app has no bundle identifier."
                        }
                    }
                }
                Text("The target must already be running. It is activated when a transcript is ready or before a keyboard action, not when speech starts. You can work in another app while dictating or transcribing.")
                Text("Output goes to the target's most recently active window, tab, and pane. No specific terminal session is selected, no app is launched, and focus is not restored afterward. Activation failure blocks output; transcripts remain available to copy.")
            } else {
                Text("Output goes to the app focused when speech began, only if it remains focused throughout capture and transcription. Keyboard actions use the app focused when their tone was detected.")
            }
            Text("The Safety allowlist restricts output destinations in either mode. Tone Test never activates an app or sends output. Saving pauses listening and cancels pending output.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var setupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("EP-2350 tone configuration").font(.headline)
                Text("The bundled tone pack comes from the upstream Ting setup, not the microphone's factory samples. MicFx compatibility has not yet been tested on hardware; verify its configuration format before replacing files.")
                Text("Upstream Ting procedure:\n1. Back up the existing configuration and samples.\n2. Connect over USB-C and power it on so TINGDISK mounts.\n3. Copy config.json and 1.wav through 4.wav from the bundled TingConfig folder to the root of TINGDISK.\n4. Restart the microphone; configuration is read only at boot.\n5. Connect the analog line-out to your USB audio adapter for normal use.")
                Button("Show EP-2350 Tone Files") {
                    if let url = Bundle.main.url(forResource: "TingConfig", withExtension: nil) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else { error = "Bundled EP-2350 tone configuration files are missing." }
                }
                Text("Keep backups of your existing device files. Fixed-pitch SAMPLE presets are required for reliable cues. Mode A uses the four original tones; mode B pitches them up 10.5 semitones.")
                Text("This app uses analog microphone audio and sample tones. It infers voice boundaries from audio levels, not USB button or handle events.")
                Text("Independent project, not affiliated with Teenage Engineering. Inspired by tajchert/tink-agent (MIT).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
