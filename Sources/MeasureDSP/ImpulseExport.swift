import Foundation

/// Prepares impulse responses for export as WAV files: trimmed, faded and scaled as asked.
public struct ImpulseExport: Equatable {
    /// Where an exported response starts.
    public enum Start: String, CaseIterable, Identifiable, Codable {
        /// The response as measured, from the start of the deconvolution.
        case asMeasured = "As measured"
        /// A little before the direct sound (`preRoll`), so convolution adds no extra delay.
        case directSound = "At the direct sound"
        public var id: String { rawValue }
    }

    public var format: WAV.SampleFormat
    public var start: Start
    /// Seconds kept before the direct sound when starting there.
    public var preRoll: Double
    /// Seconds kept from the start, or nil for all of it. A cut end is faded out.
    public var length: Double?
    /// Peak level to scale each response to, dBFS, or nil to keep its level.
    public var normalizeTo: Double?

    public init(format: WAV.SampleFormat = .float32, start: Start = .asMeasured, preRoll: Double = 0.005,
                length: Double? = nil, normalizeTo: Double? = nil) {
        self.format = format
        self.start = start
        self.preRoll = preRoll
        self.length = length
        self.normalizeTo = normalizeTo
    }

    /// The samples to write, and the gain applied to them in dB (0 when the level is kept). A
    /// fixed-point format cannot hold peaks above full scale, so those are scaled down to it.
    public func prepare(_ ir: [Double], onset: Int, sampleRate fs: Double) -> (samples: [Double], gain: Double) {
        let out = levelled([trimmed(ir, onset: onset, sampleRate: fs)])
        return (out.channels[0], out.gain)
    }

    /// The response cut to the start and length asked for, with a cut end faded out.
    public func trimmed(_ ir: [Double], onset: Int, sampleRate fs: Double) -> [Double] {
        var first = 0
        if start == .directSound { first = min(max(0, onset - Int((preRoll * fs).rounded())), ir.count) }
        var last = ir.count
        if let length { last = min(ir.count, first + max(1, Int((length * fs).rounded()))) }
        var x = Array(ir[first..<last])
        if last < ir.count {
            // Fade the cut end over 5 ms or a tenth of the length, whichever is shorter.
            let fade = max(1, min(Int(0.005 * fs), x.count / 10))
            for k in 0..<min(fade, x.count) {
                let i = x.count - 1 - k
                x[i] *= 0.5 * (1 - cos(Double.pi * Double(k) / Double(fade)))
            }
        }
        return x
    }

    /// Channels scaled together by one gain, so their relative levels stay: to the normalising peak
    /// if one is set, and down to full scale if a fixed-point format would clip. The gain is in dB.
    public func levelled(_ channels: [[Double]]) -> (channels: [[Double]], gain: Double) {
        let peak = channels.map { $0.map(abs).max() ?? 0 }.max() ?? 0
        guard peak > 0 else { return (channels, 0) }
        var target: Double?
        if let normalizeTo { target = pow(10, normalizeTo / 20) }
        if format != .float32 && (target ?? peak) > 1 { target = 1 }
        guard let target else { return (channels, 0) }
        let g = target / peak
        return (channels.map { $0.map { $0 * g } }, 20 * log10(g))
    }

    /// A file name from a trace name: no path separators or characters Finder dislikes.
    public static func fileName(_ name: String, taken: Set<String> = []) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        var base = String(name.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.hasPrefix(".") { base = "Impulse response" + base }
        var candidate = base + ".wav"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(n).wav"
            n += 1
        }
        return candidate
    }
}
