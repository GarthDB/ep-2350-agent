import AudioToolbox
import CoreAudio
import Foundation
import Darwin

/// Storage is allocated before capture; the producer never waits for the consumer.
final class AudioSampleRing: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: UnsafeMutablePointer<Float>
    let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private let dropped: UnsafeMutablePointer<Int32>

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        dropped = .allocate(capacity: 1)
        dropped.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        dropped.deinitialize(count: 1)
        dropped.deallocate()
    }

    func push(_ samples: UnsafePointer<Float>, count incoming: Int) {
        guard lock.try() else {
            OSAtomicIncrement32Barrier(dropped)
            return
        }
        defer { lock.unlock() }
        guard incoming <= capacity - count else {
            OSAtomicIncrement32Barrier(dropped)
            return
        }
        let first = min(incoming, capacity - writeIndex)
        storage.advanced(by: writeIndex).update(from: samples, count: first)
        if first < incoming { storage.update(from: samples.advanced(by: first), count: incoming - first) }
        writeIndex = (writeIndex + incoming) % capacity
        count += incoming
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer {
            let first = min(count, capacity - readIndex)
            $0.baseAddress!.update(from: storage.advanced(by: readIndex), count: first)
            if first < count { $0.baseAddress!.advanced(by: first).update(from: storage, count: count - first) }
        }
        readIndex = writeIndex
        count = 0
        return result
    }

    var droppedBufferCount: Int32 { OSAtomicAdd32Barrier(0, dropped) }
}

private final class CaptureContext: @unchecked Sendable {
    let unit: AudioUnit
    let maximumFrames: UInt32
    let samples: UnsafeMutablePointer<Float>
    let buffers: UnsafeMutablePointer<AudioBufferList>
    let ring: AudioSampleRing
    let signal = DispatchSemaphore(value: 0)
    let renderError: UnsafeMutablePointer<Int32>
    private let controlLock = NSLock()
    private var stopped = false

    init(unit: AudioUnit, maximumFrames: UInt32, sampleRate: Double) {
        self.unit = unit
        self.maximumFrames = maximumFrames
        samples = .allocate(capacity: Int(maximumFrames))
        buffers = .allocate(capacity: 1)
        buffers.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: maximumFrames * 4, mData: samples)))
        ring = AudioSampleRing(capacity: max(Int(sampleRate * 2), Int(maximumFrames) * 4))
        renderError = .allocate(capacity: 1)
        renderError.initialize(to: 0)
    }

    deinit {
        samples.deallocate()
        buffers.deinitialize(count: 1)
        buffers.deallocate()
        renderError.deinitialize(count: 1)
        renderError.deallocate()
    }

    func requestStop() {
        controlLock.lock()
        stopped = true
        controlLock.unlock()
        signal.signal()
    }

    var isStopped: Bool {
        controlLock.lock()
        defer { controlLock.unlock() }
        return stopped
    }
}

private let captureCallback: AURenderCallback = { refcon, flags, timestamp, _, frames, _ in
    let context = Unmanaged<CaptureContext>.fromOpaque(refcon).takeUnretainedValue()
    guard frames <= context.maximumFrames else {
        _ = OSAtomicCompareAndSwap32Barrier(0, kAudioUnitErr_TooManyFramesToProcess, context.renderError)
        context.signal.signal()
        return noErr
    }
    context.buffers.pointee.mBuffers.mDataByteSize = frames * 4
    let status = AudioUnitRender(context.unit, flags, timestamp, 1, frames, context.buffers)
    if status == noErr {
        context.ring.push(context.samples, count: Int(frames))
    } else {
        _ = OSAtomicCompareAndSwap32Barrier(0, status, context.renderError)
    }
    context.signal.signal()
    return noErr
}

/// Mutated only by the main actor, or during final destruction after its owner is released.
private final class CaptureResources {
    var unit: AudioUnit?
    var context: CaptureContext?
    let workerFinished = DispatchGroup()
    var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var deviceID: AudioDeviceID?
    let listenerQueue = DispatchQueue(label: "TinkAgent.audio.device-events")

    deinit { stop() }

    func stop() {
        if let deviceID {
            for (var address, listener) in listeners {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, listener)
            }
        }
        listeners.removeAll()
        context?.requestStop()
        if let unit {
            // The context remains strongly owned through HAL shutdown and worker join.
            // Listeners only enqueue weak, generation-checked main-actor tasks.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            // Dispose quiesces HAL callbacks before releasing the unretained render context.
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        workerFinished.wait()
        context = nil
        deviceID = nil
    }
}

@MainActor
final class AudioCaptureService {
    private let resources = CaptureResources()
    private let worker = DispatchQueue(label: "TinkAgent.audio.resampling", qos: .userInitiated)
    private var generation = UUID()

    /// Blocks arrive on the serial audio worker. Errors arrive on the main actor.
    /// Callbacks must not synchronously wait for the main actor; stop waits for the worker.
    func start(
        device: AudioInputDevice,
        onBlock: @escaping @Sendable ([Float]) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws {
        stop()
        guard let selected = try AudioDeviceService.inputs().first(where: { $0.id == device.id }) else {
            throw AudioServiceError.configuration("The selected audio input is no longer available.")
        }
        let session = UUID()
        generation = session
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioServiceError.configuration("HAL audio capture is unavailable.")
        }
        var created: AudioUnit?
        try checkAudioStatus(AudioComponentInstanceNew(component, &created), "Creating HAL input")
        guard let created else { throw AudioServiceError.configuration("HAL input creation returned no audio unit.") }
        resources.unit = created
        resources.deviceID = selected.deviceID
        do {
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            try set(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled)
            try set(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled)
            var deviceID = selected.deviceID
            try set(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID)
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checkAudioStatus(AudioUnitGetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                                                     1, &hardware, &size), "Reading device sample rate")
            _ = try AudioResampler(inputSampleRate: hardware.mSampleRate)
            var format = AudioStreamBasicDescription(
                mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                mBitsPerChannel: 32, mReserved: 0
            )
            try set(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format)
            // Capture channel zero explicitly rather than relying on a hardware downmix.
            var channel: Int32 = 0
            try set(created, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &channel)
            try set(created, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &disabled)
            var maximumFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            try checkAudioStatus(AudioUnitGetProperty(created, kAudioUnitProperty_MaximumFramesPerSlice,
                                                     kAudioUnitScope_Global, 0, &maximumFrames, &size), "Reading capture buffer size")
            guard maximumFrames > 0, maximumFrames <= 1_048_576 else {
                throw AudioServiceError.configuration("Unsupported capture buffer size.")
            }
            let context = CaptureContext(unit: created, maximumFrames: maximumFrames, sampleRate: hardware.mSampleRate)
            resources.context = context
            var callback = AURenderCallbackStruct(inputProc: captureCallback,
                                                 inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try set(created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)
            try checkAudioStatus(AudioUnitInitialize(created), "Initializing selected input")
            try installListeners(deviceID: selected.deviceID, session: session, onError: onError)
            startWorker(context: context, sampleRate: hardware.mSampleRate, session: session, onBlock: onBlock, onError: onError)
            try checkAudioStatus(AudioOutputUnitStart(created), "Starting selected input")
        } catch {
            stop()
            throw error
        }
    }

    private func startWorker(context: CaptureContext, sampleRate: Double, session: UUID,
                             onBlock: @escaping @Sendable ([Float]) -> Void,
                             onError: @escaping @Sendable (String) -> Void) {
        resources.workerFinished.enter()
        let finished = resources.workerFinished
        worker.async { [weak self] in
            defer { finished.leave() }
            let resampler: AudioResampler
            do {
                resampler = try AudioResampler(inputSampleRate: sampleRate)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.fail(session: session, message: message, onError: onError)
                }
                return
            }
            var pending: [Float] = []
            var lastDropped: Int32 = 0
            while true {
                context.signal.wait()
                if context.isStopped { return }
                let renderStatus = OSAtomicAdd32Barrier(0, context.renderError)
                if renderStatus != 0 {
                    Task { @MainActor [weak self] in
                        self?.fail(session: session, message: "Audio input rendering failed (\(renderStatus)).", onError: onError)
                    }
                    return
                }
                let dropped = context.ring.droppedBufferCount
                if dropped != lastDropped {
                    // Never invoke the client from this worker: its error handler may
                    // synchronously call stop(), which joins this worker.
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == session else { return }
                        onError("Audio capture overflow: input buffers were dropped.")
                    }
                    lastDropped = dropped
                }
                do {
                    pending.append(contentsOf: try resampler.process(context.ring.drain()))
                    var offset = 0
                    while pending.count - offset >= 800 {
                        if context.isStopped { return }
                        onBlock(Array(pending[offset ..< offset + 800]))
                        offset += 800
                    }
                    if offset > 0 { pending.removeFirst(offset) }
                } catch {
                    let message = error.localizedDescription
                    Task { @MainActor [weak self] in
                        self?.fail(session: session, message: message, onError: onError)
                    }
                    return
                }
            }
        }
    }

    private func installListeners(deviceID: AudioDeviceID, session: UUID,
                                  onError: @escaping @Sendable (String) -> Void) throws {
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput),
            (kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput)
        ]
        for (selector, scope) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                    mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.fail(session: session,
                               message: "The selected audio input disconnected or changed format. Capture stopped.",
                               onError: onError)
                }
            }
            try checkAudioStatus(AudioObjectAddPropertyListenerBlock(deviceID, &address, resources.listenerQueue, listener),
                                 "Monitoring selected audio input")
            resources.listeners.append((address, listener))
        }
    }

    func stop() {
        generation = UUID()
        resources.stop()
    }

    private func fail(session: UUID, message: String, onError: @Sendable (String) -> Void) {
        guard session == generation else { return }
        stop()
        onError(message)
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: inout T) throws {
        let status = withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<T>.size))
        }
        try checkAudioStatus(status, "Configuring selected audio input")
    }
}
