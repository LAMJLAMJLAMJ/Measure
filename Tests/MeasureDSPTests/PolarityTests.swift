import Foundation
import XCTest
@testable import MeasureDSP

final class PolarityTests: XCTestCase {
    let fs = 48_000.0

    /// The generator's pulse every quarter second, with a little noise; `sign` -1 is a speaker wired
    /// the wrong way round.
    func pulses(sign: Double, seconds: Double = 1.6) -> [Double] {
        var generator = SystemRandomNumberGenerator()
        let n = Int(seconds * fs)
        var x = (0..<n).map { _ in Double.random(in: -1e-4...1e-4, using: &generator) }
        let width = Int(0.00025 * fs)
        for start in stride(from: Int(0.1 * fs), to: n - width, by: Int(0.25 * fs)) {
            for i in 0..<width { x[start + i] += sign * 0.3 * 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(width))) }
        }
        return x
    }

    /// A speaker's low end: a fourth-order high-pass at 80 Hz.
    func speaker(_ x: [Double]) -> [Double] {
        let hp = EQFilter(kind: .highPass, frequency: 80, q: 0.7071).biquad(sampleRate: fs)
        var y = x
        for _ in 0..<2 {
            var z1 = 0.0, z2 = 0.0
            y = y.map { v in
                let out = hp.b0 * v + z1
                z1 = hp.b1 * v - hp.a1 * out + z2
                z2 = hp.b2 * v - hp.a2 * out
                return out
            }
        }
        return y
    }

    func check(_ x: [Double], expect: PolarityDetector.Polarity, crossovers: PolarityDetector.Crossovers = .standard) {
        let detector = PolarityDetector(sampleRate: fs, crossovers: crossovers)
        // In the blocks the app reads, a tenth of a second at a time.
        for start in stride(from: 0, to: x.count, by: 4800) { detector.process(Array(x[start..<min(start + 4800, x.count)])) }
        XCTAssertEqual(detector.pulses, 6)
        for band in PolarityDetector.Band.allCases {
            let reading = detector.readings[band]!
            XCTAssertEqual(reading.polarity, expect, "\(band)")
            XCTAssertEqual(reading.agreeing, reading.count, "\(band)")
            XCTAssertEqual(reading.count, 6, "\(band)")
            let trace = detector.bandPulses[band] ?? []
            XCTAssertFalse(trace.isEmpty, "\(band)")
            XCTAssertLessThanOrEqual(trace.count, PolarityDetector.maxTracePoints, "\(band)")
            XCTAssertEqual(trace.map(abs).max() ?? 0, 1, accuracy: 0.05, "\(band)")
        }
    }

    func testPositive() { check(pulses(sign: 1), expect: .positive) }
    func testNegative() { check(pulses(sign: -1), expect: .negative) }
    func testThroughASpeakersHighPass() {
        check(speaker(pulses(sign: 1)), expect: .positive)
        check(speaker(pulses(sign: -1)), expect: .negative)
    }

    func testOtherBandEdges() {
        for c in [PolarityDetector.Crossovers(low: 100, high: 5000), .init(low: 40, high: 500), .init(low: 1000, high: 16000)] {
            check(speaker(pulses(sign: 1)), expect: .positive, crossovers: c)
            check(speaker(pulses(sign: -1)), expect: .negative, crossovers: c)
        }
    }

    func testBandEdgesKeptSensible() {
        let c = PolarityDetector.Crossovers(low: 5, high: 30_000)
        XCTAssertEqual(c.low, 40)
        XCTAssertEqual(c.high, 16_000)
        // The mid band stays at least an octave wide.
        XCTAssertEqual(PolarityDetector.Crossovers(low: 800, high: 900).high, 1600)
        XCTAssertEqual(PolarityDetector.Band.mid.range(.standard), "250 Hz to 2.5 kHz")
        XCTAssertEqual(PolarityDetector.Band.high.range(.init(low: 100, high: 4000)), "above 4 kHz")
    }

    func testNothingInNoise() {
        let detector = PolarityDetector(sampleRate: fs)
        detector.process((0..<48_000).map { _ in Double.random(in: -1e-4...1e-4) })
        XCTAssertEqual(detector.pulses, 0)
        XCTAssertNil(detector.readings[.full]!.polarity)
    }
}
