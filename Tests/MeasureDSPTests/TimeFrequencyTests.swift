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

    func testEnergyTimePeakKeepsTheLevel() {
        var ir = [Double](repeating: 0, count: 2000)
        ir[300] = 0.5
        let (curve, peak) = TimeFrequency.energyTimeCurveAndPeak(ir)
        XCTAssertEqual(curve[300], 0, accuracy: 1e-6)
        XCTAssertEqual(peak, 20 * log10(0.5), accuracy: 0.1)
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

    func testReducedSpectrogramKeepsItsSizeAndFindsTone() {
        let fs = 8_000.0
        // 60 s of a 1 kHz tone, the second half 20 dB down.
        var x = TestSignals.sine(frequency: 1000, sampleRate: fs, count: Int(60 * fs))
        for i in x.count / 2..<x.count { x[i] *= 0.1 }
        let rows = (0..<64).map { 50 * pow(4000.0 / 50, Double($0) / 63) }
        let g = TimeFrequency.reducedSpectrogram(x, range: 0..<x.count, sampleRate: fs, windowSize: 1024, hop: 512,
                                                 frequencies: rows, columns: 100)!
        XCTAssertEqual(g.levels.count, 100)
        XCTAssertEqual(g.times.count, 100)
        XCTAssertEqual(g.levels[0].count, 64)
        XCTAssertEqual(g.times.last!, 60, accuracy: 0.5)
        let first = g.levels[10], last = g.levels[90]
        let peakRow = first.indices.max { first[$0] < first[$1] }!
        XCTAssertEqual(rows[peakRow], 1000, accuracy: 60)
        XCTAssertEqual(first[peakRow] - last[peakRow], 20, accuracy: 0.5)
    }

    func testReducedSpectrogramRangeAndCancel() {
        let fs = 8_000.0
        let x = TestSignals.sine(frequency: 500, sampleRate: fs, count: Int(30 * fs))
        let g = TimeFrequency.reducedSpectrogram(x, range: Int(10 * fs)..<Int(20 * fs), sampleRate: fs, windowSize: 512,
                                                 hop: 256, frequencies: [500], columns: 50)!
        XCTAssertEqual(g.times.first!, 10, accuracy: 0.2)
        XCTAssertEqual(g.times.last!, 20, accuracy: 0.2)
        XCTAssertNil(TimeFrequency.reducedSpectrogram(x, range: 0..<x.count, sampleRate: fs, windowSize: 512, hop: 256,
                                                      frequencies: [500], columns: 50, isCancelled: { true }))
        XCTAssertEqual(TimeFrequency.reducedSpectrogramBytes(columns: 100, rows: 63), (100 * 64 + 63) * 8)
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

    func testBandFilteredImpulseKeepsItsArrival() {
        let fs = 48_000.0
        var ir = [Double](repeating: 0, count: 48_000)
        ir[12_000] = 1
        for nominal in [63.0, 1000, 8000] {
            let band = BandResolution.octave.band(nominal: nominal)
            let filtered = TimeFrequency.bandFiltered(ir, sampleRate: fs, band: band)!
            let envelope = TimeFrequency.envelope(filtered)
            let peak = envelope.indices.max { envelope[$0] < envelope[$1] }!
            XCTAssertEqual(Double(peak), 12_000, accuracy: 1, "\(nominal) Hz")
        }
        XCTAssertNil(TimeFrequency.bandFiltered(ir, sampleRate: 16_000, band: BandResolution.octave.band(nominal: 8000)))
    }
}
