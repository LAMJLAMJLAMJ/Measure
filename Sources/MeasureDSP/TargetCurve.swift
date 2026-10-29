import Foundation

/// The response a system is tuned towards, relative to its own level: a shape, not an absolute level.
/// It is either built from a tilt, a bass shelf and a treble roll-off, or read from a file of
/// frequency and level pairs (as REW and most analysers export target curves). The target applies
/// between `low` and `high`, which is also the range it is aligned and Auto EQ is fitted over.
public struct TargetCurve: Codable, Hashable {
    public struct Point: Codable, Hashable {
        public var frequency: Double
        public var level: Double
        public init(frequency: Double, level: Double) {
            self.frequency = frequency
            self.level = level
        }
    }

    /// The tolerance band at one frequency: how far above and below the target it reaches, dB (both positive).
    public struct ToleranceBreakpoint: Codable, Hashable {
        public var frequency: Double
        public var above: Double
        public var below: Double
        public init(frequency: Double, above: Double, below: Double) {
            self.frequency = frequency
            self.above = above
            self.below = below
        }
    }

    public var name: String
    /// dB per octave about 1 kHz, over the whole range. Negative falls towards high frequencies.
    public var tilt: Double
    /// dB of the bass shelf, reached well below `bassFrequency`.
    public var bassGain: Double
    /// Midpoint of the bass shelf, Hz.
    public var bassFrequency: Double
    /// Above this frequency the target falls by `trebleSlope` dB per octave.
    public var trebleCorner: Double
    /// dB per octave of the fall above `trebleCorner`, positive for a fall.
    public var trebleSlope: Double
    /// Breakpoints read from a file. When set they replace the shape above.
    public var points: [Point]?
    /// Lowest and highest frequency the target applies to, Hz.
    public var low: Double
    public var high: Double
    /// Half-width of the tolerance band drawn around the target, dB. 0 draws none. Setting it replaces
    /// a standard's band (`toleranceBand`) with this even one.
    public var tolerance: Double { didSet { toleranceBand = nil } }
    /// A standard's tolerance band, which can be uneven and change with frequency: dB above and below
    /// the target at each breakpoint, interpolated on a log-frequency scale. Nil uses `tolerance`.
    public var toleranceBand: [ToleranceBreakpoint]?
    /// dB added to the target after it is aligned to the measurement.
    public var offset: Double

    public init(name: String, tilt: Double = 0, bassGain: Double = 0, bassFrequency: Double = 100,
                trebleCorner: Double = 20_000, trebleSlope: Double = 0, points: [Point]? = nil,
                low: Double = 40, high: Double = 16_000, tolerance: Double = 0, offset: Double = 0) {
        self.name = name
        self.tilt = tilt
        self.bassGain = bassGain
        self.bassFrequency = bassFrequency
        self.trebleCorner = trebleCorner
        self.trebleSlope = trebleSlope
        self.points = points
        self.low = low
        self.high = high
        self.tolerance = tolerance
        self.offset = offset
    }

    /// Starting shapes; every value can be changed afterwards.
    public enum Preset: String, CaseIterable, Identifiable {
        case flat = "Flat"
        case falling = "Falling 1 dB/octave"
        case xCurve = "X-curve (ISO 2969 / SMPTE ST 202, medium room)"
        case livePA = "Live PA (+6 dB bass shelf, -1 dB/octave above 2 kHz)"
        public var id: String { rawValue }

        public var curve: TargetCurve {
            switch self {
            case .flat: return TargetCurve(name: "Flat")
            case .falling: return TargetCurve(name: "Falling 1 dB/octave", tilt: -1)
            case .xCurve:
                // SMPTE ST 202 figure 5 (medium-sized theatre): −3 dB/octave below 50 Hz, flat to 2 kHz,
                // −3 dB/octave to 10 kHz (−7.0 dB), −6 dB/octave above; tolerances for 1/3-octave measurements.
                var x = TargetCurve(name: "X-curve", points: [
                    Point(frequency: 31.5, level: -2), Point(frequency: 50, level: 0), Point(frequency: 2000, level: 0),
                    Point(frequency: 10_000, level: -3 * log2(5)), Point(frequency: 16_000, level: -3 * log2(5) - 6 * log2(1.6)),
                ], low: 31.5, high: 16_000, tolerance: 3)
                x.toleranceBand = [
                    ToleranceBreakpoint(frequency: 31.5, above: 3, below: 7.5),
                    ToleranceBreakpoint(frequency: 50, above: 3, below: 3),
                    ToleranceBreakpoint(frequency: 8000, above: 3, below: 3),
                    ToleranceBreakpoint(frequency: 10_000, above: 3, below: 4),
                    ToleranceBreakpoint(frequency: 16_000, above: 3, below: 6),
                ]
                return x
            case .livePA: return TargetCurve(name: "Live PA", bassGain: 6, bassFrequency: 100, trebleCorner: 2000, trebleSlope: 1)
            }
        }
    }

    /// Level of the target at `f`, dB, before alignment and offset.
    public func level(at f: Double) -> Double {
        if let points, !points.isEmpty {
            return TargetCurve.interpolate(points, at: f)
        }
        let octaves = log2(max(f, 1) / 1000)
        var level = tilt * octaves
        if bassGain != 0 {
            // The Audio EQ Cookbook shelf, as a processor would make it, at a rate high enough not to matter.
            level += EQFilter(kind: .lowShelf, frequency: bassFrequency, gain: bassGain, q: 0.707).gainDB(at: f, sampleRate: 192_000)
        }
        if trebleSlope != 0, f > trebleCorner {
            level -= trebleSlope * log2(f / trebleCorner)
        }
        return level
    }

    /// dB the tolerance band reaches above and below the target at `f`. Zero for no band.
    public func toleranceRange(at f: Double) -> (above: Double, below: Double) {
        guard let band = toleranceBand, !band.isEmpty else { return (tolerance, tolerance) }
        let above = TargetCurve.interpolate(band.map { Point(frequency: $0.frequency, level: $0.above) }, at: f)
        let below = TargetCurve.interpolate(band.map { Point(frequency: $0.frequency, level: $0.below) }, at: f)
        return (above, below)
    }

    /// Whether a tolerance band is drawn.
    public var hasTolerance: Bool { !(toleranceBand ?? []).isEmpty || tolerance > 0 }

    /// Log-frequency linear interpolation, held at the ends.
    static func interpolate(_ points: [Point], at f: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first.frequency { return first.level }
        if f >= last.frequency { return last.level }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].frequency <= f { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let w = (log(f) - log(a.frequency)) / (log(b.frequency) - log(a.frequency))
        return a.level + w * (b.level - a.level)
    }

    /// A target read from a text file of frequency and level pairs (an REW target or house curve, or
    /// any two-column export). Its range is the file's, within 20 Hz to 20 kHz.
    public static func parse(_ text: String, name: String) throws -> TargetCurve {
        let response = try FrequencyResponseText.parse(text).response
        var points: [Point] = []
        for (f, level) in zip(response.frequencies, response.magnitude) where points.last?.frequency != f {
            points.append(Point(frequency: f, level: level))
        }
        guard points.count >= 2 else { throw FrequencyResponseText.ParseError.noData }
        return TargetCurve(name: name, points: points,
                           low: max(20, points.first!.frequency), high: min(20_000, points.last!.frequency))
    }

    /// Log-spaced frequencies across the target's range, `perOctave` per octave.
    public func grid(perOctave: Int = 24) -> [Double] {
        TargetCurve.grid(low: low, high: high, perOctave: perOctave)
    }

    static func grid(low: Double, high: Double, perOctave: Int) -> [Double] {
        guard high > low, low > 0 else { return [] }
        let count = Int((log2(high / low) * Double(perOctave)).rounded(.down)) + 1
        return (0..<count).map { low * pow(2, Double($0) / Double(perOctave)) }
    }

    /// dB to add to `level(at:)` so the target sits on `response`: the median of the response minus the
    /// target over the target's range (so a few peaks or dips do not move it), plus `offset`.
    /// `response` should already be smoothed as it is drawn.
    public func alignment(to response: FrequencyResponse) -> Double {
        let lo = max(low, response.frequencies.first ?? low)
        let hi = min(high, response.frequencies.last ?? high)
        let f = TargetCurve.grid(low: lo, high: hi, perOctave: 24)
        guard !f.isEmpty else { return offset }
        return TargetCurve.median(f.map { response.magnitude(at: $0) - level(at: $0) }) + offset
    }

    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
