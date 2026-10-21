import Foundation

/// Which signal the mic recordings were deconvolved against.
public enum TimingReference: String, Codable {
    /// A loopback recording of the sweep. Delays are absolute: interface latency cancels.
    case loopback
    /// The generated sweep. Delays include the interface's input and output latency.
    case generated
}

/// Impulse responses from one sweep measurement.
public struct SweepMeasurementResult {
    public let sampleRate: Double
    /// One impulse response per mic, in the order the mics were recorded.
    public let impulseResponses: [[Double]]
    public let timingReference: TimingReference
    /// Delay of the loopback recording relative to the generated sweep, in samples: the round-trip
    /// latency of the interface. Nil without a loopback channel.
    public let loopbackLatency: Double?
    /// Gain of the loopback path (cable, interface input), linear, measured against the played sweep.
    /// Impulse responses are scaled by it, so their levels are relative to the sweep's digital full scale.
    public let loopbackGain: Double?
    /// Peak level of each mic recording, dBFS, to warn about clipping or too little level.
    public let micPeakLevels: [Double]
}

public enum SweepProcessing {
    /// Turns the raw recordings of a sweep measurement into impulse responses.
    ///
    /// - Parameters:
    ///   - mics: one recording per mic, all the same length, starting before or at the start of playback.
    ///   - loopback: recording of the sweep looped back from the output to an input of the same device.
    ///     When present the mics are deconvolved against it, so delays are absolute.
    ///   - sweep: the sweep that was played.
    ///   - played: the samples that were played (the sweep plus its silence).
    ///   - clockRatio: the input device's actual sample rate divided by the output device's, when they
    ///     are different devices with different clocks. The played signal is resampled to the input
    ///     clock before use. Unneeded with a loopback for the mic impulse responses (mics and loopback
    ///     share a clock), but still used for the loopback latency and gain.
    public static func process(mics: [[Double]], loopback: [Double]?, sweep: ExponentialSweep, played: [Double],
                               clockRatio: Double = 1) -> SweepMeasurementResult {
        let band = sweep.startFrequency...sweep.endFrequency
        let playedOnInputClock = clockRatio == 1 ? played : Resampler.resample(played, ratio: clockRatio)
        let reference = loopback ?? playedOnInputClock
        // Each IR is as long as the recording after the sweep has finished: the silence the room decays in.
        let length = Deconvolution.defaultLength(recording: mics.first?.count ?? 0, reference: playedOnInputClock,
                                                 sampleRate: sweep.sampleRate)

        var latency: Double?
        var gain: Double?
        if let loopback {
            let loopIR = Deconvolution.impulseResponse(recording: loopback, reference: playedOnInputClock,
                                                       sampleRate: sweep.sampleRate, band: band, length: length)
            latency = Peak.index(of: loopIR)
            // A loopback reference makes the impulse responses relative to the loopback's level.
            // Scale by the loopback's own gain (energy ratio, which the whole sweep contributes to)
            // so levels are relative to the played sweep's full scale instead.
            let playedEnergy = energy(playedOnInputClock), loopEnergy = energy(loopback)
            if playedEnergy > 0, loopEnergy > 0 { gain = (loopEnergy / playedEnergy).squareRoot() }
        }

        let scale = gain ?? 1
        let irs = mics.map { mic -> [Double] in
            let ir = Deconvolution.impulseResponse(recording: mic, reference: reference, sampleRate: sweep.sampleRate,
                                                   band: band, length: length)
            return scale == 1 ? ir : ir.map { $0 * scale }
        }

        let peaks = mics.map { m -> Double in
            let p = m.map(abs).max() ?? 0
            return p > 0 ? 20 * log10(p) : -.infinity
        }
        return SweepMeasurementResult(sampleRate: sweep.sampleRate, impulseResponses: irs,
                                      timingReference: loopback == nil ? .generated : .loopback,
                                      loopbackLatency: latency, loopbackGain: gain, micPeakLevels: peaks)
    }

    private static func energy(_ x: [Double]) -> Double {
        x.reduce(0) { $0 + $1 * $1 }
    }
}
