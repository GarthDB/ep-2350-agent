import AVFoundation

/// Owned by one serial worker. Float amplitudes are preserved, not peak-normalized.
final class AudioResampler {
    static let outputSampleRate: Double = 16_000
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var finished = false

    init(inputSampleRate: Double) throws {
        guard inputSampleRate.isFinite, inputSampleRate >= 8_000, inputSampleRate <= 384_000,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate,
                                        channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioServiceError.configuration("Unsupported input sample rate: \(inputSampleRate).")
        }
        inputFormat = input
        outputFormat = output
        self.converter = converter
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    }

    func process(_ samples: [Float]) throws -> [Float] {
        guard !finished else { throw AudioServiceError.configuration("The resampler has already finished.") }
        guard !samples.isEmpty else { return [] }
        guard samples.count <= Int(UInt32.max),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioServiceError.configuration("Unable to allocate a resampling input buffer.")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        return try convert(input: input, ending: false)
    }

    /// Drains converter latency once at end of stream.
    func finish() throws -> [Float] {
        guard !finished else { return [] }
        finished = true
        return try convert(input: nil, ending: true)
    }

    private func convert(input: AVAudioPCMBuffer?, ending: Bool) throws -> [Float] {
        let expected = Double(input?.frameLength ?? 0) * Self.outputSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(min(65_536, max(1024, ceil(expected) + 1024)))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioServiceError.configuration("Unable to allocate a resampling output buffer.")
        }
        var supplied = false
        var result: [Float] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                throw error ?? AudioServiceError.configuration("Audio resampling failed.") as NSError
            }
            if output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0],
                                                              count: Int(output.frameLength)))
            }
            if status == .inputRanDry || status == .endOfStream { return result }
            guard output.frameLength > 0 else {
                throw AudioServiceError.configuration("Audio converter made no progress.")
            }
        }
    }
}
