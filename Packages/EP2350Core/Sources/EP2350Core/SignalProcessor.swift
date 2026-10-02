import Foundation

public enum AudioConstants {
    public static let sampleRate = 16_000
    public static let blockSize = 800
    public static let frequencies: [Double] = [1500, 2300, 3100, 3900, 2751, 4218, 5685, 7153]
}

public struct ToneResult: Sendable {
    public let slot: Int?
    public let active: Bool
}

public struct ToneDetector: Sendable {
    private var lastSlot: Int?
    private var cooldown = 0
    public init() {}

    public mutating func process(_ samples: [Float]) -> ToneResult {
        guard samples.count == AudioConstants.blockSize, samples.allSatisfy(\.isFinite) else {
            return ToneResult(slot: nil, active: false)
        }
        cooldown = max(0, cooldown - 1)
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = sqrt(energy / Double(samples.count))
        guard rms >= 1000.0 / 32768.0 else {
            lastSlot = nil
            return ToneResult(slot: nil, active: false)
        }
        let powers = AudioConstants.frequencies.map { frequency -> Double in
            let coefficient = 2 * cos(2 * .pi * frequency / Double(AudioConstants.sampleRate))
            var s1 = 0.0
            var s2 = 0.0
            for sample in samples {
                let s0 = Double(sample) + coefficient * s1 - s2
                s2 = s1
                s1 = s0
            }
            return max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
        }
        guard let best = powers.indices.max(by: { powers[$0] < powers[$1] }) else {
            return ToneResult(slot: nil, active: false)
        }
        let dominance = powers[best] / max(powers.reduce(0, +), 1e-12)
        let tonality = powers[best] / max(energy * Double(samples.count) / 2, 1e-12)
        guard dominance >= 0.9, tonality >= 0.5 else {
            return ToneResult(slot: nil, active: false)
        }
        let slot = best + 1
        guard cooldown == 0, lastSlot != slot else { return ToneResult(slot: nil, active: true) }
        lastSlot = slot
        cooldown = 6
        return ToneResult(slot: slot, active: true)
    }
}

public struct VoiceResult: Sendable {
    public let started: Bool
    public let finished: Bool
    public let utterance: [Float]?
    public init(started: Bool, finished: Bool, utterance: [Float]?) {
        self.started = started
        self.finished = finished
        self.utterance = utterance
    }
}

public struct VoiceGate: Sendable {
    public private(set) var active = false
    private var samples: [Float] = []
    private var voicedBlocks = 0
    private var silenceBlocks = 0
    private var elapsedBlocks = 0

    public init() { samples.reserveCapacity(AudioConstants.sampleRate * 30) }

    public mutating func process(_ block: [Float], toneActive: Bool) -> VoiceResult {
        guard block.count == AudioConstants.blockSize, block.allSatisfy(\.isFinite) else {
            return VoiceResult(started: false, finished: false, utterance: nil)
        }
        let rms = sqrt(block.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(block.count))
        let started = !active && !toneActive && rms >= 800.0 / 32768.0
        if started { active = true }
        guard active else { return VoiceResult(started: false, finished: false, utterance: nil) }
        elapsedBlocks += 1
        if !toneActive {
            samples.append(contentsOf: block)
        }
        if !toneActive && rms >= 500.0 / 32768.0 {
            voicedBlocks += 1
            silenceBlocks = 0
        } else {
            silenceBlocks += 1
        }
        guard silenceBlocks >= 16 || elapsedBlocks >= 600 else {
            return VoiceResult(started: started, finished: false, utterance: nil)
        }
        let utterance = voicedBlocks >= 8 ? samples : nil
        samples.removeAll(keepingCapacity: true)
        active = false
        voicedBlocks = 0
        silenceBlocks = 0
        elapsedBlocks = 0
        return VoiceResult(started: started, finished: true, utterance: utterance)
    }
}

public struct ProcessingResult: Sendable {
    public let rms: Double
    public let slot: Int?
    public let capturing: Bool
    public let voice: VoiceResult
    public init(rms: Double, slot: Int?, capturing: Bool, voice: VoiceResult) {
        self.rms = rms
        self.slot = slot
        self.capturing = capturing
        self.voice = voice
    }
}

public final class SignalProcessor: @unchecked Sendable {
    // Owned exclusively by the capture service's serial processing queue.
    private var detector = ToneDetector()
    private var gate = VoiceGate()
    private let voiceEnabled: Bool

    public init(voiceEnabled: Bool = true) {
        self.voiceEnabled = voiceEnabled
    }

    public func process(_ block: [Float]) -> ProcessingResult {
        let tone = detector.process(block)
        let voice = voiceEnabled
            ? gate.process(block, toneActive: tone.active)
            : VoiceResult(started: false, finished: false, utterance: nil)
        let rms = block.isEmpty ? 0 : sqrt(block.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(block.count))
        return ProcessingResult(rms: rms, slot: tone.slot, capturing: gate.active, voice: voice)
    }
}
