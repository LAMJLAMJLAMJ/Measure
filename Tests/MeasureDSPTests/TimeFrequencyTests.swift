import XCTest
@testable import MeasureDSP

final class TimeFrequencyTests: XCTestCase {
    func testEnergyTimeCurvePeaksAtImpulse() {
        var ir = [Double](repeating: 0, count: 2000)
        ir[300] = 1
        ir[900] = 0.1
        let etc = TimeFrequency.energyTimeCurve(ir)
        XCTAssertEqual(etc.count, 2000)
        XCTAssertEqual(etc[300], 0, accuracy: 1e-6)
        XCTAssertEqual(etc[900], -20, accuracy: 0.5)
    }

    func testSpectrogramFindsTone() {
        let fs = 48_000.0
        let x = TestSignals.sine(frequency: 1000, sampleRate: fs, count: 24_000)
        let g = TimeFrequency.spectrogram(x, sampleRate: fs, windowSize: 2048, hop: 1024)
        XCTAssertGreaterThan(g.times.count, 10)
        let mid = g.levels[g.levels.count / 2]
        let peakBin = mid.indices.max { mid[$0] < mid[$1] }!
        XCTAssertEqual(g.frequencies[peakBin], 1000, accuracy: fs / 2048)
    }

    func testWaterfallDecays() {
        let fs = 48_000.0
        let ir = TestSignals.exponentialDecay(rt: 0.5, sampleRate: fs, duration: 1, seed: 8)
        let g = TimeFrequency.waterfall(ir, sampleRate: fs, windowLength: 0.2, slices: 10, step: 0.05)
        XCTAssertEqual(g.times.count, 10)
        XCTAssertEqual(g.levels[0].max()!, 0, accuracy: 1e-9)
        // Each 50 ms of a 0.5 s RT is 6 dB of decay; after 0.45 s the mean level should be ~50 dB down.
        let meanFirst = g.levels[0].reduce(0, +) / Double(g.levels[0].count)
        let meanLast = g.levels[9].reduce(0, +) / Double(g.levels[9].count)
        XCTAssertEqual(meanFirst - meanLast, 54, accuracy: 6)
    }
}
