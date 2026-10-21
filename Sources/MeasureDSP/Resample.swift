import Foundation

/// Band-limited resampling by a ratio close to 1, for correcting the small clock difference
/// between two audio devices (tens of parts per million).
public enum Resampler {
    /// Taps each side of the output point. 64 gives a flat response to about 0.9 of Nyquist at 48 kHz.
    static let halfWidth = 64
    /// Sub-sample positions in the kernel table; results are interpolated linearly between them.
    static let phases = 256

    /// Kernel table: row p holds the weights for a point p/phases of a sample past an input sample.
    /// Blackman-windowed sinc with its cut-off at 0.95 of Nyquist.
    private static let table: [Double] = {
        let width = 2 * halfWidth
        let cutoff = 0.95
        var t = [Double](repeating: 0, count: (phases + 1) * width)
        for p in 0...phases {
            let frac = Double(p) / Double(phases)
            for k in 0..<width {
                // Distance from the output point to input sample (i - halfWidth + 1 + k), with i the sample just before it.
                let d = Double(k - halfWidth + 1) - frac
                let x = Double.pi * cutoff * d
                let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
                let u = (d + Double(halfWidth)) / Double(2 * halfWidth) // 0...1 across the kernel
                let window = 0.42 - 0.5 * cos(2 * Double.pi * u) + 0.08 * cos(4 * Double.pi * u)
                t[p * width + k] = cutoff * sinc * window
            }
            // Exact unity gain at DC for every sub-sample position.
            let sum = (0..<width).reduce(0.0) { $0 + t[p * width + $1] }
            for k in 0..<width { t[p * width + k] /= sum }
        }
        return t
    }()

    /// Resamples `x` so that it appears to run at `ratio` times its original rate: the result has
    /// y[m] = x(m / ratio), where x(.) is the band-limited signal between samples.
    ///
    /// For a signal played by device A and recorded by device B, `ratio` is B's actual sample rate
    /// divided by A's, and the result is the played signal as B's clock counts it.
    ///
    /// - Parameter ratio: close to 1 (within a few tenths of a percent). Output length is the input
    ///   length scaled by `ratio`, rounded down.
    public static func resample(_ x: [Double], ratio: Double) -> [Double] {
        precondition(ratio > 0.99 && ratio < 1.01, "resampling is meant for clock corrections within 1 %")
        guard x.count > 1 else { return x }
        if ratio == 1 { return x }

        let width = 2 * halfWidth
        let count = Int((Double(x.count - 1) * ratio).rounded(.down)) + 1
        var y = [Double](repeating: 0, count: count)
        table.withUnsafeBufferPointer { kernel in
            x.withUnsafeBufferPointer { input in
                for m in 0..<count {
                    let position = Double(m) / ratio
                    let i = Int(position.rounded(.down))
                    let frac = position - Double(i)
                    let scaled = frac * Double(phases)
                    let p = min(phases - 1, Int(scaled))
                    let w = scaled - Double(p)
                    let row0 = p * width, row1 = (p + 1) * width
                    let first = i - halfWidth + 1

                    var acc = 0.0
                    if first >= 0 && first + width <= input.count {
                        for k in 0..<width {
                            acc += input[first + k] * (kernel[row0 + k] + w * (kernel[row1 + k] - kernel[row0 + k]))
                        }
                    } else {
                        for k in 0..<width {
                            let j = first + k
                            guard j >= 0 && j < input.count else { continue }
                            acc += input[j] * (kernel[row0 + k] + w * (kernel[row1 + k] - kernel[row0 + k]))
                        }
                    }
                    y[m] = acc
                }
            }
        }
        return y
    }
}

/// Estimates a device's actual sample rate from the host-clock timestamps of its audio callbacks.
public enum ClockRate {
    /// Least-squares slope of device sample time against host time, in samples per second.
    /// Returns nil if there are too few points or the fit is poor (for example after a dropout).
    /// - Parameters:
    ///   - sampleTimes: device sample time at each callback.
    ///   - hostSeconds: host time of the same callbacks, in seconds.
    ///   - nominal: the sample rate the device was set to; the result must be within 0.5 % of it.
    public static func estimate(sampleTimes: [Double], hostSeconds: [Double], nominal: Double) -> Double? {
        let n = min(sampleTimes.count, hostSeconds.count)
        guard n >= 50 else { return nil }
        let mt = hostSeconds.prefix(n).reduce(0, +) / Double(n)
        let ms = sampleTimes.prefix(n).reduce(0, +) / Double(n)
        var stt = 0.0, sts = 0.0
        for i in 0..<n {
            let dt = hostSeconds[i] - mt
            stt += dt * dt
            sts += dt * (sampleTimes[i] - ms)
        }
        guard stt > 0 else { return nil }
        let rate = sts / stt
        guard abs(rate / nominal - 1) < 0.005 else { return nil }

        // Residuals of a dropout show up as a large error against the fitted line.
        var worst = 0.0
        for i in 0..<n {
            let predicted = ms + rate * (hostSeconds[i] - mt)
            worst = max(worst, abs(sampleTimes[i] - predicted))
        }
        return worst < 0.01 * nominal ? rate : nil
    }
}
