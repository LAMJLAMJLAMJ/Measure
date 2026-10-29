import Foundation
import XCTest
@testable import MeasureDSP

final class DistortionTests: XCTestCase {
    let fs = 48_000.0

    /// A sweep through a memoryless nonlinearity y = x + a2·x² + a3·x³, delayed, then processed as a measurement.
    func measure(a2: Double, a3: Double, amplitude: Double = 0.5) -> (SweepMeasurementResult, ExponentialSweep) {
        let sweep = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 2, sampleRate: fs, amplitude: amplitude)
        let played = sweep.samples(silence: 1)
        var mic = [Double](repeating: 0, count: played.count)
        let delay = 240
        for i in 0..<(played.count - delay) {
            let x = played[i]
            mic[i + delay] = x + a2 * x * x + a3 * x * x * x
        }
        return (SweepProcessing.process(mics: [mic], loopback: nil, sweep: sweep, played: played), sweep)
    }

    func testHarmonicsOfAKnownNonlinearity() throws {
        // For a sine of amplitude A: the second harmonic is a2·A²/2, the third a3·A³/4, the fundamental
        // A·(1 + 3/4·a3·A²). Deconvolution divides by the sweep's amplitude A.
        let (result, sweep) = measure(a2: 0.1, a3: 0.05)
        let d = try XCTUnwrap(result.distortion.first ?? nil)
        XCTAssertEqual(d.sweepLevel!, 20 * log10(0.5), accuracy: 1e-9)
        XCTAssertEqual(d.highestOrder, 5)
        let a = sweep.amplitude
        let h1 = a * (1 + 0.75 * 0.05 * a * a)
        let h2 = 20 * log10(0.1 * a * a / 2 / h1)
        let h3 = 20 * log10(0.05 * a * a * a / 4 / h1)
        for (i, f) in d.frequencies.enumerated() where f >= 200 && f <= 5000 {
            XCTAssertEqual(d.fundamental[i], 20 * log10(h1 / a), accuracy: 0.3, "\(f) Hz")
            XCTAssertEqual(d.harmonics[0][i]! - d.fundamental[i], h2, accuracy: 0.5, "H2 at \(f) Hz")
            XCTAssertEqual(d.harmonics[1][i]! - d.fundamental[i], h3, accuracy: 0.7, "H3 at \(f) Hz")
            // Nothing makes a fourth harmonic: it reads at the floor.
            if let h4 = d.harmonics[2][i] { XCTAssertLessThan(h4 - d.fundamental[i], -50, "H4 at \(f) Hz") }
            let thd = d.thd(i)!
            let expected = (pow(10, h2 / 10) + pow(10, h3 / 10)).squareRoot()
            XCTAssertEqual(20 * log10(thd), 20 * log10(expected), accuracy: 0.5, "THD at \(f) Hz")
        }
        // Harmonics above the sweep's range are not measured.
        let last = d.frequencies.count - 1
        XCTAssertNil(d.harmonics[0][last])
        XCTAssertNotNil(d.harmonics[0][0])
    }

    func testALinearSystemHasNoDistortion() throws {
        let (result, _) = measure(a2: 0, a3: 0)
        let d = try XCTUnwrap(result.distortion.first ?? nil)
        for i in d.frequencies.indices where d.frequencies[i] >= 50 && d.frequencies[i] <= 5000 {
            // What is left is the deconvolution's own floor.
            XCTAssertLessThan(20 * log10(d.thd(i)!), -50, "\(d.frequencies[i]) Hz")
        }
        // Including where the harmonics reach the top of the sweep, which once read false peaks there.
        for i in d.frequencies.indices where d.frequencies[i] >= 1000 {
            if let thd = d.thd(i) { XCTAssertLessThan(20 * log10(thd), -60, "\(d.frequencies[i]) Hz") }
        }
    }

    func testTHDFromLevels() {
        XCTAssertEqual(HarmonicDistortion.thd(fundamental: 0, harmonics: [-40, nil])!, 0.01, accuracy: 1e-12)
        XCTAssertEqual(HarmonicDistortion.thd(fundamental: 0, harmonics: [-40, -40])!, 0.01 * 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertNil(HarmonicDistortion.thd(fundamental: 0, harmonics: [nil, nil]))
    }
}
