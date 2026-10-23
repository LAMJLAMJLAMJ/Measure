import XCTest
@testable import MeasureDSP

final class FrequencyResponseTests: XCTestCase {
    func testImpulseIsFlatWithLinearPhase() {
        var ir = [Double](repeating: 0, count: 1024)
        ir[0] = 1
        let fr = FrequencyResponse(impulseResponse: ir, sampleRate: 48_000)
        XCTAssertEqual(fr.frequencies.count, 512)
        for m in fr.magnitude { XCTAssertEqual(m, 0, accuracy: 1e-9) }
        for p in fr.phase! { XCTAssertEqual(p, 0, accuracy: 1e-6) }
    }

    func testSmoothingKeepsFlatFlatAndAveragesPower() {
        let f = (1...2000).map { Double($0) * 10 }
        let flat = FrequencyResponse(frequencies: f, magnitude: f.map { _ in 3 })
        for m in flat.smoothed(fraction: 3).magnitude { XCTAssertEqual(m, 3, accuracy: 1e-9) }

        // Alternating +6/-inf dB averages to +3 dB in power.
        let comb = FrequencyResponse(frequencies: f, magnitude: f.indices.map { $0 % 2 == 0 ? 6.0206 : -300 })
        let s = comb.smoothed(fraction: 1)
        XCTAssertEqual(s.magnitude(at: 5000), 3, accuracy: 0.1)
    }

    func testParsesREWExport() throws {
        let text = """
        * Measurement data measured by REW V5.40
        * Source: UMIK-1, Right
        * Format is frequency, SPL, phase
        Freq(Hz), SPL(dB), Phase(degrees)
        20.000, 70.5, -12.0
        40.000, 72.0, 15.5
        80.000, 75.25, 30.0
        """
        let (fr, sens) = try FrequencyResponseText.parse(text)
        XCTAssertNil(sens)
        XCTAssertEqual(fr.frequencies, [20, 40, 80])
        XCTAssertEqual(fr.magnitude, [70.5, 72, 75.25])
        XCTAssertEqual(fr.phase!, [-12, 15.5, 30])
        XCTAssertEqual(fr.magnitude(at: 28.284271), 71.25, accuracy: 1e-6) // log-midpoint of 20 and 40
    }

    func testParsesMicCalibrationAndApplies() throws {
        let text = """
        "Sens Factor =-1.378dB, SERNO: 7000123"
        10.054\t-4.65
        1000.0\t0.0
        20000\t2.5
        """
        let (cal, sens) = try FrequencyResponseText.parse(text)
        XCTAssertEqual(sens!, -1.378, accuracy: 1e-9)
        XCTAssertNil(cal.phase)
        let measured = FrequencyResponse(frequencies: [1000, 20000], magnitude: [80, 80])
        XCTAssertEqual(measured.applyingCalibration(cal).magnitude, [80, 77.5])
    }

    func testAveragesOnTheSameGrid() {
        let f: [Double] = [100, 200, 400]
        let a = FrequencyResponse(frequencies: f, magnitude: [0, 0, 0])
        let b = FrequencyResponse(frequencies: f, magnitude: [-10, 10, 0])
        let db = FrequencyResponse.average([a, b], method: .decibel)!
        XCTAssertEqual(db.frequencies, f)
        XCTAssertEqual(db.magnitude, [-5, 5, 0])
        // Power: 10·log10((1 + 0.1) / 2) and 10·log10((1 + 10) / 2).
        let power = FrequencyResponse.average([a, b], method: .power)!
        XCTAssertEqual(power.magnitude[0], 10 * log10(0.55), accuracy: 1e-9)
        XCTAssertEqual(power.magnitude[1], 10 * log10(5.5), accuracy: 1e-9)
        XCTAssertEqual(power.magnitude[2], 0, accuracy: 1e-9)
    }

    func testAveragesAcrossDifferentGrids() {
        let a = FrequencyResponse(frequencies: stride(from: 10.0, through: 20_000, by: 1).map { $0 },
                                  magnitude: [Double](repeating: 6, count: 19_991))
        let b = FrequencyResponse(frequencies: stride(from: 20.0, through: 10_000, by: 2).map { $0 },
                                  magnitude: [Double](repeating: 0, count: 4_991))
        let avg = FrequencyResponse.average([a, b], method: .decibel)!
        XCTAssertEqual(avg.frequencies.first!, 20, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(avg.frequencies.last!, 10_000)
        for m in avg.magnitude { XCTAssertEqual(m, 3, accuracy: 1e-6) }
        XCTAssertNil(avg.phase)
    }

    func testRejectsTextWithoutData() {
        XCTAssertThrowsError(try FrequencyResponseText.parse("just a header\nand more text"))
    }
}
