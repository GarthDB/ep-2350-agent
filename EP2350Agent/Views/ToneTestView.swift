import SwiftUI
import EP2350Core

struct ToneTestView: View {
    let controller: AgentController
    let hasUnsavedSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test tones without sending actions")
                .font(.headline)
            Text("Uses the saved input and action mappings. No keys, clipboard changes, or MacWhisper transcription. Only Microphone permission is needed; you can keep this window focused.")
                .font(.callout).foregroundStyle(.secondary)
            if hasUnsavedSettings {
                Text("Save Settings first to test your edited input or mappings.")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Saved input", value: controller.selectedDeviceName)
            ProgressView(value: controller.level)
                .accessibilityLabel("Tone test input level")
            HStack {
                Button(controller.toneTestMode && controller.enabled ? "Stop Tone Test" : "Start Tone Test") {
                    controller.toggleToneTest()
                }
                if controller.toneTestMode {
                    Button("Exit Tone Test") { controller.setToneTestMode(false) }
                }
                Spacer()
                Button("Clear Results") { controller.clearToneTestEvents() }
                    .disabled(controller.toneTestEvents.isEmpty)
            }
            Text("Play each sample in modes A and B. Frequency is the matched detector frequency, not a separate frequency measurement. Exiting leaves normal listening paused.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if controller.toneTestEvents.isEmpty {
                Text("No tones detected yet.")
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
