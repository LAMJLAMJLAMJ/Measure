import Foundation

/// Exponential (logarithmic) sine sweep, as described by Farina (2000).
public struct ExponentialSweep {
    public var startFrequency: Double
    public var endFrequency: Double
    /// Sweep length in seconds, excluding any silence after it.
    public var duration: Double
    public var sampleRate: Double
    /// Peak level, linear (1.0 = full scale).
    public var amplitude: Double
    /// Raised-cosine fades in seconds, to avoid clicks at the start and end.
    public var fadeIn: Double
    public var fadeOut: Double

    public init(startFrequency: Double = 20, endFrequency: Double = 20_000, duration: Double = 3,
                sampleRate: Double = 48_000, amplitude: Double = 0.5,
                fadeIn: Double = 0.05, fadeOut: Double = 0.01) {
        precondition(startFrequency > 0 && endFrequency > startFrequency, "need 0 < start < end frequency")
        precondition(endFrequency <= sampleRate / 2, "end frequency must not exceed Nyquist")
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.duration = duration
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    /// Explains why a combination of settings cannot make a sweep, or nil when it can.
    /// Check user input with this first: the initialiser traps on invalid values.
    public static func validationError(startFrequency: Double, endFrequency: Double, duration: Double,
                                       sampleRate: Double, amplitude: Double = 0.5) -> String? {
        if !(sampleRate > 0) { return "The sample rate must be above zero." }
        if !(startFrequency > 0) { return "The sweep must start above 0 Hz." }
        if !(endFrequency > startFrequency) { return "The sweep must end above its start frequency (\(Int(startFrequency)) Hz)." }
        if endFrequency > sampleRate / 2 {
            return "The sweep must end at or below half the sample rate (\(Int(sampleRate / 2)) Hz at \(Int(sampleRate)) Hz)."
        }
        if endFrequency / startFrequency < 2 { return "The sweep should cover at least an octave." }
        if !(duration >= 0.5) { return "The sweep should be at least 0.5 s long." }
        if !(amplitude > 0 && amplitude <= 1) { return "The sweep level must be between 0 dBFS and just above silence." }
        return nil
    }

    /// Time constant L = T / ln(f2 / f1).
    public var rate: Double { duration / log(endFrequency / startFrequency) }

    /// Instantaneous frequency at time t.
    public func frequency(at t: Double) -> Double { startFrequency * exp(t / rate) }

    /// Time at which the sweep passes frequency f.
    public func time(atFrequency f: Double) -> Double { rate * log(f / startFrequency) }

    /// The sweep samples, with `silence` seconds of zeros appended so the room's decay is recorded.
    public func samples(silence: Double = 0) -> [Double] {
        let n = Int((duration * sampleRate).rounded())
        let fadeInSamples = Int(fadeIn * sampleRate)
        let fadeOutSamples = Int(fadeOut * sampleRate)
        let l = rate
        var out = [Double](repeating: 0, count: n + Int((silence * sampleRate).rounded()))
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var x = amplitude * sin(2 * Double.pi * startFrequency * l * (exp(t / l) - 1))
            if i < fadeInSamples {
                x *= 0.5 * (1 - cos(Double.pi * Double(i) / Double(fadeInSamples)))
            }
            let fromEnd = n - 1 - i
            if fromEnd < fadeOutSamples {
                x *= 0.5 * (1 - cos(Double.pi * Double(fromEnd) / Double(fadeOutSamples)))
            }
            out[i] = x
        }
        return out
    }
}

/// Turns a recording into an impulse response by dividing its spectrum by the excitation's.
///
/// Works with any broadband excitation, not only sweeps: a generated sweep, a loopback recording
/// of the sweep (which also cancels the interface's latency), or an imported test signal.
public enum Deconvolution {
    /// - Parameters:
    ///   - recording: what the measurement mic captured.
    ///   - reference: the excitation, ideally the loopback recording of it.
    ///   - sampleRate: sample rate of both signals.
    ///   - band: frequency range the excitation covers. Outside it the result is suppressed
    ///     (Kirkeby regularisation) so noise is not amplified where the excitation has no energy.
    ///   - length: number of impulse response samples to return. Defaults to the recording length minus
    ///     the active length of the excitation (its length without trailing silence). Past that point a sweep
    ///     deconvolution has no recorded noise at high frequencies, which would fool the noise-floor estimate.
    public static func impulseResponse(recording: [Double], reference: [Double], sampleRate: Double,
                                       band: ClosedRange<Double>? = nil, length: Int? = nil) -> [Double] {
        let n = FFT.size(atLeast: recording.count + reference.count)
        let fft = FFT(size: n)
        let r = fft.forward(recording)
        let x = fft.forward(reference)
        let px = x.power
        let maxPower = px.max() ?? 1
        let freqs = fft.binFrequencies(sampleRate: sampleRate)

        var h = SplitComplex(count: r.count)
        for k in 0..<r.count {
            let inBand = band.map { $0.contains(freqs[k]) } ?? true
            let eps = maxPower * (inBand ? 1e-10 : 1.0)
            // H = R * conj(X) / (|X|^2 + eps)
            let denom = px[k] + eps
            h.real[k] = (r.real[k] * x.real[k] + r.imag[k] * x.imag[k]) / denom
            h.imag[k] = (r.imag[k] * x.real[k] - r.real[k] * x.imag[k]) / denom
        }
        let ir = fft.inverse(h)
        return Array(ir.prefix(length ?? defaultLength(recording: recording.count, reference: reference, sampleRate: sampleRate)))
    }

    static func defaultLength(recording: Int, reference: [Double], sampleRate: Double) -> Int {
        let usable = recording - activeLength(reference)
        return usable >= Int(0.1 * sampleRate) ? usable : recording
    }

    /// Length of `x` without trailing samples more than 80 dB below its peak.
    static func activeLength(_ x: [Double]) -> Int {
        let peak = x.map(abs).max() ?? 0
        guard peak > 0 else { return 0 }
        return (x.lastIndex { abs($0) > peak * 1e-4 } ?? -1) + 1
    }
}

/// Time alignment helpers.
public enum Delay {
    /// Delay of `signal` relative to `reference`, in samples (fractional, by parabolic interpolation
    /// of the cross-correlation peak). Positive means `signal` arrives later.
    public static func estimate(signal: [Double], reference: [Double]) -> Double {
        let n = FFT.size(atLeast: signal.count + reference.count)
        let fft = FFT(size: n)
        let s = fft.forward(signal)
        let r = fft.forward(reference)
        var c = SplitComplex(count: s.count)
        for k in 0..<s.count {
            c.real[k] = s.real[k] * r.real[k] + s.imag[k] * r.imag[k]
            c.imag[k] = s.imag[k] * r.real[k] - s.real[k] * r.imag[k]
        }
        let xcorr = fft.inverse(c)
        let peak = Peak.index(of: xcorr)
        // Lags past the middle of the buffer are negative (signal leads reference).
        return peak > Double(n / 2) ? peak - Double(n) : peak
    }
}

public enum Peak {
    /// Index of the largest |x|, refined to a fraction of a sample by fitting a parabola
    /// through the peak and its neighbours.
    public static func index(of x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        var best = 0
        for i in 1..<x.count where abs(x[i]) > abs(x[best]) { best = i }
        guard best > 0, best < x.count - 1 else { return Double(best) }
        let a = abs(x[best - 1]), b = abs(x[best]), c = abs(x[best + 1])
        let denom = a - 2 * b + c
        return denom == 0 ? Double(best) : Double(best) + 0.5 * (a - c) / denom
    }

    /// Index of the largest |x| to about a hundredth of a sample, for band-limited signals such as
    /// impulse responses. The 64 samples around the peak are upsampled 32 times (zero-padding their
    /// spectrum) before the parabola is fitted. A parabola through the raw samples of a band-limited
    /// pulse is off by up to 0.15 samples, which is 15 degrees of phase at 15 kHz at 48 kHz.
    public static func interpolatedIndex(of x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let coarse = Int(index(of: x).rounded())
        let n = 64, factor = 32
        let first = coarse - n / 2
        let segment = (0..<n).map { i -> Double in
            let j = first + i
            return j >= 0 && j < x.count ? x[j] : 0
        }
        let spectrum = FFT(size: n).forward(segment)
        let fine = FFT(size: n * factor)
        var padded = SplitComplex(count: n * factor / 2 + 1)
        for k in 0..<(n / 2) {
            padded.real[k] = spectrum.real[k] * Double(factor)
            padded.imag[k] = spectrum.imag[k] * Double(factor)
        }
        // The segment's Nyquist bin is shared between the positive and negative frequencies.
        padded.real[n / 2] = spectrum.real[n / 2] * Double(factor) / 2
        let upsampled = fine.inverse(padded)
        // Only the middle of the segment: its ends are spoilt by the circular wrap.
        let middle = Array(upsampled[(n / 4 * factor)..<(3 * n / 4 * factor)])
        return Double(first) + (Double(n / 4 * factor) + index(of: middle)) / Double(factor)
    }
}
