import Foundation
import Testing
import EP2350Core
@testable import EP2350Agent

struct AudioServicesTests {
    @Test func resampledAllTonesTriggerProductionDetectorOnce() throws {
        let chunkSizes = [1, 127, 13, 2_049, 800, 71, 4_096]
        for (index, frequency) in AudioConstants.frequencies.enumerated() {
            let expectedSlot = index + 1
            let input = (0 ..< 72_000).map {
                Float(0.5 * sin(2 * .pi * Double(frequency) * Double($0) / 48_000))
            }
            let resampler = try AudioResampler(inputSampleRate: 48_000)
            var output: [Float] = []
            var inputOffset = 0
            var chunkIndex = 0
            while inputOffset < input.count {
                let end = min(input.count, inputOffset + chunkSizes[chunkIndex % chunkSizes.count])
                output += try resampler.process(Array(input[inputOffset ..< end]))
                inputOffset = end
                chunkIndex += 1
            }
            output += try resampler.finish()

            // Exclude converter startup and end-of-stream transients, retaining sustained audio.
            let interior = Array(output.dropFirst(800).dropLast(800))
            #expect(interior.count >= 800, "Slot \(expectedSlot) must produce detector-sized blocks.")
            var detector = ToneDetector()
            var detectedSlots: [Int] = []
            var observedActive = false
            for offset in stride(from: 0, through: interior.count - 800, by: 800) {
                let result = detector.process(Array(interior[offset ..< offset + 800]))
                if let slot = result.slot { detectedSlots.append(slot) }
                observedActive = observedActive || result.active
            }
            #expect(observedActive, "The sustained tone for slot \(expectedSlot) must become active.")
            #expect(detectedSlots == [expectedSlot],
                    "Each sustained tone must trigger its slot exactly once, including 7,153 Hz / slot 8.")
        }
    }

    @Test func rejectsInvalidSampleRates() {
        for rate in [0, -48_000, .nan, .infinity, 7_999, 384_001] as [Double] {
            #expect(throws: (any Error).self) { try AudioResampler(inputSampleRate: rate) }
        }
    }

    @Test func preserves7153HzAt48kHz() throws {
        let rate = 48_000.0
        let frequency = 7_153.0
        let input = (0 ..< 48_000).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / rate)) }
        let converter = try AudioResampler(inputSampleRate: rate)
        var output = try converter.process(input)
        output += try converter.finish()
        #expect(abs(output.count - 16_000) <= 64)
        let interior = Array(output.dropFirst(512).dropLast(512))
        let amplitude = toneAmplitude(interior, frequency: frequency)
        #expect(amplitude > 0.35)
        #expect(amplitude < 0.6)
        #expect(toneAmplitude(interior, frequency: 1_153) < 0.02)
        // Evaluate the actual 50 ms capture block size, not merely output length.
        for offset in stride(from: 0, through: interior.count - 800, by: 800) {
            let block = Array(interior[offset ..< offset + 800])
            let meanSquare = block.reduce(0.0) { $0 + Double($1) * Double($1) } / 800
            let targetAmplitude = toneAmplitude(block, frequency: frequency)
            let targetEnergy = targetAmplitude * targetAmplitude / 2
            #expect(sqrt(meanSquare) > 0.2)
            #expect(targetEnergy / meanSquare > 0.9)
            #expect(toneAmplitude(block, frequency: 1_153) < 0.02)
        }
    }

    @Test func irregularBoundariesPreserveContinuity() throws {
        let input = (0 ..< 48_000).map { Float(0.4 * sin(2 * .pi * 1_001 * Double($0) / 48_000)) }
        let whole = try AudioResampler(inputSampleRate: 48_000)
        var expected = try whole.process(input)
        expected += try whole.finish()
        let streaming = try AudioResampler(inputSampleRate: 48_000)
        let sizes = [1, 127, 13, 2_049, 800, 71, 4_096]
        var actual: [Float] = []
        var offset = 0
        var index = 0
        while offset < input.count {
            let end = min(input.count, offset + sizes[index % sizes.count])
            actual += try streaming.process(Array(input[offset ..< end]))
            offset = end
            index += 1
        }
        actual += try streaming.finish()
        #expect(actual.count == expected.count)
        let maximumDifference = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(maximumDifference < 0.0001)
        #expect(try streaming.finish().isEmpty)
        #expect(throws: (any Error).self) { try streaming.process([0]) }
    }

    @Test func identityRateAndEmptyInput() throws {
        let converter = try AudioResampler(inputSampleRate: 16_000)
        #expect(try converter.process([]).isEmpty)
        let input = (0 ..< 1_600).map { Float($0 % 101) / 101 }
        var result = try converter.process(input)
        result += try converter.finish()
        #expect(result == input)
    }

    @Test func boundedRingDropsWholeBufferAndWraps() {
        let ring = AudioSampleRing(capacity: 5)
        push([1, 2, 3, 4], to: ring)
        push([5, 6], to: ring)
        #expect(ring.droppedBufferCount == 1)
        #expect(ring.drain() == [1, 2, 3, 4])
        push([7, 8, 9], to: ring)
        #expect(ring.drain() == [7, 8, 9])
        #expect(ring.drain().isEmpty)
        push([1, 2, 3, 4, 5, 6], to: ring)
        #expect(ring.droppedBufferCount == 2)
        #expect(ring.drain().isEmpty)
    }

    @Test func deviceIdentityUsesPersistentUID() {
        let device = AudioInputDevice(id: "persistent-input-uid", name: "Input", deviceID: 42)
        #expect(device.id == "persistent-input-uid")
        #expect(device == AudioInputDevice(id: device.id, name: device.name, deviceID: 42))
    }

    @Test @MainActor func stoppingBeforeStartIsIdempotent() {
        let capture = AudioCaptureService()
        capture.stop()
        capture.stop()
    }

    @Test @MainActor func unavailableUIDCannotFallBackToDefaultInput() {
        let capture = AudioCaptureService()
        let missing = AudioInputDevice(id: "EP2350Agent.nonexistent.\(UUID())", name: "Missing", deviceID: 0)
        #expect(throws: (any Error).self) {
            try capture.start(device: missing, onBlock: { _ in
                Issue.record("Unavailable input unexpectedly emitted audio.")
            }, onError: { _ in })
        }
        capture.stop()
    }

    private func push(_ samples: [Float], to ring: AudioSampleRing) {
        samples.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: $0.count) }
    }

    private func toneAmplitude(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * .pi * frequency * Double(index) / 16_000
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(samples.count)
    }
}
