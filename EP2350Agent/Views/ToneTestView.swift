import SwiftUI
import EP2350Core

struct ToneTestPresentation: Equatable {
    enum State: Equatable {
        case normalListening
        case normalPaused
        case testing
        case testPaused
    }

    let state: State

    init(toneTestMode: Bool, enabled: Bool) {
        switch (toneTestMode, enabled) {
        case (false, true): state = .normalListening
        case (false, false): state = .normalPaused
        case (true, true): state = .testing
        case (true, false): state = .testPaused
        }
    }

    var title: String {
        switch state {
        case .normalListening, .normalPaused: "Tone Test"
        case .testing: "Tone Test is active"
        case .testPaused: "Tone Test is paused"
        }
    }

    var guidance: String {
        switch state {
        case .normalListening:
            "Normal listening and output are active. Starting Tone Test will pause normal operation before monitoring samples."
        case .normalPaused:
            "Normal listening is paused. Starting Tone Test begins monitoring samples; normal listening will remain paused when you exit."
        case .testing:
            "Detections are report-only while Tone Test is active. No keyboard actions, clipboard changes, or MacWhisper transcription occur. Normal output is paused; only Microphone permission is needed."
        case .testPaused:
            "Tone Test is paused. Normal listening remains paused. Resume Tone Test to keep detecting samples, or exit; normal listening will not resume automatically."
        }
    }

    var meterLabel: String? {
        switch state {
        case .normalListening: "Normal listening input level"
        case .testing: "Tone Test input level"
        case .normalPaused, .testPaused: nil
        }
    }

    var idleMeterMessage: String? {
        switch state {
        case .normalPaused: "Input meter is idle while normal listening is paused."
        case .testPaused: "Input meter is idle while Tone Test is paused."
        case .normalListening, .testing: nil
        }
    }

    var emptyResultsMessage: String {
        switch state {
        case .normalListening:
            "No Tone Test results. Normal listening is active; this tab is not monitoring test tones."
        case .normalPaused:
            "No Tone Test results. Start Tone Test to monitor sample tones."
        case .testing:
            "No tones detected yet. Play a sample to record a result."
        case .testPaused:
            "No tones detected yet. Resume Tone Test to monitor samples."
        }
    }

    var startButtonTitle: String {
        switch state {
        case .normalListening, .normalPaused: "Start Tone Test"
        case .testing: "Stop Tone Test"
        case .testPaused: "Resume Tone Test"
        }
    }
}

struct ToneTestView: View {
    let controller: AgentController
    let hasUnsavedSettings: Bool

    var presentation: ToneTestPresentation {
        ToneTestPresentation(toneTestMode: controller.toneTestMode, enabled: controller.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                content
            }
            .scrollIndicators(.visible)
            ToneTestControlsView(
                startTitle: presentation.startButtonTitle,
                isTesting: controller.toneTestMode,
                canClear: !controller.toneTestEvents.isEmpty,
                toggle: { controller.toggleToneTest() },
                exit: { controller.setToneTestMode(false) },
                clear: { controller.clearToneTestEvents() }
            )
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settingsRuntimeCopy(presentation.title))
                .font(.headline)
            Text(settingsRuntimeCopy(presentation.guidance))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hasUnsavedSettings {
                Text("Save Settings first to test your edited input or mappings.")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved input")
                Text(settingsRuntimeCopy(controller.selectedDeviceName))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let meterLabel = presentation.meterLabel {
                ProgressView(value: controller.level)
                    .accessibilityLabel(settingsRuntimeCopy(meterLabel))
            } else if let idleMeterMessage = presentation.idleMeterMessage {
                Text(settingsRuntimeCopy(idleMeterMessage))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller.toneTestMode {
                Text("Play each sample in modes A and B. Frequency is the matched detector frequency, not a separate frequency measurement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if controller.toneTestEvents.isEmpty {
                ToneTestEmptyResultsView(message: presentation.emptyResultsMessage)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.toneTestEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(settingsRuntimeCopy(event.summary)).font(.headline)
                                Spacer()
                                Text(event.timestamp, style: .time)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text("Global slot \(event.slot), \(event.frequency) Hz")
                                .font(.caption).foregroundStyle(.secondary)
                            if event.mapping.action == .custom {
                                Text(settingsRuntimeCopy(event.mapping.text))
                                    .font(.body.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            Text("Most recent \(AgentController.toneTestEventLimit) detections, newest first. Results stay only in memory.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToneTestControlsView: View {
    let startTitle: String
    let isTesting: Bool
    let canClear: Bool
    var exitTitle: LocalizedStringKey = "Exit Tone Test"
    var clearTitle: LocalizedStringKey = "Clear Results"
    let toggle: () -> Void
    let exit: () -> Void
    let clear: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                startButton
                if isTesting { exitButton }
                Spacer()
                clearButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                startButton
                if isTesting { exitButton }
                clearButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startButton: some View {
        Button(action: toggle) {
            Text(settingsRuntimeCopy(startTitle)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exitButton: some View {
        Button(action: exit) {
            Text(exitTitle).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clearButton: some View {
        Button(action: clear) {
            Text(clearTitle).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!canClear)
    }
}

struct ToneTestEmptyResultsView: View {
    let message: String

    var body: some View {
        Text(settingsRuntimeCopy(message))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
