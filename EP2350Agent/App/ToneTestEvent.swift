import Foundation
import EP2350Core

struct ToneTestEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let slot: Int
    let mapping: SlotMapping

    var frequency: Int { Int(AudioConstants.frequencies[slot - 1]) }
    var mode: String { slot <= 4 ? "A" : "B" }
    var sampleSlot: Int { (slot - 1) % 4 + 1 }
    var summary: String {
        "Slot \(slot): \(frequency) Hz - \(mapping.action.label)"
    }
}
