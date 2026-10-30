import Foundation

/// How a live level is averaged over time.
public enum LevelAverage: String, CaseIterable, Identifiable, Codable {
    /// Exponential time weighting with a 125 ms time constant (IEC 61672-1).
    case fast = "Fast"
    /// Exponential time weighting with a 1 s time constant.
    case slow = "Slow"
    /// Equivalent continuous level over the last 1, 5, 10 or 15 minutes, moving with time.
    case oneMinute = "Leq 1 min"
    case fiveMinutes = "Leq 5 min"
    case tenMinutes = "Leq 10 min"
    case fifteenMinutes = "Leq 15 min"
    /// Equivalent continuous level since the meter was started or reset.
    case continuous = "Leq"
    public var id: String { rawValue }

    /// Seconds a moving Leq covers. Nil for the time weightings and the running Leq.
    public var window: Int? {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        case .fifteenMinutes: return 900
        default: return nil
        }
    }

    /// The usual short name with the weighting letter, such as "LAF", "LCS", "LAeq 10 min" or "LZeq".
    public func label(_ w: SoundLevel.FrequencyWeighting) -> String {
        switch self {
        case .fast: return "L\(w.rawValue)F"
        case .slow: return "L\(w.rawValue)S"
        case .continuous: return "L\(w.rawValue)eq"
        default: return "L\(w.rawValue)eq \(window! / 60) min"
        }
    }
}

/// A frequency weighting run sample by sample, keeping its state between blocks, so a live input can
/// be filtered in pieces of any length with the same result as `WeightingFilter.apply` on the whole.
public struct StreamingWeighting {
    let filter: SoundLevel.WeightingFilter
    private var x1: [Double]
    private var y1: [Double]
    /// The FIR's input history, stored twice over so the latest `taps` samples are always contiguous.
    private var line: [Double]
    private var position = 0

    public init(_ weighting: SoundLevel.FrequencyWeighting, sampleRate fs: Double) {
        filter = SoundLevel.WeightingFilter(weighting, sampleRate: fs)
        x1 = [Double](repeating: 0, count: filter.sections.count)
        y1 = x1
        line = [Double](repeating: 0, count: 2 * filter.correction.count)
    }

    public mutating func process(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        let sections = filter.sections
        let taps = filter.correction
        let n = taps.count
        for i in x.indices {
            var v = x[i] * filter.gain
            for s in sections.indices {
                let y = v - sections[s].zero * x1[s] + sections[s].pole * y1[s]
                x1[s] = v
                y1[s] = y
                v = y
            }
            if n == 0 {
                out[i] = v
                continue
            }
            // Newest sample first: tap k multiplies the sample k steps back.
            position = position == 0 ? n - 1 : position - 1
            line[position] = v
            line[position + n] = v
            var acc = 0.0
            line.withUnsafeBufferPointer { l in
                taps.withUnsafeBufferPointer { h in
                    for k in 0..<n { acc += h[k] * l[position + k] }
                }
            }
            out[i] = acc
        }
        return out
    }
}

/// A sound level meter for a live input: A, C and Z weighting at once, each with Fast and Slow time
/// weighting, moving Leqs over 1, 5, 10 and 15 minutes, the Leq since the start, peaks, and one value a
/// second for the history. Levels are dB re full scale; add the mic's calibration for dB SPL.
public final class SoundLevelMeter {
    public let sampleRate: Double

    /// Per weighting, in `SoundLevel.FrequencyWeighting.allCases` order.
    private var filters: [StreamingWeighting]
    private var fast: [Double]
    private var slow: [Double]
    private var fastMax: [Double]
    private var slowMax: [Double]
    private var peak: [Double]
    /// Sum of squares and sample count since the start.
    private var total: [Double]
    private var count = 0
    /// The second being filled: sum of squares, highest Fast mean square, and samples so far.
    private var secondSum: [Double]
    private var secondFastMax: [Double]
    private var secondCount = 0
    private let samplesPerSecond: Int
    private var tenthCount = 0
    private let samplesPerTenth: Int
    private let kFast: Double
    private let kSlow: Double

    /// One entry per whole second since the start: mean square, highest Fast mean square, and Slow
    /// mean square at its end, per weighting.
    public private(set) var secondEnergy: [[Double]]
    public private(set) var secondFast: [[Double]]
    public private(set) var secondSlow: [[Double]]
    /// The Fast and Slow levels every tenth of a second, dB re full scale, per weighting: the samples
    /// the statistical levels (L10, L50, L90) of those meters are taken from.
    public private(set) var tenthFast: [[Float]]
    public private(set) var tenthSlow: [[Float]]

    public init(sampleRate fs: Double) {
        sampleRate = fs
        let weightings = SoundLevel.FrequencyWeighting.allCases
        filters = weightings.map { StreamingWeighting($0, sampleRate: fs) }
        let zeros = [Double](repeating: 0, count: weightings.count)
        fast = zeros
        slow = zeros
        fastMax = zeros
        slowMax = zeros
        peak = zeros
        total = zeros
        secondSum = zeros
        secondFastMax = zeros
        samplesPerSecond = max(1, Int(fs.rounded()))
        samplesPerTenth = max(1, Int((fs / 10).rounded()))
        kFast = 1 - exp(-1 / (SoundLevel.TimeWeighting.fast.tau * fs))
        kSlow = 1 - exp(-1 / (SoundLevel.TimeWeighting.slow.tau * fs))
        secondEnergy = weightings.map { _ in [] }
        secondFast = secondEnergy
        secondSlow = secondEnergy
        tenthFast = weightings.map { _ in [] }
        tenthSlow = tenthFast
    }

    /// Seconds of input so far.
    public var duration: Double { Double(count) / sampleRate }
    /// Whole seconds in the history.
    public var seconds: Int { secondEnergy.first?.count ?? 0 }

    public func process(_ x: [Double]) {
        guard !x.isEmpty else { return }
        let ys = filters.indices.map { filters[$0].process(x) }
        for i in x.indices {
            for w in ys.indices {
                let v = ys[w][i]
                let sq = v * v
                fast[w] += (sq - fast[w]) * kFast
                slow[w] += (sq - slow[w]) * kSlow
                fastMax[w] = max(fastMax[w], fast[w])
                slowMax[w] = max(slowMax[w], slow[w])
                peak[w] = max(peak[w], abs(v))
                total[w] += sq
                secondSum[w] += sq
                secondFastMax[w] = max(secondFastMax[w], fast[w])
            }
            count += 1
            tenthCount += 1
            if tenthCount == samplesPerTenth {
                for w in ys.indices {
                    tenthFast[w].append(Float(SoundLevelMeter.db(fast[w])))
                    tenthSlow[w].append(Float(SoundLevelMeter.db(slow[w])))
                }
                tenthCount = 0
            }
            secondCount += 1
            if secondCount == samplesPerSecond {
                for w in ys.indices {
                    secondEnergy[w].append(secondSum[w] / Double(samplesPerSecond))
                    secondFast[w].append(secondFastMax[w])
                    secondSlow[w].append(slow[w])
                    secondSum[w] = 0
                    secondFastMax[w] = 0
                }
                secondCount = 0
            }
        }
    }

    private func index(_ w: SoundLevel.FrequencyWeighting) -> Int {
        SoundLevel.FrequencyWeighting.allCases.firstIndex(of: w)!
    }

    static func db(_ ms: Double) -> Double { 10 * log10(max(ms, 1e-30)) }

    /// The level now, dB re full scale. A moving Leq covers the whole seconds so far until its window
    /// has filled; before the first whole second it uses what there is.
    public func level(_ w: SoundLevel.FrequencyWeighting, _ average: LevelAverage) -> Double {
        let k = index(w)
        switch average {
        case .fast: return SoundLevelMeter.db(fast[k])
        case .slow: return SoundLevelMeter.db(slow[k])
        case .continuous: return SoundLevelMeter.db(count > 0 ? total[k] / Double(count) : 0)
        default:
            let energies = secondEnergy[k]
            guard !energies.isEmpty else {
                return SoundLevelMeter.db(secondCount > 0 ? secondSum[k] / Double(secondCount) : 0)
            }
            let n = min(average.window!, energies.count)
            return SoundLevelMeter.db(energies.suffix(n).reduce(0, +) / Double(n))
        }
    }

    /// The highest level since the start: of the time-weighted level for Fast and Slow (LAFmax and so
    /// on), or of the moving Leq second by second for the others.
    public func maximum(_ w: SoundLevel.FrequencyWeighting, _ average: LevelAverage) -> Double {
        let k = index(w)
        switch average {
        case .fast: return SoundLevelMeter.db(fastMax[k])
        case .slow: return SoundLevelMeter.db(slowMax[k])
        default: return history(w, average).max() ?? level(w, average)
        }
    }

    /// Peak sample level since the start (LApeak, LCpeak, LZpeak), dB re full scale.
    public func peakLevel(_ w: SoundLevel.FrequencyWeighting) -> Double {
        20 * log10(max(peak[index(w)], 1e-15))
    }

    /// The level exceeded `percent` % of the time (L10, L50, L90 and so on) over the last `seconds`
    /// seconds, or since the start when nil. Fast and Slow meters use their level every tenth of a
    /// second, as sound level meters do; the Leqs use their value each second.
    public func exceeded(_ percent: Int, _ w: SoundLevel.FrequencyWeighting, _ average: LevelAverage,
                         seconds: Int? = nil) -> Double? {
        let k = index(w)
        let values: [Double]
        switch average {
        case .fast, .slow:
            let tenths = average == .fast ? tenthFast[k] : tenthSlow[k]
            values = tenths.suffix(seconds.map { $0 * 10 } ?? tenths.count).map(Double.init)
        default:
            let h = history(w, average)
            values = Array(h.suffix(seconds ?? h.count))
        }
        return SoundLevelMeter.exceeded(percent, of: values)
    }

    /// The value exceeded by `percent` % of `values`: their (100 − percent)th percentile.
    public static func exceeded(_ percent: Int, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let i = Int((Double(100 - percent) / 100 * Double(sorted.count - 1)).rounded())
        return sorted[min(sorted.count - 1, max(0, i))]
    }

    /// One value per whole second: the highest Fast level in that second, the Slow level at its end,
    /// the moving Leq ending with it (over the seconds so far while the window fills), or the Leq
    /// from the start to its end.
    public func history(_ w: SoundLevel.FrequencyWeighting, _ average: LevelAverage) -> [Double] {
        let k = index(w)
        switch average {
        case .fast: return secondFast[k].map(SoundLevelMeter.db)
        case .slow: return secondSlow[k].map(SoundLevelMeter.db)
        default:
            let e = secondEnergy[k]
            var prefix = [0.0]
            prefix.reserveCapacity(e.count + 1)
            for v in e { prefix.append(prefix.last! + v) }
            let window = average.window ?? Int.max
            return e.indices.map { i in
                let start = window == Int.max ? 0 : max(0, i + 1 - window)
                return SoundLevelMeter.db((prefix[i + 1] - prefix[start]) / Double(i + 1 - start))
            }
        }
    }
}

/// A real-time analyser: the power spectrum of the latest block (Hann window), averaged over time and
/// summed into fractional-octave bands. A bin is shared between the bands it overlaps in proportion
/// to the overlap, so narrow low bands read a smooth level rather than a hole or a step.
public final class RealTimeAnalyzer {
    public struct Band: Hashable {
        public let center: Double
        public let lower: Double
        public let upper: Double
    }

    /// How the band powers are averaged.
    public enum Averaging: String, CaseIterable, Identifiable, Codable {
        case fast = "Fast"
        case slow = "Slow"
        /// Every block since the start or reset, equally weighted.
        case infinite = "Average"
        public var id: String { rawValue }
        /// Time constant in seconds for the exponential averages.
        public var tau: Double? {
            switch self {
            case .fast: return 0.125
            case .slow: return 1
            case .infinite: return nil
            }
        }
    }

    public let fftSize: Int
    public let sampleRate: Double
    public let bands: [Band]
    /// Averaged band levels, dB re full scale (a full-scale sine reads -3 dB in its band).
    public private(set) var levels: [Double]
    /// Highest level of each band since the start or reset.
    public private(set) var peaks: [Double]
    public private(set) var blocks = 0

    private let fft: FFT
    private let window: [Double]
    private let scale: Double
    /// For each band, the bins it covers and the share of each.
    private let weights: [[(bin: Int, share: Double)]]
    private var power: [Double]

    /// IEC 61260-1 base-ten bands, 1/`fraction` octave, whose mid-band frequency lies from `low` to `high`
    /// (and whose upper edge is below Nyquist).
    public static func bands(fraction: Int, low: Double = 20, high: Double = 20_000, sampleRate: Double) -> [Band] {
        let g = pow(10, 0.3)
        let b = Double(max(1, fraction))
        // Odd fractions put a band on 1 kHz; even ones put band edges there.
        func center(_ x: Int) -> Double {
            let n = Double(x)
            let exponent: Double = fraction % 2 == 1 ? n / b : (2 * n + 1) / (2 * b)
            return 1000 * pow(g, exponent)
        }
        let half = pow(g, 1 / (2 * b))
        let first = Int((b * log(low / 1000) / log(g)).rounded(.down)) - 1
        let last = Int((b * log(high / 1000) / log(g)).rounded(.up)) + 1
        // Spelled out step by step: the compiler times out on this as one chained expression.
        let lowest = low / pow(2, 0.01), highest = high * pow(2, 0.01), nyquist = sampleRate / 2
        var out: [Band] = []
        for x in first...last {
            let f: Double = center(x)
            guard f >= lowest, f <= highest, f * half < nyquist else { continue }
            out.append(Band(center: f, lower: f / half, upper: f * half))
        }
        return out
    }

    public init(fftSize: Int, sampleRate fs: Double, fraction: Int) {
        self.fftSize = fftSize
        sampleRate = fs
        fft = FFT(size: fftSize)
        window = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) }
        // One-sided power spectrum scaled so the bins sum to the mean square of the block (Parseval,
        // corrected for the window's energy).
        scale = 2 / (Double(fftSize) * window.reduce(0) { $0 + $1 * $1 })
        bands = RealTimeAnalyzer.bands(fraction: fraction, sampleRate: fs)
        let df = fs / Double(fftSize)
        weights = bands.map { band in
            let lo = max(1, Int((band.lower / df - 0.5).rounded(.down)))
            let hi = min(fftSize / 2 - 1, Int((band.upper / df + 0.5).rounded(.up)))
            guard hi >= lo else { return [] }
            return (lo...hi).compactMap { k in
                let a = (Double(k) - 0.5) * df, b = (Double(k) + 0.5) * df
                let overlap = min(b, band.upper) - max(a, band.lower)
                return overlap > 0 ? (k, overlap / df) : nil
            }
        }
        power = [Double](repeating: 0, count: bands.count)
        levels = [Double](repeating: -300, count: bands.count)
        peaks = levels
    }

    /// Adds the latest `fftSize` samples, which arrived `hop` samples after the previous block.
    public func process(_ block: [Double], hop: Int, averaging: Averaging) {
        guard block.count == fftSize else { return }
        let spectrum = fft.forward(zip(block, window).map { $0 * $1 }).power
        let now = weights.map { w in w.reduce(0) { $0 + spectrum[$1.bin] * $1.share } * scale }
        blocks += 1
        let a: Double
        if let tau = averaging.tau {
            a = blocks == 1 ? 1 : 1 - exp(-Double(max(1, hop)) / (tau * sampleRate))
        } else {
            a = 1 / Double(blocks)
        }
        for i in power.indices {
            power[i] += (now[i] - power[i]) * a
            levels[i] = SoundLevelMeter.db(power[i])
            peaks[i] = max(peaks[i], levels[i])
        }
    }

    public func reset() {
        blocks = 0
        for i in power.indices { power[i] = 0 }
        levels = levels.map { _ in -300 }
        peaks = levels
    }

    /// Clears the peak hold only.
    public func resetPeaks() { peaks = levels }
}

extension SoundLevel {
    /// The standard's A, C or Z weighting at `f`, dB (0 at 1 kHz): the analogue curve of IEC 61672-1,
    /// for weighting levels that are already split into bands.
    public static func weightingDB(_ w: FrequencyWeighting, at f: Double) -> Double {
        guard w != .z, f > 0 else { return 0 }
        return 20 * log10(WeightingFilter.analogue(w, f) / WeightingFilter.analogue(w, 1000))
    }
}

/// A meter's record second by second, kept for export: per weighting, the mean square of each second,
/// its highest Fast mean square, and the Slow mean square at its end.
public struct LevelLog: Equatable {
    public var energy: [[Double]]
    public var fastMax: [[Double]]
    public var slow: [[Double]]

    public init(energy: [[Double]], fastMax: [[Double]], slow: [[Double]]) {
        self.energy = energy
        self.fastMax = fastMax
        self.slow = slow
    }

    public init(_ meter: SoundLevelMeter) {
        self.init(energy: meter.secondEnergy, fastMax: meter.secondFast, slow: meter.secondSlow)
    }

    /// Whole seconds recorded.
    public var seconds: Int { energy.first?.count ?? 0 }

    /// One mic's log for the CSV: its name, the dB added to its levels (calibration and offset) and
    /// the unit they are then in.
    public struct Column {
        public var name: String
        public var offset: Double
        public var unit: String
        public var log: LevelLog
        public init(name: String, offset: Double, unit: String, log: LevelLog) {
            self.name = name
            self.offset = offset
            self.unit = unit
            self.log = log
        }
    }

    /// A stretch of time when monitoring was paused: after `afterSecond` recorded seconds, `duration`
    /// seconds went by unmeasured.
    public struct Pause: Equatable {
        public var afterSecond: Int
        public var duration: Double
        public init(afterSecond: Int, duration: Double) {
            self.afterSecond = afterSecond
            self.duration = duration
        }
    }

    /// When recorded second `index` (from 0) ended, in seconds after the start: its count plus every
    /// pause before it.
    public static func endTime(ofSecond index: Int, pauses: [Pause]) -> Double {
        Double(index + 1) + pauses.filter { $0.afterSecond <= index }.reduce(0) { $0 + $1.duration }
    }

    /// A CSV with a row per second: the time it ended (when `start` is given, with any pauses counted)
    /// and the seconds measured, then for each mic and weighting the Leq over that second, the highest
    /// Fast level in it and the Slow level at its end, to 0.1 dB.
    /// `markers` names seconds (by index from 0) in a last Marker column.
    public static func csv(_ mics: [Column], start: Date?, pauses: [Pause] = [], markers: [Int: String] = [:]) -> String {
        let weightings = SoundLevel.FrequencyWeighting.allCases
        var header = ["Time", "Elapsed s"]
        for m in mics {
            for w in weightings {
                let l = "L\(w.rawValue)"
                header += ["\(m.name) \(l)eq,1s (\(m.unit))", "\(m.name) \(l)Fmax (\(m.unit))", "\(m.name) \(l)S (\(m.unit))"]
            }
        }
        if !markers.isEmpty { header.append("Marker") }
        var lines = [header.map(field).joined(separator: ",")]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rows = mics.map(\.log.seconds).max() ?? 0
        for s in 0..<rows {
            var row = [start.map { formatter.string(from: $0.addingTimeInterval(endTime(ofSecond: s, pauses: pauses))) } ?? "", "\(s + 1)"]
            for m in mics {
                for k in weightings.indices {
                    for series in [m.log.energy, m.log.fastMax, m.log.slow] {
                        if k < series.count, s < series[k].count {
                            row.append(String(format: "%.1f", SoundLevelMeter.db(series[k][s]) + m.offset))
                        } else {
                            row.append("")
                        }
                    }
                }
            }
            if !markers.isEmpty { row.append(field(markers[s] ?? "")) }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func field(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

/// How long until a moving or running Leq crosses a level if the sound stays as it is now: the
/// forecast a monitor engineer reads against a limit.
public enum LeqForecast {
    /// Whole seconds until the Leq crosses `target` if every second from now has mean square `now`:
    /// rising to it or above when the Leq is below it, falling below it when the Leq is at or above it.
    /// `energies` are the mean squares of the whole seconds so far, oldest first; `window` is the
    /// moving Leq's length in seconds (it covers the seconds so far while it fills), nil for the Leq
    /// since the start. Nil when it never crosses at that level, or not within `limit` seconds.
    public static func secondsToCross(energies: [Double], window: Int?, now: Double, target: Double,
                                      limit: Int = 24 * 3600) -> Int? {
        let history = window.map { Array(energies.suffix($0)) } ?? energies
        let n = history.count
        let sum = history.reduce(0, +)
        let rising = n == 0 || sum / Double(n) < target
        func crossed(_ mean: Double) -> Bool { rising ? mean >= target : mean < target }

        guard let window else {
            // The Leq since the start: (sum + t·now) / (n + t), solved for t.
            if n == 0 { return crossed(now) ? 1 : nil }
            let t: Double
            if rising {
                guard now > target else { return nil }
                t = max(1, ((target * Double(n) - sum) / (now - target)).rounded(.up))
            } else {
                guard now < target else { return nil }
                t = ((sum - target * Double(n)) / (target - now)).rounded(.down) + 1
            }
            return t <= Double(limit) ? Int(t) : nil
        }

        // A moving Leq: each second adds one at `now` and, once the window is full, drops the oldest.
        var prefix = [0.0]
        prefix.reserveCapacity(n + 1)
        for e in history { prefix.append(prefix.last! + e) }
        for t in 1...max(1, window) {
            let count = min(window, n + t)
            let kept = max(0, count - t)
            let old = prefix[n] - prefix[n - kept]
            let mean = (old + Double(min(t, count)) * now) / Double(count)
            if crossed(mean) { return t <= limit ? t : nil }
        }
        return nil
    }

    /// `secondsToCross` with levels in dB instead of mean squares.
    public static func secondsToCross(energies: [Double], window: Int?, nowLevel: Double, targetLevel: Double) -> Int? {
        secondsToCross(energies: energies, window: window, now: pow(10, nowLevel / 10), target: pow(10, targetLevel / 10))
    }
}

/// The show budget: the highest level that can be kept up for the rest of a show of fixed length and
/// still bring the Leq over the whole show to the limit.
public enum ShowBudget: Equatable {
    /// Keep the Leq for the rest of the show at or below this level (dB) for `remaining` seconds.
    case allowed(level: Double, remaining: Int)
    /// The show's Leq is already over the limit, even with silence for the rest of it.
    case spent(remaining: Int)
    /// The show's length has passed.
    case finished

    /// The budget after `energies` (mean squares of the whole seconds so far, oldest first) in a show
    /// of `showSeconds`, for a limit `target` in dB on the same scale as the energies.
    public static func after(_ energies: [Double], showSeconds: Int, target: Double) -> ShowBudget {
        let remaining = showSeconds - energies.count
        guard remaining > 0 else { return .finished }
        let allowed = (pow(10, target / 10) * Double(showSeconds) - energies.reduce(0, +)) / Double(remaining)
        guard allowed > 0 else { return .spent(remaining: remaining) }
        return .allowed(level: 10 * log10(allowed), remaining: remaining)
    }
}
