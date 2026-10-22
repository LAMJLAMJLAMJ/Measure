import Foundation

/// Speech Transmission Index from an impulse response (IEC 60268-16:2020, edition 5, indirect method).
///
/// The modulation transfer function of each octave band comes from the squared impulse response
/// (Schroeder's method). When speech and background noise levels are given, it is reduced by the
/// noise, by auditory masking from the band below and by the hearing threshold (A.2.3, A.2.4, A.4).
/// The band filters run backwards in time, as A.3.2.2 requires.
public enum SpeechTransmission {
    /// Octave bands, Hz.
    public static let bands: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000]
    /// The 14 modulation frequencies, Hz.
    public static let modulationFrequencies: [Double] = [0.63, 0.8, 1, 1.25, 1.6, 2, 2.5, 3.15, 4, 5, 6.3, 8, 10, 12.5]
    /// Band weights (male speech), Table A.1.
    public static let alpha: [Double] = [0.085, 0.127, 0.230, 0.233, 0.309, 0.224, 0.173]
    /// Redundancy factors between adjacent bands (male speech), Table A.1.
    public static let beta: [Double] = [0.085, 0.078, 0.065, 0.011, 0.047, 0.095]
    /// Male speech spectrum, octave levels relative to the A-weighted speech level, dB, Table A.4.
    /// (Changed in edition 5; edition 4 used 2.9, 2.9, −0.8, −6.8, −12.8, −18.8, −24.8.)
    public static let maleSpeechSpectrum: [Double] = [-2.5, 0.5, 0, -6, -12, -18, -24]
    /// Absolute speech reception threshold per band, dB SPL, Table A.3.
    public static let receptionThreshold: [Double] = [46, 27, 12, 6.5, 7.5, 8, 12]

    /// Octave speech levels for an A-weighted speech level, using the male speech spectrum.
    public static func speechLevels(aWeighted level: Double) -> [Double] {
        maleSpeechSpectrum.map { level + $0 }
    }

    public struct Conditions: Hashable {
        /// Speech level per octave band, dB SPL. Needed for noise, masking and threshold.
        public var speechLevels: [Double]?
        /// Background noise per octave band, dB SPL. Nil means no noise.
        public var noiseLevels: [Double]?
        /// Apply auditory masking and the reception threshold (needs speech levels).
        public var auditoryEffects: Bool

        public init(speechLevels: [Double]? = nil, noiseLevels: [Double]? = nil, auditoryEffects: Bool = true) {
            self.speechLevels = speechLevels
            self.noiseLevels = noiseLevels
            self.auditoryEffects = auditoryEffects
        }
    }

    public struct Result {
        /// Corrected modulation transfer values, `mtf[band][modulation frequency]`.
        public let mtf: [[Double]]
        /// Modulation transfer index per band.
        public let mti: [Double]
        public let sti: Double
        /// Qualification band per Annex F, A+ to U.
        public var rating: String { SpeechTransmission.rating(sti) }
    }

    /// Modulation transfer function of `h` (already band filtered, starting at the direct sound).
    public static func mtf(_ h: [Double], sampleRate fs: Double) -> [Double] {
        let e = h.map { $0 * $0 }
        let total = e.reduce(0, +)
        guard total > 0 else { return modulationFrequencies.map { _ in 0 } }
        return modulationFrequencies.map { f in
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * f / fs
            for (i, v) in e.enumerated() where v > 0 {
                re += v * cos(w * Double(i))
                im -= v * sin(w * Double(i))
            }
            return sqrt(re * re + im * im) / total
        }
    }

    /// - Parameters:
    ///   - onset: index of the direct sound. Analysis starts 50 ms earlier, because the backward band
    ///     filters ring before it.
    ///   - truncation: per band, seconds after the onset where the response meets its noise floor; the
    ///     rest is left out so measurement noise does not lower the result. Nil uses the whole response.
    public static func analyze(impulseResponse ir: [Double], sampleRate fs: Double, onset: Int,
                               conditions: Conditions = Conditions(), truncation: [Double?]? = nil) -> Result {
        let onset = min(max(0, onset), ir.count)
        let start = max(0, onset - Int(0.05 * fs))
        var raw: [[Double]] = []
        for (k, nominal) in bands.enumerated() {
            let band = BandResolution.octave.band(nominal: nominal)
            guard band.upper < fs / 2 else {
                raw.append(modulationFrequencies.map { _ in 0 })
                continue
            }
            let filtered = BandPassFilter(band: band, sampleRate: fs).applyTimeReversed(ir)
            var end = filtered.count
            if let t = truncation?[k] { end = min(end, onset + max(1, Int(t * fs))) }
            raw.append(mtf(Array(filtered[start..<max(start, end)]), sampleRate: fs))
        }
        return correct(raw, conditions: conditions)
    }

    /// Applies noise, masking and threshold to raw modulation transfer values and computes the STI (A.2).
    /// m'' = m · I_s / (I_s + I_n) · I_k / (I_k + I_am + I_rt) with I_k = I_s + I_n, which simplifies to
    /// m · I_s / (I_s + I_n + I_am + I_rt).
    public static func correct(_ raw: [[Double]], conditions c: Conditions) -> Result {
        func intensity(_ db: Double) -> Double { pow(10, db / 10) }
        var mtf = raw
        if let speech = c.speechLevels, speech.count == bands.count {
            let noise = c.noiseLevels?.count == bands.count ? c.noiseLevels! : nil
            let signal = speech.map(intensity)
            let noiseI = noise?.map(intensity) ?? bands.map { _ in 0 }
            for k in bands.indices {
                var masking = 0.0, threshold = 0.0
                if c.auditoryEffects {
                    threshold = intensity(receptionThreshold[k])
                    if k > 0 {
                        let below = signal[k - 1] + noiseI[k - 1]
                        let level = 10 * log10(below)
                        let slope: Double
                        switch level {
                        case ..<63: slope = 0.5 * level - 65
                        case ..<67: slope = 1.8 * level - 146.9
                        case ..<100: slope = 0.5 * level - 59.8
                        default: slope = -10
                        }
                        masking = below * intensity(slope)
                    }
                }
                let factor = signal[k] / (signal[k] + noiseI[k] + masking + threshold)
                mtf[k] = mtf[k].map { $0 * factor }
            }
        }
        let mti = mtf.map { values -> Double in
            let ti = values.map { m -> Double in
                let m = min(max(m, 1e-12), 1 - 1e-12)
                let snr = min(max(10 * log10(m / (1 - m)), -15), 15)
                return (snr + 15) / 30
            }
            return ti.reduce(0, +) / Double(ti.count)
        }
        var sti = 0.0
        for k in bands.indices { sti += alpha[k] * mti[k] }
        for k in beta.indices { sti -= beta[k] * sqrt(mti[k] * mti[k + 1]) }
        return Result(mtf: mtf, mti: mti, sti: min(max(sti, 0), 1))
    }

    public static func rating(_ sti: Double) -> String {
        let limits: [(Double, String)] = [(0.76, "A+"), (0.72, "A"), (0.68, "B"), (0.64, "C"), (0.60, "D"), (0.56, "E"),
                                          (0.52, "F"), (0.48, "G"), (0.44, "H"), (0.40, "I"), (0.36, "J")]
        return limits.first { sti >= $0.0 }?.1 ?? "U"
    }
}
