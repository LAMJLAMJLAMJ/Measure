import Foundation

/// Harmonic distortion from an exponential sweep measurement (Farina's method). Deconvolving the
/// recording against the sweep puts the impulse response of each harmonic before the linear one, at
/// L·ln(k) earlier for harmonic k (L is the sweep's rate). Windowed apart and transformed, each gives
/// that harmonic's level against frequency; with an exponential sweep no further correction is needed.
/// Harmonic k produced while the sweep plays f sounds at k·f, so it is read there and drawn at f.
public struct HarmonicDistortion: Codable, Hashable {
    /// Fundamental frequencies, Hz, log-spaced.
    public var frequencies: [Double]
    /// Level of the fundamental at each frequency, dB re the sweep's full scale (as the impulse response).
    public var fundamental: [Double]
    /// Level of harmonic 2, 3, … at each fundamental frequency, dB on the same scale. Nil where the
    /// harmonic is above the sweep's range, so it was not measured.
    public var harmonics: [[Double?]]
    /// The sweep's peak level, dBFS: distortion depends on how hard the system was driven.
    public var sweepLevel: Double?

    public init(frequencies: [Double], fundamental: [Double], harmonics: [[Double?]], sweepLevel: Double? = nil) {
        self.frequencies = frequencies
        self.fundamental = fundamental
        self.harmonics = harmonics
        self.sweepLevel = sweepLevel
    }

    /// The highest harmonic, 2 or more.
    public var highestOrder: Int { harmonics.count + 1 }

    /// Total harmonic distortion at point `i` from the harmonics given (dB each), as a ratio to the
    /// fundamental: the root of their summed power over the fundamental's. Nil when none was measured.
    public static func thd(fundamental: Double, harmonics: [Double?]) -> Double? {
        let measured = harmonics.compactMap { $0 }
        guard !measured.isEmpty else { return nil }
        let power = measured.reduce(0) { $0 + pow(10, $1 / 10) }
        return (power / pow(10, fundamental / 10)).squareRoot()
    }

    /// THD at point `i` as a ratio (0.01 is 1 %).
    public func thd(_ i: Int) -> Double? {
        HarmonicDistortion.thd(fundamental: fundamental[i], harmonics: harmonics.map { $0[i] })
    }

    /// Separates the harmonics in `impulseResponse`, the whole (circular) result of deconvolving a
    /// recording against `sweep`, with the linear response's peak near its start and the harmonics
    /// wrapped round to its end. Nil when the sweep is too short to keep the harmonics apart.
    /// - Parameters:
    ///   - maxOrder: the highest harmonic, 2 to 9.
    ///   - smoothing: fractional-octave smoothing of each harmonic's spectrum.
    public static func analyze(impulseResponse h: [Double], sweep: ExponentialSweep, maxOrder: Int = 5,
                               pointsPerOctave: Int = 12, smoothing: Double = 6) -> HarmonicDistortion? {
        let n = h.count
        let fs = sweep.sampleRate
        let order = min(max(maxOrder, 2), 9)
        guard n > 0, let peak = h.indices.max(by: { abs(h[$0]) < abs(h[$1]) }) else { return nil }
        let rate = sweep.rate
        // Each harmonic's window ends half way to the next one up the time axis (the next lower order),
        // and every window is that long, the fundamental's too, so they take in the same reflections.
        let gap = rate * log(Double(order) / Double(order - 1))
        let post = Int((0.5 * gap * fs).rounded(.down))
        let pre = max(1, min(Int((0.002 * fs).rounded()), post / 4))
        guard post >= Int(0.005 * fs), Double(post + pre) * 2 < Double(n) else { return nil }
        let fftSize = FFT.size(atLeast: max(post + pre, Int(fs)))

        func spectrum(_ k: Int) -> FrequencyResponse {
            let shift = Int((rate * log(Double(k)) * fs).rounded())
            let centre = ((peak - shift) % n + n) % n
            var x = [Double](repeating: 0, count: pre + post)
            for j in 0..<(pre + post) {
                let index = ((centre - pre + j) % n + n) % n
                // Half-Hann fade in over the pre-roll, flat, then a half-Hann fade out over the last quarter.
                var w = 1.0
                if j < pre { w = 0.5 * (1 - cos(Double.pi * Double(j) / Double(pre))) }
                let fadeStart = pre + post * 3 / 4
                if j >= fadeStart {
                    let t = Double(j - fadeStart) / Double(max(pre + post - fadeStart, 1))
                    w = 0.5 * (1 + cos(Double.pi * t))
                }
                x[j] = h[index] * w
            }
            return FrequencyResponse(impulseResponse: x, sampleRate: fs, fftSize: fftSize).smoothed(fraction: smoothing)
        }

        // The window's length limits the lowest frequency it resolves: about two periods.
        let low = max(sweep.startFrequency, 2 * fs / Double(post + pre))
        let top = min(sweep.endFrequency, 0.45 * fs)
        guard top > low * 1.1 else { return nil }
        var frequencies: [Double] = []
        var f = low
        while f <= top {
            frequencies.append(f)
            f *= pow(2, 1 / Double(pointsPerOctave))
        }
        let linear = spectrum(1)
        let fundamental = frequencies.map { linear.magnitude(at: $0) }
        // Harmonics stop a smoothing width short of the top: near the sweep's end its fade and the
        // deconvolution's band edge smear energy through every window, which reads as a false harmonic.
        let harmonicTop = top / pow(2, 1 / smoothing)
        var harmonics: [[Double?]] = []
        for k in 2...order {
            let s = spectrum(k)
            harmonics.append(frequencies.map { f -> Double? in
                Double(k) * f <= harmonicTop ? s.magnitude(at: Double(k) * f) : nil
            })
        }
        return HarmonicDistortion(frequencies: frequencies, fundamental: fundamental, harmonics: harmonics,
                                  sweepLevel: 20 * log10(max(sweep.amplitude, 1e-10)))
    }
}
