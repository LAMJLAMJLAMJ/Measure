import Foundation

/// A test signal for the signal generator: one period of it, played in a loop. Every kind is scaled to
/// an RMS of 1 (0 dBFS RMS), so a gain in dB sets its RMS level re full scale directly; its peak is
/// `crestFactor` dB higher.
public struct TestSignal: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case pink = "Pink noise"
        case white = "White noise"
        case sine = "Sine"
        case sweep = "Sweep"
        /// A short positive-going pulse, repeated: a polarity checker shows which way each driver moves.
        case polarity = "Polarity pulse"
        public var id: String { rawValue }
    }

    public var kind: Kind
    /// Sine frequency, Hz. Rounded so a whole number of cycles fits the loop.
    public var frequency: Double
    /// Band of the noise and range of the sweep, Hz.
    public var low: Double
    public var high: Double
    /// Seconds of each sweep, and of the silence after it.
    public var sweepDuration: Double
    public var sweepGap: Double
    /// Seconds between polarity pulses.
    public var pulseInterval: Double

    public init(kind: Kind = .pink, frequency: Double = 1000, low: Double = 20, high: Double = 20_000,
                sweepDuration: Double = 2, sweepGap: Double = 0.5, pulseInterval: Double = 0.5) {
        self.kind = kind
        self.frequency = frequency
        self.low = low
        self.high = high
        self.sweepDuration = sweepDuration
        self.sweepGap = sweepGap
        self.pulseInterval = pulseInterval
    }

    /// The sine frequency actually played at `sampleRate`: the nearest whole number of hertz, so it
    /// loops without a click, kept between 1 Hz and just under half the sample rate.
    public func sineFrequency(sampleRate fs: Double) -> Double {
        min(max(frequency.rounded(), 1), (fs / 2 - 1).rounded(.down))
    }

    /// The band actually used at `sampleRate`: within 1 Hz and just under half the sample rate, at least
    /// a tenth of an octave wide.
    public func band(sampleRate fs: Double) -> (low: Double, high: Double) {
        let top = 0.49 * fs
        let lo = min(max(low, 1), top / 1.08)
        let hi = min(max(high, lo * 1.08), top)
        return (lo, hi)
    }

    /// One period of the signal at `sampleRate`, with an RMS of 1.
    public func samples(sampleRate fs: Double) -> [Double] {
        let x: [Double]
        let (lo, hi) = band(sampleRate: fs)
        switch kind {
        case .pink:
            x = PinkNoise.periodic(count: 1 << 18, sampleRate: fs, low: lo, high: hi)
        case .white:
            x = PinkNoise.periodic(count: 1 << 18, sampleRate: fs, low: lo, high: hi, white: true)
        case .sine:
            // One second holds a whole number of cycles of a whole-hertz tone.
            let n = Int(fs.rounded())
            let f = sineFrequency(sampleRate: fs)
            x = (0..<n).map { sin(2 * Double.pi * f * Double($0) / Double(n)) }
        case .sweep:
            let duration = min(max(sweepDuration, 0.5), 30)
            let end = max(hi, lo * 2.01)
            let sweep = ExponentialSweep(startFrequency: lo, endFrequency: min(end, fs / 2), duration: duration,
                                         sampleRate: fs, amplitude: 1, fadeIn: 0.02, fadeOut: 0.01)
            x = sweep.samples(silence: min(max(sweepGap, 0), 10))
        case .polarity:
            // A raised-cosine bump 1 ms wide: all positive, so a speaker moving the right way pushes first.
            let n = max(Int((min(max(pulseInterval, 0.05), 5) * fs).rounded()), 2)
            let width = max(Int((0.001 * fs).rounded()), 2)
            var pulse = [Double](repeating: 0, count: n)
            for i in 0..<min(width, n) {
                pulse[i] = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(width)))
            }
            x = pulse
        }
        let ms = x.reduce(0) { $0 + $1 * $1 } / Double(max(x.count, 1))
        guard ms > 0 else { return x }
        let scale = 1 / ms.squareRoot()
        return x.map { $0 * scale }
    }

    /// Peak over RMS of `x`, dB.
    public static func crestFactor(_ x: [Double]) -> Double {
        let ms = x.reduce(0) { $0 + $1 * $1 } / Double(max(x.count, 1))
        let peak = x.map(abs).max() ?? 0
        guard ms > 0, peak > 0 else { return 0 }
        return 20 * log10(peak / ms.squareRoot())
    }
}

/// Levels of a stretch of signal, for meters: RMS and peak re full scale, in dB.
public enum SignalLevel {
    public static func rms(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return -200 }
        let ms = x.reduce(0) { $0 + $1 * $1 } / Double(x.count)
        return 10 * log10(max(ms, 1e-20))
    }

    public static func peak(_ x: [Double]) -> Double {
        let p = x.map(abs).max() ?? 0
        return 20 * log10(max(p, 1e-10))
    }
}
