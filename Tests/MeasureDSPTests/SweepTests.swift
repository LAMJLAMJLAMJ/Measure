import XCTest
@testable import MeasureDSP

final class SweepTests: XCTestCase {
    func testSweepLengthAndFrequencyLaw() {
        let s = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 2, sampleRate: 48_000)
        XCTAssertEqual(s.samples(silence: 1).count, 3 * 48_000)
        XCTAssertEqual(s.frequency(at: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(s.frequency(at: 2), 20_000, accuracy: 1e-6)
        XCTAssertEqual(s.time(atFrequency: 632.4555), 1, accuracy: 1e-4) // geometric mean is half way
        XCTAssertLessThanOrEqual(s.samples().map(abs).max()!, 0.5 + 1e-12)
    }

    func testDeconvolutionRecoversDelayAndGain() {
        let fs = 48_000.0
        let sweep = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 1, sampleRate: fs).samples()
        // A "room" that is a pure delay of 480 samples (10 ms) and a gain of 0.3.
        let delay = 480, gain = 0.3
        var recording = [Double](repeating: 0, count: sweep.count + 24_000)
        for i in sweep.indices { recording[i + delay] = gain * sweep[i] }

        let ir = Deconvolution.impulseResponse(recording: recording, reference: sweep, sampleRate: fs, band: 20...20_000)
        // By default the response is as long as the recording after the sweep has finished.
        XCTAssertEqual(Double(ir.count), Double(recording.count - sweep.count), accuracy: 16) // the last few faded samples count as silence
        let peak = Peak.index(of: ir)
        XCTAssertEqual(peak, Double(delay), accuracy: 0.05)
        // The response is band-limited to 20 Hz-20 kHz, so check the gain in the frequency domain.
        let fr = FrequencyResponse(impulseResponse: ir, sampleRate: fs)
        for f in [100.0, 1000, 10_000] {
            XCTAssertEqual(fr.magnitude(at: f), 20 * log10(gain), accuracy: 0.1, "\(f) Hz")
        }
    }

    func testDelayEstimate() {
        var rng = SeededRandom(seed: 5)
        let ref = (0..<8000).map { _ in rng.gaussian() }
        let sig = [Double](repeating: 0, count: 137) + ref
        XCTAssertEqual(Delay.estimate(signal: sig, reference: ref), 137, accuracy: 0.01)
        XCTAssertEqual(Delay.estimate(signal: ref, reference: sig), -137, accuracy: 0.01)
    }

    func testValidation() {
        func problem(_ a: Double, _ b: Double, _ d: Double = 3, _ fs: Double = 48_000) -> String? {
            ExponentialSweep.validationError(startFrequency: a, endFrequency: b, duration: d, sampleRate: fs)
        }
        XCTAssertNil(problem(20, 20_000))
        XCTAssertNotNil(problem(20_000, 20))
        XCTAssertNotNil(problem(0, 20_000))
        XCTAssertNotNil(problem(20, 30_000))          // above Nyquist
        XCTAssertNotNil(problem(1000, 1200))          // under an octave
        XCTAssertNotNil(problem(20, 20_000, 0.1))     // too short
        XCTAssertNotNil(problem(.nan, 20_000))
    }

    func testSweepPeakFollowsAmplitude() {
        for db in [-60.0, -30.0, -12.0, 0.0] {
            let amplitude = pow(10, db / 20)
            let x = ExponentialSweep(sampleRate: 48_000, amplitude: amplitude).samples(silence: 1)
            let peak = x.map(abs).max() ?? 0
            XCTAssertEqual(20 * log10(peak), db, accuracy: 0.1, "sweep peak at \(db) dBFS")
        }
    }
}
