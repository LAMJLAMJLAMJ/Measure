import XCTest
@testable import MeasureDSP

final class MeasurementQualityTests: XCTestCase {
    let fs = 48_000.0

    func testCleanMeasurementHasNoIssues() {
        let ir = TestSignals.exponentialDecay(rt: 1, sampleRate: fs, duration: 3, noiseDB: -90, seed: 1)
        let acoustics = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs)
        XCTAssertEqual(MeasurementQuality.check(micPeak: -12, loopbackPeak: -6, acoustics: acoustics), [])
    }

    func testClippingAndLowLevel() {
        let issues = MeasurementQuality.check(micPeak: -0.2, loopbackPeak: 0, acoustics: nil)
        XCTAssertEqual(issues, [.loopbackClipped(peak: 0), .micClipped(peak: -0.2)])
        XCTAssertTrue(issues.allSatisfy(\.isSevere))
        XCTAssertEqual(MeasurementQuality.check(micPeak: -62, acoustics: nil), [.lowLevel(peak: -62)])
    }

    func testNoisyMeasurementFlagsBands() {
        let ir = TestSignals.exponentialDecay(rt: 1, sampleRate: fs, duration: 3, noiseDB: -20, seed: 2)
        let acoustics = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs)
        let issues = MeasurementQuality.check(micPeak: -12, acoustics: acoustics)
        guard case .lowPeakToNoise(_, let t20, let worst) = issues.first else {
            return XCTFail("Expected a peak-to-noise issue, got \(issues)")
        }
        XCTAssertFalse(t20.isEmpty)
        XCTAssertLessThan(worst, MeasurementQuality.t20Range)
        XCTAssertTrue(issues[0].isSevere)
        XCTAssertTrue(issues[0].message.contains("T20 and T30 unreliable"))
        // Only the octaves from 125 Hz to 4 kHz are checked.
        XCTAssertTrue(t20.allSatisfy { (125...4000).contains($0.nominal) })
    }

    func testMarginalMeasurementOnlyLosesT30() {
        // About 40 dB between peak and noise in every band: enough for T20, not for T30.
        var found = false
        for noise in stride(from: -30.0, through: -45, by: -1) {
            let ir = TestSignals.exponentialDecay(rt: 1, sampleRate: fs, duration: 3, noiseDB: noise, seed: 3)
            let acoustics = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs)
            let issues = MeasurementQuality.check(micPeak: -12, acoustics: acoustics)
            if case .lowPeakToNoise(let t30, let t20, _) = issues.first, t20.isEmpty, !t30.isEmpty {
                XCTAssertFalse(issues[0].isSevere)
                XCTAssertTrue(issues[0].message.contains("T30 unreliable"))
                found = true
                break
            }
        }
        XCTAssertTrue(found, "Some noise level should leave T20 usable but not T30")
    }
}
