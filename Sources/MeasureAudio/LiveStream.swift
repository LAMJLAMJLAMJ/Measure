#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Where the live analyser listens, and where it plays its noise.
public struct LiveRouting {
    public var inputDevice: AudioDevice
    /// The input carrying the reference: the signal fed to the system, by a loopback cable or a feed
    /// from the console. From 0. Nil uses the generated signal itself as the reference (an internal
    /// reference), which needs a signal to play.
    public var referenceChannel: Int?
    /// Mic inputs. From 0.
    public var micChannels: [Int]
    /// Where the noise generator plays, or nil to measure with an external signal such as programme.
    public var outputDevice: AudioDevice?
    /// From 0.
    public var outputChannel: Int
    /// A second output that also gets the noise, for a loopback cable to the reference input. From 0.
    public var loopbackOutputChannel: Int?

    public init(inputDevice: AudioDevice, referenceChannel: Int?, micChannels: [Int],
                outputDevice: AudioDevice?, outputChannel: Int, loopbackOutputChannel: Int?) {
        self.inputDevice = inputDevice
        self.referenceChannel = referenceChannel
        self.micChannels = micChannels
        self.outputDevice = outputDevice
        self.outputChannel = outputChannel
        self.loopbackOutputChannel = loopbackOutputChannel
    }

    func validate() throws {
        for c in [referenceChannel].compactMap({ $0 }) + micChannels where c < 0 || c >= inputDevice.inputChannels {
            throw AudioEngineError.channelOutOfRange(device: inputDevice.name, channel: c + 1, available: inputDevice.inputChannels)
        }
        if let out = outputDevice {
            for c in [outputChannel] + [loopbackOutputChannel].compactMap({ $0 }) where c < 0 || c >= out.outputChannels {
                throw AudioEngineError.channelOutOfRange(device: out.name, channel: c + 1, available: out.outputChannels)
            }
        }
    }
}

/// Runs the inputs (and optionally a looping test signal) continuously and keeps the last few seconds
/// of the reference and mic inputs, for the live transfer function. The reference is recorded on the
/// same device as the mics, so their clocks always agree, whichever device plays the noise.
///
/// The audio callbacks only copy samples between preallocated buffers. Readers copy out of the ring
/// buffer while it is being written; it holds several seconds, far more than a block, so the part
/// they read is never overwritten during the copy.
public final class LiveStream {
    private var state: UnsafeMutablePointer<LiveState>?
    private var input: AudioUnit?
    private var output: AudioUnit?
    public private(set) var sampleRate: Double = 48_000
    public private(set) var micCount = 0

    public init() {}
    deinit { stop() }

    public var isRunning: Bool { state != nil }

    /// Starts the inputs and, when `signal` is given, plays it in a loop at `level` dB re its peak.
    public func start(routing: LiveRouting, sampleRate: Double, signal: [Double]?, level: Double) async throws {
        stop()
        try routing.validate()
        if routing.referenceChannel == nil && (signal == nil || routing.outputDevice == nil) {
            throw AudioEngineError.coreAudio("starting: an internal reference needs the generator", -1)
        }
        guard await SweepRecorder.requestMicrophoneAccess() else { throw AudioEngineError.microphoneAccessDenied }
        try AudioDevices.setSampleRate(sampleRate, on: routing.inputDevice)
        if let out = routing.outputDevice, signal != nil, out.id != routing.inputDevice.id {
            try AudioDevices.setSampleRate(sampleRate, on: out)
        }
        self.sampleRate = sampleRate
        micCount = routing.micChannels.count

        let s = LiveState.make(signal: signal ?? [], gain: Float(pow(10, level / 20)),
                               outputChannel: routing.outputChannel,
                               loopbackOutputChannel: routing.loopbackOutputChannel ?? -1,
                               // -1: the internal reference, made from the signal in the input callback.
                               captureChannels: [routing.referenceChannel ?? -1] + routing.micChannels,
                               inputChannelCount: routing.inputDevice.inputChannels)
        state = s
        do {
            input = try makeInputUnit(device: routing.inputDevice, sampleRate: sampleRate, state: s)
            try check(AudioOutputUnitStart(input!), "starting input")
            if let out = routing.outputDevice, signal != nil {
                output = try makeOutputUnit(device: out, sampleRate: sampleRate, state: s)
                try check(AudioOutputUnitStart(output!), "starting output")
            }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        for unit in [output, input].compactMap({ $0 }) {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        output = nil
        input = nil
        if let s = state { LiveState.destroy(s) }
        state = nil
    }

    /// Changes the noise level, dB re the signal's peak, while running.
    public func setLevel(_ level: Double) {
        state?.pointee.gain = Float(pow(10, level / 20))
    }

    /// Frames captured since the start.
    public var capturedFrames: Int { state?.pointee.written ?? 0 }

    /// Peak level of each captured channel (reference first) over the last block, dB re full scale.
    public var recentPeaks: [Double] {
        guard let s = state else { return [] }
        return (0..<s.pointee.channelCount).map { c in
            let p = s.pointee.peaks[c]
            s.pointee.peaks[c] = 0
            return 20 * log10(max(Double(p), 1e-10))
        }
    }

    /// The latest `count` samples of the reference and of mic `mic` (from 0). `delay` (samples) moves
    /// the reference earlier to line it up with a mic that hears it later; a negative delay moves the
    /// mic earlier instead. Nil until enough has been captured.
    public func block(_ count: Int, mic: Int, delay: Int) -> (reference: [Double], mic: [Double])? {
        guard let s = state, mic >= 0, mic + 1 < s.pointee.channelCount else { return nil }
        let written = s.pointee.written
        let capacity = s.pointee.capacity
        let refEnd = written - max(0, delay)
        let micEnd = written - max(0, -delay)
        guard min(refEnd, micEnd) - count >= 0, count + abs(delay) < capacity / 2 else { return nil }
        func read(_ channel: Int, end: Int) -> [Double] {
            let base = s.pointee.ring + channel * capacity
            let mask = capacity - 1
            return (end - count..<end).map { Double(base[$0 & mask]) }
        }
        return (read(0, end: refEnd), read(mic + 1, end: micEnd))
    }

    /// Mic `mic`'s samples (from 0) captured from frame `from` up to now, and the frame they end at, to
    /// read every sample once by passing the end back next time. A reader that fell more than half
    /// the buffer behind gets only the latest half.
    public func samples(mic: Int, from: Int) -> (samples: [Double], end: Int) {
        guard let s = state, mic >= 0, mic + 1 < s.pointee.channelCount else { return ([], from) }
        let written = s.pointee.written
        let capacity = s.pointee.capacity
        let start = max(from, written - capacity / 2, 0)
        guard written > start else { return ([], written) }
        let base = s.pointee.ring + (mic + 1) * capacity
        let mask = capacity - 1
        return ((start..<written).map { Double(base[$0 & mask]) }, written)
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
        try withUnsafeBytes(of: &v) { bytes in
            try check(AudioUnitSetProperty(unit, property, scope, element, bytes.baseAddress, UInt32(bytes.count)), what)
        }
    }

    /// Float32, non-interleaved: one buffer per channel.
    private func format(channels: Int, sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func makeInputUnit(device: AudioDevice, sampleRate: Double, state: UnsafeMutablePointer<LiveState>) throws -> AudioUnit {
        let unit = try makeUnit()
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enabling input")
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disabling output on the input unit")
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, "selecting \(device.name) for input")
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                format(channels: device.inputChannels, sampleRate: sampleRate), "setting the input format")
        state.pointee.inputUnit = unit
        try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                AURenderCallbackStruct(inputProc: liveInputCallback, inputProcRefCon: UnsafeMutableRawPointer(state)),
                "installing the input callback")
        try check(AudioUnitInitialize(unit), "initialising input on \(device.name)")
        return unit
    }

    private func makeOutputUnit(device: AudioDevice, sampleRate: Double, state: UnsafeMutablePointer<LiveState>) throws -> AudioUnit {
        let unit = try makeUnit()
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, "selecting \(device.name) for output")
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                format(channels: device.outputChannels, sampleRate: sampleRate), "setting the output format")
        try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                AURenderCallbackStruct(inputProc: liveOutputCallback, inputProcRefCon: UnsafeMutableRawPointer(state)),
                "installing the output callback")
        try check(AudioUnitInitialize(unit), "initialising output on \(device.name)")
        return unit
    }
}

// MARK: - Real-time state and callbacks

struct LiveState {
    var signal: UnsafeMutablePointer<Float>
    var signalCount: Int
    var position: Int
    /// Input frame count when the output played its first frame, -1 before that. The internal
    /// reference counts from here, so it only lags the input by the interface latency.
    var outputStartFrame: Int
    var gain: Float
    var outputChannel: Int
    var loopbackOutputChannel: Int

    /// One ring buffer per captured channel, `capacity` (a power of two) samples each.
    var ring: UnsafeMutablePointer<Float>
    var captureChannels: UnsafeMutablePointer<Int>
    var channelCount: Int
    var capacity: Int
    /// Frames written since the start; the ring index is this modulo `capacity`.
    var written: Int
    /// Peak magnitude per channel since the reader last took it.
    var peaks: UnsafeMutablePointer<Float>

    var inputUnit: AudioUnit?
    var inputBuffers: UnsafeMutableAudioBufferListPointer
    var maxFrames: Int

    static func make(signal: [Double], gain: Float, outputChannel: Int, loopbackOutputChannel: Int,
                     captureChannels: [Int], inputChannelCount: Int) -> UnsafeMutablePointer<LiveState> {
        let sig = UnsafeMutablePointer<Float>.allocate(capacity: max(1, signal.count))
        for i in signal.indices { sig[i] = Float(signal[i]) }
        // 2^20 samples: about 22 s at 48 kHz, room for the largest FFT plus a long delay.
        let capacity = 1 << 20
        let ring = UnsafeMutablePointer<Float>.allocate(capacity: captureChannels.count * capacity)
        ring.initialize(repeating: 0, count: captureChannels.count * capacity)
        let chans = UnsafeMutablePointer<Int>.allocate(capacity: captureChannels.count)
        for (i, c) in captureChannels.enumerated() { chans[i] = c }
        let peaks = UnsafeMutablePointer<Float>.allocate(capacity: captureChannels.count)
        peaks.initialize(repeating: 0, count: captureChannels.count)

        let maxFrames = 16_384
        let buffers = AudioBufferList.allocate(maximumBuffers: max(1, inputChannelCount))
        for i in 0..<buffers.count {
            let bytes = maxFrames * MemoryLayout<Float>.size
            buffers[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes),
                                     mData: UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16))
        }
        let state = UnsafeMutablePointer<LiveState>.allocate(capacity: 1)
        state.initialize(to: LiveState(
            signal: sig, signalCount: signal.count, position: 0, outputStartFrame: -1, gain: gain,
            outputChannel: outputChannel, loopbackOutputChannel: loopbackOutputChannel,
            ring: ring, captureChannels: chans, channelCount: captureChannels.count, capacity: capacity,
            written: 0, peaks: peaks, inputUnit: nil, inputBuffers: buffers, maxFrames: maxFrames))
        return state
    }

    static func destroy(_ state: UnsafeMutablePointer<LiveState>) {
        let s = state.pointee
        s.signal.deallocate()
        s.ring.deallocate()
        s.captureChannels.deallocate()
        s.peaks.deallocate()
        for b in s.inputBuffers { b.mData?.deallocate() }
        free(s.inputBuffers.unsafeMutablePointer)
        state.deinitialize(count: 1)
        state.deallocate()
    }
}

/// Plays the signal in a loop on the measurement (and loopback) channel; silence elsewhere.
private let liveOutputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let state = refCon.assumingMemoryBound(to: LiveState.self)
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let frames = Int(frameCount)
    let count = state.pointee.signalCount
    let start = state.pointee.position
    let gain = state.pointee.gain
    if state.pointee.outputStartFrame < 0 { state.pointee.outputStartFrame = state.pointee.written }
    for (channel, buffer) in buffers.enumerated() {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let n = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        if count > 0 && (channel == state.pointee.outputChannel || channel == state.pointee.loopbackOutputChannel) {
            var p = start
            for i in 0..<n {
                data[i] = state.pointee.signal[p] * gain
                p += 1
                if p == count { p = 0 }
            }
        } else {
            for i in 0..<n { data[i] = 0 }
        }
    }
    if count > 0 { state.pointee.position = (start + frames) % count }
    return noErr
}

/// Pulls the input samples and appends the reference and mic channels to their ring buffers.
private let liveInputCallback: AURenderCallback = { refCon, actionFlags, timeStamp, bus, frameCount, _ in
    let state = refCon.assumingMemoryBound(to: LiveState.self)
    guard let unit = state.pointee.inputUnit else { return noErr }
    let frames = min(Int(frameCount), state.pointee.maxFrames)
    let buffers = state.pointee.inputBuffers
    for i in 0..<buffers.count { buffers[i].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size) }
    let status = AudioUnitRender(unit, actionFlags, timeStamp, bus, UInt32(frames), buffers.unsafeMutablePointer)
    if status != noErr { return status }

    let start = state.pointee.written
    let capacity = state.pointee.capacity
    let mask = capacity - 1
    for c in 0..<state.pointee.channelCount {
        let source = state.pointee.captureChannels[c]
        let dest = state.pointee.ring + c * capacity
        var peak = state.pointee.peaks[c]
        if source < 0 {
            // Internal reference: the signal as played, frame for frame with the input from when the
            // output started. Both run on one clock, so what is left between them is a constant
            // latency, which the delay finder measures along with the acoustic delay.
            let count = state.pointee.signalCount
            let origin = state.pointee.outputStartFrame
            guard count > 0 else { continue }
            let gain = state.pointee.gain
            for i in 0..<frames {
                let n = start + i - origin
                let v = origin < 0 || n < 0 ? 0 : state.pointee.signal[n % count] * gain
                dest[(start + i) & mask] = v
                peak = max(peak, abs(v))
            }
            state.pointee.peaks[c] = peak
            continue
        }
        guard source < buffers.count, let data = buffers[source].mData?.assumingMemoryBound(to: Float.self) else { continue }
        for i in 0..<frames {
            let v = data[i]
            dest[(start + i) & mask] = v
            peak = max(peak, abs(v))
        }
        state.pointee.peaks[c] = peak
    }
    state.pointee.written = start + frames
    return noErr
}
#endif
