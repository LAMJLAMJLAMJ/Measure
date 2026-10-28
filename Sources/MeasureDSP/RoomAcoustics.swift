import Foundation

/// A straight line fitted to a decay curve, in dB against seconds from the impulse response onset.
public struct DecayFit: Equatable {
    /// dB per second (negative for a decay).
    public let slope: Double
    /// dB at t = 0.
    public let intercept: Double
    /// Range of the decay curve the line was fitted over, in seconds.
    public let start: Double
    public let end: Double

    /// Time for a 60 dB decay at this slope.
    public var reverberationTime: Double { -60 / slope }
}

/// ISO 3382-1 parameters for one band, or for the unfiltered (broadband) response when `band` is nil.
public struct BandParameters {
    public let band: Band?
    /// Early decay time (0 to -10 dB), seconds.
    public let edt: Double?
    /// Reverberation time from the -5 to -25 dB range, seconds.
    public let t20: Double?
    /// Reverberation time from the -5 to -35 dB range, seconds.
    public let t30: Double?
    public let edtFit: DecayFit?
    public let t20Fit: DecayFit?
    public let t30Fit: DecayFit?
    /// Clarity for speech, dB.
    public let c50: Double
    /// Clarity for music, dB.
    public let c80: Double
    /// Definition, 0...1.
    public let d50: Double
    /// Centre time, seconds.
    public let ts: Double
    /// Schroeder backward-integrated decay, dB, one value per sample from the onset to the truncation point.
    public let decayCurve: [Double]
    /// Background noise level relative to the peak of the squared response, dB.
    public let noiseFloor: Double
    /// Where the decay meets the noise (Lundeby), seconds from onset. The decay curve ends here.
    public let truncationTime: Double
    /// Peak-to-noise ratio of the squared response, dB.
    public var peakToNoise: Double { -noiseFloor }
}

public struct RoomAcousticsResult {
    /// Index of the onset in the original impulse response.
    public let onsetIndex: Int
    public let sampleRate: Double
    public let broadband: BandParameters
    public let bands: [BandParameters]
}

/// Room acoustic parameters from an impulse response, following ISO 3382-1:2009.
public enum RoomAcoustics {
    public struct Options {
        /// Bands to analyse.
        public var resolution: BandResolution = .octave
        public var lowestBand: Double = 63
        public var highestBand: Double = 8000
        /// The onset is where the squared response first comes within this many dB of its peak (ISO 3382-1 A.3.4 uses 20 dB).
        public var onsetThreshold: Double = 20
        /// Truncate at the Lundeby crosspoint and add the estimated energy of the lost tail.
        public var noiseCompensation: Bool = true
        /// Run band filters backwards in time, so their ringing falls before the onset (where it is cut
        /// off) rather than after it. Forwards, a low band rings from the loud broadband direct sound,
        /// which makes EDT far too short and C50/C80 too high at 63 and 125 Hz. Backwards is what
        /// AARAE does by default (maximum-phase filters), and what ISO 3382-1 suggests for short decays.
        public var timeReversedFiltering: Bool = true

        public init() {}
    }

    public static func analyze(impulseResponse ir: [Double], sampleRate: Double, options: Options = Options()) -> RoomAcousticsResult {
        let onset = onsetIndex(ir, thresholdDB: options.onsetThreshold)
        let fromOnset = Array(ir[onset...])
        let broadband = parameters(fromOnset, sampleRate: sampleRate, band: nil, noiseCompensation: options.noiseCompensation,
                                   clarity: clarity(fromOnset, sampleRate: sampleRate, filter: nil, reversed: false))

        let bank = FilterBank(resolution: options.resolution, sampleRate: sampleRate,
                              from: options.lowestBand, to: options.highestBand)
        let bands = bank.filters.map { filter -> BandParameters in
            let filtered = options.timeReversedFiltering ? filter.applyTimeReversed(ir) : filter.apply(ir)
            return parameters(Array(filtered[onset...]), sampleRate: sampleRate, band: filter.band,
                              noiseCompensation: options.noiseCompensation,
                              clarity: clarity(fromOnset, sampleRate: sampleRate, filter: filter,
                                               reversed: options.timeReversedFiltering))
        }
        return RoomAcousticsResult(onsetIndex: onset, sampleRate: sampleRate, broadband: broadband, bands: bands)
    }

    /// First sample where the squared response comes within `thresholdDB` of its maximum.
    public static func onsetIndex(_ ir: [Double], thresholdDB: Double = 20) -> Int {
        guard let peak = ir.map({ $0 * $0 }).max(), peak > 0 else { return 0 }
        let limit = peak * pow(10, -thresholdDB / 10)
        return ir.firstIndex { $0 * $0 >= limit } ?? 0
    }

    /// C50, C80 and D50 the way AARAE's ReverberationTimeIR2 works them out: the unfiltered response
    /// (from its onset) is split at 50 or 80 ms first, and each part is padded with a second of silence
    /// on either side and band-filtered on its own, so the filter's ringing stays with the part it came
    /// from instead of crossing the boundary. The late part runs to the end of the response, with no
    /// truncation or noise compensation.
    public struct Clarity {
        public let c50: Double
        public let c80: Double
        public let d50: Double
    }

    public static func clarity(_ h: [Double], sampleRate fs: Double, filter: BandPassFilter?, reversed: Bool) -> Clarity {
        func energy(_ part: ArraySlice<Double>) -> Double {
            guard let filter else { return part.reduce(0) { $0 + $1 * $1 } }
            let pad = [Double](repeating: 0, count: Int(fs))
            let padded = pad + part + pad
            let y = reversed ? filter.applyTimeReversed(padded) : filter.apply(padded)
            return y.reduce(0) { $0 + $1 * $1 }
        }
        func split(_ t: Double) -> (early: Double, late: Double) {
            let n = min(h.count, Int(t * fs) + 1)
            return (energy(h[0..<n]), energy(h[n...]))
        }
        let (e50, l50) = split(0.05), (e80, l80) = split(0.08)
        let tiny = Double.leastNonzeroMagnitude
        return Clarity(c50: 10 * log10(max(e50, tiny) / max(l50, tiny)),
                       c80: 10 * log10(max(e80, tiny) / max(l80, tiny)),
                       d50: e50 / max(e50 + l50, tiny))
    }

    /// Parameters for a response that already starts at its onset. Without `clarity`, C50, C80 and D50
    /// come from `h` itself, truncated and compensated like the decay.
    public static func parameters(_ h: [Double], sampleRate fs: Double, band: Band?, noiseCompensation: Bool = true,
                                  clarity: Clarity? = nil) -> BandParameters {
        let e = h.map { $0 * $0 }
        let peak = max(e.max() ?? 0, .leastNonzeroMagnitude)

        // Truncation point and the energy beyond it.
        var end = e.count
        var tail = 0.0
        var tailMoment = 0.0
        var noiseDB = 10 * log10(max(mean(e.suffix(max(1, e.count / 10))), .leastNonzeroMagnitude) / peak)
        if noiseCompensation, let l = lundeby(e, sampleRate: fs) {
            end = max(1, min(e.count, Int(l.crossTime * fs)))
            noiseDB = 10 * log10(max(l.noise, .leastNonzeroMagnitude) / peak)
            // The fitted line gives the mean energy per sample E(t) = 10^((a + b t)/10) = E_c exp(-k (t - tc)).
            let k = -l.slope * log(10) / 10
            let ec = pow(10, (l.intercept + l.slope * l.crossTime) / 10)
            tail = ec * fs / k
            tailMoment = ec * fs / k * (l.crossTime + 1 / k)
        }

        // Schroeder backward integration up to the truncation point.
        var curve = [Double](repeating: 0, count: end)
        var acc = tail
        for i in stride(from: end - 1, through: 0, by: -1) {
            acc += e[i]
            curve[i] = acc
        }
        let total = max(curve.first ?? 0, .leastNonzeroMagnitude)
        let curveDB = curve.map { 10 * log10(max($0, .leastNonzeroMagnitude) / total) }

        let edtFit = fitDecay(curveDB, sampleRate: fs, from: 0, to: -10)
        let t20Fit = fitDecay(curveDB, sampleRate: fs, from: -5, to: -25)
        let t30Fit = fitDecay(curveDB, sampleRate: fs, from: -5, to: -35)

        func energy(until t: Double) -> Double {
            let n = min(end, Int((t * fs).rounded()))
            return e[0..<max(0, n)].reduce(0, +)
        }
        let e50 = energy(until: 0.05)
        let e80 = energy(until: 0.08)
        var moment = tailMoment
        for i in 0..<end { moment += Double(i) / fs * e[i] }

        return BandParameters(
            band: band,
            edt: edtFit?.reverberationTime, t20: t20Fit?.reverberationTime, t30: t30Fit?.reverberationTime,
            edtFit: edtFit, t20Fit: t20Fit, t30Fit: t30Fit,
            c50: clarity?.c50 ?? 10 * log10(e50 / max(total - e50, .leastNonzeroMagnitude)),
            c80: clarity?.c80 ?? 10 * log10(e80 / max(total - e80, .leastNonzeroMagnitude)),
            d50: clarity?.d50 ?? e50 / total,
            ts: moment / total,
            decayCurve: curveDB,
            noiseFloor: noiseDB,
            truncationTime: Double(end) / fs)
    }

    /// Least-squares line through the part of the decay curve between `from` and `to` dB.
    /// Returns nil when the curve never falls as far as `to`.
    public static func fitDecay(_ curveDB: [Double], sampleRate fs: Double, from upper: Double, to lower: Double) -> DecayFit? {
        guard let i0 = curveDB.firstIndex(where: { $0 <= upper }),
              let i1 = curveDB[i0...].firstIndex(where: { $0 <= lower }),
              i1 - i0 >= 2 else { return nil }
        let t = (i0...i1).map { Double($0) / fs }
        let y = Array(curveDB[i0...i1])
        guard let (slope, intercept) = linearFit(t, y), slope < 0 else { return nil }
        return DecayFit(slope: slope, intercept: intercept, start: t.first!, end: t.last!)
    }

    // MARK: - Lundeby

    struct LundebyResult {
        /// Mean noise energy per sample.
        let noise: Double
        /// Seconds from onset where the late decay line meets the noise.
        let crossTime: Double
        /// Late decay line, dB of energy per sample against seconds.
        let slope: Double
        let intercept: Double
    }

    /// Lundeby, Vigran, Bietz and Vorländer (1995): iteratively find where the decay meets the background noise.
    static func lundeby(_ e: [Double], sampleRate fs: Double, maxIterations: Int = 5) -> LundebyResult? {
        let n = e.count
        guard n > Int(0.1 * fs) else { return nil }

        // 1. Smooth the squared response in 10 ms blocks.
        var block = max(1, Int(0.01 * fs))
        var env = blockAverageDB(e, block: block)
        let peakBlock = env.indices.max { env[$0] < env[$1] } ?? 0

        // 2. First noise estimate from the last 10 %.
        var noise = mean(e.suffix(max(1, n / 10)))
        var noiseDB = 10 * log10(max(noise, .leastNonzeroMagnitude))

        // 3. Line from the peak to 10 dB above the noise.
        guard let stop = env[peakBlock...].firstIndex(where: { $0 <= noiseDB + 10 }), stop - peakBlock >= 2,
              var line = fitBlocks(env, block: block, fs: fs, from: peakBlock, to: stop) else { return nil }
        var cross = (noiseDB - line.intercept) / line.slope

        for _ in 0..<maxIterations {
            // 4. Re-block so there are about 5 blocks per 10 dB of decay.
            let tenDB = -10 / line.slope
            block = max(1, Int(tenDB / 5 * fs))
            env = blockAverageDB(e, block: block)

            // 5. Noise from 10 dB of decay after the crosspoint, but never less than the last 10 %.
            let noiseStart = min(Int((cross + tenDB) * fs), n - max(1, n / 10))
            guard noiseStart > 0, noiseStart < n else { break }
            noise = mean(e[noiseStart...])
            noiseDB = 10 * log10(max(noise, .leastNonzeroMagnitude))

            // 6. Fit the late decay from 25 dB down to 5 dB above the noise (not closer than 5 dB to the peak).
            let top = min((env.max() ?? 0) - 5, noiseDB + 25)
            guard let a = env.firstIndex(where: { $0 <= top }),
                  let b = env[a...].firstIndex(where: { $0 <= noiseDB + 5 }), b - a >= 2,
                  let next = fitBlocks(env, block: block, fs: fs, from: a, to: b) else { break }
            line = next
            let newCross = (noiseDB - line.intercept) / line.slope
            let converged = abs(newCross - cross) < 0.001
            cross = newCross
            if converged { break }
        }

        guard line.slope < 0, cross > 0 else { return nil }
        return LundebyResult(noise: noise, crossTime: min(cross, Double(n) / fs),
                             slope: line.slope, intercept: line.intercept)
    }

    private static func blockAverageDB(_ e: [Double], block: Int) -> [Double] {
        stride(from: 0, to: e.count, by: block).map { start in
            let chunk = e[start..<min(e.count, start + block)]
            return 10 * log10(max(mean(chunk), .leastNonzeroMagnitude))
        }
    }

    /// Fit a line to block levels, placing each block at its centre time.
    private static func fitBlocks(_ env: [Double], block: Int, fs: Double, from a: Int, to b: Int) -> (slope: Double, intercept: Double)? {
        let t = (a...b).map { (Double($0) + 0.5) * Double(block) / fs }
        guard let fit = linearFit(t, Array(env[a...b])), fit.slope < 0 else { return nil }
        return fit
    }

    // MARK: - Helpers

    static func linearFit(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double)? {
        let n = Double(x.count)
        guard x.count >= 2 else { return nil }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in 0..<x.count {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return (slope, my - slope * mx)
    }

    static func mean<C: Collection>(_ c: C) -> Double where C.Element == Double {
        c.isEmpty ? 0 : c.reduce(0, +) / Double(c.count)
    }
}
