import Foundation

/// Magnitude and phase against frequency, from a measurement or an imported file.
public struct FrequencyResponse: Equatable {
    /// Frequencies in Hz, ascending.
    public var frequencies: [Double]
    /// Level in dB.
    public var magnitude: [Double]
    /// Phase in degrees, wrapped to (-180, 180]. Nil when the source had no phase.
    public var phase: [Double]?

    public init(frequencies: [Double], magnitude: [Double], phase: [Double]? = nil) {
        precondition(frequencies.count == magnitude.count, "frequencies and magnitude differ in length")
        precondition(phase == nil || phase!.count == frequencies.count, "phase length differs")
        self.frequencies = frequencies
        self.magnitude = magnitude
        self.phase = phase
    }

    /// Frequency response of an impulse response. Bin 0 (DC) is left out.
    /// - Parameter fftSize: zero-pads to this size for finer frequency spacing; defaults to the next power of two.
    public init(impulseResponse ir: [Double], sampleRate: Double, fftSize: Int? = nil) {
        let fft = FFT(size: fftSize ?? FFT.size(atLeast: ir.count))
        let spectrum = fft.forward(Array(ir.prefix(fft.size)))
        let freqs = fft.binFrequencies(sampleRate: sampleRate)
        let power = spectrum.power
        let phase = spectrum.phase
        self.init(frequencies: Array(freqs.dropFirst()),
                  magnitude: power.dropFirst().map { 10 * log10(max($0, 1e-30)) },
                  phase: phase.dropFirst().map { $0 * 180 / Double.pi })
    }

    /// Fractional-octave smoothing of the magnitude (power average over a window of 1/`fraction` octave
    /// centred on each point, as REW and most analysers do). Phase is dropped.
    public func smoothed(fraction: Double) -> FrequencyResponse {
        precondition(fraction > 0)
        let half = pow(2, 0.5 / fraction)
        let power = magnitude.map { pow(10, $0 / 10) }
        // Prefix sums make each window an O(1) lookup.
        var prefix = [0.0]
        prefix.reserveCapacity(power.count + 1)
        for p in power { prefix.append(prefix.last! + p) }

        var lo = 0, hi = 0
        var out = [Double](repeating: 0, count: frequencies.count)
        for i in frequencies.indices {
            let fLo = frequencies[i] / half, fHi = frequencies[i] * half
            while lo < i && frequencies[lo] < fLo { lo += 1 }
            if hi < i { hi = i }
            while hi + 1 < frequencies.count && frequencies[hi + 1] <= fHi { hi += 1 }
            let avg = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            out[i] = 10 * log10(max(avg, 1e-30))
        }
        return FrequencyResponse(frequencies: frequencies, magnitude: out, phase: nil)
    }

    /// Linear interpolation of the magnitude on a log-frequency axis. Values outside the range are held at the ends.
    public func magnitude(at f: Double) -> Double {
        guard let first = frequencies.first, let last = frequencies.last else { return 0 }
        if f <= first { return magnitude.first! }
        if f >= last { return magnitude.last! }
        var lo = 0, hi = frequencies.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= f { lo = mid } else { hi = mid }
        }
        let x0 = log(frequencies[lo]), x1 = log(frequencies[hi])
        let w = x1 == x0 ? 0 : (log(f) - x0) / (x1 - x0)
        return magnitude[lo] + w * (magnitude[hi] - magnitude[lo])
    }

    public enum AverageMethod: String, CaseIterable, Identifiable {
        /// Mean of the power (RMS average): what a spatial average of several mic positions usually uses.
        case power = "Power (RMS)"
        /// Mean of the levels in dB.
        case decibel = "dB"
        public var id: String { rawValue }
    }

    /// The average of several responses' magnitudes. Responses on the same frequency grid (the same
    /// FFT size and sample rate) are averaged bin by bin. Otherwise each is smoothed to 1/48 octave and
    /// averaged at 96 points per octave over the range they all cover. Phase is dropped.
    public static func average(_ responses: [FrequencyResponse], method: AverageMethod) -> FrequencyResponse? {
        guard let first = responses.first, !first.frequencies.isEmpty else { return nil }
        guard responses.count > 1 else { return FrequencyResponse(frequencies: first.frequencies, magnitude: first.magnitude) }
        let sameGrid = responses.allSatisfy { $0.frequencies == first.frequencies }
        let frequencies: [Double]
        let levels: [[Double]]
        if sameGrid {
            frequencies = first.frequencies
            levels = responses.map(\.magnitude)
        } else {
            guard let low = responses.compactMap({ $0.frequencies.first }).max(),
                  let high = responses.compactMap({ $0.frequencies.last }).min(), high > low else { return nil }
            let count = Int((log2(high / low) * 96).rounded(.down)) + 1
            frequencies = (0..<count).map { low * pow(2, Double($0) / 96) }
            levels = responses.map { r in
                let smooth = r.smoothed(fraction: 48)
                return frequencies.map { smooth.magnitude(at: $0) }
            }
        }
        let n = Double(levels.count)
        let magnitude = frequencies.indices.map { i -> Double in
            switch method {
            case .power: return 10 * log10(max(levels.map { pow(10, $0[i] / 10) }.reduce(0, +) / n, 1e-30))
            case .decibel: return levels.map { $0[i] }.reduce(0, +) / n
            }
        }
        return FrequencyResponse(frequencies: frequencies, magnitude: magnitude)
    }

    /// Subtracts a calibration curve (for example a mic calibration file) from the magnitude.
    public func applyingCalibration(_ calibration: FrequencyResponse) -> FrequencyResponse {
        var out = self
        out.magnitude = zip(frequencies, magnitude).map { $1 - calibration.magnitude(at: $0) }
        return out
    }

    /// Resamples onto log-spaced points, `pointsPerOctave` per octave, between `low` and `high`.
    public func logResampled(pointsPerOctave: Int = 48, low: Double = 20, high: Double = 20_000) -> FrequencyResponse {
        let octaves = log2(high / low)
        let count = Int((octaves * Double(pointsPerOctave)).rounded()) + 1
        let freqs = (0..<count).map { low * pow(2, Double($0) / Double(pointsPerOctave)) }
        return FrequencyResponse(frequencies: freqs, magnitude: freqs.map { magnitude(at: $0) }, phase: nil)
    }
}

// MARK: - Text import (REW exports and mic calibration files)

public enum FrequencyResponseText {
    public enum ParseError: Error, CustomStringConvertible {
        case noData
        public var description: String { "No frequency/level data found in the file" }
    }

    /// Parses REW "Export measurement as text" files and mic calibration files
    /// (UMIK, Earthworks, etc.): lines of `frequency level [phase]` separated by spaces, tabs,
    /// commas or semicolons. Header and comment lines (starting with `*`, `#`, `"` or text) are skipped.
    /// Lines like `Sens Factor =-1.23dB` are reported as `sensitivity`.
    public static func parse(_ text: String) throws -> (response: FrequencyResponse, sensitivity: Double?) {
        var f = [Double](), m = [Double](), p = [Double]()
        var hasPhase = true
        var sensitivity: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.lowercased().contains("sens factor") || line.lowercased().contains("sensitivity") {
                sensitivity = firstNumber(in: line)
            }
            let fields = line.split(whereSeparator: { " \t,;".contains($0) }).compactMap { Double($0) }
            // A data line starts with a number and has at least frequency and level.
            guard let firstChar = line.first, firstChar.isNumber || firstChar == "." || firstChar == "-" || firstChar == "+",
                  fields.count >= 2, fields[0] > 0 else { continue }
            f.append(fields[0])
            m.append(fields[1])
            if fields.count >= 3 { p.append(fields[2]) } else { hasPhase = false }
        }
        guard !f.isEmpty else { throw ParseError.noData }
        // Keep ascending order even if the file was not sorted.
        let order = f.indices.sorted { f[$0] < f[$1] }
        let phase = hasPhase && p.count == f.count ? order.map { p[$0] } : nil
        return (FrequencyResponse(frequencies: order.map { f[$0] }, magnitude: order.map { m[$0] }, phase: phase), sensitivity)
    }

    public static func parse(contentsOf url: URL) throws -> (response: FrequencyResponse, sensitivity: Double?) {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    private static func firstNumber(in s: String) -> Double? {
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: "0123456789+-.").inverted
        return scanner.scanDouble()
    }
}
