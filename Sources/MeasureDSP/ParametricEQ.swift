import Foundation

/// One parametric EQ filter, as found on loudspeaker processors and consoles. Its response is the
/// biquad from Robert Bristow-Johnson's Audio EQ Cookbook at a given sample rate, which is how most
/// digital processors implement these filters.
public struct EQFilter: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case peak = "Peak"
        case lowShelf = "Low shelf"
        case highShelf = "High shelf"
        case highPass = "High-pass"
        case lowPass = "Low-pass"
        case notch = "Notch"
        public var id: String { rawValue }
        /// Whether the gain applies; pass filters and notches have none.
        public var hasGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
    }

    public var id = UUID()
    public var kind: Kind
    /// Centre, corner or shelf midpoint frequency, Hz.
    public var frequency: Double
    /// dB, for peak and shelf filters.
    public var gain: Double
    /// Bandwidth: Q for peaks, notches and pass filters (0.707 is Butterworth), shelf slope Q for shelves.
    public var q: Double
    public var enabled = true
    /// True for a filter added by Auto EQ, which the next Auto EQ run replaces. Nil or false for one
    /// added or kept by hand.
    public var auto: Bool?

    public init(kind: Kind, frequency: Double, gain: Double = 0, q: Double = 0.707, enabled: Bool = true) {
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.enabled = enabled
    }

    /// The filter's biquad at `sampleRate`, normalised so a0 = 1.
    public func biquad(sampleRate fs: Double) -> Biquad {
        let f0 = min(max(frequency, 1), 0.49 * fs)
        let w0 = 2 * Double.pi * f0 / fs
        let c = cos(w0)
        let alpha = sin(w0) / (2 * max(q, 0.01))
        let a = pow(10, (kind.hasGain ? gain : 0) / 40)
        let b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peak:
            (b0, b1, b2) = (1 + alpha * a, -2 * c, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * c, 1 - alpha / a)
        case .lowShelf:
            let s = 2 * a.squareRoot() * alpha
            (b0, b1, b2) = (a * ((a + 1) - (a - 1) * c + s), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - s))
            (a0, a1, a2) = ((a + 1) + (a - 1) * c + s, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - s)
        case .highShelf:
            let s = 2 * a.squareRoot() * alpha
            (b0, b1, b2) = (a * ((a + 1) + (a - 1) * c + s), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - s))
            (a0, a1, a2) = ((a + 1) - (a - 1) * c + s, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - s)
        case .highPass:
            (b0, b1, b2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        case .lowPass:
            (b0, b1, b2) = ((1 - c) / 2, 1 - c, (1 - c) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        case .notch:
            (b0, b1, b2) = (1, -2 * c, 1)
            (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Gain in dB at `f`. 0 when the filter is off.
    public func gainDB(at f: Double, sampleRate fs: Double) -> Double {
        guard enabled, f > 0, f < fs / 2 else { return 0 }
        let r = biquad(sampleRate: fs).response(at: 2 * Double.pi * f / fs)
        return 10 * log10(max(r.re * r.re + r.im * r.im, 1e-30))
    }
}

public enum ParametricEQ {
    /// Combined gain in dB of the enabled filters at `f`.
    public static func gainDB(_ filters: [EQFilter], at f: Double, sampleRate fs: Double) -> Double {
        filters.reduce(0) { $0 + $1.gainDB(at: f, sampleRate: fs) }
    }

    /// `response` with the filters' gain added to its magnitude: the predicted result of the EQ.
    /// Phase is dropped.
    public static func apply(_ filters: [EQFilter], to response: FrequencyResponse, sampleRate fs: Double) -> FrequencyResponse {
        FrequencyResponse(frequencies: response.frequencies,
                          magnitude: zip(response.frequencies, response.magnitude).map { $1 + gainDB(filters, at: $0, sampleRate: fs) })
    }

    /// The filters as text, one per line, for typing into a processor.
    public static func description(_ filters: [EQFilter]) -> String {
        filters.enumerated().map { i, f in
            var line = "\(i + 1). \(f.kind.rawValue)  \(String(format: f.frequency >= 1000 ? "%.0f" : "%.1f", f.frequency)) Hz"
            if f.kind.hasGain { line += String(format: "  %+.1f dB", f.gain) }
            line += String(format: "  Q %.2f", f.q)
            if !f.enabled { line += "  (off)" }
            return line
        }.joined(separator: "\n")
    }
}
