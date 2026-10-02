import Foundation
import AVFoundation
import Testing
@testable import EP2350Core

func tone(_ frequency: Double, amplitude: Double = 0.25, offset: Int = 0) -> [Float] {
    (0..<800).map { Float(amplitude * sin(2 * .pi * frequency * Double($0 + offset) / 16_000)) }
}

func voice() -> [Float] {
    (0..<800).map { n in
        let time = Double(n) / 16_000.0
        let fundamental = 0.1 * sin(2.0 * Double.pi * 173.0 * time)
        let harmonic = 0.07 * sin(2.0 * Double.pi * 347.0 * time)
        return Float(fundamental + harmonic)
    }
}

@Test(arguments: Array(AudioConstants.frequencies.enumerated()))
func allTonesDetect(pair: EnumeratedSequence<[Double]>.Element) {
    var detector = ToneDetector()
    let result = detector.process(tone(pair.element))
    #expect(result.slot == pair.offset + 1)
    #expect(result.active)
    for _ in 0..<20 { #expect(detector.process(tone(pair.element)).slot == nil) }
    _ = detector.process(Array(repeating: 0, count: 800))
    #expect(detector.process(tone(pair.element)).slot == pair.offset + 1)
}

@Test func speechAndNoiseDoNotPressKeys() {
    var detector = ToneDetector()
    #expect(!detector.process(voice()).active)
    var state: UInt64 = 17
    for _ in 0..<100 {
        let noise = (0..<800).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) - 0.5) * 0.5
        }
        #expect(!detector.process(noise).active)
    }
    #expect(!detector.process(tone(1500, amplitude: 0.001)).active)
}

@Test func softToneDipDoesNotRetrigger() {
    var detector = ToneDetector()
    #expect(detector.process(tone(1500)).slot == 1)
    for _ in 0..<8 { _ = detector.process(voice()) }
    #expect(detector.process(tone(1500)).slot == nil)
    #expect(detector.process(tone(2300)).slot == 2)
}

@Test func voiceGateMinimumHangoverAndToneExclusion() {
    var gate = VoiceGate()
    let silence = Array(repeating: Float(0), count: 800)
    #expect(!gate.process(tone(1500), toneActive: true).started)
    #expect(gate.process(voice(), toneActive: false).started)
    for _ in 0..<7 { _ = gate.process(voice(), toneActive: false) }
    _ = gate.process(tone(1500), toneActive: true)
    for _ in 0..<14 { #expect(!gate.process(silence, toneActive: false).finished) }
    let result = gate.process(silence, toneActive: false)
    #expect(result.finished)
    #expect(result.utterance?.count == 23 * 800)
    #expect(!gate.active)

    _ = gate.process(voice(), toneActive: false)
    for _ in 0..<16 { _ = gate.process(silence, toneActive: false) }
    #expect(!gate.active)
}

@Test(arguments: AudioConstants.frequencies)
func toneOnlyProcessingDoesNotCaptureSpeech(frequency: Double) {
    let processor = SignalProcessor(voiceEnabled: false)
    let result = processor.process(tone(frequency))
    #expect(result.slot == AudioConstants.frequencies.firstIndex(of: frequency).map { $0 + 1 })
    #expect(result.rms > 0)
    #expect(!result.capturing)
    for _ in 0..<32 {
        let speech = processor.process(voice())
        #expect(!speech.capturing)
        #expect(!speech.voice.started)
        #expect(!speech.voice.finished)
        #expect(speech.voice.utterance == nil)
    }
}

@Test func maximumDurationIsBounded() {
    var gate = VoiceGate()
    for _ in 0..<599 { #expect(!gate.process(voice(), toneActive: false).finished) }
    let result = gate.process(voice(), toneActive: false)
    #expect(result.finished)
    #expect(result.utterance?.count == 480_000)
    #expect(!gate.active)
    for _ in 0..<8 { _ = gate.process(voice(), toneActive: false) }
    for _ in 0..<15 { #expect(!gate.process(tone(1500), toneActive: true).finished) }
    #expect(gate.process(tone(1500), toneActive: true).finished)
}

@Test func configurationRoundTripAndValidation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConfigurationStore(url: folder.appendingPathComponent("settings.json"))
    #expect(try store.load() == Configuration())
    var configuration = Configuration()
    configuration.slots[7] = SlotMapping(.custom, text: "Hello world")
    configuration.allowedBundleIDs = ["com.apple.Terminal"]
    try store.save(configuration)
    #expect(try store.load() == configuration)
    configuration.slots.removeLast()
    #expect(throws: ConfigurationError.self) { try configuration.validate() }
    try Data("invalid".utf8).write(to: store.url)
    #expect(throws: DecodingError.self) { try store.load() }
    var invalid = Configuration()
    invalid.slots[0] = SlotMapping(.custom)
    #expect(throws: ConfigurationError.self) { try invalid.validate() }
    invalid = Configuration()
    invalid.allowedBundleIDs = ["com.apple.Terminal", "com.apple.Terminal"]
    #expect(throws: ConfigurationError.self) { try invalid.validate() }
    #expect(ButtonAction.allCases.count == 24)
}

@Test func focusGenerationAndPermissionsGuard() {
    let app = AppIdentity(processID: 12, bundleID: "com.apple.Terminal")
    let ticket = DeliveryTicket(target: app, focusRevision: 2, generation: 3)
    func allowed(current: AppIdentity? = app, revision: UInt64 = 2, generation: UInt64 = 3,
                 enabled: Bool = true, accessibility: Bool = true, apps: [String] = [], excluded: Set<String> = []) -> Bool {
        DeliveryPolicy.allows(ticket: ticket, current: current, focusRevision: revision, generation: generation,
                              enabled: enabled, accessibility: accessibility, allowedBundleIDs: apps, excludedBundleIDs: excluded)
    }
    #expect(allowed())
    #expect(!allowed(revision: 4))
    #expect(!allowed(generation: 4))
    #expect(!allowed(enabled: false))
    #expect(!allowed(accessibility: false))
    #expect(!allowed(current: nil))
    #expect(!allowed(current: AppIdentity(processID: 13, bundleID: app.bundleID)))
    #expect(!allowed(apps: ["com.apple"]))
    #expect(!allowed(excluded: [app.bundleID]))
    #expect(allowed(apps: [app.bundleID]))
}

@Test func legacyConfigurationDefaultsToForegroundOutput() throws {
    let data = try JSONEncoder().encode(Configuration())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "outputMode")
    object.removeValue(forKey: "targetApplication")
    let decoded = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == Configuration())
    try decoded.validate()
    object["outputMode"] = "unknown"
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: object))
    }
    object["outputMode"] = NSNull()
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@Test func fixedTargetConfigurationRoundTrips() throws {
    var config = Configuration()
    config.outputMode = .fixedTarget
    config.targetApplication = TargetApplication(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
    try config.validate()
    config.allowedBundleIDs = ["com.mitchellh.ghostty"]
    try config.validate()
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(Configuration.self, from: data) == config)
}

@Test(arguments: ["missing", "not-allowed", "self", "macwhisper", "bad-id", "blank-name", "null-id"])
func invalidFixedTargetsAreRejected(reason: String) {
    var config = Configuration()
    config.outputMode = .fixedTarget
    config.targetApplication = TargetApplication(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
    switch reason {
    case "missing": config.targetApplication = nil
    case "not-allowed": config.allowedBundleIDs = ["com.apple.TextEdit"]
    case "self": config.targetApplication?.bundleID = "io.github.garthdb.TinkAgent"
    case "macwhisper": config.targetApplication?.bundleID = "com.goodsnooze.MacWhisper"
    case "bad-id": config.targetApplication?.bundleID = "com.ghostty invalid"
    case "blank-name": config.targetApplication?.name = " "
    case "null-id": config.targetApplication?.bundleID = "com.ghostty\0"
    default: Issue.record("Unexpected invalid-target fixture")
    }
    #expect(throws: ConfigurationError.self) { try config.validate() }
}

@Test func wavShapeAndInvalidSamples() throws {
    let data = try WAVEncoder.encode([0, 1, -1])
    #expect(data.count == 50)
    #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
    #expect(Array(data.suffix(6)) == [0, 0, 255, 127, 1, 128])
    #expect(throws: ConfigurationError.self) { try WAVEncoder.encode([.nan]) }
    #expect(throws: ConfigurationError.self) { try WAVEncoder.encode([]) }
}

@Test(arguments: ["speech", "tones"])
func realAudioRegression(name: String) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    var detector = ToneDetector()
    var detected: [Int] = []
    for offset in stride(from: 0, to: Int(buffer.frameLength) - 799, by: 800) {
        let block = Array(UnsafeBufferPointer(start: channel + offset, count: 800))
        if let slot = detector.process(block).slot { detected.append(slot) }
    }
    if name == "speech" { #expect(detected.isEmpty) }
    else { #expect(Array(detected.prefix(4)) == [1, 2, 3, 4]) }
}
