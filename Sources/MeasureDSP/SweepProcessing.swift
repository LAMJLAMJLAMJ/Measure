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
    public static func process(mics: [[Double]], loopback: [Double]?, sweep: ExponentialSweep, played: [Double]) -> SweepMeasurementResult {
        let band = sweep.startFrequency...sweep.endFrequency
        let reference = loopback ?? played
        // Each IR is as long as the recording after the sweep has finished: the silence the room decays in.
        let length = Deconvolution.defaultLength(recording: mics.first?.count ?? 0, reference: played, sampleRate: sweep.sampleRate)

        let irs = mics.map {
            Deconvolution.impulseResponse(recording: $0, reference: reference, sampleRate: sweep.sampleRate,
                                          band: band, length: length)
        }

        var latency: Double?
        if let loopback {
            let loopIR = Deconvolution.impulseResponse(recording: loopback, reference: played, sampleRate: sweep.sampleRate,
                                                       band: band, length: length)
            latency = Peak.index(of: loopIR)
        }

        let peaks = mics.map { m -> Double in
            let p = m.map(abs).max() ?? 0
            return p > 0 ? 20 * log10(p) : -.infinity
        }
        return SweepMeasurementResult(sampleRate: sweep.sampleRate, impulseResponses: irs,
                                      timingReference: loopback == nil ? .generated : .loopback,
                                      loopbackLatency: latency, micPeakLevels: peaks)
    }
}
