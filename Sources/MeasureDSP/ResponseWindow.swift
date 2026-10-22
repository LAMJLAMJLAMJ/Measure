import Foundation

/// The window that cuts a frequency response out of an impulse response, like REW's IR windows.
/// It is placed around the onset (direct sound): a half-Hann rise over the part before the onset,
/// flat after it, and a half-Hann fade over the last part of the right side (a Tukey window).
public struct ResponseWindow: Codable, Hashable {
    /// Seconds before the onset where the window starts.
    public var left: Double
    /// Seconds after the onset where the window ends.
    public var right: Double
    /// Fraction of the right side, at its end, that fades out. 0 is a hard cut.
    public var rightTaper: Double

    public init(left: Double, right: Double, rightTaper: Double = 0.25) {
        self.left = left
        self.right = right
        self.rightTaper = rightTaper
    }

    /// 5 ms before the onset to 1 s after it.
    public static let standard = ResponseWindow(left: 0.005, right: 1.0)

    /// Gain of the window at `i` samples from the onset.
    public func gain(atOffset i: Int, sampleRate fs: Double) -> Double {
        let leftN = max(0, Int((left * fs).rounded()))
        let rightN = max(1, Int((right * fs).rounded()))
        let taperN = Int((Double(rightN) * min(max(rightTaper, 0), 1)).rounded())
        if i < -leftN || i >= rightN { return 0 }
        if i < 0 { return 0.5 - 0.5 * cos(Double.pi * Double(i + leftN) / Double(leftN)) }
        let fadeStart = rightN - taperN
        if taperN > 0 && i >= fadeStart { return 0.5 + 0.5 * cos(Double.pi * Double(i - fadeStart) / Double(taperN)) }
        return 1
    }

    /// The windowed part of `ir`, and the index in `ir` of its first sample.
    public func apply(to ir: [Double], onset: Int, sampleRate fs: Double) -> (samples: [Double], start: Int) {
        let start = max(0, onset - max(0, Int((left * fs).rounded())))
        let end = min(ir.count, onset + max(1, Int((right * fs).rounded())))
        guard start < end else { return ([], start) }
        return ((start..<end).map { ir[$0] * gain(atOffset: $0 - onset, sampleRate: fs) }, start)
    }
}
