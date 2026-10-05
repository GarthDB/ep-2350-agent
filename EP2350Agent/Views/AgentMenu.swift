import AppKit
import SwiftUI

struct AgentMenu: View {
    let controller: AgentController
    let openSettings: () -> Void
    var body: some View {
        Text("EP-2350 Agent - \(controller.status)")
        Text(controller.selectedDeviceName)
        Text(controller.outputDestinationLabel)
        Divider()
        Button(controller.listeningButtonTitle) { controller.toggle() }
        if controller.toneTestMode {
            Text("Actions and transcription disabled")
            if let event = controller.toneTestEvents.first { Text(event.summary) }
            Button("Exit Tone Test") { controller.setToneTestMode(false) }
        }
        if let error = controller.lastError {
            Text(error)
        }
        if let notice = controller.notice { Text(notice) }
        if !controller.lastAction.isEmpty { Text(controller.lastAction) }
        if !controller.lastTranscript.isEmpty {
            Divider()
            Text(String(controller.lastTranscript.prefix(120)))
            Button("Copy Last Transcript") { controller.copyTranscript() }
            Button("Clear Last Transcript") { controller.clearTranscript() }
        }
        Divider()
        Button("Settings...") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Quit EP-2350 Agent") {
            controller.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        .onAppear {
            controller.refreshDevices()
            controller.refreshPermissions()
        }
    }
}
