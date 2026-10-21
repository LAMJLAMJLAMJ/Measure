import Foundation

/// Deterministic test signals, so every run (and every machine) sees the same numbers.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Standard normal, by Box-Muller.
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

enum TestSignals {
    /// Gaussian noise with an exponential energy decay of 60 dB in `rt` seconds, plus steady background
    /// noise `noiseDB` below the decay's starting energy. `delay` samples of background noise come first.
    static func exponentialDecay(rt: Double, sampleRate fs: Double, duration: Double,
                                 noiseDB: Double = -200, delay: Int = 0, seed: UInt64 = 1) -> [Double] {
        var rng = SeededRandom(seed: seed)
        let n = Int(duration * fs)
        let a = 3 * log(10) / rt // amplitude decay rate: 20 log10(e^(-a rt)) = -60 dB
        let noiseAmp = pow(10, noiseDB / 20)
        return (0..<(n + delay)).map { i in
            let background = noiseAmp * rng.gaussian()
            guard i >= delay else { return background }
            let t = Double(i - delay) / fs
            return rng.gaussian() * exp(-a * t) + background
        }
    }

    static func sine(frequency: Double, sampleRate: Double, count: Int, amplitude: Double = 1) -> [Double] {
        (0..<count).map { amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate) }
    }
}
