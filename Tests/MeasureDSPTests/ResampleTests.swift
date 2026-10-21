import XCTest
@testable import MeasureDSP

final class ResampleTests: XCTestCase {
    let fs = 48_000.0

    func testSineIsResampledToTheScaledTimeBase() {
        let ratio = 1.00005 // input clock 50 ppm faster than output clock
        for f in [200.0, 5_000, 15_000, 19_000] {
            let x = TestSignals.sine(frequency: f, sampleRate: fs, count: 48_000)
            let y = Resampler.resample(x, ratio: ratio)
            XCTAssertEqual(y.count, Int(Double(x.count - 1) * ratio) + 1)
            // y[m] should equal x(m / ratio), the same sine sampled at stretched times.
            var worst = 0.0
            for m in 200..<(y.count - 200) {
                let expected = sin(2 * Double.pi * f * Double(m) / ratio / fs)
                worst = max(worst, abs(y[m] - expected))
            }
            XCTAssertLessThan(worst, 2e-3, "\(f) Hz: worst error \(worst)")
        }
    }

    func testUnityRatioIsIdentity() {
        let x = TestSignals.sine(frequency: 1000, sampleRate: fs, count: 1000)
        XCTAssertEqual(Resampler.resample(x, ratio: 1), x)
    }

    func testPulseKeepsItsShape() {
        // A single sample pulse moved by a fraction of a sample keeps unit gain at DC.
        var x = [Double](repeating: 0, count: 4000)
        x[2000] = 1
        let y = Resampler.resample(x, ratio: 0.9999)
        XCTAssertEqual(y.reduce(0, +), 1, accuracy: 1e-3)
    }

    func testClockRateEstimate() {
        // Callbacks of 512 samples whose host times carry 0.05 ms of jitter, on a device running 40 ppm fast.
        var rng = SeededRandom(seed: 21)
        let nominal = 48_000.0, actual = nominal * (1 + 40e-6)
        let sampleTimes = (0..<600).map { Double($0 * 512) }
        let hostTimes = sampleTimes.map { $0 / actual + 0.05e-3 * rng.gaussian() }
        let estimate = ClockRate.estimate(sampleTimes: sampleTimes, hostSeconds: hostTimes, nominal: nominal)!
        XCTAssertEqual(estimate / nominal - 1, 40e-6, accuracy: 5e-6)
    }

    func testClockRateRejectsDropouts() {
        let nominal = 48_000.0
        var sampleTimes = (0..<600).map { Double($0 * 512) }
        let hostTimes = sampleTimes.map { $0 / nominal }
        for i in 300..<600 { sampleTimes[i] += 4800 } // 100 ms of lost samples
        XCTAssertNil(ClockRate.estimate(sampleTimes: sampleTimes, hostSeconds: hostTimes, nominal: nominal))
        XCTAssertNil(ClockRate.estimate(sampleTimes: [0, 1], hostSeconds: [0, 1], nominal: nominal))
    }
}
