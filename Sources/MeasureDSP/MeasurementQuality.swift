import Foundation

/// Checks a sweep measurement for the problems that make its results unreliable: an input that
/// clipped, a signal too low to use, and too little decay range above the noise for the
/// reverberation times (ISO 3382-1:2009, 5.3.3: the evaluation range must end at least 10 dB above
/// the noise, so T20 needs 35 dB and T30 45 dB between the peak and the noise).
public enum MeasurementQuality {
    public enum Issue: Equatable {
        /// A mic input's peak came within `clipLevel` of full scale. dBFS.
        case micClipped(peak: Double)
        /// The loopback input's peak came within `clipLevel` of full scale. dBFS.
        case loopbackClipped(peak: Double)
        /// The mic's peak was below `lowLevel`. dBFS.
        case lowLevel(peak: Double)
        /// Bands whose peak-to-noise ratio is too small for T30 (but enough for T20), and bands too
        /// small even for T20, with the lowest ratio in dB.
        case lowPeakToNoise(t30Bands: [Band], t20Bands: [Band], worst: Double)

        /// A short sentence for the status line.
        public var message: String {
            switch self {
            case .micClipped(let peak):
                return "Mic input clipped (peak \(format(peak)) dBFS): lower the sweep level or the input gain."
            case .loopbackClipped(let peak):
                return "Loopback input clipped (peak \(format(peak)) dBFS): lower the loopback gain."
            case .lowLevel(let peak):
                return "Low signal level (peak \(format(peak)) dBFS): raise the sweep level or the input gain."
            case .lowPeakToNoise(let t30, let t20, let worst):
                var parts: [String] = []
                if !t20.isEmpty { parts.append("T20 and T30 unreliable at \(names(t20)) Hz") }
                if !t30.isEmpty { parts.append("T30 unreliable at \(names(t30)) Hz") }
                return "Low signal-to-noise (down to \(String(format: "%.0f", worst)) dB): "
                    + parts.joined(separator: "; ")
                    + ". Raise the level, use a longer sweep or reduce the background noise."
            }
        }

        /// True for problems that spoil the whole measurement rather than some results.
        public var isSevere: Bool {
            switch self {
            case .micClipped, .loopbackClipped, .lowLevel: return true
            case .lowPeakToNoise(_, let t20, _): return !t20.isEmpty
            }
        }

        private func format(_ x: Double) -> String { String(format: "%.1f", x) }
        private func names(_ bands: [Band]) -> String { bands.map(\.description).joined(separator: ", ") }
    }

    /// Peaks above this are taken as clipping, dBFS. Some interfaces clip a little below 0 dBFS.
    public static let clipLevel = -1.0
    /// Peaks below this are too low to give a usable measurement, dBFS.
    public static let lowLevel = -50.0
    /// Peak-to-noise ratios needed for T20 and T30, dB.
    public static let t20Range = 35.0
    public static let t30Range = 45.0
    /// The octave bands checked for peak-to-noise: those the usual single-number results use.
    public static let checkedBands: ClosedRange<Double> = 125...4000

    /// The issues of one mic's measurement. `micPeak` and `loopbackPeak` are the recordings' peak
    /// levels in dBFS; `acoustics` gives each band's peak-to-noise ratio.
    public static func check(micPeak: Double?, loopbackPeak: Double? = nil,
                             acoustics: RoomAcousticsResult?) -> [Issue] {
        var issues: [Issue] = []
        if let peak = loopbackPeak, peak > clipLevel { issues.append(.loopbackClipped(peak: peak)) }
        if let peak = micPeak {
            if peak > clipLevel { issues.append(.micClipped(peak: peak)) }
            if peak < lowLevel { issues.append(.lowLevel(peak: peak)) }
        }
        if let acoustics {
            let bands = acoustics.bands.filter { band in
                guard let b = band.band else { return false }
                return checkedBands.contains(b.nominal) && band.peakToNoise.isFinite
            }
            let t20 = bands.filter { $0.peakToNoise < t20Range }
            let t30 = bands.filter { $0.peakToNoise >= t20Range && $0.peakToNoise < t30Range }
            if !t20.isEmpty || !t30.isEmpty {
                let worst = (t20 + t30).map(\.peakToNoise).min() ?? 0
                issues.append(.lowPeakToNoise(t30Bands: t30.compactMap(\.band), t20Bands: t20.compactMap(\.band),
                                              worst: worst))
            }
        }
        return issues
    }
}
