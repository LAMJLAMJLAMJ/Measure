import Foundation

/// Echo criterion after Dietsch and Kraak (Acustica 60, 1986).
///
/// The build-up of the centre time t_S(τ) = Σ t|p(t)|ⁿ / Σ |p(t)|ⁿ over 0…τ from the direct sound is
/// differenced over Δτ_E: EK(τ) = (t_S(τ) − t_S(τ − Δτ_E)) / Δτ_E. A peak of EK above the limit for the
/// programme means an echo is likely to be heard by that share of listeners.
public enum EchoCriterion {
    public enum Programme: String, CaseIterable, Identifiable {
        case speech = "Speech"
        case music = "Music"
        public var id: String { rawValue }

        /// Exponent n applied to |p(t)|.
        public var exponent: Double { self == .speech ? 2.0 / 3.0 : 1 }
        /// Difference interval Δτ_E in seconds.
        public var interval: Double { self == .speech ? 0.009 : 0.014 }
        /// EK above which 50 % of listeners hear an echo.
        public var limit50: Double { self == .speech ? 1.0 : 1.8 }
        /// EK above which 10 % of listeners hear an echo.
        public var limit10: Double { self == .speech ? 0.9 : 1.5 }
    }

    public struct Result {
        public let programme: Programme
        /// Seconds from the direct sound.
        public let times: [Double]
        public let ek: [Double]
        public let maxEK: Double
        /// Seconds from the direct sound to the largest EK.
        public let timeOfMax: Double

        /// Share of listeners likely to hear an echo: 50, 10 or 0 (%).
        public var audibleShare: Int {
            maxEK > programme.limit50 ? 50 : maxEK > programme.limit10 ? 10 : 0
        }
    }

    /// - Parameters:
    ///   - ir: impulse response, already band filtered if wanted (Dietsch and Kraak use the 1 kHz octave).
    ///   - onset: index of the direct sound.
    ///   - duration: seconds after the direct sound to analyse.
    ///   - step: seconds between output points. Each point keeps the largest EK in its step so peaks survive.
    public static func analyze(_ ir: [Double], sampleRate fs: Double, onset: Int, programme: Programme,
                               duration: Double = 1, step: Double = 0.001) -> Result {
        let start = min(max(0, onset), ir.count)
        let end = min(ir.count, start + Int(duration * fs))
        let n = programme.exponent
        let d = max(1, Int((programme.interval * fs).rounded()))
        let stepN = max(1, Int((step * fs).rounded()))

        // Running sums give t_S at every sample.
        var weighted = 0.0, total = 0.0
        var ts = [Double](repeating: 0, count: end - start)
        for i in start..<end {
            let w = pow(abs(ir[i]), n)
            let t = Double(i - start) / fs
            weighted += t * w
            total += w
            ts[i - start] = total > 0 ? weighted / total : 0
        }

        var times: [Double] = [], ek: [Double] = []
        var maxEK = 0.0, timeOfMax = 0.0
        var k = d
        while k < ts.count {
            var bucketMax = -Double.infinity, bucketTime = 0.0
            for i in k..<min(ts.count, k + stepN) {
                let v = (ts[i] - ts[i - d]) / (Double(d) / fs)
                if v > bucketMax { bucketMax = v; bucketTime = Double(i) / fs }
            }
            times.append(Double(k) / fs)
            ek.append(bucketMax)
            if bucketMax > maxEK { maxEK = bucketMax; timeOfMax = bucketTime }
            k += stepN
        }
        return Result(programme: programme, times: times, ek: ek, maxEK: maxEK, timeOfMax: timeOfMax)
    }
}
