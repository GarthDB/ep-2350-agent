import Foundation

public struct AppIdentity: Equatable, Sendable {
    public let processID: Int32
    public let bundleID: String
    public init(processID: Int32, bundleID: String) {
        self.processID = processID
        self.bundleID = bundleID
    }
}

public struct DeliveryTicket: Sendable {
    public let target: AppIdentity?
    public let focusRevision: UInt64
    public let generation: UInt64
    public init(target: AppIdentity?, focusRevision: UInt64, generation: UInt64) {
        self.target = target
        self.focusRevision = focusRevision
        self.generation = generation
    }
}

public enum DeliveryPolicy {
    public static func allows(
        ticket: DeliveryTicket, current: AppIdentity?, focusRevision: UInt64,
        generation: UInt64, enabled: Bool, accessibility: Bool,
        allowedBundleIDs: [String], excludedBundleIDs: Set<String>
    ) -> Bool {
        guard enabled, accessibility, generation == ticket.generation,
              focusRevision == ticket.focusRevision,
              let target = ticket.target, target == current,
              !excludedBundleIDs.contains(target.bundleID) else { return false }
        return allowedBundleIDs.isEmpty || allowedBundleIDs.contains(target.bundleID)
    }
}

public enum WAVEncoder {
    public static func encode(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty, samples.count <= AudioConstants.sampleRate * 30,
              samples.allSatisfy(\.isFinite) else {
            throw ConfigurationError.invalid("Audio must contain finite samples and be at most 30 seconds.")
        }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        text("RIFF"); number(byteCount + 36); text("WAVE")
        text("fmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(AudioConstants.sampleRate)); number(UInt32(AudioConstants.sampleRate * 2))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(byteCount)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            number(Int16((clipped * 32767).rounded()))
        }
        return data
    }
}
