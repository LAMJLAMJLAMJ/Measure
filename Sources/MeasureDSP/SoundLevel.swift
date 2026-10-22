import Foundation

/// Sound level meter functions for plain recordings: frequency and time weighting, equivalent,
/// maximum and statistical levels, and octave band levels.
///
/// Levels are 10·log10 of the mean square plus `offset`, so with `offset` = 0 they are relative to a
/// full-scale square wave (a full-scale sine reads −3 dB). A mic calibration supplies the offset that
/// turns them into dB SPL.
public enum SoundLevel {
    public enum FrequencyWeighting: String, CaseIterable, Identifiable, Codable {
        case a = "A", c = "C", z = "Z"
        public var id: String { rawValue }
    }

    public enum TimeWeighting: String, CaseIterable, Identifiable, Codable {
        case fast = "Fast", slow = "Slow"
        public var id: String { rawValue }
        /// Time constant, seconds.
        public var tau: Double { self == .fast ? 0.125 : 1 }
    }

    /// A and C weighting (IEC 61672-1): the analogue poles mapped by the bilinear transform, followed by
    /// a short linear-phase FIR that corrects the transform's high-frequency warping. Within 0.1 dB of
    /// the standard's curves from 10 Hz to 16 kHz at 48 kHz.
    public struct WeightingFilter {
        /// First-order sections (1 − zero·z⁻¹) / (1 − pole·z⁻¹).
        let sections: [(zero: Double, pole: Double)]
        /// High-frequency correction, empty for Z.
        let correction: [Double]
        let gain: Double

        static let f1 = 20.598997, f2 = 107.65265, f3 = 737.86223, f4 = 12194.217

        public init(_ weighting: FrequencyWeighting, sampleRate fs: Double) {
            let f1 = WeightingFilter.f1, f2 = WeightingFilter.f2, f3 = WeightingFilter.f3, f4 = WeightingFilter.f4
            func pole(_ f: Double) -> Double {
                let p = -2 * Double.pi * f / (2 * fs)
                return (1 + p) / (1 - p)
            }
            switch weighting {
            case .a:
                sections = [(1, pole(f1)), (1, pole(f1)), (1, pole(f2)), (1, pole(f3)), (-1, pole(f4)), (-1, pole(f4))]
            case .c:
                sections = [(1, pole(f1)), (1, pole(f1)), (-1, pole(f4)), (-1, pole(f4))]
            case .z:
                sections = []
            }
            let iir = sections
            func digital(_ f: Double) -> Double {
                let w = 2 * Double.pi * f / fs
                return iir.reduce(1) { $0 * WeightingFilter.magnitude(zero: $1.zero, pole: $1.pole, w: w) }
            }

            // Frequency-sampling design of the correction: the ratio of the analogue to the digital
            // response, Hann-windowed so it does not ripple. The ratio is held at its 20 kHz value
            // above 20 kHz (and capped at +12 dB), where the digital response falls to zero, and DC
            // takes the next bin's value so the low end stays flat.
            var taps: [Double] = []
            if weighting != .z {
                let n = 63, grid = 1024
                let hold = min(20_000, fs / 2)
                func ratio(_ k: Int) -> Double {
                    let f = min(Double(max(k, 1)) * fs / Double(grid), hold)
                    let d = digital(f)
                    return d > 1e-9 ? min(4, WeightingFilter.analogue(weighting, f) / d) : 4
                }
                let r = (0...grid / 2).map(ratio)
                let c = Double(n - 1) / 2
                taps = (0..<n).map { i in
                    var sum = r[0] + r[grid / 2] * cos(Double.pi * (Double(i) - c))
                    for k in 1..<(grid / 2) {
                        sum += 2 * r[k] * cos(2 * Double.pi * Double(k) * (Double(i) - c) / Double(grid))
                    }
                    let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i + 1) / Double(n + 1))
                    return sum / Double(grid) * window
                }
            }
            correction = taps
            // 0 dB at 1 kHz, as the standard defines.
            gain = 1 / (digital(1000) * WeightingFilter.firMagnitude(taps, f: 1000, sampleRate: fs))
        }

        /// The standard's analogue response, relative (not yet 0 dB at 1 kHz).
        static func analogue(_ weighting: FrequencyWeighting, _ f: Double) -> Double {
            let s = f * f
            switch weighting {
            case .a: return f4 * f4 * s * s / ((s + f1 * f1) * sqrt((s + f2 * f2) * (s + f3 * f3)) * (s + f4 * f4))
            case .c: return f4 * f4 * s / ((s + f1 * f1) * (s + f4 * f4))
            case .z: return 1
            }
        }

        static func magnitude(zero: Double, pole: Double, w: Double) -> Double {
            let num = hypot(1 - zero * cos(w), zero * sin(w))
            let den = hypot(1 - pole * cos(w), pole * sin(w))
            return num / den
        }

        static func firMagnitude(_ taps: [Double], f: Double, sampleRate fs: Double) -> Double {
            guard !taps.isEmpty else { return 1 }
            let w = 2 * Double.pi * f / fs
            var re = 0.0, im = 0.0
            for (n, h) in taps.enumerated() {
                re += h * cos(w * Double(n))
                im -= h * sin(w * Double(n))
            }
            return hypot(re, im)
        }

        /// Gain in dB at frequency `f`.
        public func gainDB(at f: Double, sampleRate fs: Double) -> Double {
            let w = 2 * Double.pi * f / fs
            var g = gain * WeightingFilter.firMagnitude(correction, f: f, sampleRate: fs)
            for s in sections { g *= WeightingFilter.magnitude(zero: s.zero, pole: s.pole, w: w) }
            return 20 * log10(g)
        }

        public func apply(_ x: [Double]) -> [Double] {
            var y = x.map { $0 * gain }
            for s in sections {
                var x1 = 0.0, y1 = 0.0
                for i in y.indices {
                    let v = y[i] - s.zero * x1 + s.pole * y1
                    x1 = y[i]
                    y1 = v
                    y[i] = v
                }
            }
            guard !correction.isEmpty else { return y }
            var out = [Double](repeating: 0, count: y.count)
            for i in y.indices {
                var acc = 0.0
                for (n, h) in correction.enumerated() where i >= n { acc += h * y[i - n] }
                out[i] = acc
            }
            return out
        }
    }

    public struct Result {
        public let weighting: FrequencyWeighting
        public let timeWeighting: TimeWeighting
        public let duration: Double
        public let leq: Double
        public let lmax: Double
        public let lmin: Double
        /// Levels exceeded for 1, 5, 10, 50, 90 and 95 % of the time (from the time-weighted level).
        public let percentiles: [(n: Int, level: Double)]
        /// Time-weighted level every `historyStep` seconds.
        public let history: [Double]
        public let historyStep: Double

        public func l(_ n: Int) -> Double? { percentiles.first { $0.n == n }?.level }
    }

    /// - Parameters:
    ///   - offset: dB added to every level (the mic's calibration), 0 for levels re full scale.
    ///   - historyStep: seconds between points of the level history and the statistics.
    public static func analyze(_ x: [Double], sampleRate fs: Double, weighting: FrequencyWeighting,
                               timeWeighting: TimeWeighting, offset: Double = 0, historyStep: Double = 0.01) -> Result {
        let y = WeightingFilter(weighting, sampleRate: fs).apply(x)
        func db(_ ms: Double) -> Double { 10 * log10(max(ms, 1e-30)) + offset }

        let leq = db(y.reduce(0) { $0 + $1 * $1 } / Double(max(1, y.count)))
        let k = 1 - exp(-1 / (timeWeighting.tau * fs))
        let step = max(1, Int(historyStep * fs))
        // Start the exponential average at the mean square of the first time constant rather than at
        // zero, so the start of the recording does not read as a quiet spell.
        let first = y.prefix(max(1, Int(timeWeighting.tau * fs)))
        var state = first.reduce(0) { $0 + $1 * $1 } / Double(max(1, first.count))
        var history: [Double] = []
        history.reserveCapacity(y.count / step)
        // Track the extremes as mean squares and convert once: a logarithm per sample is slow on long recordings.
        var maxMS = 0.0, minMS = Double.infinity
        for (i, v) in y.enumerated() {
            state += (v * v - state) * k
            maxMS = max(maxMS, state)
            minMS = min(minMS, state)
            if i % step == step - 1 { history.append(db(state)) }
        }
        let lmax = y.isEmpty ? -Double.infinity : db(maxMS)
        let lmin = y.isEmpty ? Double.infinity : db(minMS)
        let sorted = history.sorted()
        let percentiles = [1, 5, 10, 50, 90, 95].map { n -> (n: Int, level: Double) in
            guard !sorted.isEmpty else { return (n, -.infinity) }
            // Ln is exceeded n % of the time: the (100 − n)th percentile.
            let index = min(sorted.count - 1, max(0, Int((Double(100 - n) / 100 * Double(sorted.count - 1)).rounded())))
            return (n, sorted[index])
        }
        return Result(weighting: weighting, timeWeighting: timeWeighting, duration: Double(x.count) / fs,
                      leq: leq, lmax: lmax.isFinite ? lmax : leq, lmin: lmin.isFinite ? lmin : leq,
                      percentiles: percentiles, history: history, historyStep: Double(step) / fs)
    }

    /// Unweighted Leq per octave band, for the given nominal bands, in dB (plus `offset`).
    public static func octaveLevels(_ x: [Double], sampleRate fs: Double,
                                    bands: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000],
                                    offset: Double = 0) -> [(band: Double, level: Double)] {
        bands.compactMap { nominal in
            let band = BandResolution.octave.band(nominal: nominal)
            guard band.upper < fs / 2 else { return nil }
            let y = BandPassFilter(band: band, sampleRate: fs).apply(x)
            let ms = y.reduce(0) { $0 + $1 * $1 } / Double(max(1, y.count))
            return (nominal, 10 * log10(max(ms, 1e-30)) + offset)
        }
    }
}

/// Noise rating curves for octave band background noise levels.
public enum NoiseRating {
    /// NR curves (ISO R 1996:1971): L = a + b·NR in each octave band, 31.5 Hz to 8 kHz.
    public static let nrBands: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000]
    static let nrA: [Double] = [55.4, 35.5, 22.0, 12.0, 4.8, 0, -3.5, -6.1, -8.0]
    static let nrB: [Double] = [0.681, 0.790, 0.870, 0.930, 0.974, 1.000, 1.015, 1.025, 1.030]

    /// Level of the NR curve `nr` in each of `nrBands`.
    public static func nrCurve(_ nr: Double) -> [Double] { zip(nrA, nrB).map { $0 + $1 * nr } }

    /// NR of a spectrum: the highest NR value any band reaches. Bands not in `nrBands` are ignored.
    public static func nr(_ levels: [(band: Double, level: Double)]) -> Double? {
        let values = levels.compactMap { item -> Double? in
            guard let k = nrBands.firstIndex(of: item.band) else { return nil }
            return (item.level - nrA[k]) / nrB[k]
        }
        return values.max()
    }

    /// NC curves (Beranek, 1957) from NC 15 to NC 70 in octave bands 63 Hz to 8 kHz.
    public static let ncBands: [Double] = [63, 125, 250, 500, 1000, 2000, 4000, 8000]
    public static let ncCurves: [(nc: Double, levels: [Double])] = [
        (15, [47, 36, 29, 22, 17, 14, 12, 11]),
        (20, [51, 40, 33, 26, 22, 19, 17, 16]),
        (25, [54, 44, 37, 31, 27, 24, 22, 21]),
        (30, [57, 48, 41, 35, 31, 29, 28, 27]),
        (35, [60, 52, 45, 40, 36, 34, 33, 32]),
        (40, [64, 56, 50, 45, 41, 39, 38, 37]),
        (45, [67, 60, 54, 49, 46, 44, 43, 42]),
        (50, [71, 64, 58, 54, 51, 49, 48, 47]),
        (55, [74, 67, 62, 58, 56, 54, 53, 52]),
        (60, [77, 71, 67, 63, 61, 59, 58, 57]),
        (65, [80, 75, 71, 68, 66, 64, 63, 62]),
        (70, [83, 79, 75, 72, 71, 70, 69, 68]),
    ]

    /// NC of one band level: interpolated between the tabulated curves, extrapolated beyond them.
    static func nc(band k: Int, level: Double) -> Double {
        let curves = ncCurves
        for i in 0..<(curves.count - 1) {
            let lo = curves[i], hi = curves[i + 1]
            if level <= hi.levels[k] || i == curves.count - 2 {
                let t = (level - lo.levels[k]) / (hi.levels[k] - lo.levels[k])
                return lo.nc + t * (hi.nc - lo.nc)
            }
        }
        return curves.last!.nc
    }

    /// NC of a spectrum (tangency method): the highest NC any band reaches.
    public static func nc(_ levels: [(band: Double, level: Double)]) -> Double? {
        let values = levels.compactMap { item -> Double? in
            guard let k = ncBands.firstIndex(of: item.band) else { return nil }
            return nc(band: k, level: item.level)
        }
        return values.max()
    }

    /// Level of an NC curve in each of `ncBands`, interpolating between tabulated curves.
    public static func ncCurve(_ nc: Double) -> [Double] {
        let curves = ncCurves
        let i = min(curves.count - 2, max(0, curves.lastIndex { $0.nc <= nc } ?? 0))
        let lo = curves[i], hi = curves[i + 1]
        let t = (nc - lo.nc) / (hi.nc - lo.nc)
        return zip(lo.levels, hi.levels).map { $0 + t * ($1 - $0) }
    }
}
