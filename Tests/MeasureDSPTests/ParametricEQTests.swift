import Foundation
import XCTest
@testable import MeasureDSP

final class ParametricEQTests: XCTestCase {
    let fs = 48_000.0

    func testPeakHasItsGainAtTheCentre() {
        let peak = EQFilter(kind: .peak, frequency: 1000, gain: -6, q: 2)
        XCTAssertEqual(peak.gainDB(at: 1000, sampleRate: fs), -6, accuracy: 1e-9)
        XCTAssertEqual(peak.gainDB(at: 50, sampleRate: fs), 0, accuracy: 0.05)
        XCTAssertEqual(peak.gainDB(at: 15_000, sampleRate: fs), 0, accuracy: 0.05)
        // Narrower Q, less effect an octave away.
        let narrow = EQFilter(kind: .peak, frequency: 1000, gain: -6, q: 8)
        XCTAssertGreaterThan(narrow.gainDB(at: 2000, sampleRate: fs), peak.gainDB(at: 2000, sampleRate: fs))
    }

    func testShelvesReachTheirGain() {
        let low = EQFilter(kind: .lowShelf, frequency: 200, gain: 6, q: 0.707)
        XCTAssertEqual(low.gainDB(at: 10, sampleRate: fs), 6, accuracy: 0.05)
        XCTAssertEqual(low.gainDB(at: 200, sampleRate: fs), 3, accuracy: 0.05)
        XCTAssertEqual(low.gainDB(at: 10_000, sampleRate: fs), 0, accuracy: 0.05)
        let high = EQFilter(kind: .highShelf, frequency: 4000, gain: -4, q: 0.707)
        XCTAssertEqual(high.gainDB(at: 20, sampleRate: fs), 0, accuracy: 0.05)
        XCTAssertEqual(high.gainDB(at: 4000, sampleRate: fs), -2, accuracy: 0.05)
    }

    func testPassFiltersAndNotch() {
        let hp = EQFilter(kind: .highPass, frequency: 80, q: 1 / 2.squareRoot())
        XCTAssertEqual(hp.gainDB(at: 80, sampleRate: fs), -3.01, accuracy: 0.01)
        XCTAssertEqual(hp.gainDB(at: 40, sampleRate: fs), -12.3, accuracy: 0.2)
        XCTAssertEqual(hp.gainDB(at: 5000, sampleRate: fs), 0, accuracy: 0.01)
        let lp = EQFilter(kind: .lowPass, frequency: 8000, q: 1 / 2.squareRoot())
        XCTAssertEqual(lp.gainDB(at: 8000, sampleRate: fs), -3.01, accuracy: 0.01)
        XCTAssertLessThan(EQFilter(kind: .notch, frequency: 60, q: 10).gainDB(at: 60, sampleRate: fs), -60)
    }

    func testFiltersAddAndOffDoesNothing() {
        let a = EQFilter(kind: .peak, frequency: 500, gain: 3, q: 1)
        var b = EQFilter(kind: .peak, frequency: 500, gain: 2, q: 1)
        XCTAssertEqual(ParametricEQ.gainDB([a, b], at: 500, sampleRate: fs), 5, accuracy: 1e-9)
        b.enabled = false
        XCTAssertEqual(ParametricEQ.gainDB([a, b], at: 500, sampleRate: fs), 3, accuracy: 1e-9)

        let flat = FrequencyResponse(frequencies: [100, 500, 2000], magnitude: [-10, -10, -10])
        let predicted = ParametricEQ.apply([a], to: flat, sampleRate: fs)
        XCTAssertEqual(predicted.magnitude[1], -7, accuracy: 1e-9)
    }

    func testDescription() {
        let text = ParametricEQ.description([EQFilter(kind: .peak, frequency: 1250, gain: -4.5, q: 3),
                                             EQFilter(kind: .highPass, frequency: 45, q: 0.71)])
        XCTAssertEqual(text, "1. Peak  1250 Hz  -4.5 dB  Q 3.00\n2. High-pass  45.0 Hz  Q 0.71")
    }
}
