import Foundation
import XCTest
@testable import MeasureDSP

final class SpeechTransmissionTests: XCTestCase {
    let fs = 48_000.0

    func testWeightsAddUpToOne() {
        let a = SpeechTransmission.alpha.reduce(0, +), b = SpeechTransmission.beta.reduce(0, +)
        XCTAssertEqual(a - b, 1, accuracy: 1e-9)
    }

    func testMaleSpectrumIsZeroDBA() {
        let aWeighting = [-16.1, -8.6, -3.2, 0, 1.2, 1.0, -1.1]
        let total = zip(SpeechTransmission.maleSpeechSpectrum, aWeighting).map { pow(10, ($0 + $1) / 10) }.reduce(0, +)
        XCTAssertEqual(10 * log10(total), 0, accuracy: 0.05)
    }

    func testExponentialDecayMatchesTheory() {
        // Squared response exp(-13.8 t / T) gives m(F) = 1 / sqrt(1 + (2πF T / 13.8)²).
        let t60 = 1.0
        let h = (0..<Int(4 * fs)).map { exp(-6.9 * Double($0) / fs / t60) }
        let m = SpeechTransmission.mtf(h, sampleRate: fs)
        for (f, value) in zip(SpeechTransmission.modulationFrequencies, m) {
            let expected = 1 / sqrt(1 + pow(2 * Double.pi * f * t60 / 13.8, 2))
            XCTAssertEqual(value, expected, accuracy: 0.002, "F = \(f) Hz")
        }
    }

    func testIdealChannelScoresOne() {
        var ir = [Double](repeating: 0, count: 96_000)
        ir[4800] = 1
        let r = SpeechTransmission.analyze(impulseResponse: ir, sampleRate: fs, onset: 4800)
        XCTAssertGreaterThan(r.sti, 0.95) // only the band filters' own ringing lowers it
        XCTAssertEqual(r.rating, "A+")
    }

    func testNoiseAtSpeechLevelHalvesModulation() {
        let raw = SpeechTransmission.bands.map { _ in SpeechTransmission.modulationFrequencies.map { _ in 1.0 } }
        let speech = SpeechTransmission.speechLevels(aWeighted: 60)
        let r = SpeechTransmission.correct(raw, conditions: .init(speechLevels: speech, noiseLevels: speech, auditoryEffects: false))
        for row in r.mtf { for m in row { XCTAssertEqual(m, 0.5, accuracy: 1e-12) } }
        XCTAssertEqual(r.sti, 0.5, accuracy: 1e-9)
    }

    func testMaskingAndThresholdLowerAPerfectChannel() {
        let raw = SpeechTransmission.bands.map { _ in SpeechTransmission.modulationFrequencies.map { _ in 1.0 } }
        let quiet = SpeechTransmission.correct(raw, conditions: .init(speechLevels: SpeechTransmission.speechLevels(aWeighted: 40)))
        let normal = SpeechTransmission.correct(raw, conditions: .init(speechLevels: SpeechTransmission.speechLevels(aWeighted: 50)))
        XCTAssertLessThan(quiet.sti, normal.sti) // threshold matters more for quiet speech
        XCTAssertLessThan(normal.sti, 1)
        XCTAssertGreaterThan(normal.sti, 0.9)
    }

    func testRatings() {
        XCTAssertEqual(SpeechTransmission.rating(0.80), "A+")
        XCTAssertEqual(SpeechTransmission.rating(0.62), "D")
        XCTAssertEqual(SpeechTransmission.rating(0.30), "U")
    }
}
