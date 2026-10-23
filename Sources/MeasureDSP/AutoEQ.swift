import Foundation

/// Finds parametric filters that bring a measured response close to a target curve: a starting point
/// for tuning, to be checked by ear and by measurement, not a replacement for either.
///
/// The fit is greedy. Each step adds the filter (a peak at the largest deviation, or a shelf at either
/// end) that lowers the RMS deviation most, then refines every filter it has added together by a
/// pattern search on frequency, gain and Q. It stops at the filter limit, when the deviation is under
/// half a decibel, or when another filter would help by less than 0.05 dB. Boosts are limited
/// separately from cuts, because a dip is often a cancellation that boosting cannot fill.
public enum AutoEQ {
    public struct Settings: Codable, Hashable {
        /// Most filters to add.
        public var maxFilters: Int
        /// Largest boost and largest cut of any filter, dB (both positive).
        public var maxBoost: Double
        public var maxCut: Double
        /// Narrowest peak allowed. The widest is Q 0.5.
        public var maxQ: Double
        /// Allow a low shelf and a high shelf at the ends of the range.
        public var shelves: Bool
        /// Fractional-octave smoothing of the response before fitting, as 1/`smoothing` octave.
        public var smoothing: Double

        public init(maxFilters: Int = 8, maxBoost: Double = 3, maxCut: Double = 12, maxQ: Double = 6,
                    shelves: Bool = true, smoothing: Double = 6) {
            self.maxFilters = maxFilters
            self.maxBoost = maxBoost
            self.maxCut = maxCut
            self.maxQ = maxQ
            self.shelves = shelves
            self.smoothing = smoothing
        }
    }

    public struct Result {
        /// The filters added, from low to high frequency.
        public var filters: [EQFilter]
        /// RMS deviation from the aligned target over its range, dB, with only the filters kept
        /// (`fixed`), and with the new ones too.
        public var rmsBefore: Double
        public var rmsAfter: Double
    }

    /// Fits filters to `response` so that, with `fixed` (filters already chosen by hand, left as they
    /// are) and the new filters, it follows `target` over the target's range.
    /// - Parameters:
    ///   - response: the measured response, with the mic calibration already applied. It is smoothed
    ///     here to 1/`settings.smoothing` octave.
    ///   - alignment: dB added to the target so it sits on the response, from `TargetCurve.alignment(to:)`.
    ///   - sampleRate: the rate the filters are designed at, as on the processor.
    public static func fit(response: FrequencyResponse, target: TargetCurve, alignment: Double,
                           fixed: [EQFilter] = [], settings: Settings = Settings(), sampleRate fs: Double) -> Result {
        let smoothed = response.smoothed(fraction: max(settings.smoothing, 1))
        let low = max(target.low, response.frequencies.first ?? target.low)
        let high = min(target.high, response.frequencies.last ?? target.high, 0.45 * fs)
        let f = TargetCurve.grid(low: low, high: high, perOctave: 24)
        // What the new filters have to correct: positive where the response is above the target.
        let base = f.map { smoothed.magnitude(at: $0) + ParametricEQ.gainDB(fixed, at: $0, sampleRate: fs)
            - target.level(at: $0) - alignment }
        var fitter = Fitter(frequencies: f, base: base, sampleRate: fs, settings: settings, low: low, high: high)
        let before = fitter.rms

        while fitter.filters.count < max(0, settings.maxFilters) && fitter.rms > 0.5 {
            let previous = fitter.rms
            var best: Fitter?
            for candidate in fitter.candidates() {
                var trial = fitter
                trial.append(candidate)
                trial.optimise(only: [trial.filters.count - 1], sweeps: 40)
                if best == nil || trial.cost < best!.cost { best = trial }
            }
            guard var next = best else { break }
            next.optimise(only: Array(next.filters.indices), sweeps: 60)
            if previous - next.rms < 0.05 { break }
            fitter = next
        }
        // A filter left with almost no gain does nothing worth typing in.
        let kept = fitter.filters.filter { abs($0.gain) >= 0.3 }
        let after = Fitter.rms(base, f.indices.map { i in kept.reduce(0) { $0 + $1.gainDB(at: f[i], sampleRate: fs) } })
        return Result(filters: kept.sorted { $0.frequency < $1.frequency }, rmsBefore: before, rmsAfter: after)
    }

    /// The working state of a fit: the filters so far and each one's gain on the grid.
    struct Fitter {
        let frequencies: [Double]
        let base: [Double]
        let sampleRate: Double
        let settings: Settings
        let low: Double
        let high: Double
        private(set) var filters: [EQFilter] = []
        private var gains: [[Double]] = []
        private var total: [Double]

        init(frequencies: [Double], base: [Double], sampleRate: Double, settings: Settings, low: Double, high: Double) {
            self.frequencies = frequencies
            self.base = base
            self.sampleRate = sampleRate
            self.settings = settings
            self.low = low
            self.high = high
            total = [Double](repeating: 0, count: frequencies.count)
        }

        var cost: Double {
            var sum = 0.0
            for i in base.indices { let r = base[i] + total[i]; sum += r * r }
            return base.isEmpty ? 0 : sum / Double(base.count)
        }

        var rms: Double { cost.squareRoot() }

        static func rms(_ base: [Double], _ eq: [Double]) -> Double {
            guard !base.isEmpty else { return 0 }
            return (zip(base, eq).reduce(0) { $0 + ($1.0 + $1.1) * ($1.0 + $1.1) } / Double(base.count)).squareRoot()
        }

        func curve(_ filter: EQFilter) -> [Double] {
            let b = filter.biquad(sampleRate: sampleRate)
            return frequencies.map { f in
                let r = b.response(at: 2 * Double.pi * f / sampleRate)
                return 10 * log10(max(r.re * r.re + r.im * r.im, 1e-30))
            }
        }

        mutating func append(_ filter: EQFilter) {
            let g = curve(filter)
            filters.append(filter)
            gains.append(g)
            for i in total.indices { total[i] += g[i] }
        }

        private mutating func replace(_ k: Int, with filter: EQFilter, gains g: [Double]) {
            for i in total.indices { total[i] += g[i] - gains[k][i] }
            filters[k] = filter
            gains[k] = g
        }

        private func cost(replacing k: Int, with g: [Double]) -> Double {
            var sum = 0.0
            for i in base.indices {
                let r = base[i] + total[i] - gains[k][i] + g[i]
                sum += r * r
            }
            return sum / Double(base.count)
        }

        /// Starting filters for the next step: a peak on the largest deviation, and a shelf at each end
        /// that has none yet.
        func candidates() -> [EQFilter] {
            let residual = base.indices.map { base[$0] + total[$0] }
            var out: [EQFilter] = []
            if let peak = peakCandidate(residual) { out.append(peak) }
            if settings.shelves {
                let ends: [(EQFilter.Kind, Double, ClosedRange<Double>)] = [
                    (.lowShelf, low * 2, low...(low * 2)), (.highShelf, high / 2, (high / 2)...high),
                ]
                for (kind, f0, band) in ends where !filters.contains(where: { $0.kind == kind }) {
                    let r = frequencies.indices.filter { band.contains(frequencies[$0]) }.map { residual[$0] }
                    guard !r.isEmpty else { continue }
                    let mean = r.reduce(0, +) / Double(r.count)
                    out.append(clamp(EQFilter(kind: kind, frequency: f0, gain: -mean, q: 0.707)))
                }
            }
            return out
        }

        /// A peak centred on the largest deviation, as wide as the stretch around it that is at least half
        /// as large.
        private func peakCandidate(_ r: [Double]) -> EQFilter? {
            // A boost can only go so far, so weigh dips by what a filter could do about them.
            func reach(_ x: Double) -> Double { x > 0 ? min(x, settings.maxCut) : min(-x, settings.maxBoost) }
            guard let i = r.indices.max(by: { reach(r[$0]) < reach(r[$1]) }), reach(r[i]) > 0.3 else { return nil }
            let half = r[i] / 2
            var lo = i, hi = i
            while lo > 0 && r[lo - 1] * r[i] > 0 && abs(r[lo - 1]) >= abs(half) { lo -= 1 }
            while hi < r.count - 1 && r[hi + 1] * r[i] > 0 && abs(r[hi + 1]) >= abs(half) { hi += 1 }
            let octaves = max(log2(frequencies[hi] / frequencies[lo]), 1.0 / 12)
            let ratio = pow(2, octaves)
            let q = ratio.squareRoot() / (ratio - 1)
            return clamp(EQFilter(kind: .peak, frequency: frequencies[i], gain: -r[i], q: q))
        }

        /// Keeps a filter within the settings: gain, Q, and a frequency inside the range (shelves may sit
        /// up to an octave outside it).
        func clamp(_ filter: EQFilter) -> EQFilter {
            var f = filter
            let shelf = f.kind == .lowShelf || f.kind == .highShelf
            let lo = shelf ? low / 2 : low, hi = min(shelf ? high * 2 : high, 0.45 * sampleRate)
            f.frequency = min(max(f.frequency, lo), hi)
            f.gain = min(max(f.gain, -settings.maxCut), settings.maxBoost)
            f.q = shelf ? min(max(f.q, 0.5), 1) : min(max(f.q, 0.5), max(settings.maxQ, 0.5))
            return f
        }

        /// Pattern search over the chosen filters' frequency (in octaves), gain and Q (in octaves): try a
        /// step either way on each, keep what lowers the cost, and halve the steps when nothing does.
        mutating func optimise(only indices: [Int], sweeps: Int) {
            var steps = [1.0 / 6, 1.0, 0.25]
            for _ in 0..<sweeps {
                var improved = false
                for k in indices {
                    for p in 0..<3 {
                        var current = cost
                        for sign in [1.0, -1.0] {
                            var trial = filters[k]
                            switch p {
                            case 0: trial.frequency *= pow(2, sign * steps[0])
                            case 1: trial.gain += sign * steps[1]
                            default: trial.q *= pow(2, sign * steps[2])
                            }
                            trial = clamp(trial)
                            if trial == filters[k] { continue }
                            let g = curve(trial)
                            let c = cost(replacing: k, with: g)
                            if c < current - 1e-9 {
                                replace(k, with: trial, gains: g)
                                current = c
                                improved = true
                                break
                            }
                        }
                    }
                }
                if !improved {
                    steps = steps.map { $0 / 2 }
                    if steps[1] < 0.02 { break }
                }
            }
        }
    }
}
