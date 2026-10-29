import Foundation

/// Finds parametric filters that bring a measured response close to a target curve: a starting point
/// for tuning, to be checked by ear and by measurement, not a replacement for either.
///
/// The fit is greedy. Each step tries a peak on each of the largest deviations (and a shelf at either
/// end), adds the one that helps most, then refines every filter it has added together by a pattern
/// search on frequency, gain and Q. What it minimises is the squared deviation from the target, with
/// anything more than `peakAllowance` above the target (or above the target's tolerance band) counted
/// `peakWeight` times over: peaks are heard, and dips are often cancellations that boosting cannot fill.
/// So the fit keeps the response under the band first and accepts a deeper dip to do it. Boosts are
/// limited separately from cuts, kept broad, and limited in total; two filters of the same sign are
/// not started on the same spot. It stops at the filter limit, when the response is within half a
/// decibel RMS and nowhere above the allowance, or when another filter would help by less than 0.05 dB.
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
        /// Largest boost of all the new filters together at any frequency, dB. Nil in `init` uses `maxBoost`.
        public var maxTotalBoost: Double
        /// dB above the target the response may sit before it counts as a peak to remove, when the
        /// target has no tolerance band. With a band, its upper edge is used.
        public var peakAllowance: Double

        public init(maxFilters: Int = 8, maxBoost: Double = 3, maxCut: Double = 12, maxQ: Double = 6,
                    shelves: Bool = true, smoothing: Double = 6, maxTotalBoost: Double? = nil, peakAllowance: Double = 1) {
            self.maxFilters = maxFilters
            self.maxBoost = maxBoost
            self.maxCut = maxCut
            self.maxQ = maxQ
            self.shelves = shelves
            self.smoothing = smoothing
            self.maxTotalBoost = maxTotalBoost ?? maxBoost
            self.peakAllowance = peakAllowance
        }

        // Settings saved before the total boost and peak allowance existed keep their other values.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings()
            maxFilters = try c.decodeIfPresent(Int.self, forKey: .maxFilters) ?? d.maxFilters
            maxBoost = try c.decodeIfPresent(Double.self, forKey: .maxBoost) ?? d.maxBoost
            maxCut = try c.decodeIfPresent(Double.self, forKey: .maxCut) ?? d.maxCut
            maxQ = try c.decodeIfPresent(Double.self, forKey: .maxQ) ?? d.maxQ
            shelves = try c.decodeIfPresent(Bool.self, forKey: .shelves) ?? d.shelves
            smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
            maxTotalBoost = try c.decodeIfPresent(Double.self, forKey: .maxTotalBoost) ?? maxBoost
            peakAllowance = try c.decodeIfPresent(Double.self, forKey: .peakAllowance) ?? d.peakAllowance
        }
    }

    /// How many times worse a decibel above the allowance counts than one below the target.
    static let peakWeight = 10.0
    /// Narrowest boost: a narrow boost mostly tries to fill a cancellation.
    static let boostMaxQ = 3.0
    /// Largest deviations tried as starting points for the next peak filter.
    static let startingPoints = 5

    public struct Result {
        /// The filters added, from low to high frequency.
        public var filters: [EQFilter]
        /// RMS deviation from the aligned target over its range, dB, with only the filters kept
        /// (`fixed`), and with the new ones too.
        public var rmsBefore: Double
        public var rmsAfter: Double
        /// Most the response rises above the target, dB, before and after (0 if it never does).
        public var peakBefore: Double
        public var peakAfter: Double
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
        let allowance = f.map { target.hasTolerance ? target.toleranceRange(at: $0).above : max(settings.peakAllowance, 0) }
        var fitter = Fitter(frequencies: f, base: base, allowance: allowance, sampleRate: fs, settings: settings, low: low, high: high)
        let before = fitter.rms

        while fitter.filters.count < max(0, settings.maxFilters) && (fitter.rms > 0.5 || fitter.overAllowance) {
            let previous = fitter.cost.squareRoot()
            var best: Fitter?
            for candidate in fitter.candidates() {
                var trial = fitter
                trial.append(candidate)
                trial.optimise(only: [trial.filters.count - 1], sweeps: 40)
                if best == nil || trial.cost < best!.cost { best = trial }
            }
            guard var next = best else { break }
            next.optimise(only: Array(next.filters.indices), sweeps: 60)
            if previous - next.cost.squareRoot() < 0.05 { break }
            fitter = next
        }
        // A filter left with almost no gain does nothing worth typing in.
        let kept = fitter.filters.filter { abs($0.gain) >= 0.3 }
        let eq = f.indices.map { i in kept.reduce(0) { $0 + $1.gainDB(at: f[i], sampleRate: fs) } }
        let zero = [Double](repeating: 0, count: f.count)
        return Result(filters: kept.sorted { $0.frequency < $1.frequency }, rmsBefore: before, rmsAfter: Fitter.rms(base, eq),
                      peakBefore: Fitter.peak(base, zero), peakAfter: Fitter.peak(base, eq))
    }

    /// The working state of a fit: the filters so far and each one's gain on the grid.
    struct Fitter {
        let frequencies: [Double]
        let base: [Double]
        /// dB above the target allowed at each frequency before the deviation counts `peakWeight` times.
        let allowance: [Double]
        let sampleRate: Double
        let settings: Settings
        let low: Double
        let high: Double
        private(set) var filters: [EQFilter] = []
        private var gains: [[Double]] = []
        private var total: [Double]

        init(frequencies: [Double], base: [Double], allowance: [Double], sampleRate: Double, settings: Settings,
             low: Double, high: Double) {
            self.frequencies = frequencies
            self.base = base
            self.allowance = allowance
            self.sampleRate = sampleRate
            self.settings = settings
            self.low = low
            self.high = high
            total = [Double](repeating: 0, count: frequencies.count)
        }

        /// What the fit minimises: the mean squared deviation, with peaks above the allowance weighted, and
        /// a wall where the new filters together boost more than `maxTotalBoost`.
        var cost: Double { cost(total) }

        private func cost(_ eq: [Double]) -> Double {
            guard !base.isEmpty else { return 0 }
            var sum = 0.0, boost = -Double.infinity
            for i in base.indices {
                let r = base[i] + eq[i]
                let over = max(r - allowance[i], 0)
                sum += r * r + AutoEQ.peakWeight * over * over
                boost = max(boost, eq[i])
            }
            let wall = boost > settings.maxTotalBoost + 0.05 ? 1e6 + boost : 0
            return sum / Double(base.count) + wall
        }

        /// RMS deviation from the target, dB.
        var rms: Double { Fitter.rms(base, total) }

        /// Whether the response still rises above the allowance anywhere.
        var overAllowance: Bool { base.indices.contains { base[$0] + total[$0] > allowance[$0] + 0.05 } }

        static func peak(_ base: [Double], _ eq: [Double]) -> Double {
            max(0, zip(base, eq).map { $0 + $1 }.max() ?? 0)
        }

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
            cost(total.indices.map { total[$0] - gains[k][$0] + g[$0] })
        }

        /// Starting filters for the next step: a peak on each of the largest deviations, and a shelf at
        /// each end that has none yet.
        func candidates() -> [EQFilter] {
            let residual = base.indices.map { base[$0] + total[$0] }
            var out = peakCandidates(residual)
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

        /// Peaks centred on the largest deviations, at most one in each stretch of one sign, each as wide as
        /// the stretch around it that is at least half as large. None starts within a third of an octave of
        /// a filter of the same sign already added.
        private func peakCandidates(_ r: [Double]) -> [EQFilter] {
            // A boost can only go so far, so weigh dips by what a filter could do about them.
            func reach(_ i: Int) -> Double {
                r[i] > 0 ? min(r[i] + AutoEQ.peakWeight.squareRoot() * max(r[i] - allowance[i], 0), settings.maxCut)
                    : min(-r[i], settings.maxBoost, settings.maxTotalBoost)
            }
            var extremes: [Int] = []
            var start = 0
            while start < r.count {
                var end = start
                while end + 1 < r.count && (r[end + 1] > 0) == (r[start] > 0) { end += 1 }
                if let i = (start...end).max(by: { reach($0) < reach($1) }) { extremes.append(i) }
                start = end + 1
            }
            var out: [EQFilter] = []
            for i in extremes.sorted(by: { reach($0) > reach($1) }) where reach(i) > 0.3 {
                let half = r[i] / 2
                var lo = i, hi = i
                while lo > 0 && r[lo - 1] * r[i] > 0 && abs(r[lo - 1]) >= abs(half) { lo -= 1 }
                while hi < r.count - 1 && r[hi + 1] * r[i] > 0 && abs(r[hi + 1]) >= abs(half) { hi += 1 }
                let octaves = max(log2(frequencies[hi] / frequencies[lo]), 1.0 / 12)
                let ratio = pow(2, octaves)
                let q = ratio.squareRoot() / (ratio - 1)
                let peak = clamp(EQFilter(kind: .peak, frequency: frequencies[i], gain: -r[i], q: q))
                let stacked = filters.contains {
                    $0.kind == .peak && ($0.gain > 0) == (peak.gain > 0) && abs(log2($0.frequency / peak.frequency)) < 1.0 / 3
                }
                if stacked { continue }
                out.append(peak)
                if out.count == AutoEQ.startingPoints { break }
            }
            return out
        }

        /// Keeps a filter within the settings: gain, Q (boosts no narrower than `boostMaxQ`), and a
        /// frequency inside the range (shelves may sit up to an octave outside it).
        func clamp(_ filter: EQFilter) -> EQFilter {
            var f = filter
            let shelf = f.kind == .lowShelf || f.kind == .highShelf
            let lo = shelf ? low / 2 : low, hi = min(shelf ? high * 2 : high, 0.45 * sampleRate)
            f.frequency = min(max(f.frequency, lo), hi)
            f.gain = min(max(f.gain, -settings.maxCut), settings.maxBoost)
            let narrowest = f.gain > 0 ? min(settings.maxQ, AutoEQ.boostMaxQ) : settings.maxQ
            f.q = shelf ? min(max(f.q, 0.5), 1) : min(max(f.q, 0.5), max(narrowest, 0.5))
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
