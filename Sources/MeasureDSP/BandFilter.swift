import Foundation

/// One fractional-octave band, with frequencies per IEC 61260-1 (base-ten system).
public struct Band: Equatable, CustomStringConvertible {
    /// Exact mid-band frequency.
    public let center: Double
    public let lower: Double
    public let upper: Double
    /// Nominal label such as 125 or 1000.
    public let nominal: Double

    public var description: String {
        nominal >= 1000 ? "\(formatted(nominal / 1000))k" : formatted(nominal)
    }

    private func formatted(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

public enum BandResolution: Int {
    case octave = 1
    case thirdOctave = 3

    /// Standard bands from 25 Hz (third octave) or 31.5 Hz (octave) to 16 kHz (octave) or 20 kHz (third octave).
    public var standardBands: [Band] {
        let nominals: [Double]
        switch self {
        case .octave:
            nominals = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        case .thirdOctave:
            nominals = [25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                        1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]
        }
        return nominals.map { band(nominal: $0) }
    }

    /// The band whose exact mid-band frequency is closest to `nominal`.
    public func band(nominal: Double) -> Band {
        let g = pow(10, 0.3)
        let b = Double(rawValue)
        let x = (b * log(nominal / 1000) / log(g)).rounded()
        let center = 1000 * pow(g, x / b)
        let half = pow(g, 1 / (2 * b))
        return Band(center: center, lower: center / half, upper: center * half, nominal: nominal)
    }

    /// Standard bands that fit below the Nyquist frequency at `sampleRate`.
    public func bands(sampleRate: Double, from low: Double = 0, to high: Double = .infinity) -> [Band] {
        standardBands.filter { $0.upper < 0.5 * sampleRate && $0.nominal >= low && $0.nominal <= high }
    }
}

/// A biquad section: y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2.
public struct Biquad: Equatable {
    public var b0, b1, b2, a1, a2: Double

    /// Complex response at normalised angular frequency w (radians per sample).
    func response(at w: Double) -> (re: Double, im: Double) {
        let c1 = cos(w), s1 = -sin(w), c2 = cos(2 * w), s2 = -sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
        let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
        let d = dr * dr + di * di
        return ((nr * dr + ni * di) / d, (ni * dr - nr * di) / d)
    }
}

/// Butterworth band-pass filter built as a cascade of biquads.
///
/// Order 3 (the default) gives a sixth-order band-pass, the usual choice for IEC 61260 class 1
/// octave and third-octave filters in room acoustics.
public struct BandPassFilter {
    public let band: Band
    public let sampleRate: Double
    public let sections: [Biquad]

    public init(band: Band, sampleRate: Double, order: Int = 3) {
        precondition(band.upper < sampleRate / 2, "band \(band) is above Nyquist at \(sampleRate) Hz")
        self.band = band
        self.sampleRate = sampleRate

        // Pre-warp the band edges for the bilinear transform.
        let fs2 = 2 * sampleRate
        let w1 = fs2 * tan(Double.pi * band.lower / sampleRate)
        let w2 = fs2 * tan(Double.pi * band.upper / sampleRate)
        let w0sq = w1 * w2
        let bw = w2 - w1

        // Analog Butterworth low-pass poles in the upper half plane (and the real pole for odd orders).
        var analogPoles: [(re: Double, im: Double)] = []
        for k in 0..<order {
            let theta = Double.pi * Double(2 * k + 1 + order) / Double(2 * order)
            let p = (re: cos(theta), im: sin(theta))
            if abs(p.im) < 1e-9 {
                analogPoles.append((p.re, 0))
            } else if p.im > 0 {
                analogPoles.append(p)
            }
        }

        var sections: [Biquad] = []
        for p in analogPoles {
            // Low-pass to band-pass: each pole p gives the roots of s^2 - p*bw*s + w0^2 = 0.
            let pr = p.re * bw, pi = p.im * bw
            // discriminant = (p*bw)^2 - 4 w0^2
            let dr = pr * pr - pi * pi - 4 * w0sq
            let di = 2 * pr * pi
            let (sr, si) = BandPassFilter.complexSqrt(dr, di)
            let roots = [((pr + sr) / 2, (pi + si) / 2), ((pr - sr) / 2, (pi - si) / 2)]
            if p.im == 0 {
                // A real low-pass pole gives one conjugate pair of band-pass poles.
                let s = roots[0].1 >= 0 ? roots[0] : roots[1]
                sections.append(BandPassFilter.section(pole: s, fs2: fs2))
            } else {
                // A complex pole gives two band-pass poles; each pairs with its conjugate (from the conjugate low-pass pole).
                for s in roots { sections.append(BandPassFilter.section(pole: (s.0, abs(s.1)), fs2: fs2)) }
            }
        }

        // Normalise to unity gain at the mid-band frequency.
        let w0 = 2 * Double.pi * band.center / sampleRate
        var gain = 1.0
        for s in sections {
            let r = s.response(at: w0)
            gain *= (r.re * r.re + r.im * r.im).squareRoot()
        }
        let perSection = pow(1 / gain, 1 / Double(sections.count))
        self.sections = sections.map {
            Biquad(b0: $0.b0 * perSection, b1: $0.b1 * perSection, b2: $0.b2 * perSection, a1: $0.a1, a2: $0.a2)
        }
    }

    /// Filters `x` forwards in time.
    public func apply(_ x: [Double]) -> [Double] {
        var y = x
        for s in sections {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<y.count {
                let xi = y[i]
                let yi = s.b0 * xi + s.b1 * x1 + s.b2 * x2 - s.a1 * y1 - s.a2 * y2
                x2 = x1; x1 = xi
                y2 = y1; y1 = yi
                y[i] = yi
            }
        }
        return y
    }

    /// Filters `x` backwards in time. For decay analysis this keeps the filter's own ringing
    /// out of the decay, which matters for short reverberation times in low bands.
    public func applyTimeReversed(_ x: [Double]) -> [Double] {
        Array(apply(Array(x.reversed())).reversed())
    }

    /// Filters `x` forwards and then backwards in time: zero phase, so peaks and arrivals stay where
    /// they are, at the cost of a steeper magnitude (each band edge is -6 dB rather than -3 dB) and
    /// ringing before each arrival as well as after it. For looking at one band of an impulse response.
    public func applyZeroPhase(_ x: [Double]) -> [Double] {
        applyTimeReversed(apply(x))
    }

    /// Magnitude response in dB at frequency f.
    public func magnitudeDB(at f: Double) -> Double {
        let w = 2 * Double.pi * f / sampleRate
        var g = 1.0
        for s in sections {
            let r = s.response(at: w)
            g *= (r.re * r.re + r.im * r.im).squareRoot()
        }
        return 20 * log10(g)
    }

    /// Bilinear transform of an analog pole pair (s, conj s) into a biquad with zeros at z = 1 and z = -1.
    private static func section(pole s: (Double, Double), fs2: Double) -> Biquad {
        // z = (fs2 + s) / (fs2 - s)
        let nr = fs2 + s.0, ni = s.1
        let dr = fs2 - s.0, di = -s.1
        let d = dr * dr + di * di
        let zr = (nr * dr + ni * di) / d
        let zi = (ni * dr - nr * di) / d
        return Biquad(b0: 1, b1: 0, b2: -1, a1: -2 * zr, a2: zr * zr + zi * zi)
    }

    private static func complexSqrt(_ re: Double, _ im: Double) -> (Double, Double) {
        let m = (re * re + im * im).squareRoot()
        let r = ((m + re) / 2).squareRoot()
        let i = ((m - re) / 2).squareRoot()
        return (r, im < 0 ? -i : i)
    }
}

/// A set of band-pass filters covering a range of standard bands.
public struct FilterBank {
    public let filters: [BandPassFilter]

    public init(resolution: BandResolution, sampleRate: Double, from low: Double = 0, to high: Double = .infinity, order: Int = 3) {
        filters = resolution.bands(sampleRate: sampleRate, from: low, to: high).map {
            BandPassFilter(band: $0, sampleRate: sampleRate, order: order)
        }
    }

    public var bands: [Band] { filters.map(\.band) }
}
