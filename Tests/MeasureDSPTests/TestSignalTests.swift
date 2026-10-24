import Foundation
import XCTest
@testable import MeasureDSP

final class TestSignalTests: XCTestCase {
    let fs = 48_000.0

    func rms(_ x: [Double]) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot() }

    func testEveryKindHasUnitRMS() {
        for kind in TestSignal.Kind.allCases {
            let x = TestSignal(kind: kind).samples(sampleRate: fs)
            XCTAssertFalse(x.isEmpty, "\(kind)")
            XCTAssertEqual(rms(x), 1, accuracy: 1e-9, "\(kind)")
        }
        let sine = TestSignal(kind: .sine).samples(sampleRate: fs)
        XCTAssertEqual(TestSignal.crestFactor(sine), 3.01, accuracy: 0.01)
        XCTAssertEqual(SignalLevel.rms(sine), 0, accuracy: 1e-9)
        XCTAssertEqual(SignalLevel.peak(sine), 3.01, accuracy: 0.01)
        let pink = TestSignal(kind: .pink).samples(sampleRate: fs)
        XCTAssertGreaterThan(TestSignal.crestFactor(pink), 9)
        XCTAssertLessThan(TestSignal.crestFactor(pink), 16)
    }

    func testSineLoopsWithoutAClick() {
        let s = TestSignal(kind: .sine, frequency: 997.3)
        XCTAssertEqual(s.sineFrequency(sampleRate: fs), 997)
        let x = s.samples(sampleRate: fs)
        // The sample after the last is the first again: the step across the loop is an ordinary one.
        let wrap = x[0] - x[x.count - 1]
        XCTAssertEqual(wrap, x[1] - x[0], accuracy: 1e-6)
        XCTAssertEqual(TestSignal(kind: .sine, frequency: 30_000).sineFrequency(sampleRate: fs), 23_999)
    }

    func testNoiseStaysInItsBand() {
        let s = TestSignal(kind: .white, low: 500, high: 2000)
        let x = s.samples(sampleRate: fs)
        let fr = FrequencyResponse(impulseResponse: x, sampleRate: fs)
        var inside = 0.0, outside = 0.0
        for (f, m) in zip(fr.frequencies, fr.magnitude) {
            let p = pow(10, m / 10)
            if f >= 500 && f <= 2000 { inside += p } else { outside += p }
        }
        XCTAssertLessThan(outside / inside, 1e-12)
        // Pink has equal power per octave; white rises 3 dB per octave.
        let pink = FrequencyResponse(impulseResponse: TestSignal(kind: .pink).samples(sampleRate: fs), sampleRate: fs)
        let white = FrequencyResponse(impulseResponse: TestSignal(kind: .white).samples(sampleRate: fs), sampleRate: fs)
        func octave(_ r: FrequencyResponse, _ f: Double) -> Double {
            10 * log10(zip(r.frequencies, r.magnitude).filter { $0.0 >= f && $0.0 < 2 * f }.map { pow(10, $0.1 / 10) }.reduce(0, +))
        }
        XCTAssertEqual(octave(pink, 1000) - octave(pink, 125), 0, accuracy: 0.3)
        XCTAssertEqual(octave(white, 1000) - octave(white, 125), 9.03, accuracy: 0.3)
    }

    func testPolarityPulseIsPositiveAndRepeats() {
        let x = TestSignal(kind: .polarity, pulseInterval: 0.25).samples(sampleRate: fs)
        XCTAssertEqual(x.count, 12_000)
        XCTAssertGreaterThanOrEqual(x.min()!, 0)
        XCTAssertGreaterThan(x.max()!, 0)
        let sweep = TestSignal(kind: .sweep, sweepDuration: 1, sweepGap: 0.5).samples(sampleRate: fs)
        XCTAssertEqual(sweep.count, 72_000)
        XCTAssertEqual(sweep.suffix(1000).map(abs).max()!, 0)
    }
}
