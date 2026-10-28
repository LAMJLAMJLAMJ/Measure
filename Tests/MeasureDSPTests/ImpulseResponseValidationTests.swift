import XCTest
@testable import MeasureDSP

/// Validation of the sweep measurement chain against systems with known answers: the sweep is played
/// through a known filter and delay, deconvolved, windowed like a trace (the standard window) and turned
/// into a frequency response, which is compared with the filter's exact response.
final class ImpulseResponseValidationTests: XCTestCase {
    let fs = 48_000.0

    /// `x` delayed by `delay` samples (any fraction), by a linear phase shift of its spectrum.
    func delayed(_ x: [Double], by delay: Double) -> [Double] {
        let fft = FFT(size: FFT.size(atLeast: 2 * x.count))
        var s = fft.forward(x)
        for k in 0..<s.count {
            let w = -2 * Double.pi * Double(k) * delay / Double(fft.size)
            let (re, im) = (s.real[k], s.imag[k])
            s.real[k] = re * cos(w) - im * sin(w)
            s.imag[k] = re * sin(w) + im * cos(w)
        }
        return Array(fft.inverse(s).prefix(x.count))
    }

    func filtered(_ x: [Double], by filters: [Biquad]) -> [Double] {
        var y = x
        for f in filters {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in y.indices {
                let v = y[i]
                let out = f.b0 * v + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
                (x2, x1, y2, y1) = (x1, v, y1, out)
                y[i] = out
            }
        }
        return y
    }

    /// The impulse response measured through `filters`, `delay` samples and `gain`.
    func measure(filters: [Biquad] = [], delay: Double, gain: Double) -> [Double] {
        let sweep = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 3, sampleRate: fs)
        let played = sweep.samples(silence: 1)
        let recording = delayed(filtered(played, by: filters), by: delay).map { $0 * gain }
        return SweepProcessing.process(mics: [recording], loopback: nil, sweep: sweep, played: played)
            .impulseResponses[0]
    }

    func index(of f: Double, in response: FrequencyResponse) -> Int {
        response.frequencies.indices.min { abs(response.frequencies[$0] - f) < abs(response.frequencies[$1] - f) }!
    }

    func testPeakIsFoundToAHundredthOfASample() {
        for delay in [480.0, 480.13, 480.37, 480.5, 480.81, 12.4] {
            let ir = measure(delay: delay, gain: 0.2)
            XCTAssertEqual(Peak.interpolatedIndex(of: ir), delay, accuracy: 0.01, "delay \(delay)")
        }
        // A parabola through the raw samples is not enough: it is 0.12 samples out here.
        XCTAssertGreaterThan(abs(Peak.index(of: measure(delay: 480.37, gain: 0.2)) - 480.37), 0.08)
    }

    func testPureDelayHasFlatPhaseAndLevel() {
        for delay in [480.0, 480.37, 480.5, 1234.81] {
            let ir = measure(delay: delay, gain: 0.2)
            let onset = RoomAcoustics.onsetIndex(ir)
            let r = ResponseWindow.standard.response(of: ir, onset: onset, sampleRate: fs)
            for f in [200.0, 1000, 5000, 10_000, 15_000, 18_000] {
                let i = index(of: f, in: r.response)
                XCTAssertEqual(r.response.magnitude[i], 20 * log10(0.2), accuracy: 0.05, "delay \(delay), \(f) Hz")
                let phase = ResponseWindow.phase(r.response.phase![i], frequency: r.response.frequencies[i],
                                                 removingDelay: r.peakDelay)
                XCTAssertEqual(phase, 0, accuracy: 1, "delay \(delay), \(f) Hz")
            }
            // The onset is earlier than the peak: the band-limited pulse rises before it.
            XCTAssertLessThan(r.onsetDelay, r.peakDelay)
        }
    }

    func testKnownFilterIsMeasuredExactly() {
        // A loudspeaker-like system: 60 Hz and 16 kHz Butterworth corners and a +6 dB peak at 1 kHz.
        let eq = [EQFilter(kind: .highPass, frequency: 60), EQFilter(kind: .lowPass, frequency: 16_000),
                  EQFilter(kind: .peak, frequency: 1000, gain: 6, q: 2)]
        let biquads = eq.map { $0.biquad(sampleRate: fs) }
        let delay = 480, gain = 0.2
        let ir = measure(filters: biquads, delay: Double(delay), gain: gain)
        let onset = RoomAcoustics.onsetIndex(ir)
        let r = ResponseWindow.standard.response(of: ir, onset: onset, sampleRate: fs)
        let start = Double(onset) - r.onsetDelay * fs
        for f in [50.0, 60, 100, 500, 1000, 2000, 5000, 10_000, 15_000, 18_000] {
            let i = index(of: f, in: r.response)
            let bin = r.response.frequencies[i]
            var re = gain, im = 0.0
            for b in biquads {
                let h = b.response(at: 2 * Double.pi * bin / fs)
                (re, im) = (re * h.re - im * h.im, re * h.im + im * h.re)
            }
            XCTAssertEqual(r.response.magnitude[i], 10 * log10(re * re + im * im), accuracy: 0.15, "\(f) Hz")
            // With the true delay removed, the phase is the filters' own.
            guard f >= 100 else { continue }
            let phase = ResponseWindow.phase(r.response.phase![i], frequency: bin,
                                             removingDelay: (Double(delay) - start) / fs)
            let expected = atan2(im, re) * 180 / Double.pi
            var error = phase - expected
            if error > 180 { error -= 360 } else if error <= -180 { error += 360 }
            XCTAssertEqual(error, 0, accuracy: 1, "\(f) Hz")
        }
    }
}
