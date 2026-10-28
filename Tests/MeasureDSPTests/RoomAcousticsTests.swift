import XCTest
@testable import MeasureDSP

final class RoomAcousticsTests: XCTestCase {
    let fs = 48_000.0

    /// Analytic C, D and Ts of a pure exponential energy decay with reverberation time `rt`.
    func expected(rt: Double) -> (c50: Double, c80: Double, d50: Double, ts: Double) {
        let k = 6 * log(10) / rt
        let late50 = exp(-k * 0.05), late80 = exp(-k * 0.08)
        return (10 * log10((1 - late50) / late50), 10 * log10((1 - late80) / late80), 1 - late50, 1 / k)
    }

    func testCleanDecayBroadband() {
        for rt in [0.5, 1.0, 2.0] {
            let ir = TestSignals.exponentialDecay(rt: rt, sampleRate: fs, duration: 2.5 * rt, seed: 2)
            let p = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs).broadband
            XCTAssertEqual(p.t30!, rt, accuracy: 0.03 * rt, "T30 at RT \(rt)")
            XCTAssertEqual(p.t20!, rt, accuracy: 0.03 * rt, "T20 at RT \(rt)")
            XCTAssertEqual(p.edt!, rt, accuracy: 0.06 * rt, "EDT at RT \(rt)")
            let e = expected(rt: rt)
            XCTAssertEqual(p.c50, e.c50, accuracy: 0.3, "C50 at RT \(rt)")
            XCTAssertEqual(p.c80, e.c80, accuracy: 0.3, "C80 at RT \(rt)")
            XCTAssertEqual(p.d50, e.d50, accuracy: 0.02, "D50 at RT \(rt)")
            XCTAssertEqual(p.ts, e.ts, accuracy: 0.05 * e.ts, "Ts at RT \(rt)")
        }
    }

    func testNoisyDecayUsesLundebyTruncation() {
        let rt = 1.2
        // Background noise 55 dB below the start of the decay, and 3 s of recording so the last half is noise.
        let ir = TestSignals.exponentialDecay(rt: rt, sampleRate: fs, duration: 3, noiseDB: -55, seed: 4)
        let p = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs).broadband
        XCTAssertEqual(p.t30!, rt, accuracy: 0.05 * rt)
        XCTAssertEqual(p.t20!, rt, accuracy: 0.05 * rt)
        // The noise floor is reported relative to the peak of the squared response.
        let peakDB = 10 * log10(ir.map { $0 * $0 }.max()!)
        XCTAssertEqual(p.noiseFloor, -55 - peakDB, accuracy: 2)
        // The decay meets the noise about 55/60 of the way through RT.
        XCTAssertEqual(p.truncationTime, 55.0 / 60 * rt, accuracy: 0.15)
    }

    func testNoiseCompensationMatters() {
        // With only 45 dB of decay above the noise, plain Schroeder integration badly overestimates T30.
        let rt = 1.2
        var compensated = 0.0, raw = 0.0
        var plain = RoomAcoustics.Options()
        plain.noiseCompensation = false
        for seed in 1...4 {
            let ir = TestSignals.exponentialDecay(rt: rt, sampleRate: fs, duration: 3, noiseDB: -45, seed: UInt64(seed))
            compensated += RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs).broadband.t30! / 4
            raw += RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs, options: plain).broadband.t30! / 4
        }
        XCTAssertEqual(compensated, rt, accuracy: 0.05 * rt)
        XCTAssertGreaterThan(raw, 2 * rt)
    }

    func testBandsOfWhiteDecay() {
        // Band-limited decays fluctuate a lot from one noise realisation to the next (ISO 3382-2 annex A),
        // so average several before comparing.
        let rt = 1.0, runs = 8
        var options = RoomAcoustics.Options()
        options.lowestBand = 125
        options.highestBand = 8000
        var t20 = [Double](repeating: 0, count: 7), t30 = t20
        for seed in 1...runs {
            let ir = TestSignals.exponentialDecay(rt: rt, sampleRate: fs, duration: 2.5, noiseDB: -70, seed: UInt64(seed))
            let result = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs, options: options)
            XCTAssertEqual(result.bands.map { $0.band!.nominal }, [125, 250, 500, 1000, 2000, 4000, 8000])
            for (i, p) in result.bands.enumerated() {
                t20[i] += p.t20! / Double(runs)
                t30[i] += p.t30! / Double(runs)
            }
        }
        for (i, band) in options.resolution.bands(sampleRate: fs, from: 125, to: 8000).enumerated() {
            XCTAssertEqual(t30[i], rt, accuracy: 0.04 * rt, "T30 in \(band) band")
            XCTAssertEqual(t20[i], rt, accuracy: (band.nominal < 250 ? 0.08 : 0.05) * rt, "T20 in \(band) band")
        }
    }

    func testOnsetSkipsLeadingSilence() {
        let ir = TestSignals.exponentialDecay(rt: 0.8, sampleRate: fs, duration: 2, noiseDB: -80, delay: 1234, seed: 6)
        let result = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs)
        XCTAssertEqual(result.onsetIndex, 1234, accuracy: 30)
        XCTAssertEqual(result.broadband.t30!, 0.8, accuracy: 0.04)
    }

    func testLowBandsIgnoreTheFilterRingingFromTheDirectSound() {
        // A loud direct sound on a 1.2 s decay. Filtered forwards, the 63 and 125 Hz bands ring from
        // the direct sound and their EDT comes out a fraction of the decay's; backwards (the default)
        // the ringing falls before the onset and EDT is what it is without the direct sound. (EDT
        // itself varies a lot between noise realisations in low bands, so compare like with like.)
        let rt = 1.2, runs = 8
        var options = RoomAcoustics.Options()
        options.lowestBand = 63
        options.highestBand = 125
        var forwards = options
        forwards.timeReversedFiltering = false
        var edt = [0.0, 0.0], edtWithoutDirect = [0.0, 0.0], edtForwards = [0.0, 0.0]
        for seed in 1...runs {
            let decay = TestSignals.exponentialDecay(rt: rt, sampleRate: fs, duration: 3, noiseDB: -80, delay: 480,
                                                     seed: UInt64(seed))
            var ir = decay
            ir[480] += 300
            let backwards = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs, options: options).bands
            let plain = RoomAcoustics.analyze(impulseResponse: decay, sampleRate: fs, options: options).bands
            let ringing = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs, options: forwards).bands
            for i in 0..<2 {
                edt[i] += backwards[i].edt! / Double(runs)
                edtWithoutDirect[i] += plain[i].edt! / Double(runs)
                edtForwards[i] += ringing[i].edt! / Double(runs)
            }
        }
        for i in 0..<2 {
            XCTAssertEqual(edt[i], edtWithoutDirect[i], accuracy: 0.03 * rt, "EDT in band \(i)")
            XCTAssertEqual(edtWithoutDirect[i], rt, accuracy: 0.25 * rt, "EDT without the direct sound in band \(i)")
            XCTAssertLessThan(edtForwards[i], 0.5 * rt, "forward-filtered EDT in band \(i)")
        }
    }

    func testDecayFitNeedsEnoughRange() {
        // A curve that only falls 20 dB can give EDT and T20 but not T30.
        let curve = (0..<1000).map { -20 * Double($0) / 999 }
        XCTAssertNotNil(RoomAcoustics.fitDecay(curve, sampleRate: 1000, from: 0, to: -10))
        XCTAssertNil(RoomAcoustics.fitDecay(curve, sampleRate: 1000, from: -5, to: -35))
    }
}
