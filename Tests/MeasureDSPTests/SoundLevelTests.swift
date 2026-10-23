import Foundation
import XCTest
@testable import MeasureDSP

final class SoundLevelTests: XCTestCase {
    let fs = 48_000.0

    func sine(_ f: Double, amplitude: Double = 1, seconds: Double) -> [Double] {
        (0..<Int(seconds * fs)).map { amplitude * sin(2 * Double.pi * f * Double($0) / fs) }
    }

    func testWeightingMatchesIEC61672() {
        let a = SoundLevel.WeightingFilter(.a, sampleRate: fs)
        let c = SoundLevel.WeightingFilter(.c, sampleRate: fs)
        // Nominal values from IEC 61672-1 Table 3.
        let aTable: [(Double, Double)] = [(31.5, -39.4), (63, -26.2), (125, -16.1), (250, -8.6), (500, -3.2),
                                          (1000, 0), (2000, 1.2), (4000, 1.0), (8000, -1.1), (16000, -6.6)]
        let cTable: [(Double, Double)] = [(31.5, -3.0), (63, -0.8), (125, -0.2), (1000, 0), (4000, -0.8),
                                          (8000, -3.0), (16000, -8.5)]
        for (f, expected) in aTable { XCTAssertEqual(a.gainDB(at: f, sampleRate: fs), expected, accuracy: 0.2, "A at \(f) Hz") }
        for (f, expected) in cTable { XCTAssertEqual(c.gainDB(at: f, sampleRate: fs), expected, accuracy: 0.2, "C at \(f) Hz") }
    }

    func testFullScaleSineReadsMinusThreeDB() {
        let x = sine(1000, seconds: 2)
        for w in SoundLevel.FrequencyWeighting.allCases {
            let r = SoundLevel.analyze(x, sampleRate: fs, weighting: w, timeWeighting: .fast)
            XCTAssertEqual(r.leq, -3.01, accuracy: 0.05, "\(w)")
            XCTAssertEqual(r.lmax, -3.01, accuracy: 0.1)
            XCTAssertEqual(r.lmin, -3.01, accuracy: 0.1)
        }
        let calibrated = SoundLevel.analyze(x, sampleRate: fs, weighting: .z, timeWeighting: .slow, offset: 97.01)
        XCTAssertEqual(calibrated.leq, 94, accuracy: 0.05)
    }

    func testStatisticalLevels() {
        // 4 s at −20 dB then 4 s at 0 dB (sine amplitudes 0.1 and 1).
        let x = sine(1000, amplitude: 0.1, seconds: 4) + sine(1000, seconds: 4)
        let r = SoundLevel.analyze(x, sampleRate: fs, weighting: .z, timeWeighting: .fast)
        XCTAssertEqual(r.l(10)!, -3.01, accuracy: 0.1)
        XCTAssertEqual(r.l(90)!, -23.01, accuracy: 0.1)
        XCTAssertEqual(r.lmax, -3.01, accuracy: 0.1)
        XCTAssertEqual(r.leq, 10 * log10((0.01 + 1) / 2 / 2), accuracy: 0.05)
        XCTAssertEqual(r.history.count, x.count / Int(0.01 * fs))
    }

    func testOctaveLevels() {
        let levels = SoundLevel.octaveLevels(sine(1000, seconds: 2), sampleRate: fs)
        let k = levels.firstIndex { $0.band == 1000 }!
        XCTAssertEqual(levels[k].level, -3.01, accuracy: 0.2)
        XCTAssertLessThan(levels[k - 2].level, -40)
        XCTAssertLessThan(levels[k + 2].level, -40)
    }

    func testNoiseRatings() {
        let nr30 = zip(NoiseRating.nrBands, NoiseRating.nrCurve(30)).map { (band: $0, level: $1) }
        XCTAssertEqual(NoiseRating.nr(nr30)!, 30, accuracy: 1e-9)
        XCTAssertEqual(NoiseRating.nrCurve(0)[5], 0) // NR is the 1 kHz level

        let nc40 = NoiseRating.ncCurves.first { $0.nc == 40 }!.levels
        XCTAssertEqual(NoiseRating.nc(zip(NoiseRating.ncBands, nc40).map { (band: $0, level: $1) })!, 40, accuracy: 1e-9)
        XCTAssertEqual(NoiseRating.ncCurve(40), nc40)
        // Halfway between NC 35 and NC 40 at 1 kHz (36 and 41 dB), everything else quiet.
        var levels = NoiseRating.ncBands.map { (band: $0, level: 0.0) }
        levels[4].level = 38.5
        XCTAssertEqual(NoiseRating.nc(levels)!, 37.5, accuracy: 1e-9)
    }
}
