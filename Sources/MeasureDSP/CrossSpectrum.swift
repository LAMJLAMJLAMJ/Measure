import Foundation

/// Dual-channel FFT transfer function, as live analysers measure it: the system's response is the
/// averaged cross spectrum of reference and measurement over the averaged reference power,
/// H = Gxy / Gxx. Any signal with energy at a frequency will do, pink noise or programme, as long as
/// the reference is the signal fed to the system. Coherence, |Gxy|² / (Gxx Gyy), shows how much of
/// the measurement the reference explains: 1 for a clean linear path, lower with noise, reverberation
/// longer than the FFT, or a delay the reference was not aligned for.
public struct CrossSpectrum {
    public let fftSize: Int
    public let sampleRate: Double
    private let fft: FFT
    private let window: [Double]

    // Averaged spectra, bins 0...fftSize/2.
    private var gxx: [Double]
    private var gyy: [Double]
    private var gxyRe: [Double]
    private var gxyIm: [Double]
    /// Blocks averaged since the last reset.
    public private(set) var blocks = 0

    public init(fftSize: Int, sampleRate: Double) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        fft = FFT(size: fftSize)
        window = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) }
        let bins = fftSize / 2 + 1
        gxx = [Double](repeating: 0, count: bins)
        gyy = gxx
        gxyRe = gxx
        gxyIm = gxx
    }

    public mutating func reset() {
        for k in gxx.indices { gxx[k] = 0; gyy[k] = 0; gxyRe[k] = 0; gxyIm[k] = 0 }
        blocks = 0
    }

    /// Adds one block of `fftSize` samples of each channel, Hann-windowed. The average is a running
    /// mean for the first `averages` blocks and exponential after that, so it settles quickly and then
    /// follows changes with a memory of about `averages` blocks.
    public mutating func add(reference x: [Double], measurement y: [Double], averages: Int) {
        precondition(x.count == fftSize && y.count == fftSize, "blocks must be fftSize samples")
        let X = fft.forward(zip(x, window).map { $0 * $1 })
        let Y = fft.forward(zip(y, window).map { $0 * $1 })
        blocks += 1
        let a = 1 / Double(min(blocks, max(1, averages)))
        for k in gxx.indices {
            let xr = X.real[k], xi = X.imag[k], yr = Y.real[k], yi = Y.imag[k]
            gxx[k] += a * (xr * xr + xi * xi - gxx[k])
            gyy[k] += a * (yr * yr + yi * yi - gyy[k])
            // conj(X) · Y
            gxyRe[k] += a * (xr * yr + xi * yi - gxyRe[k])
            gxyIm[k] += a * (xr * yi - xi * yr - gxyIm[k])
        }
    }

    /// H at bins 0...fftSize/2. Bins where the reference has no energy are 0.
    private var transfer: SplitComplex {
        let peak = gxx.max() ?? 0
        var h = SplitComplex(count: gxx.count)
        for k in gxx.indices where gxx[k] > peak * 1e-12 && gxx[k] > 0 {
            h.real[k] = gxyRe[k] / gxx[k]
            h.imag[k] = gxyIm[k] / gxx[k]
        }
        return h
    }

    /// Magnitude (dB) and phase (degrees) of H, DC left out.
    public var response: FrequencyResponse {
        let h = transfer
        let freqs = fft.binFrequencies(sampleRate: sampleRate)
        return FrequencyResponse(frequencies: Array(freqs.dropFirst()),
                                 magnitude: h.power.dropFirst().map { 10 * log10(max($0, 1e-30)) },
                                 phase: h.phase.dropFirst().map { $0 * 180 / Double.pi })
    }

    /// Coherence per bin, DC left out, matching `response.frequencies`.
    public var coherence: [Double] {
        (1..<gxx.count).map { k in
            let d = gxx[k] * gyy[k]
            return d > 0 ? min(1, (gxyRe[k] * gxyRe[k] + gxyIm[k] * gxyIm[k]) / d) : 0
        }
    }

    /// The impulse response of H, `fftSize` samples. It is circular: a delay longer than half the FFT
    /// wraps round to the end.
    public var impulseResponse: [Double] { fft.inverse(transfer) }

    /// Delay of the measurement behind the reference, in samples, from the peak of the impulse
    /// response. Negative when the measurement leads (the peak wrapped into the second half).
    /// Nil before any block has been added.
    public var delay: Int? {
        guard blocks > 0 else { return nil }
        let ir = impulseResponse
        guard let peak = ir.indices.max(by: { abs(ir[$0]) < abs(ir[$1]) }) else { return nil }
        return peak < fftSize / 2 ? peak : peak - fftSize
    }
}

/// Pink noise test signals.
public enum PinkNoise {
    /// Pink noise that repeats every `count` samples (a power of two): flat power per octave from
    /// `low` to `high`, random phase, scaled to a peak of 1. When the analyser's FFT is the same
    /// length, every block holds whole periods, so the transfer function has no leakage.
    /// `white` gives flat power per hertz instead.
    public static func periodic(count: Int, sampleRate: Double, low: Double = 20, high: Double = 20_000,
                                seed: UInt64 = 0x5EED, white: Bool = false) -> [Double] {
        let fft = FFT(size: count)
        var spectrum = SplitComplex(count: count / 2 + 1)
        var state = seed
        func random() -> Double {
            // xorshift64*, the same sequence on every platform.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return Double((state &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
        }
        for k in 1..<(count / 2) {
            let f = Double(k) * sampleRate / Double(count)
            guard f >= low && f <= high else { continue }
            let amplitude = white ? 1 : 1 / f.squareRoot()
            let phase = 2 * Double.pi * random()
            spectrum.real[k] = amplitude * cos(phase)
            spectrum.imag[k] = amplitude * sin(phase)
        }
        let x = fft.inverse(spectrum)
        let peak = x.map { abs($0) }.max() ?? 1
        return peak > 0 ? x.map { $0 / peak } : x
    }

    /// RMS level re full scale of `x`, in dB.
    public static func rmsLevel(_ x: [Double]) -> Double {
        10 * log10(max(x.reduce(0) { $0 + $1 * $1 } / Double(max(1, x.count)), 1e-30))
    }
}
