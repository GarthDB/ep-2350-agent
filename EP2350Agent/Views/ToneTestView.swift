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
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.title)
                .font(.headline)
            Text(presentation.guidance)
                .font(.callout).foregroundStyle(.secondary)
            if hasUnsavedSettings {
                Text("Save Settings first to test your edited input or mappings.")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Saved input", value: controller.selectedDeviceName)
            if let meterLabel = presentation.meterLabel {
                ProgressView(value: controller.level)
                    .accessibilityLabel(meterLabel)
            } else if let idleMeterMessage = presentation.idleMeterMessage {
                Text(idleMeterMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(presentation.startButtonTitle) {
                    controller.toggleToneTest()
                }
                if controller.toneTestMode {
                    Button("Exit Tone Test") { controller.setToneTestMode(false) }
                }
                Spacer()
                Button("Clear Results") { controller.clearToneTestEvents() }
                    .disabled(controller.toneTestEvents.isEmpty)
            }
            if controller.toneTestMode {
                Text("Play each sample in modes A and B. Frequency is the matched detector frequency, not a separate frequency measurement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if controller.toneTestEvents.isEmpty {
                Text(presentation.emptyResultsMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.toneTestEvents) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(event.summary).font(.headline)
                                    Spacer()
                                    Text(event.timestamp, style: .time)
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text("Mode \(event.mode), sample \(event.sampleSlot)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if event.mapping.action == .custom {
                                    Text(event.mapping.text)
                                        .font(.body.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Most recent \(AgentController.toneTestEventLimit) detections, newest first. Results stay only in memory.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
