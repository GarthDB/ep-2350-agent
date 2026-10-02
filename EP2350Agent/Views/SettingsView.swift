import AppKit
import AVFoundation
import Combine
import SwiftUI
import EP2350Core

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("EP-2350 Agent", systemImage: "mic")
                    .font(.title2.bold())
                Spacer()
                Text(controller.status).foregroundStyle(.secondary)
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
            Button(controller.listeningButtonTitle) { controller.toggle() }
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
                    if index == 0 || index == 4 {
                        Text(index == 0 ? "Mode A - no mode LED" : "Mode B - first mode LED")
                            .font(.headline).padding(.top, 8)
                    }
                    HStack {
                        Text("Slot \(index % 4 + 1)")
                        Text("\(Int(AudioConstants.frequencies[index])) Hz")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Action \(index + 1)", selection: $draft.slots[index].action) {
                            ForEach(ButtonAction.allCases, id: \.self) { action in
                                Text(action.label).tag(action)
                            }
                        }
                        .labelsHidden().frame(width: 230)
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
            LabeledContent("Microphone", value: controller.microphoneStatus == .authorized ? "Granted" : "Required")
            LabeledContent("Accessibility", value: controller.accessibilityGranted ? "Granted" : "Required")
            HStack {
                Button("Grant Microphone") { controller.toggle() }
                    .disabled(controller.microphoneStatus == .authorized)
                Button("Grant Accessibility") { ActionRouter.requestAccessibility() }
                Button("Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("Allowed output destinations (empty allows any app except EP-2350 Agent and MacWhisper)")
            ForEach(draft.allowedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                    Spacer()
                    Button("Remove") { draft.allowedBundleIDs.removeAll { $0 == bundleID } }
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

    private var outputTab: some View {
        Form {
            Picker("Output mode", selection: $draft.outputMode) {
                ForEach(OutputMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if draft.outputMode == .fixedTarget {
                if let target = draft.targetApplication {
                    LabeledContent("Target application", value: target.name)
                    Text(target.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !draft.allowedBundleIDs.isEmpty && !draft.allowedBundleIDs.contains(target.bundleID) {
                        Text("This target is not in Allowed apps. Add it before saving.")
                            .foregroundStyle(.red)
                        Button("Allow \(target.name)") { draft.allowedBundleIDs.append(target.bundleID) }
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
            LabeledContent("Saved destination", value: controller.outputDestinationLabel)
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
