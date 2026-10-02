import Foundation
import EP2350Core

struct PhysicalSample: Equatable {
    let globalSlot: Int

    var mode: String { globalSlot <= 4 ? "A" : "B" }
    var number: Int { (globalSlot - 1) % 4 + 1 }
    var label: String { "\(mode)\(number)" }
    var accessibilityLabel: String { "Mode \(mode), sample \(number), action" }
}

struct ToneTestEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let slot: Int
    let mapping: SlotMapping

    var frequency: Int { Int(AudioConstants.frequencies[slot - 1]) }
    var sample: PhysicalSample { PhysicalSample(globalSlot: slot) }
    var mode: String { sample.mode }
    var sampleSlot: Int { sample.number }
    var sampleLabel: String { sample.label }
    var summary: String {
        "\(sampleLabel) - \(mapping.action.label)"
    }
    var details: String { "Global slot \(slot), \(frequency) Hz" }
}
