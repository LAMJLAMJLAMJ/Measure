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

    /// IEC 60268-16:2020 Table M.2: the MTF matrix of step 3 (noise, masking and threshold removed),
    /// adjusted for the operational speech and noise levels of step 4, gives the MTIs of step 6c and STI 0.509.
    func testWorkedExampleOfTheStandard() {
        let byModulation: [[Double]] = [
            [1.06162, 1.00016, 0.96800, 0.98229, 0.99478, 0.99249, 0.99976],
            [1.04519, 0.97479, 0.94880, 0.96706, 0.98462, 0.98543, 0.99775],
            [1.02218, 0.94202, 0.92152, 0.94575, 0.97040, 0.97433, 0.99474],
            [0.99369, 0.90501, 0.88818, 0.92039, 0.95414, 0.96122, 0.98972],
            [0.95644, 0.86061, 0.84271, 0.88487, 0.92975, 0.94105, 0.98370],
            [0.91919, 0.82360, 0.79926, 0.84935, 0.90435, 0.91986, 0.97667],
            [0.88085, 0.78766, 0.75581, 0.80978, 0.87590, 0.89667, 0.96663],
            [0.83483, 0.75065, 0.72247, 0.77020, 0.84541, 0.87145, 0.95559],
            [0.79978, 0.71259, 0.69720, 0.73976, 0.81290, 0.84422, 0.94355],
            [0.78334, 0.65444, 0.67093, 0.73063, 0.78445, 0.81799, 0.93150],
            [0.77129, 0.58043, 0.64870, 0.71743, 0.75701, 0.79177, 0.91845],
            [0.72308, 0.54132, 0.61637, 0.67278, 0.73161, 0.77059, 0.90641],
            [0.63763, 0.50325, 0.54968, 0.61088, 0.70417, 0.75445, 0.89537],
            [0.59819, 0.46414, 0.51735, 0.60987, 0.68893, 0.74235, 0.88633],
        ]
        let raw = SpeechTransmission.bands.indices.map { k in byModulation.map { $0[k] } }
        let r = SpeechTransmission.correct(raw, conditions: .init(speechLevels: [79.0, 82.9, 79.2, 73.2, 67.2, 61.2, 55.2],
                                                                  noiseLevels: [67, 70, 72, 68, 65, 63, 60]))
        // Step 5, 0.63 Hz row.
        for (m, expected) in zip(r.mtf.map { $0[0] }, [0.99814, 0.94761, 0.78860, 0.72687, 0.60997, 0.39183, 0.24801]) {
            XCTAssertEqual(m, expected, accuracy: 2e-5)
        }
        for (mti, expected) in zip(r.mti, [0.75013, 0.65686, 0.57136, 0.55622, 0.51345, 0.40721, 0.33022]) {
            XCTAssertEqual(mti, expected, accuracy: 2e-5)
        }
        XCTAssertEqual(r.sti, 0.509, accuracy: 0.0005)
    }

    func testRatings() {
        XCTAssertEqual(SpeechTransmission.rating(0.80), "A+")
        XCTAssertEqual(SpeechTransmission.rating(0.62), "D")
        XCTAssertEqual(SpeechTransmission.rating(0.30), "U")
    }
}
