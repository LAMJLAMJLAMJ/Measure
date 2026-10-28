import Foundation

/// The window that cuts a frequency response out of an impulse response, like REW's IR windows.
/// It is placed around the onset (direct sound) and has a separately chosen half-window shape on each
/// side: the left side rises from its outer edge to 1 at the onset, the right side falls from 1 at the
/// onset to its outer edge.
public struct ResponseWindow: Codable, Hashable {
    public enum Shape: String, Codable, CaseIterable, Identifiable {
        case rectangular = "Rectangular"
        case hann = "Hann"
        case hamming = "Hamming"
        case blackman = "Blackman"
        /// Flat, then a Hann taper over the outer `taper` fraction of the side.
        case tukey = "Tukey"
        public var id: String { rawValue }

        /// Gain at `x` from the outer edge (0) to the onset (1).
        public func gain(_ x: Double, taper: Double) -> Double {
            let x = min(max(x, 0), 1)
            switch self {
            case .rectangular: return 1
            case .hann: return 0.5 - 0.5 * cos(Double.pi * x)
            case .hamming: return 0.54 - 0.46 * cos(Double.pi * x)
            case .blackman: return max(0, 0.42 - 0.5 * cos(Double.pi * x) + 0.08 * cos(2 * Double.pi * x))
            case .tukey:
                let a = min(max(taper, 0), 1)
                return a > 0 && x < a ? 0.5 - 0.5 * cos(Double.pi * x / a) : 1
            }
        }
    }

    /// Seconds before the onset where the window starts.
    public var left: Double
    /// Seconds after the onset where the window ends.
    public var right: Double
    public var leftShape: Shape
    public var rightShape: Shape
    /// Fraction of each side, at its outer edge, that a Tukey shape tapers over. 0 is a hard cut.
    public var leftTaper: Double
    public var rightTaper: Double

    public init(left: Double, right: Double, leftShape: Shape = .hann, rightShape: Shape = .tukey,
                leftTaper: Double = 0.5, rightTaper: Double = 0.25) {
        self.left = left
        self.right = right
        self.leftShape = leftShape
        self.rightShape = rightShape
        self.leftTaper = leftTaper
        self.rightTaper = rightTaper
    }

    /// 5 ms before the onset (Hann) to 1 s after it (Tukey, 25 % taper).
    public static let standard = ResponseWindow(left: 0.005, right: 1.0)

    // Windows saved before the shapes existed have only left, right and rightTaper.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let standard = ResponseWindow.standard
        left = try c.decode(Double.self, forKey: .left)
        right = try c.decode(Double.self, forKey: .right)
        leftShape = try c.decodeIfPresent(Shape.self, forKey: .leftShape) ?? standard.leftShape
        rightShape = try c.decodeIfPresent(Shape.self, forKey: .rightShape) ?? standard.rightShape
        leftTaper = try c.decodeIfPresent(Double.self, forKey: .leftTaper) ?? standard.leftTaper
        rightTaper = try c.decodeIfPresent(Double.self, forKey: .rightTaper) ?? standard.rightTaper
    }

    /// Gain of the window at `i` samples from the onset.
    public func gain(atOffset i: Int, sampleRate fs: Double) -> Double {
        let leftN = max(0, Int((left * fs).rounded()))
        let rightN = max(1, Int((right * fs).rounded()))
        if i < -leftN || i >= rightN { return 0 }
        if i < 0 { return leftShape.gain(Double(i + leftN) / Double(leftN), taper: leftTaper) }
        return rightShape.gain(Double(rightN - i) / Double(rightN), taper: rightTaper)
    }

    /// The windowed part of `ir`, and the index in `ir` of its first sample.
    public func apply(to ir: [Double], onset: Int, sampleRate fs: Double) -> (samples: [Double], start: Int) {
        let start = max(0, onset - max(0, Int((left * fs).rounded())))
        let end = min(ir.count, onset + max(1, Int((right * fs).rounded())))
        guard start < end else { return ([], start) }
        return ((start..<end).map { ir[$0] * gain(atOffset: $0 - onset, sampleRate: fs) }, start)
    }

    /// The frequency response of `ir` within the window, with the times its phase is drawn against.
    public struct Response {
        public let response: FrequencyResponse
        /// Seconds from the start of the window to the onset.
        public let onsetDelay: Double
        /// Seconds from the start of the window to the impulse's peak, to a fraction of a sample: the
        /// time the phase is drawn relative to, as REW does. The onset (the first sample within 20 dB
        /// of the peak) is a few samples early, since a band-limited pulse rises before its peak, and a
        /// whole number of samples: removing that delay instead left the phase of a pure delay
        /// wrapping at high frequencies (135 degrees out at 10 kHz).
        public let peakDelay: Double
    }

    /// The windowed part of `ir` as a frequency response, zero-padded to at least a second so short
    /// windows still draw as smooth curves.
    public func response(of ir: [Double], onset: Int, sampleRate fs: Double) -> Response {
        let (samples, start) = apply(to: ir, onset: onset, sampleRate: fs)
        let response = FrequencyResponse(impulseResponse: samples, sampleRate: fs,
                                         fftSize: FFT.size(atLeast: max(samples.count, Int(fs))))
        let peak = samples.isEmpty ? Double(onset - start) : Peak.interpolatedIndex(of: samples)
        return Response(response: response, onsetDelay: Double(onset - start) / fs, peakDelay: peak / fs)
    }

    /// Phase in degrees with `delay` seconds removed, wrapped to (-180, 180].
    public static func phase(_ degrees: Double, frequency: Double, removingDelay delay: Double) -> Double {
        var p = (degrees + 360 * frequency * delay).truncatingRemainder(dividingBy: 360)
        if p > 180 { p -= 360 } else if p <= -180 { p += 360 }
        return p
    }
}
