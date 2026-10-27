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
    private let kFast: Double
    private let kSlow: Double

    /// One entry per whole second since the start: mean square, highest Fast mean square, and Slow
    /// mean square at its end, per weighting.
    public private(set) var secondEnergy: [[Double]]
    public private(set) var secondFast: [[Double]]
    public private(set) var secondSlow: [[Double]]

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
        kFast = 1 - exp(-1 / (SoundLevel.TimeWeighting.fast.tau * fs))
        kSlow = 1 - exp(-1 / (SoundLevel.TimeWeighting.slow.tau * fs))
        secondEnergy = weightings.map { _ in [] }
        secondFast = secondEnergy
        secondSlow = secondEnergy
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
    public static func csv(_ mics: [Column], start: Date?, pauses: [Pause] = []) -> String {
        let weightings = SoundLevel.FrequencyWeighting.allCases
        var header = ["Time", "Elapsed s"]
        for m in mics {
            for w in weightings {
                let l = "L\(w.rawValue)"
                header += ["\(m.name) \(l)eq,1s (\(m.unit))", "\(m.name) \(l)Fmax (\(m.unit))", "\(m.name) \(l)S (\(m.unit))"]
            }
        }
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
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func field(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}
