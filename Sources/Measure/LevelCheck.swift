#if os(macOS)
import Foundation
import MeasureAudio
import MeasureDSP
import Observation

/// Plays the measurement sweep in a loop, as Measure would play it, and meters every mic input and
/// the loopback, so the gains can be set before measuring. The peaks are held over a whole loop of the
/// sweep, and an input that clips stays marked until the check starts again.
@Observable @MainActor
final class LevelCheck {
    struct Meter: Equatable {
        var name: String
        /// Highest peak over the last loop of the sweep, dB re full scale.
        var peak = -200.0
        /// Peaked above `MeasurementQuality.clipLevel` since the check started.
        var clipped = false
    }

    private(set) var isRunning = false
    /// Mic inputs recorded by sweeps, in order.
    private(set) var mics: [Meter] = []
    /// Nil without a loopback input.
    private(set) var loopback: Meter?

    @ObservationIgnored private let stream = LiveStream()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var positions: [Int] = []
    /// Recent peaks of each channel (loopback first when there is one), one per update.
    @ObservationIgnored private var recent: [[Double]] = []
    @ObservationIgnored private var updatesPerLoop = 40

    func start(_ model: AppModel) async {
        guard !isRunning, !model.isMeasuring else { return }
        model.live.stop(model)
        model.monitor.stop(model)
        model.generator.stop()
        let s = model.settings
        let active = s.activeMics
        guard let out = model.outputDevice, let input = model.inputDevice, !active.isEmpty else {
            model.errorMessage = "Choose an output, an input and at least one mic in Measurement Setup."
            return
        }
        let end = min(s.endFrequency, s.sampleRate / 2)
        let sweep = ExponentialSweep(startFrequency: s.startFrequency, endFrequency: end,
                                     duration: s.sweepLength, sampleRate: s.sampleRate,
                                     amplitude: pow(10, s.level / 20))
        // A short gap between sweeps, so the meters see every sweep without a long wait.
        let signal = sweep.samples(silence: min(s.silence, 1))
        let routing = LiveRouting(inputDevice: input, referenceChannel: s.loopbackInput.map { $0 - 1 },
                                  micChannels: active.map { $0.channel - 1 },
                                  outputDevice: out, outputChannel: s.outputChannel - 1,
                                  loopbackOutputChannel: s.loopbackOutput.map { $0 - 1 })
        do {
            // The sweep already has its level, so it plays at its own peak.
            try await stream.start(routing: routing, sampleRate: s.sampleRate, signal: signal, level: 0)
        } catch {
            model.errorMessage = "\(error)"
            return
        }
        model.errorMessage = nil
        mics = active.map { Meter(name: $0.micName ?? "Input \($0.channel)") }
        loopback = s.loopbackInput.map { Meter(name: "Loopback (input \($0))") }
        let channels = active.count + (loopback == nil ? 0 : 1)
        positions = Array(repeating: 0, count: channels)
        recent = Array(repeating: [], count: channels)
        updatesPerLoop = max(10, Int((Double(signal.count) / s.sampleRate / 0.1).rounded(.up)))
        isRunning = true
        model.status = "Level check: playing the sweep in a loop at \(Int(s.level)) dBFS."
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.update()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        loop?.cancel()
        loop = nil
        stream.stop()
        isRunning = false
    }

    private func update() {
        guard isRunning else { return }
        var channel = 0
        if var meter = loopback {
            meter = updated(meter, channel: channel, samples: read(channel) { stream.referenceSamples(from: $0) })
            loopback = meter
            channel += 1
        }
        for i in mics.indices {
            let c = channel + i
            mics[i] = updated(mics[i], channel: c, samples: read(c) { stream.samples(mic: i, from: $0) })
        }
    }

    private func read(_ channel: Int, _ get: (Int) -> (samples: [Double], end: Int)) -> [Double] {
        let (samples, end) = get(positions[channel])
        positions[channel] = end
        return samples
    }

    private func updated(_ meter: Meter, channel: Int, samples: [Double]) -> Meter {
        var meter = meter
        let peak = samples.isEmpty ? -200 : SignalLevel.peak(samples)
        recent[channel].append(peak)
        if recent[channel].count > updatesPerLoop { recent[channel].removeFirst(recent[channel].count - updatesPerLoop) }
        meter.peak = recent[channel].max() ?? -200
        if peak > MeasurementQuality.clipLevel { meter.clipped = true }
        return meter
    }
}
#endif
