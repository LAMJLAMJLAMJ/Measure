import Foundation

/// Reads the polarity of a loudspeaker from repeated positive-going pulses picked up by a mic, as a
/// handheld polarity checker does: each pulse that stands well out of what came before it is split
/// into bands, and the sign of the first strong excursion in each band says which way the speaker
/// moved. The last few pulses vote, so one reflection or a cough does not flip the reading.
public final class PolarityDetector {
    public enum Band: String, CaseIterable, Identifiable {
        case full = "Full range"
        case low = "Low"
        case mid = "Mid"
        case high = "High"
        public var id: String { rawValue }

        /// The band's edges, for labels.
        public func range(_ c: Crossovers) -> String {
            switch self {
            case .full: return "20 Hz up"
            case .low: return "below \(Crossovers.text(c.low))"
            case .mid: return "\(Crossovers.text(c.low)) to \(Crossovers.text(c.high))"
            case .high: return "above \(Crossovers.text(c.high))"
            }
        }
    }

    /// Where the low band meets the mid band, and the mid band the high band, Hz.
    public struct Crossovers: Equatable, Codable {
        public var low: Double
        public var high: Double

        public static let standard = Crossovers(low: 250, high: 2500)
        public static let lowRange = 40.0...1000.0
        public static let highRange = 500.0...16000.0

        /// Keeps each edge in its range and the mid band at least an octave wide.
        public init(low: Double, high: Double) {
            self.low = min(max(low, Self.lowRange.lowerBound), Self.lowRange.upperBound)
            self.high = min(max(high, max(Self.highRange.lowerBound, 2 * self.low)), Self.highRange.upperBound)
        }

        /// "250 Hz", "2.5 kHz".
        public static func text(_ f: Double) -> String {
            if f >= 1000 {
                let k = (f / 100).rounded() / 10
                return k == k.rounded() ? "\(Int(k)) kHz" : "\(k) kHz"
            }
            return "\(Int(f.rounded())) Hz"
        }
    }

    public enum Polarity: Equatable {
        case positive, negative
    }

    public struct Reading: Equatable {
        /// What most of the recent pulses say; nil before any pulse is strong enough in this band.
        public var polarity: Polarity?
        /// How many of the recent pulses agree with it, out of `count`.
        public var agreeing = 0
        public var count = 0
        /// Peak of the last pulse in this band, dB re full scale.
        public var level = -200.0

        public init() {}
    }

    /// Pulses that vote.
    public static let votes = 8
    /// A pulse must peak this many times higher than the RMS of the 20 ms before it (18 dB).
    static let triggerRatio = 8.0
    /// And above this, re full scale (-70 dBFS).
    static let floor = 3e-4

    public let sampleRate: Double
    public let crossovers: Crossovers
    public private(set) var readings: [Band: Reading] = [:]
    /// Pulses found since the start.
    public private(set) var pulses = 0
    /// The last pulse, full range, from 1 ms before it to 10 ms after, scaled to a peak of 1.
    public private(set) var lastPulse: [Double] = []
    /// The last pulse in each band, scaled to its own peak of 1, from 1 ms before it over about three
    /// cycles of the band's lowest frequency, at most `maxTracePoints` points.
    public private(set) var bandPulses: [Band: [Double]] = [:]
    public static let maxTracePoints = 300

    /// Everything per band is kept in arrays in `Band.allCases` order, as dictionaries are too slow
    /// for every sample of every mic.
    private static let bands = Band.allCases
    private var chains: [[Section]]
    /// Each band's recent output, a ring of `history` samples; the next write goes at `write`.
    private var buffers: [[Double]]
    private var write = 0
    private let history: Int
    /// Mean square of each band over about the last 20 ms, before the current sample.
    private var envelope: [Double]
    private let envelopeCoefficient: Double
    private var index = 0
    private var holdUntil = 0
    /// The sample where the pulse being read started, and each band's background then.
    private var pending: (start: Int, background: [Double])?
    private var signs: [Band: [Polarity]] = [:]
    private let pre: Int
    private let window: Int
    private let refractory: Int

    public init(sampleRate fs: Double, crossovers: Crossovers = .standard) {
        sampleRate = fs
        self.crossovers = crossovers
        func pass(_ kind: EQFilter.Kind, _ f: Double) -> Section {
            Section(EQFilter(kind: kind, frequency: f, q: 0.7071).biquad(sampleRate: fs))
        }
        chains = Self.bands.map { band in
            switch band {
            case .full: return [pass(.highPass, 20)]
            case .low: return [pass(.highPass, 20), pass(.lowPass, crossovers.low)]
            case .mid: return [pass(.highPass, crossovers.low), pass(.lowPass, crossovers.high)]
            case .high: return [pass(.highPass, crossovers.high)]
            }
        }
        pre = max(Int(0.001 * fs), 1)
        // Long enough for the low band's first swing when its edge is set low.
        window = Int(max(0.015, 1.5 / crossovers.low) * fs)
        refractory = window + Int(0.005 * fs)
        history = Int(0.1 * fs)
        buffers = Self.bands.map { _ in [Double](repeating: 0, count: Int(0.1 * fs)) }
        envelope = Self.bands.map { _ in 0 }
        envelopeCoefficient = exp(-1 / (0.02 * fs))
        // Let the filters and the background settle before looking for pulses.
        holdUntil = Int(0.05 * fs)
        for band in Band.allCases { readings[band] = Reading() }
    }

    /// Clears the votes and the readings.
    public func reset() {
        signs = [:]
        pulses = 0
        lastPulse = []
        bandPulses = [:]
        for band in Band.allCases { readings[band] = Reading() }
    }

    /// Adds the next samples from the mic.
    public func process(_ samples: [Double]) {
        let count = Self.bands.count
        let k = envelopeCoefficient
        let threshold = Self.triggerRatio * Self.triggerRatio
        for x in samples {
            var outputs = (0.0, 0.0, 0.0, 0.0)
            for b in 0..<count {
                var y = x
                for s in chains[b].indices { y = chains[b][s].process(y) }
                buffers[b][write] = y
                switch b {
                case 0: outputs.0 = y
                case 1: outputs.1 = y
                case 2: outputs.2 = y
                default: outputs.3 = y
                }
            }
            // Look for a pulse against the background before this sample, then let this one in.
            let full = outputs.0
            if pending == nil, index >= holdUntil, abs(full) > Self.floor, full * full > threshold * envelope[0] {
                pending = (index, envelope)
                holdUntil = index + max(refractory, Int(0.04 * sampleRate))
            }
            envelope[0] = k * envelope[0] + (1 - k) * outputs.0 * outputs.0
            envelope[1] = k * envelope[1] + (1 - k) * outputs.1 * outputs.1
            envelope[2] = k * envelope[2] + (1 - k) * outputs.2 * outputs.2
            envelope[3] = k * envelope[3] + (1 - k) * outputs.3 * outputs.3
            write = (write + 1) % history
            index += 1
            if let p = pending, index >= p.start + window {
                read(p.start, background: p.background)
                pending = nil
            }
        }
    }

    /// Band `band` from sample `from` for `count` samples, from the history.
    private func segment(_ band: Band, from: Int, count: Int) -> [Double] {
        let buffer = buffers[Self.bands.firstIndex(of: band)!]
        return (0..<count).map { i in
            let age = index - (from + i)
            return buffer[((write - age) % history + history) % history]
        }
    }

    private func read(_ start: Int, background: [Double]) {
        pulses += 1
        for (b, band) in Self.bands.enumerated() {
            let s = segment(band, from: start - pre, count: pre + window)
            let peak = s.map(abs).max() ?? 0
            readings[band]!.level = 20 * log10(max(peak, 1e-10))
            if band == .full {
                let shown = segment(.full, from: start - pre, count: pre + Int(0.01 * sampleRate))
                lastPulse = peak > 0 ? shown.map { $0 / peak } : shown
            }
            bandPulses[band] = trace(band, start: start, peak: peak)
            // Too weak in this band to say: a speaker that does not reproduce it, or noise.
            guard peak > Self.floor / 4, peak * peak > 16 * background[b] else { continue }
            guard let first = s.first(where: { abs($0) >= 0.5 * peak }) else { continue }
            var votes = signs[band] ?? []
            votes.append(first > 0 ? .positive : .negative)
            if votes.count > Self.votes { votes.removeFirst(votes.count - Self.votes) }
            signs[band] = votes
            let positive = votes.filter { $0 == .positive }.count
            let negative = votes.count - positive
            readings[band]!.polarity = positive >= negative ? .positive : .negative
            readings[band]!.agreeing = max(positive, negative)
            readings[band]!.count = votes.count
        }
    }

    /// The band's last pulse for drawing, thinned to at most `maxTracePoints` points.
    private func trace(_ band: Band, start: Int, peak: Double) -> [Double] {
        let lowest: Double
        switch band {
        case .full, .low: lowest = 0
        case .mid: lowest = crossovers.low
        case .high: lowest = crossovers.high
        }
        let span = lowest > 0 ? min(window, max(Int(0.003 * sampleRate), Int(3 / lowest * sampleRate))) : window
        let s = segment(band, from: start - pre, count: pre + span)
        let step = max(1, (s.count + Self.maxTracePoints - 1) / Self.maxTracePoints)
        let scale = peak > 0 ? 1 / peak : 1
        // Each point is the strongest sample of its stretch, so a short pulse keeps its peak.
        return stride(from: 0, to: s.count, by: step).map { i in
            let stretch = s[i..<min(i + step, s.count)]
            return (stretch.max { abs($0) < abs($1) } ?? 0) * scale
        }
    }

    /// One biquad with its state (transposed direct form II).
    private struct Section {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        init(_ q: Biquad) {
            b0 = q.b0; b1 = q.b1; b2 = q.b2; a1 = q.a1; a2 = q.a2
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
