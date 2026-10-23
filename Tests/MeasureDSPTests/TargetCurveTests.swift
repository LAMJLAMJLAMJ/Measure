import Foundation
import XCTest
@testable import MeasureDSP

final class TargetCurveTests: XCTestCase {
    let fs = 48_000.0

    /// A response on a fine log grid: `level` plus the filters' gain.
    func response(level: Double, filters: [EQFilter] = []) -> FrequencyResponse {
        let f = (0..<1200).map { 10 * pow(2, Double($0) / 100) }.filter { $0 < 22_000 }
        return FrequencyResponse(frequencies: f, magnitude: f.map { level + ParametricEQ.gainDB(filters, at: $0, sampleRate: fs) })
    }

    func testPresetShapes() {
        let flat = TargetCurve.Preset.flat.curve
        XCTAssertEqual(flat.level(at: 50), 0)
        XCTAssertEqual(flat.level(at: 12_000), 0)

        let falling = TargetCurve.Preset.falling.curve
        XCTAssertEqual(falling.level(at: 1000), 0, accuracy: 1e-9)
        XCTAssertEqual(falling.level(at: 4000), -2, accuracy: 1e-9)
        XCTAssertEqual(falling.level(at: 250), 2, accuracy: 1e-9)

        let x = TargetCurve.Preset.xCurve.curve
        XCTAssertEqual(x.level(at: 500), 0, accuracy: 1e-9)
        XCTAssertEqual(x.level(at: 2000), 0, accuracy: 1e-9)
        XCTAssertEqual(x.level(at: 8000), -6, accuracy: 1e-9)

        let pa = TargetCurve.Preset.livePA.curve
        XCTAssertEqual(pa.level(at: 20), 6, accuracy: 0.2)
        XCTAssertEqual(pa.level(at: 100), 3, accuracy: 0.05)
        XCTAssertEqual(pa.level(at: 1000), 0, accuracy: 0.1)
        XCTAssertEqual(pa.level(at: 8000), -2, accuracy: 0.01)
    }

    func testImportedPointsInterpolateOnLogFrequency() throws {
        let target = try TargetCurve.parse("* house curve\n20 6\n200 0\n2000 0\n20000 -10\n", name: "House")
        XCTAssertEqual(target.points?.count, 4)
        XCTAssertEqual(target.low, 20)
        XCTAssertEqual(target.high, 20_000)
        XCTAssertEqual(target.level(at: 63.2456), 3, accuracy: 1e-3)  // halfway between 20 and 200 in log
        XCTAssertEqual(target.level(at: 1000), 0, accuracy: 1e-9)
        XCTAssertEqual(target.level(at: 10), 6)
        XCTAssertThrowsError(try TargetCurve.parse("no numbers here", name: "Bad"))
    }

    func testAlignmentIgnoresAPeak() {
        // 75 dB with a narrow 10 dB peak: the median keeps the target at 75 dB.
        let measured = response(level: 75, filters: [EQFilter(kind: .peak, frequency: 2000, gain: 10, q: 8)])
        var target = TargetCurve.Preset.flat.curve
        XCTAssertEqual(target.alignment(to: measured), 75, accuracy: 0.05)
        target.offset = -2
        XCTAssertEqual(target.alignment(to: measured), 73, accuracy: 0.05)
    }

    func testAutoEQFindsKnownPeaks() {
        let room = [EQFilter(kind: .peak, frequency: 120, gain: 8, q: 4),
                    EQFilter(kind: .peak, frequency: 2500, gain: 5, q: 1.5)]
        let measured = response(level: -20, filters: room)
        let target = TargetCurve.Preset.flat.curve
        let result = AutoEQ.fit(response: measured, target: target, alignment: target.alignment(to: measured),
                                settings: AutoEQ.Settings(smoothing: 24), sampleRate: fs)
        XCTAssertGreaterThan(result.rmsBefore, 1.5)
        XCTAssertLessThan(result.rmsAfter, 0.6)
        XCTAssertLessThanOrEqual(result.filters.count, 8)
        for peak in room {
            XCTAssertTrue(result.filters.contains { $0.gain < -peak.gain / 2 && abs(log2($0.frequency / peak.frequency)) < 0.25 },
                          "no cut near \(peak.frequency) Hz in \(ParametricEQ.description(result.filters))")
        }
        // The predicted response is close to flat.
        let corrected = ParametricEQ.apply(result.filters, to: measured, sampleRate: fs).smoothed(fraction: 24)
        for f in [100.0, 120, 150, 1000, 2500, 5000] {
            XCTAssertEqual(corrected.magnitude(at: f), -20, accuracy: 1.5, "at \(f) Hz")
        }
    }

    func testAutoEQFollowsATiltWithShelves() {
        // A response 4 dB too strong in the bass and 4 dB too weak in the treble, against a flat target.
        let measured = response(level: 0, filters: [EQFilter(kind: .lowShelf, frequency: 150, gain: 4, q: 0.707),
                                                    EQFilter(kind: .highShelf, frequency: 6000, gain: -3, q: 0.707)])
        let target = TargetCurve.Preset.flat.curve
        let settings = AutoEQ.Settings(maxBoost: 6)
        let result = AutoEQ.fit(response: measured, target: target, alignment: target.alignment(to: measured),
                                settings: settings, sampleRate: fs)
        XCTAssertLessThan(result.rmsAfter, 0.6)
        XCTAssertTrue(result.filters.contains { $0.kind == .lowShelf && $0.gain < -2 })
        XCTAssertTrue(result.filters.contains { $0.kind == .highShelf && $0.gain > 1.5 })
    }

    func testBoostIsLimitedAndFixedFiltersAreKept() {
        // A deep narrow dip cannot be filled with a 3 dB boost limit.
        let dip = response(level: 0, filters: [EQFilter(kind: .peak, frequency: 800, gain: -15, q: 6)])
        let target = TargetCurve.Preset.flat.curve
        let result = AutoEQ.fit(response: dip, target: target, alignment: target.alignment(to: dip), sampleRate: fs)
        XCTAssertTrue(result.filters.allSatisfy { $0.gain <= 3 + 1e-9 })

        // A peak already corrected by a filter kept by hand needs nothing more.
        let peak = EQFilter(kind: .peak, frequency: 400, gain: 6, q: 2)
        let measured = response(level: 0, filters: [peak])
        let manual = EQFilter(kind: .peak, frequency: 400, gain: -6, q: 2)
        let kept = AutoEQ.fit(response: measured, target: target, alignment: 0, fixed: [manual], sampleRate: fs)
        XCTAssertLessThan(kept.rmsBefore, 0.1)
        XCTAssertTrue(kept.filters.isEmpty)
    }

    func testAutoEQRespectsTheFilterLimitAndTarget() {
        // Fitting a measured X-curve shape to the X-curve target needs nothing.
        let x = TargetCurve.Preset.xCurve.curve
        let f = (0..<1000).map { 20 * pow(2, Double($0) / 100) }.filter { $0 < 20_000 }
        let measured = FrequencyResponse(frequencies: f, magnitude: f.map { x.level(at: $0) + 80 })
        let none = AutoEQ.fit(response: measured, target: x, alignment: x.alignment(to: measured),
                              settings: AutoEQ.Settings(smoothing: 48), sampleRate: fs)
        XCTAssertTrue(none.filters.isEmpty, ParametricEQ.description(none.filters))

        let rough = response(level: 0, filters: (0..<6).map { EQFilter(kind: .peak, frequency: 100 * pow(2, Double($0) * 1.3), gain: 5, q: 3) })
        let two = AutoEQ.fit(response: rough, target: TargetCurve.Preset.flat.curve, alignment: 0,
                             settings: AutoEQ.Settings(maxFilters: 2), sampleRate: fs)
        XCTAssertLessThanOrEqual(two.filters.count, 2)
        XCTAssertLessThan(two.rmsAfter, two.rmsBefore)
    }
}
