#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import MeasureDSP

/// Where a sweep is played and which inputs are recorded.
public struct SweepRouting {
    public var outputDevice: AudioDevice
    /// Output channel the sweep goes to, from 0.
    public var outputChannel: Int
    public var inputDevice: AudioDevice
    /// Input channels with measurement mics, from 0. Up to 4 for the prototype, but any number works.
    public var micChannels: [Int]
    /// Input channel with the sweep looped back from the output, from 0. Must be on the same
    /// device as the mics for its timing to apply to them.
    public var loopbackChannel: Int?
    /// A second output channel that also plays the sweep, to cable to the loopback input
    /// without splitting the speaker feed. From 0.
    public var loopbackOutputChannel: Int?

    public init(outputDevice: AudioDevice, outputChannel: Int, inputDevice: AudioDevice,
                micChannels: [Int], loopbackChannel: Int? = nil, loopbackOutputChannel: Int? = nil) {
        self.outputDevice = outputDevice
        self.outputChannel = outputChannel
        self.inputDevice = inputDevice
        self.micChannels = micChannels
        self.loopbackChannel = loopbackChannel
        self.loopbackOutputChannel = loopbackOutputChannel
    }

    func validate() throws {
        for c in [outputChannel] + [loopbackOutputChannel].compactMap({ $0 }) where c < 0 || c >= outputDevice.outputChannels {
            throw AudioEngineError.channelOutOfRange(device: outputDevice.name, channel: c + 1,
                                                     available: outputDevice.outputChannels)
        }
        for c in micChannels + [loopbackChannel].compactMap({ $0 }) where c < 0 || c >= inputDevice.inputChannels {
            throw AudioEngineError.channelOutOfRange(device: inputDevice.name, channel: c + 1,
                                                     available: inputDevice.inputChannels)
        }
    }
}

/// What was recorded during one sweep, before deconvolution.
public struct SweepRecording {
    public let sampleRate: Double
    /// One recording per mic channel, aligned so index 0 is (approximately) when playback started.
    public let mics: [[Double]]
    public let loopback: [Double]?
    /// The samples that were played.
    public let played: [Double]
}

/// Plays a signal on one output channel while recording several input channels, using two
/// Core Audio HAL output units (one for playback, one for capture).
///
/// The audio callbacks only copy samples between preallocated buffers: no allocation, locks or
/// Swift object access happens on the audio thread.
public final class SweepRecorder {
    public init() {}

    /// Asks for microphone access if it has not been decided yet. On macOS the first call shows the
    /// system prompt (for Terminal when run from the command line).
    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Plays `signal` on the routing's output and records its inputs until the signal has finished.
    /// - Parameter preroll: seconds of input captured before playback starts, so nothing is missed.
    public func record(_ signal: [Double], sampleRate: Double, routing: SweepRouting, preroll: Double = 0.2) async throws -> SweepRecording {
        try routing.validate()
        guard await SweepRecorder.requestMicrophoneAccess() else { throw AudioEngineError.microphoneAccessDenied }
        try AudioDevices.setSampleRate(sampleRate, on: routing.outputDevice)
        if routing.inputDevice.id != routing.outputDevice.id {
            try AudioDevices.setSampleRate(sampleRate, on: routing.inputDevice)
        }

        let captureChannels = routing.micChannels + [routing.loopbackChannel].compactMap { $0 }
        let prerollFrames = Int(preroll * sampleRate)
        // Room for the preroll, the signal, and a second of slack for start-up and latency.
        let capacity = prerollFrames + signal.count + Int(sampleRate)
        let state = RealtimeState.make(signal: signal, outputChannel: routing.outputChannel,
                                       loopbackOutputChannel: routing.loopbackOutputChannel ?? -1,
                                       captureChannels: captureChannels,
                                       inputChannelCount: routing.inputDevice.inputChannels,
                                       capacity: capacity)
        defer { RealtimeState.destroy(state) }

        let input = try makeInputUnit(device: routing.inputDevice, sampleRate: sampleRate, state: state)
        defer { AudioOutputUnitStop(input); AudioUnitUninitialize(input); AudioComponentInstanceDispose(input) }
        let output = try makeOutputUnit(device: routing.outputDevice, sampleRate: sampleRate, state: state)
        defer { AudioOutputUnitStop(output); AudioUnitUninitialize(output); AudioComponentInstanceDispose(output) }

        try check(AudioOutputUnitStart(input), "starting input")
        try await waitUntil(timeout: 5) { state.pointee.capturedFrames >= prerollFrames }
        try check(AudioOutputUnitStart(output), "starting output")

        // Run until the signal has played and the input has caught up with it.
        let timeout = Double(signal.count) / sampleRate + 10
        try await waitUntil(timeout: timeout) {
            state.pointee.playedFrames >= signal.count
                && state.pointee.capturedFrames >= min(capacity, prerollFrames + signal.count + Int(0.1 * sampleRate))
        }
        AudioOutputUnitStop(output)
        AudioOutputUnitStop(input)
        if state.pointee.renderError != noErr {
            throw AudioEngineError.coreAudio("recording", state.pointee.renderError)
        }

        // Align: drop the input captured before the first played sample, using the host clock
        // timestamps of the first input and output buffers.
        let s = state.pointee
        var offset = prerollFrames
        if s.firstInputHostTime > 0, s.firstOutputHostTime > s.firstInputHostTime {
            let seconds = hostTicksToSeconds(s.firstOutputHostTime - s.firstInputHostTime)
            offset = Int((seconds * sampleRate).rounded())
        }
        offset = max(0, min(offset, s.capturedFrames))
        let length = min(signal.count, s.capturedFrames - offset)

        var tracks: [[Double]] = []
        for c in 0..<captureChannels.count {
            let base = s.capture + c * capacity + offset
            tracks.append((0..<length).map { Double(base[$0]) })
        }
        let loopback = routing.loopbackChannel == nil ? nil : tracks.removeLast()
        return SweepRecording(sampleRate: sampleRate, mics: tracks, loopback: loopback,
                              played: Array(signal.prefix(length)))
    }

    // MARK: - Units

    private func makeUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioEngineError.coreAudio("finding the HAL output unit", -1)
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "creating an audio unit")
        return unit!
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: T, _ what: String) throws {
        var v = value
        try check(AudioUnitSetProperty(unit, property, scope, element, &v, UInt32(MemoryLayout<T>.size)), what)
    }

    /// Float32, non-interleaved: one buffer per channel.
    private func format(channels: Int, sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func makeInputUnit(device: AudioDevice, sampleRate: Double, state: UnsafeMutablePointer<RealtimeState>) throws -> AudioUnit {
        let unit = try makeUnit()
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enabling input")
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disabling output on the input unit")
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, "selecting \(device.name) for input")
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                format(channels: device.inputChannels, sampleRate: sampleRate), "setting the input format")
        state.pointee.inputUnit = unit
        try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: UnsafeMutableRawPointer(state)),
                "installing the input callback")
        try check(AudioUnitInitialize(unit), "initialising input on \(device.name)")
        return unit
    }

    private func makeOutputUnit(device: AudioDevice, sampleRate: Double, state: UnsafeMutablePointer<RealtimeState>) throws -> AudioUnit {
        let unit = try makeUnit()
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, "selecting \(device.name) for output")
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                format(channels: device.outputChannels, sampleRate: sampleRate), "setting the output format")
        try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                AURenderCallbackStruct(inputProc: outputCallback, inputProcRefCon: UnsafeMutableRawPointer(state)),
                "installing the output callback")
        try check(AudioUnitInitialize(unit), "initialising output on \(device.name)")
        return unit
    }

    private func waitUntil(timeout: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw AudioEngineError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func hostTicksToSeconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }
}

// MARK: - Real-time state and callbacks

/// Everything the audio callbacks touch. Plain memory, allocated before the units start.
struct RealtimeState {
    var signal: UnsafeMutablePointer<Float>
    var signalCount: Int
    var playedFrames: Int
    var outputChannel: Int
    var loopbackOutputChannel: Int

    var capture: UnsafeMutablePointer<Float>
    var captureChannels: UnsafeMutablePointer<Int>
    var captureChannelCount: Int
    var capacity: Int
    var capturedFrames: Int

    var inputUnit: AudioUnit?
    var inputBuffers: UnsafeMutableAudioBufferListPointer
    var maxFrames: Int

    var firstInputHostTime: UInt64
    var firstOutputHostTime: UInt64
    var renderError: OSStatus

    static func make(signal: [Double], outputChannel: Int, loopbackOutputChannel: Int,
                     captureChannels: [Int], inputChannelCount: Int, capacity: Int) -> UnsafeMutablePointer<RealtimeState> {
        let sig = UnsafeMutablePointer<Float>.allocate(capacity: max(1, signal.count))
        for i in signal.indices { sig[i] = Float(signal[i]) }
        let cap = UnsafeMutablePointer<Float>.allocate(capacity: max(1, captureChannels.count * capacity))
        cap.initialize(repeating: 0, count: max(1, captureChannels.count * capacity))
        let chans = UnsafeMutablePointer<Int>.allocate(capacity: max(1, captureChannels.count))
        for (i, c) in captureChannels.enumerated() { chans[i] = c }

        // Larger than any buffer size Core Audio will ask for.
        let maxFrames = 16_384
        let buffers = AudioBufferList.allocate(maximumBuffers: max(1, inputChannelCount))
        for i in 0..<buffers.count {
            let bytes = maxFrames * MemoryLayout<Float>.size
            buffers[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes),
                                     mData: UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16))
        }

        let state = UnsafeMutablePointer<RealtimeState>.allocate(capacity: 1)
        state.initialize(to: RealtimeState(
            signal: sig, signalCount: signal.count, playedFrames: 0,
            outputChannel: outputChannel, loopbackOutputChannel: loopbackOutputChannel,
            capture: cap, captureChannels: chans, captureChannelCount: captureChannels.count,
            capacity: capacity, capturedFrames: 0,
            inputUnit: nil, inputBuffers: buffers, maxFrames: maxFrames,
            firstInputHostTime: 0, firstOutputHostTime: 0, renderError: noErr))
        return state
    }

    static func destroy(_ state: UnsafeMutablePointer<RealtimeState>) {
        let s = state.pointee
        s.signal.deallocate()
        s.capture.deallocate()
        s.captureChannels.deallocate()
        for b in s.inputBuffers { b.mData?.deallocate() }
        free(s.inputBuffers.unsafeMutablePointer)
        state.deinitialize(count: 1)
        state.deallocate()
    }
}

/// Fills every output channel with silence except the measurement (and loopback) channel, which get the signal.
private let outputCallback: AURenderCallback = { refCon, _, timeStamp, _, frameCount, ioData in
    let state = refCon.assumingMemoryBound(to: RealtimeState.self)
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let frames = Int(frameCount)
    if state.pointee.firstOutputHostTime == 0 { state.pointee.firstOutputHostTime = timeStamp.pointee.mHostTime }

    let start = state.pointee.playedFrames
    let remaining = max(0, state.pointee.signalCount - start)
    for (channel, buffer) in buffers.enumerated() {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        if channel == state.pointee.outputChannel || channel == state.pointee.loopbackOutputChannel {
            let n = min(count, remaining)
            for i in 0..<n { data[i] = state.pointee.signal[start + i] }
            for i in n..<count { data[i] = 0 }
        } else {
            for i in 0..<count { data[i] = 0 }
        }
    }
    state.pointee.playedFrames = start + min(frames, remaining)
    return noErr
}

/// Pulls the input samples from the unit and copies the selected channels into the capture buffer.
private let inputCallback: AURenderCallback = { refCon, actionFlags, timeStamp, bus, frameCount, _ in
    let state = refCon.assumingMemoryBound(to: RealtimeState.self)
    guard let unit = state.pointee.inputUnit else { return noErr }
    let frames = min(Int(frameCount), state.pointee.maxFrames)
    let buffers = state.pointee.inputBuffers
    for i in 0..<buffers.count { buffers[i].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size) }

    let status = AudioUnitRender(unit, actionFlags, timeStamp, bus, UInt32(frames), buffers.unsafeMutablePointer)
    if status != noErr {
        state.pointee.renderError = status
        return status
    }
    if state.pointee.firstInputHostTime == 0 { state.pointee.firstInputHostTime = timeStamp.pointee.mHostTime }

    let start = state.pointee.capturedFrames
    let n = min(frames, state.pointee.capacity - start)
    guard n > 0 else { return noErr }
    for c in 0..<state.pointee.captureChannelCount {
        let source = state.pointee.captureChannels[c]
        guard source < buffers.count, let data = buffers[source].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let dest = state.pointee.capture + c * state.pointee.capacity + start
        for i in 0..<n { dest[i] = data[i] }
    }
    state.pointee.capturedFrames = start + n
    return noErr
}
#endif
