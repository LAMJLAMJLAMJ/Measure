import Foundation

/// How several measured sources add up after a change of delay, polarity and gain: subs to tops, fills to
/// mains, delay towers to the stage, or any other pair. Each source is a complex response on a shared
/// log-spaced grid, timed from a common zero (the start of the recordings), so their sum is a prediction
/// of what the mic would measure with all of them playing.
public enum TimeAlignment {
    /// Speed of sound at 20 °C, m/s.
    public static let speedOfSound = 343.0

    /// Log-spaced frequencies, `pointsPerOctave` per octave, from `low` to `high`.
    public static func grid(pointsPerOctave: Int = 48, low: Double = 10, high: Double = 20_000) -> [Double] {
        guard high > low, low > 0 else { return [] }
        let count = Int((log2(high / low) * Double(pointsPerOctave)).rounded(.down)) + 1
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count { out.append(low * pow(2, Double(i) / Double(pointsPerOctave))) }
        return out
    }

    /// The change made to one source: what a processor's output channel would be set to.
    public struct Setting: Codable, Hashable {
        /// Seconds added to the source's arrival.
        public var delay: Double
        /// dB added to its level.
        public var gain: Double
        public var inverted: Bool

        public init(delay: Double = 0, gain: Double = 0, inverted: Bool = false) {
            self.delay = delay
            self.gain = gain
            self.inverted = inverted
        }

        /// The complex factor for gain and polarity.
        var factor: Double { (inverted ? -1 : 1) * pow(10, gain / 20) }
    }

    /// One source's complex response on a grid. The phase is relative to `arrival`, so it changes slowly
    /// with frequency and can be smoothed and interpolated; `arrival` puts the time back.
    public struct Part {
        public let frequencies: [Double]
        public var re: [Double]
        public var im: [Double]
        /// Seconds from the common time zero that the phase is relative to.
        public var arrival: Double

        public init(frequencies: [Double], re: [Double], im: [Double], arrival: Double) {
            precondition(frequencies.count == re.count && re.count == im.count, "lengths differ")
            self.frequencies = frequencies
            self.re = re
            self.im = im
            self.arrival = arrival
        }

        /// A part from a measured response on `grid`.
        /// - Parameters:
        ///   - response: magnitude in dB and phase in degrees, as from an FFT of samples starting at `start`.
        ///   - start: seconds from the common time zero to the first sample the response was taken from (the
        ///     start of the window). 0 for an impulse response taken from the start of its file.
        ///   - arrival: seconds from the common zero to the direct sound. Only a reference for the phase; the
        ///     prediction does not depend on it.
        ///   - smoothing: complex (vector) smoothing over 1/`smoothing` octave, which keeps the phase; nil for none.
        ///   - gain: dB to add at each grid frequency, for a mic calibration or an EQ.
        /// Nil when the response has no phase. Grid points beyond the response's range are left at zero.
        public init?(response: FrequencyResponse, start: Double, arrival: Double, grid: [Double],
                     smoothing: Double? = nil, gain: ((Double) -> Double)? = nil) {
            guard let phase = response.phase else { return nil }
            let f = response.frequencies
            let n = f.count
            // The response relative to the arrival, bin by bin.
            var binRe = [Double](repeating: 0, count: n)
            var binIm = [Double](repeating: 0, count: n)
            let shift = arrival - start
            for k in 0..<n {
                let a = pow(10, response.magnitude[k] / 20)
                let radians = (phase[k] + 360 * f[k] * shift) * Double.pi / 180
                binRe[k] = a * cos(radians)
                binIm[k] = a * sin(radians)
            }
            var sumRe = [0.0], sumIm = [0.0]
            sumRe.reserveCapacity(n + 1)
            sumIm.reserveCapacity(n + 1)
            for k in 0..<n {
                sumRe.append(sumRe[k] + binRe[k])
                sumIm.append(sumIm[k] + binIm[k])
            }
            let half = smoothing.map { pow(2, 0.5 / $0) } ?? 1
            var re = [Double](repeating: 0, count: grid.count)
            var im = [Double](repeating: 0, count: grid.count)
            for (i, fi) in grid.enumerated() {
                guard n > 0, fi >= f[0], fi <= f[n - 1] else { continue }
                // First bin at or above each edge of the smoothing window.
                let lo = TimeAlignment.firstIndex(f, atLeast: fi / half)
                let hi = TimeAlignment.firstIndex(f, atLeast: fi * half * (1 + 1e-12))
                if hi - lo >= 2 {
                    re[i] = (sumRe[hi] - sumRe[lo]) / Double(hi - lo)
                    im[i] = (sumIm[hi] - sumIm[lo]) / Double(hi - lo)
                } else {
                    // Fewer than two bins in the window: interpolate between the two bins around fi.
                    let above = min(max(TimeAlignment.firstIndex(f, atLeast: fi), 1), n - 1)
                    let below = above - 1
                    let w = n == 1 ? 0 : (fi - f[below]) / (f[above] - f[below])
                    re[i] = binRe[below] + w * (binRe[above] - binRe[below])
                    im[i] = binIm[below] + w * (binIm[above] - binIm[below])
                }
                if let gain {
                    let g = pow(10, gain(fi) / 20)
                    re[i] *= g
                    im[i] *= g
                }
            }
            self.init(frequencies: grid, re: re, im: im, arrival: arrival)
        }

        /// Level in dB at grid point `i`.
        public func level(_ i: Int) -> Double { 10 * log10(max(re[i] * re[i] + im[i] * im[i], 1e-30)) }

        /// Phase in degrees at grid point `i`, relative to `arrival`, wrapped to (-180, 180].
        public func phase(_ i: Int) -> Double {
            let p = atan2(im[i], re[i]) * 180 / Double.pi
            return p <= -180 ? p + 360 : p
        }

        /// Phase in degrees at grid point `i`, relative to another time.
        public func phase(_ i: Int, relativeTo time: Double) -> Double {
            var p = (phase(i) - 360 * frequencies[i] * (arrival - time)).truncatingRemainder(dividingBy: 360)
            if p > 180 { p -= 360 } else if p <= -180 { p += 360 }
            return p
        }

        /// This part with `setting` applied, its phase relative to `reference` seconds.
        public func adjusted(_ setting: Setting, reference: Double) -> Part {
            let g = setting.factor
            let t = arrival + setting.delay - reference
            var out = Part(frequencies: frequencies, re: re, im: im, arrival: reference)
            for i in frequencies.indices {
                let w = -2 * Double.pi * frequencies[i] * t
                let c = cos(w), s = sin(w)
                out.re[i] = g * (re[i] * c - im[i] * s)
                out.im[i] = g * (re[i] * s + im[i] * c)
            }
            return out
        }

        /// This part through `filters` (the enabled ones), magnitude and phase, as a processor at `sampleRate`
        /// would apply them.
        public func applying(_ filters: [EQFilter], sampleRate fs: Double) -> Part {
            var out = self
            for filter in filters where filter.enabled {
                let b = filter.biquad(sampleRate: fs)
                for i in frequencies.indices where frequencies[i] < fs / 2 {
                    let h = b.response(at: 2 * Double.pi * frequencies[i] / fs)
                    let r = out.re[i] * h.re - out.im[i] * h.im
                    out.im[i] = out.re[i] * h.im + out.im[i] * h.re
                    out.re[i] = r
                }
            }
            return out
        }

        /// Grid points from `low` to `high`.
        func indices(_ low: Double, _ high: Double) -> [Int] {
            frequencies.indices.filter { frequencies[$0] >= low && frequencies[$0] <= high }
        }
    }

    /// The sum of the parts with their settings, its phase relative to `reference` seconds. Nil for none.
    public static func sum(_ parts: [Part], settings: [Setting], reference: Double) -> Part? {
        precondition(parts.count == settings.count, "one setting per part")
        guard let first = parts.first else { return nil }
        var out = Part(frequencies: first.frequencies, re: [Double](repeating: 0, count: first.frequencies.count),
                       im: [Double](repeating: 0, count: first.frequencies.count), arrival: reference)
        for (part, setting) in zip(parts, settings) {
            let a = part.adjusted(setting, reference: reference)
            for i in out.frequencies.indices {
                out.re[i] += a.re[i]
                out.im[i] += a.im[i]
            }
        }
        return out
    }

    /// How well the parts add from `low` to `high`, in dB: the power of their sum over the power they would
    /// have if every one arrived in phase. 0 is a perfect addition; -3 is what unrelated sources give on
    /// average for two equal parts; large negative values are cancellation.
    public static func summation(_ parts: [Part], settings: [Setting], low: Double, high: Double) -> Double? {
        guard let first = parts.first, let total = sum(parts, settings: settings, reference: first.arrival) else { return nil }
        var actual = 0.0, ideal = 0.0
        for i in first.indices(low, high) {
            actual += total.re[i] * total.re[i] + total.im[i] * total.im[i]
            var magnitudes = 0.0
            for (part, setting) in zip(parts, settings) {
                let m = (part.re[i] * part.re[i] + part.im[i] * part.im[i]).squareRoot()
                magnitudes += m * abs(setting.factor)
            }
            ideal += magnitudes * magnitudes
        }
        guard ideal > 0 else { return nil }
        return 10 * log10(max(actual / ideal, 1e-30))
    }

    /// The delay and polarity that make one part add best to the rest.
    public struct Fit: Equatable {
        /// The moving part's new delay, seconds. It can be negative: then the others need delay instead
        /// (see `normalized`).
        public var delay: Double
        public var inverted: Bool
        /// `summation` over the range with this fit, dB.
        public var summation: Double
        /// Seconds between the moving part's arrival and the others' after the fit: how far the best phase
        /// match is from simply lining up the arrivals.
        public var fromArrival: Double
    }

    /// Finds the delay and polarity for `moving` (its gain kept) that give the most level from `low` to
    /// `high` when added to `others` (already with their settings, timed from the common zero by its
    /// `arrival`). The search spans `span` seconds either side of lining up the arrivals. Several delays a
    /// period apart can add almost equally well over a narrow range; of those within 0.1 dB of the best,
    /// the one nearest the arrival is taken.
    public static func fit(moving: Part, gain: Double = 0, to others: Part, low: Double, high: Double,
                           span: Double = 0.010) -> Fit? {
        let band = moving.indices(low, high)
        guard !band.isEmpty else { return nil }
        let g = pow(10, gain / 20)
        // |O + s·g·M·e^(-jωτ)|² = |O|² + |gM|² + 2s·Re(O·conj(gM)·e^(jωτ)), where τ is the moving part's
        // arrival after the delay less the others'. Only the cross term depends on τ and the polarity s.
        var base = 0.0, ideal = 0.0
        var xRe: [Double] = [], xIm: [Double] = [], w: [Double] = []
        for i in band {
            let oRe = others.re[i], oIm = others.im[i]
            let mRe = g * moving.re[i], mIm = g * moving.im[i]
            let o2 = oRe * oRe + oIm * oIm, m2 = mRe * mRe + mIm * mIm
            base += o2 + m2
            ideal += o2 + m2 + 2 * (o2 * m2).squareRoot()
            xRe.append(oRe * mRe + oIm * mIm)
            xIm.append(oIm * mRe - oRe * mIm)
            w.append(2 * Double.pi * moving.frequencies[i])
        }
        guard ideal > 0 else { return nil }
        func cross(_ tau: Double) -> Double {
            var c = 0.0
            for k in w.indices { c += xRe[k] * cos(w[k] * tau) - xIm[k] * sin(w[k] * tau) }
            return 2 * c
        }
        func level(_ c: Double) -> Double { 10 * log10(max((base + c) / ideal, 1e-30)) }

        // A step of 10° at the top of the range finds every peak; parabolas through the samples refine them.
        let top = moving.frequencies[band.last!]
        let step = max(1e-6, 1 / (36 * top))
        let count = Int((2 * span / step).rounded(.up))
        guard count >= 2 else { return nil }
        var values = [Double](repeating: 0, count: count + 1)
        for k in 0...count { values[k] = cross(-span + Double(k) * step) }

        struct Peak { let tau: Double; let level: Double; let inverted: Bool }
        var peaks: [Peak] = []
        for sign in [1.0, -1.0] {
            for k in 0...count {
                let v = sign * values[k]
                let left = k > 0 ? sign * values[k - 1] : -Double.infinity
                let right = k < count ? sign * values[k + 1] : -Double.infinity
                guard v >= left && v >= right else { continue }
                var tau = -span + Double(k) * step
                if k > 0 && k < count {
                    let d = left - 2 * v + right
                    if d < 0 { tau += step * 0.5 * (left - right) / d }
                }
                peaks.append(Peak(tau: tau, level: level(sign * cross(tau)), inverted: sign < 0))
            }
        }
        guard let best = peaks.map(\.level).max() else { return nil }
        let chosen = peaks.filter { $0.level >= best - 0.1 }.min { abs($0.tau) < abs($1.tau) }!
        return Fit(delay: others.arrival + chosen.tau - moving.arrival, inverted: chosen.inverted,
                   summation: chosen.level, fromArrival: chosen.tau)
    }

    /// The delays shifted so the smallest is zero: a processor can add delay but not take it away.
    public static func normalized(_ settings: [Setting]) -> [Setting] {
        guard let least = settings.map(\.delay).min() else { return settings }
        return settings.map { s in
            var out = s
            out.delay -= least
            return out
        }
    }

    /// Where two parts are at the same level between `low` and `high`: the crossover. Of several crossings,
    /// the loudest. Nil when they do not cross in the range.
    public static func crossover(_ a: Part, _ b: Part, low: Double = 20, high: Double = 20_000) -> Double? {
        let band = a.indices(low, high)
        var best: (f: Double, level: Double)?
        for (j, i) in band.enumerated().dropFirst() {
            let p = band[j - 1]
            let d0 = a.level(p) - b.level(p), d1 = a.level(i) - b.level(i)
            guard (d0 <= 0) != (d1 <= 0) else { continue }
            let t = d0 == d1 ? 0 : d0 / (d0 - d1)
            let f = a.frequencies[p] * pow(a.frequencies[i] / a.frequencies[p], t)
            let level = a.level(p) + t * (a.level(i) - a.level(p))
            if best == nil || level > best!.level { best = (f, level) }
        }
        return best?.f
    }
}

extension TimeAlignment {
    /// The first index of ascending `x` whose value is at least `value`; `x.count` when there is none.
    static func firstIndex(_ x: [Double], atLeast value: Double) -> Int {
        var lo = 0, hi = x.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if x[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
