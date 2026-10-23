import Foundation
import XCTest
@testable import MeasureDSP

final class CrossSpectrumTests: XCTestCase {
    let fs = 48_000.0
    let n = 8192

    /// Runs `reference` and `measurement` through the analyser in half-overlapping blocks.
    func analyse(_ x: [Double], _ y: [Double]) -> CrossSpectrum {
        var cs = CrossSpectrum(fftSize: n, sampleRate: fs)
        var start = n
        while start + n <= x.count - n {
            cs.add(reference: Array(x[start..<start + n]), measurement: Array(y[start..<start + n]), averages: 100)
            start += n / 2
        }
        return cs
    }

    func testDelayAndGainOfAPlainPath() {
        let pink = PinkNoise.periodic(count: n, sampleRate: fs)
        let x = Array((0..<6).map { _ in pink }.joined())
        let delay = 100
        let y = x.indices.map { 0.5 * x[($0 - delay + x.count) % x.count] }
        let cs = analyse(x, y)

        XCTAssertEqual(cs.delay, delay)
        let r = cs.response
        let coherence = cs.coherence
        let band = r.frequencies.indices.filter { r.frequencies[$0] > 100 && r.frequencies[$0] < 10_000 }
        let mean = band.map { r.magnitude[$0] }.reduce(0, +) / Double(band.count)
        XCTAssertEqual(mean, 20 * log10(0.5), accuracy: 0.1)
        for k in band {
            XCTAssertEqual(r.magnitude[k], 20 * log10(0.5), accuracy: 0.5)
            XCTAssertGreaterThan(coherence[k], 0.98)
        }
    }

    func testNoiseLowersCoherence() {
        let pink = PinkNoise.periodic(count: n, sampleRate: fs)
        let x = Array((0..<6).map { _ in pink }.joined())
        let other = PinkNoise.periodic(count: 65_536, sampleRate: fs, seed: 99)
        let y = x.indices.map { x[$0] + other[$0] * 0.5 }
        let cs = analyse(x, y)
        let r = cs.response
        let band = r.frequencies.indices.filter { r.frequencies[$0] > 200 && r.frequencies[$0] < 5_000 }
        let coherence = cs.coherence
        let mean = band.map { coherence[$0] }.reduce(0, +) / Double(band.count)
        XCTAssertLessThan(mean, 0.95)
        // The transfer function is still right: the noise is uncorrelated with the reference.
        let level = band.map { r.magnitude[$0] }.reduce(0, +) / Double(band.count)
        XCTAssertEqual(level, 0, accuracy: 1)
    }

    func testPinkNoiseIsFlatPerOctave() {
        let x = PinkNoise.periodic(count: 65_536, sampleRate: fs)
        XCTAssertEqual(x.map { abs($0) }.max()!, 1, accuracy: 1e-12)
        let spectrum = FFT(size: x.count).forward(x)
        let power = spectrum.power
        func octave(_ centre: Double) -> Double {
            let k = power.indices.filter {
                let f = Double($0) * fs / Double(x.count)
                return f >= centre / 2.squareRoot() && f < centre * 2.squareRoot()
            }
            return 10 * log10(k.map { power[$0] }.reduce(0, +))
        }
        XCTAssertEqual(octave(125), octave(2000), accuracy: 0.5)
        XCTAssertEqual(octave(63), octave(8000), accuracy: 0.5)
        XCTAssertLessThan(PinkNoise.rmsLevel(x), -9)
    }

    func testResetClearsTheAverage() {
        let pink = PinkNoise.periodic(count: n, sampleRate: fs)
        var cs = CrossSpectrum(fftSize: n, sampleRate: fs)
        cs.add(reference: pink, measurement: pink, averages: 4)
        XCTAssertEqual(cs.blocks, 1)
        cs.reset()
        XCTAssertEqual(cs.blocks, 0)
        XCTAssertNil(cs.delay)
    }
}
