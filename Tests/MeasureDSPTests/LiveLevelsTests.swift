import Foundation
import XCTest
@testable import MeasureDSP

final class LiveLevelsTests: XCTestCase {
    let fs = 16_000.0

    func sine(_ f: Double, amplitude: Double = 1, seconds: Double) -> [Double] {
        (0..<Int(seconds * fs)).map { amplitude * sin(2 * Double.pi * f * Double($0) / fs) }
    }

    func testStreamingWeightingMatchesTheWholeSignal() {
        let x = (0..<5000).map { _ in Double.random(in: -1...1) }
        for w in SoundLevel.FrequencyWeighting.allCases {
            let whole = SoundLevel.WeightingFilter(w, sampleRate: fs).apply(x)
            var streaming = StreamingWeighting(w, sampleRate: fs)
            var pieces: [Double] = []
            var i = 0
            for n in [1, 7, 300, 1024, 5000] where i < x.count {
                let end = min(x.count, i + n)
                pieces += streaming.process(Array(x[i..<end]))
                i = end
            }
            pieces += streaming.process(Array(x[i...]))
            XCTAssertEqual(pieces.count, whole.count)
            for k in stride(from: 0, to: x.count, by: 97) {
                XCTAssertEqual(pieces[k], whole[k], accuracy: 1e-9, "\(w) at \(k)")
            }
        }
    }

    func testMeterReadsASineAndItsWeighting() {
        let meter = SoundLevelMeter(sampleRate: fs)
        let x = sine(1000, seconds: 3)
        // In pieces, as from a live input.
        for start in stride(from: 0, to: x.count, by: 1600) { meter.process(Array(x[start..<min(x.count, start + 1600)])) }
        XCTAssertEqual(meter.seconds, 3)
        for w in SoundLevel.FrequencyWeighting.allCases {
            XCTAssertEqual(meter.level(w, .fast), -3.01, accuracy: 0.1, "\(w)")
            // Slow has a 1 s time constant: after 3 s it has risen to 1 - e^-3 of the mean square.
            XCTAssertEqual(meter.level(w, .slow), -3.01 + 10 * log10(1 - exp(-3.0)), accuracy: 0.1, "\(w)")
            XCTAssertEqual(meter.level(w, .continuous), -3.01, accuracy: 0.1, "\(w)")
            XCTAssertEqual(meter.level(w, .oneMinute), -3.01, accuracy: 0.1, "\(w)")
            // C weighting overshoots a little as the tone starts.
            XCTAssertEqual(meter.peakLevel(w), 0, accuracy: 0.3, "\(w)")
        }
        // A 100 Hz tone is 19.1 dB down on A weighting, 0.3 dB on C.
        let low = SoundLevelMeter(sampleRate: fs)
        low.process(sine(100, seconds: 2))
        XCTAssertEqual(low.level(.a, .continuous), -3.01 - 19.1, accuracy: 0.3)
        XCTAssertEqual(low.level(.c, .continuous), -3.01 - 0.3, accuracy: 0.2)
        XCTAssertEqual(low.level(.z, .continuous), -3.01, accuracy: 0.1)
    }

    func testTimeWeightingAndMovingAverages() {
        let meter = SoundLevelMeter(sampleRate: fs)
        // 30 s of tone, then 30 s of silence (well, -120 dB).
        meter.process(sine(1000, seconds: 30))
        XCTAssertEqual(meter.level(.z, .fast), -3.01, accuracy: 0.1)
        meter.process(sine(1000, amplitude: 1e-6, seconds: 30))
        // Fast falls 34.7 dB per second, Slow 4.3 dB per second: both long gone after 30 s.
        XCTAssertLessThan(meter.level(.z, .fast), -100)
        XCTAssertLessThan(meter.level(.z, .slow), -100)
        XCTAssertEqual(meter.maximum(.z, .fast), -3.01, accuracy: 0.1)
        // Half the minute at -3 dB: the 1-minute Leq and the running Leq are 3 dB lower.
        XCTAssertEqual(meter.level(.z, .oneMinute), -6.02, accuracy: 0.1)
        XCTAssertEqual(meter.level(.z, .continuous), -6.02, accuracy: 0.1)
        // Before the window fills, a moving Leq covers what there is.
        XCTAssertEqual(meter.level(.z, .fiveMinutes), -6.02, accuracy: 0.1)

        let history = meter.history(.z, .oneMinute)
        XCTAssertEqual(history.count, 60)
        XCTAssertEqual(history[29], -3.01, accuracy: 0.1)
        XCTAssertEqual(history[59], -6.02, accuracy: 0.1)
        XCTAssertEqual(meter.maximum(.z, .oneMinute), -3.01, accuracy: 0.1)
        let slow = meter.history(.z, .slow)
        XCTAssertEqual(slow[20], -3.01, accuracy: 0.1)
        XCTAssertLessThan(slow[59], -100)
    }

    func testBandsFollowTheStandard() {
        let thirds = RealTimeAnalyzer.bands(fraction: 3, sampleRate: 48_000)
        XCTAssertEqual(thirds.count, 31)  // 20 Hz to 20 kHz
        XCTAssertEqual(thirds.first!.center, 19.95, accuracy: 0.01)
        XCTAssertTrue(thirds.contains { abs($0.center - 1000) < 1e-9 })
        let octaves = RealTimeAnalyzer.bands(fraction: 1, sampleRate: 48_000)
        XCTAssertEqual(octaves.map { $0.center.rounded() }, [32, 63, 126, 251, 501, 1000, 1995, 3981, 7943, 15849])
        let sixths = RealTimeAnalyzer.bands(fraction: 6, sampleRate: 48_000)
        // Even fractions have band edges on 1 kHz.
        XCTAssertTrue(sixths.contains { abs($0.lower - 1000) < 1e-9 })
        XCTAssertEqual(Double(RealTimeAnalyzer.bands(fraction: 24, sampleRate: 48_000).count), 240, accuracy: 2)
    }

    func testRTAReadsASineInItsBand() {
        let rta = RealTimeAnalyzer(fftSize: 8192, sampleRate: fs, fraction: 3)
        let x = sine(1000, amplitude: 0.5, seconds: 1)
        rta.process(Array(x.prefix(8192)), hop: 8192, averaging: .fast)
        let i = rta.bands.firstIndex { abs($0.center - 1000) < 1e-6 }!
        XCTAssertEqual(rta.levels[i], -9.03, accuracy: 0.2)
        // Two bands away it is far down.
        XCTAssertLessThan(rta.levels[i + 2], -60)
        // The bands add up to the whole: white noise reads the same total in thirds and octaves.
        let noise = (0..<8192).map { _ in Double.random(in: -1...1) }
        let msTotal = 10 * log10(noise.map { $0 * $0 }.reduce(0, +) / 8192)
        for fraction in [1, 3, 12] {
            let r = RealTimeAnalyzer(fftSize: 8192, sampleRate: 48_000, fraction: fraction)
            r.process(noise, hop: 8192, averaging: .infinite)
            let sum = 10 * log10(r.levels.map { pow(10, $0 / 10) }.reduce(0, +))
            // White noise spreads evenly to 24 kHz; the bands cover their own span of it.
            let covered = (r.bands.last!.upper - r.bands.first!.lower) / 24_000
            XCTAssertEqual(sum, msTotal + 10 * log10(covered), accuracy: 0.3, "1/\(fraction) octave")
        }
    }

    func testRTAPeakHoldAndAveraging() {
        let rta = RealTimeAnalyzer(fftSize: 4096, sampleRate: fs, fraction: 1)
        let loud = sine(1000, amplitude: 1, seconds: 0.256)
        let quiet = sine(1000, amplitude: 0.01, seconds: 0.256)
        rta.process(loud, hop: 4096, averaging: .infinite)
        rta.process(quiet, hop: 4096, averaging: .infinite)
        let i = rta.bands.firstIndex { abs($0.center - 1000) < 1e-6 }!
        // The plain average of the two powers: 3 dB under the loud one, near enough.
        XCTAssertEqual(rta.levels[i], -3.01 - 3.01, accuracy: 0.2)
        XCTAssertEqual(rta.peaks[i], -3.01, accuracy: 0.2)
        rta.reset()
        XCTAssertEqual(rta.blocks, 0)
        rta.process(quiet, hop: 4096, averaging: .slow)
        XCTAssertEqual(rta.levels[i], -43.01, accuracy: 0.2)
    }

    func testWeightingCurve() {
        // IEC 61672-1 table values, at the exact mid-band frequencies.
        XCTAssertEqual(SoundLevel.weightingDB(.a, at: 1000), 0, accuracy: 1e-9)
        XCTAssertEqual(SoundLevel.weightingDB(.a, at: 100), -19.1, accuracy: 0.05)
        XCTAssertEqual(SoundLevel.weightingDB(.a, at: 31.62), -39.4, accuracy: 0.05)
        XCTAssertEqual(SoundLevel.weightingDB(.c, at: 31.62), -3.0, accuracy: 0.05)
        XCTAssertEqual(SoundLevel.weightingDB(.a, at: 8000), -1.1, accuracy: 0.05)
        XCTAssertEqual(SoundLevel.weightingDB(.z, at: 50), 0)
    }

    func testLevelLogCSV() {
        // Three weightings; two seconds, at 0.01 mean square (-20 dB) and 0.1 (-10 dB).
        let series = [[0.01, 0.1], [0.01, 0.1], [0.01, 0.1]]
        let log = LevelLog(energy: series, fastMax: series, slow: series)
        XCTAssertEqual(log.seconds, 2)
        let start = Date(timeIntervalSince1970: 0)
        let csv = LevelLog.csv([LevelLog.Column(name: "Mic, 1", offset: 100, unit: "dB SPL", log: log)], start: start)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("Time,Elapsed s,\"Mic, 1 LAeq,1s (dB SPL)\""))
        let row = lines[2].split(separator: ",").map(String.init)
        XCTAssertEqual(row[1], "2")
        XCTAssertEqual(row[2], "90.0")
        XCTAssertEqual(row.count, 2 + 9)
    }

    func testPausesShiftTheLogTimes() {
        let pauses = [LevelLog.Pause(afterSecond: 1, duration: 30), LevelLog.Pause(afterSecond: 3, duration: 5)]
        XCTAssertEqual(LevelLog.endTime(ofSecond: 0, pauses: pauses), 1)
        XCTAssertEqual(LevelLog.endTime(ofSecond: 1, pauses: pauses), 32)
        XCTAssertEqual(LevelLog.endTime(ofSecond: 3, pauses: pauses), 39)

        let series = [[0.01, 0.01], [0.01, 0.01], [0.01, 0.01]]
        let log = LevelLog(energy: series, fastMax: series, slow: series)
        let csv = LevelLog.csv([LevelLog.Column(name: "Mic 1", offset: 0, unit: "dBFS", log: log)],
                               start: Date(timeIntervalSince1970: 0), pauses: [LevelLog.Pause(afterSecond: 1, duration: 60)])
        let rows = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",").map(String.init) }
        // The second row ends a minute later than without the pause, and still counts 2 seconds measured.
        XCTAssertTrue(rows[1][0].hasSuffix(":01:02"), rows[1][0])
        XCTAssertEqual(rows[1][1], "2")
    }

    func testStatisticsUseTheFastLevelEveryTenthOfASecond() {
        // A 1 kHz tone, loud (0 dB) for 0.8 s and 20 dB down for 3.2 s, every 4 s for 20 s. The quiet
        // part is the level most of the time, so L50 must be near −23 dB re full scale; each second's
        // highest Fast level (the history) is loud or still decaying in half the seconds, about −10 dB.
        let fs = 48_000.0
        let x = (0..<Int(20 * fs)).map { i -> Double in
            let t = Double(i) / fs
            let loud = t.truncatingRemainder(dividingBy: 4) < 0.8
            return (loud ? 1 : 0.1) * sin(2 * Double.pi * 1000 * t)
        }
        let meter = SoundLevelMeter(sampleRate: fs)
        for start in stride(from: 0, to: x.count, by: 4800) { meter.process(Array(x[start..<min(x.count, start + 4800)])) }
        XCTAssertEqual(meter.tenthFast[0].count, 200)
        let l50 = meter.exceeded(50, .z, .fast)!, l90 = meter.exceeded(90, .z, .fast)!, l10 = meter.exceeded(10, .z, .fast)!
        XCTAssertEqual(l50, -23, accuracy: 1)
        XCTAssertEqual(l90, -23, accuracy: 1)
        XCTAssertEqual(l10, -3.2, accuracy: 1)
        XCTAssertGreaterThan(SoundLevelMeter.exceeded(50, of: meter.history(.z, .fast))!, -15)
        // Over the last 5 s only.
        XCTAssertEqual(meter.exceeded(50, .z, .fast, seconds: 5)!, -23, accuracy: 1)
        XCTAssertEqual(SoundLevelMeter.exceeded(10, of: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])!, 10)
    }
}

final class LeqForecastTests: XCTestCase {
    func ms(_ db: Double) -> Double { pow(10, db / 10) }

    /// A 5 min Leq at 94 dB with a 96 dB limit and the level now 97 dB: it reaches the limit when
    /// ((300 − t)·94 dB + t·97 dB) / 300 does.
    func testMovingLeqRisesToTheLimit() {
        let energies = [Double](repeating: ms(94), count: 300)
        let t = LeqForecast.secondsToCross(energies: energies, window: 300, nowLevel: 97, targetLevel: 96)
        let expected = Int((300 * (ms(96) - ms(94)) / (ms(97) - ms(94))).rounded(.up))
        XCTAssertEqual(t, expected)
        XCTAssertEqual(t, 177)
    }

    func testMovingLeqNeverReachesALimitAboveTheLevelNow() {
        let energies = [Double](repeating: ms(94), count: 300)
        XCTAssertNil(LeqForecast.secondsToCross(energies: energies, window: 300, nowLevel: 95, targetLevel: 96))
    }

    /// Over the limit at 98 dB; at 3 dB under the limit it comes back under when enough of the loud
    /// seconds have left the window.
    func testMovingLeqFallsBackUnder() {
        let energies = [Double](repeating: ms(98), count: 300)
        let t = LeqForecast.secondsToCross(energies: energies, window: 300, nowLevel: 93, targetLevel: 96)
        // ((300 − t)·98 dB + t·93 dB) / 300 < 96 dB.
        let exact = 300 * (ms(98) - ms(96)) / (ms(98) - ms(93))
        XCTAssertEqual(t, Int(exact.rounded(.down)) + 1)
        XCTAssertNil(LeqForecast.secondsToCross(energies: energies, window: 300, nowLevel: 97, targetLevel: 96))
    }

    /// Older seconds leave the window first: a loud start followed by quiet leaves sooner than the
    /// average alone suggests.
    func testMovingLeqDropsTheOldestSecondsFirst() {
        let energies = [Double](repeating: ms(100), count: 120) + [Double](repeating: ms(90), count: 180)
        // Under 96 dB once the 100 dB seconds that remain are few enough; the level now is 90 dB.
        let t = LeqForecast.secondsToCross(energies: energies, window: 300, nowLevel: 90, targetLevel: 96)!
        func mean(_ t: Int) -> Double { (Double(120 - t) * ms(100) + Double(180 + t) * ms(90)) / 300 }
        XCTAssertEqual(t, 21)
        XCTAssertGreaterThanOrEqual(mean(t - 1), ms(96))
        XCTAssertLessThan(mean(t), ms(96))
    }

    /// While the window fills it covers the seconds so far.
    func testMovingLeqWhileTheWindowFills() {
        let energies = [Double](repeating: ms(90), count: 10)
        let t = LeqForecast.secondsToCross(energies: energies, window: 300, nowLevel: 100, targetLevel: 96)!
        func mean(_ t: Int) -> Double { (10 * ms(90) + Double(t) * ms(100)) / Double(10 + t) }
        XCTAssertLessThan(mean(t - 1), ms(96))
        XCTAssertGreaterThanOrEqual(mean(t), ms(96))
    }

    func testRunningLeq() {
        let energies = [Double](repeating: ms(94), count: 600)
        let up = LeqForecast.secondsToCross(energies: energies, window: nil, nowLevel: 97, targetLevel: 96)!
        func mean(_ t: Int, _ now: Double) -> Double { (600 * ms(94) + Double(t) * ms(now)) / Double(600 + t) }
        XCTAssertLessThan(mean(up - 1, 97), ms(96))
        XCTAssertGreaterThanOrEqual(mean(up, 97), ms(96))

        let loud = [Double](repeating: ms(98), count: 600)
        let down = LeqForecast.secondsToCross(energies: loud, window: nil, nowLevel: 93, targetLevel: 96)!
        func loudMean(_ t: Int) -> Double { (600 * ms(98) + Double(t) * ms(93)) / Double(600 + t) }
        XCTAssertGreaterThanOrEqual(loudMean(down - 1), ms(96))
        XCTAssertLessThan(loudMean(down), ms(96))
        XCTAssertNil(LeqForecast.secondsToCross(energies: loud, window: nil, nowLevel: 96, targetLevel: 96))
    }
}

final class ShowBudgetTests: XCTestCase {
    func ms(_ db: Double) -> Double { pow(10, db / 10) }

    /// Half of a 60 min show at 98 dB with a 100 dB limit: the other half can run at the level that
    /// makes the energy average 100 dB.
    func testAllowedLevelForTheRestOfTheShow() {
        let energies = [Double](repeating: ms(98), count: 1800)
        guard case let .allowed(level, remaining) = ShowBudget.after(energies, showSeconds: 3600, target: 100) else {
            return XCTFail("expected a budget")
        }
        XCTAssertEqual(remaining, 1800)
        XCTAssertEqual(level, 10 * log10(2 * ms(100) - ms(98)), accuracy: 1e-9)
        // Running at that level for the rest gives exactly the limit.
        let total = (1800 * ms(98) + 1800 * ms(level)) / 3600
        XCTAssertEqual(10 * log10(total), 100, accuracy: 1e-9)
    }

    func testSpentAndFinished() {
        let loud = [Double](repeating: ms(110), count: 600)
        XCTAssertEqual(ShowBudget.after(loud, showSeconds: 3600, target: 100), .spent(remaining: 3000))
        XCTAssertEqual(ShowBudget.after(loud, showSeconds: 600, target: 100), .finished)
    }
}
