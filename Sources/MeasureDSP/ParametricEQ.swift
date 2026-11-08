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

/// How a processor counts the Q of a peak filter. The app keeps the Audio EQ Cookbook's Q; the
/// French Q of L-Acoustics LA Network Manager is that Q times 10^(|gain| / 40), so the two agree
/// at 0 dB and the French figure is larger the more the filter boosts or cuts. Only peaks
/// differ; other filters' Q is the same in both.
public enum QStyle: String, Codable, CaseIterable, Identifiable {
    case standard = "Standard"
    case french = "French"
    public var id: String { rawValue }

    /// The factor from the Cookbook Q to this style's Q for a filter of `kind` and `gain` dB.
    public func factor(_ kind: EQFilter.Kind, gain: Double) -> Double {
        self == .french && kind == .peak ? pow(10, abs(gain) / 40) : 1
    }

    /// The filter's Q as this style counts it.
    public func q(of filter: EQFilter) -> Double { filter.q * factor(filter.kind, gain: filter.gain) }

    /// The Cookbook Q for a Q given in this style.
    public func cookbookQ(_ shown: Double, kind: EQFilter.Kind, gain: Double) -> Double {
        shown / factor(kind, gain: gain)
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

    /// The filters as text, one per line, for typing into a processor, with Q counted as `style` does.
    public static func description(_ filters: [EQFilter], qStyle style: QStyle = .standard) -> String {
        let lines = filters.enumerated().map { i, f in
            var line = "\(i + 1). \(f.kind.rawValue)  \(String(format: f.frequency >= 1000 ? "%.0f" : "%.1f", f.frequency)) Hz"
            if f.kind.hasGain { line += String(format: "  %+.1f dB", f.gain) }
            line += String(format: "  Q %.2f", style.q(of: f))
            if !f.enabled { line += "  (off)" }
            return line
        }
        let note = style == .standard || !filters.contains { $0.kind == .peak } ? [] : ["French Q, as in LA Network Manager"]
        return (lines + note).joined(separator: "\n")
    }
}

/// The EQ as LA Network Manager (L-Acoustics) pastes it: a group with a bank of 16 IIR peaks.
/// F is Hz, G tenths of a dB, Q the French Q × 1000 (at most 10), T 1 for a peak, On the tick.
public enum LANetworkManager {
    public static let bankSize = 16
    public static let maxQ = 10.0

    public struct Export: Equatable {
        public let xml: String
        /// Peaks written, out of the bank's 16.
        public let written: Int
        /// Filters left out: shelves, pass filters and notches, and peaks past the 16th.
        public let skipped: Int
        /// Peaks whose French Q was over 10 and was written as 10.
        public let capped: Int
    }

    public static func export(_ filters: [EQFilter], groupName: String = "Group 1") -> Export {
        let peaks = filters.filter { $0.kind == .peak }
        let used = Array(peaks.prefix(bankSize))
        var capped = 0
        var lines: [String] = []
        for i in 0..<bankSize {
            guard i < used.count else {
                lines.append(line(index: i, frequency: 1000, gainTenths: 0, qThousandths: 1000, on: false))
                continue
            }
            let f = used[i]
            let q = QStyle.french.q(of: f)
            if q > maxQ + 0.0005 { capped += 1 }
            lines.append(line(index: i, frequency: Int(f.frequency.rounded()), gainTenths: Int((f.gain * 10).rounded()),
                              qThousandths: Int((min(q, maxQ) * 1000).rounded()), on: f.enabled))
        }
        let name = groupName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <LAGROUP Delay="0.0" Gain="0.0" M1ReversedPolarity="0" Name="\(name)" formatVersion="5"
                 gId="1"
                 height="30"
                 importedFromSoundvision="0"
                 isForP1="1"
                 uid="1"
                 width="120"
                 xpos="0"
                 ypos="0">
           <processorEq EqBypass="0">
        \(lines.joined(separator: "\n"))
           </processorEq>
        </LAGROUP>
        """
        return Export(xml: xml, written: used.count, skipped: filters.count - used.count, capped: capped)
    }

    private static func line(index: Int, frequency: Int, gainTenths: Int, qThousandths: Int, on: Bool) -> String {
        "      <iir F=\"\(frequency)\" G=\"\(gainTenths)\" On=\"\(on ? 1 : 0)\" Q=\"\(qThousandths)\" T=\"1\" index=\"\(index)\"/>"
    }
}

