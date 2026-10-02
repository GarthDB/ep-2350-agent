import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
}

enum AudioServiceError: Error, LocalizedError {
    case coreAudio(String, OSStatus)
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            "\(operation) failed (Core Audio status \(status))."
        case let .configuration(message):
            message
        }
    }
}

enum AudioDeviceService {
    static func inputs() throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try checkAudioStatus(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
            "Enumerating audio devices"
        )
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        try checkAudioStatus(status, "Reading audio devices")
        var result: [AudioInputDevice] = []
        for id in ids where try inputChannelCount(id) > 0 {
            result.append(AudioInputDevice(
                id: try stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                name: try stringProperty(id, selector: kAudioObjectPropertyName),
                deviceID: id
            ))
        }
        return result.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try checkAudioStatus(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Reading audio device identity")
        guard let value else { throw AudioServiceError.configuration("Audio device identity is unavailable.") }
        return value.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ id: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try checkAudioStatus(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Reading input configuration")
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try checkAudioStatus(AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage), "Reading input channels")
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

func checkAudioStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioServiceError.coreAudio(operation, status) }
}
