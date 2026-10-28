import Foundation

/// Time-domain and time-frequency views of an impulse response.
public enum TimeFrequency {
    /// One band of an impulse response, through the same Butterworth band-pass as the room acoustic
    /// parameters but with zero phase, so its arrivals line up with the unfiltered response.
    /// Nil when the band reaches the Nyquist frequency.
    public static func bandFiltered(_ ir: [Double], sampleRate fs: Double, band: Band) -> [Double]? {
        guard band.upper < 0.5 * fs else { return nil }
        return BandPassFilter(band: band, sampleRate: fs).applyZeroPhase(ir)
    }

    /// Energy-time curve: the Hilbert envelope of the impulse response in dB, 0 dB at its peak.
    public static func energyTimeCurve(_ ir: [Double]) -> [Double] {
        energyTimeCurveAndPeak(ir).curve
    }

    /// The energy-time curve in dB re its peak, and that peak in dB re a full-scale sample, so the
    /// curve can also be drawn at its own level: `curve[i] + peak`.
    public static func energyTimeCurveAndPeak(_ ir: [Double]) -> (curve: [Double], peak: Double) {
        let env = envelope(ir)
        let peak = max(env.max() ?? 1, .leastNonzeroMagnitude)
        return (env.map { 10 * log10(max($0 / peak, 1e-30)) }, 10 * log10(peak))
    }

    /// The squared Hilbert envelope of `x`: its instantaneous power, not normalised.
    public static func envelope(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return [] }
        let fft = FFT(size: FFT.size(atLeast: x.count))
        var spectrum = fft.forward(x)
        // Analytic signal: double the positive frequencies, keep DC and Nyquist, drop the negatives.
        for k in 1..<(spectrum.count - 1) {
            spectrum.real[k] *= 2
            spectrum.imag[k] *= 2
        }
        var full = SplitComplex(count: fft.size)
        for k in 0..<spectrum.count {
            full.real[k] = spectrum.real[k]
            full.imag[k] = spectrum.imag[k]
        }
        let analytic = fft.transform(full, inverse: true)
        return (0..<x.count).map { analytic.real[$0] * analytic.real[$0] + analytic.imag[$0] * analytic.imag[$0] }
    }

    /// A grid of levels in dB: `levels[t][f]` at `times[t]` (seconds) and `frequencies[f]` (Hz).
    public struct Grid {
        public let times: [Double]
        public let frequencies: [Double]
        public let levels: [[Double]]
    }

    /// Short-time spectrum with a Hann window.
    /// - Parameters:
    ///   - windowSize: samples per frame (power of two).
    ///   - hop: samples between frames.
    public static func spectrogram(_ x: [Double], sampleRate: Double, windowSize: Int = 2048, hop: Int = 256) -> Grid {
        let fft = FFT(size: windowSize)
        let window = hann(windowSize)
        let windowPower = window.reduce(0) { $0 + $1 * $1 }
        var times = [Double](), levels = [[Double]]()
        var start = 0
        while start + windowSize <= max(x.count, windowSize) {
            var frame = [Double](repeating: 0, count: windowSize)
            for i in 0..<windowSize where start + i < x.count { frame[i] = x[start + i] * window[i] }
            let p = fft.forward(frame).power
            levels.append(p.map { 10 * log10(max($0 / windowPower, 1e-30)) })
            times.append((Double(start) + Double(windowSize) / 2) / sampleRate)
            start += hop
        }
        return Grid(times: times, frequencies: fft.binFrequencies(sampleRate: sampleRate), levels: levels)
    }

    /// Cumulative spectral decay (waterfall): the spectrum of the impulse response from successively
    /// later start times, each with a fixed-length window that ends in a half-Hann fade.
    /// Levels are relative to the peak of the first slice.
    /// - Parameters:
    ///   - start: index of the impulse response peak or onset.
    ///   - windowLength: seconds of response in each slice.
    ///   - slices: number of slices.
    ///   - step: seconds between slices.
    public static func waterfall(_ ir: [Double], sampleRate: Double, start: Int = 0, windowLength: Double = 0.3,
                                 slices: Int = 30, step: Double = 0.01) -> Grid {
        let length = Int(windowLength * sampleRate)
        let fft = FFT(size: FFT.size(atLeast: length))
        let fade = max(1, length / 4)
        var times = [Double](), levels = [[Double]]()
        for s in 0..<slices {
            let offset = start + Int(Double(s) * step * sampleRate)
            guard offset < ir.count else { break }
            var frame = [Double](repeating: 0, count: length)
            for i in 0..<length where offset + i < ir.count {
                var w = 1.0
                let fromEnd = length - 1 - i
                if fromEnd < fade { w = 0.5 * (1 - cos(Double.pi * Double(fromEnd) / Double(fade))) }
                frame[i] = ir[offset + i] * w
            }
            levels.append(fft.forward(frame).power.map { 10 * log10(max($0, 1e-30)) })
            times.append(Double(offset - start) / sampleRate)
        }
        let ref = levels.first?.max() ?? 0
        return Grid(times: times, frequencies: fft.binFrequencies(sampleRate: sampleRate),
                    levels: levels.map { $0.map { $0 - ref } })
    }

    static func hann(_ n: Int) -> [Double] {
        (0..<n).map { 0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(n))) }
    }
}
