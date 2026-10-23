import Foundation
import XCTest
@testable import MeasureDSP

final class AlignmentTests: XCTestCase {
    let fs = 48_000.0
    let grid = TimeAlignment.grid(pointsPerOctave: 24, low: 20, high: 20_000)

    /// A biquad run over `x`, direct form I.
    func filter(_ x: [Double], _ b: Biquad) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in x.indices {
            y[n] = b.b0 * x[n] + b.b1 * x1 + b.b2 * x2 - b.a1 * y1 - b.a2 * y2
            (x2, x1, y2, y1) = (x1, x[n], y1, y[n])
        }
        return y
    }

    /// A unit impulse at `at` samples, through `filters` (Linkwitz-Riley when the same Butterworth twice).
    func impulse(at: Int, length: Int = 48_000, filters: [EQFilter] = []) -> [Double] {
        var x = [Double](repeating: 0, count: length)
        x[at] = 1
        for f in filters { x = filter(x, f.biquad(sampleRate: fs)) }
        return x
    }

    /// A part from an impulse response taken from sample `start`, as a trace's window does.
    func part(_ ir: [Double], start: Int = 0, arrival: Double? = nil, smoothing: Double? = nil) -> TimeAlignment.Part {
        let response = FrequencyResponse(impulseResponse: Array(ir[start...]), sampleRate: fs, fftSize: 65_536)
        let onset = Double(RoomAcoustics.onsetIndex(ir)) / fs
        return TimeAlignment.Part(response: response, start: Double(start) / fs, arrival: arrival ?? onset,
                              grid: grid, smoothing: smoothing)!
    }

    func testPartsAddUpToTheWhole() {
        // Two sources in one recording; their parts, from different window starts and with any arrival as
        // the phase reference, add up to the whole.
        let a = impulse(at: 1000, filters: [EQFilter(kind: .lowPass, frequency: 300)])
        let b = impulse(at: 1700, filters: [EQFilter(kind: .highPass, frequency: 200)])
        let whole = part(zip(a, b).map(+))
        let pa = part(a, start: 600, arrival: 0.0123)
        let pb = part(b, start: 1500)
        let total = TimeAlignment.sum([pa, pb], settings: [.init(), .init()], reference: whole.arrival)!
        for i in stride(from: 0, to: grid.count, by: 7) {
            XCTAssertEqual(total.level(i), whole.level(i), accuracy: 0.01, "\(grid[i]) Hz")
            let dp = abs(total.phase(i) - whole.phase(i))
            XCTAssertLessThan(min(dp, 360 - dp), 0.5, "\(grid[i]) Hz")
        }
        // The phase relative to its own arrival is flat for a plain delay.
        let d = part(impulse(at: 2400))
        XCTAssertEqual(d.arrival, 0.05, accuracy: 1e-9)
        for i in grid.indices { XCTAssertEqual(d.phase(i), 0, accuracy: 0.01) }
        XCTAssertEqual(d.phase(grid.firstIndex { $0 > 1000 }!, relativeTo: 0.05 - 0.25e-3), -90, accuracy: 10)
    }

    func testSettingsDelayInvertAndScale() {
        let p = part(impulse(at: 480))
        let moved = TimeAlignment.sum([p], settings: [.init(delay: 0.001, gain: -6, inverted: true)], reference: 0.011)!
        let reference = part(impulse(at: 528))
        for i in stride(from: 0, to: grid.count, by: 11) {
            XCTAssertEqual(moved.level(i), reference.level(i) - 6, accuracy: 0.01)
            XCTAssertEqual(abs(moved.phase(i)), 180, accuracy: 0.1)
        }
        // Two equal copies half a period apart cancel there.
        let f = 1000.0
        let i = grid.firstIndex { $0 >= f }!
        let halfPeriod = 0.5 / grid[i]
        let cancel = TimeAlignment.sum([p, p], settings: [.init(), .init(delay: halfPeriod)], reference: p.arrival)!
        XCTAssertLessThan(cancel.level(i), -60)
        XCTAssertEqual(TimeAlignment.summation([p, p], settings: [.init(), .init()], low: 20, high: 20_000)!, 0, accuracy: 1e-6)
    }

    func testFitFindsTheDelayAndPolarity() {
        // The same source measured twice, 3.2 ms apart and inverted: the fit undoes both.
        let a = part(impulse(at: 1000))
        let b = part(impulse(at: 1154, filters: [EQFilter(kind: .peak, frequency: 2000, gain: -12, q: 1)]).map { -$0 })
        let fit = TimeAlignment.fit(moving: b, to: a, low: 100, high: 10_000)!
        XCTAssertEqual(fit.delay * 1000, -154 / 48, accuracy: 0.01)
        XCTAssertTrue(fit.inverted)
        // The cut also turns the phase near 2 kHz, so the addition is not quite perfect.
        XCTAssertEqual(fit.summation, 0, accuracy: 0.3)
        XCTAssertEqual(fit.fromArrival * 1000, 0, accuracy: 0.01)
        let settings = TimeAlignment.normalized([.init(), .init(delay: fit.delay, inverted: true)])
        XCTAssertEqual(settings[0].delay * 1000, 154 / 48, accuracy: 0.01)
        XCTAssertEqual(settings[1].delay, 0, accuracy: 1e-12)
    }

    func testSubToTopThroughALinkwitzRileyCrossover() {
        // A fourth-order Linkwitz-Riley crossover at 100 Hz, the top 5 ms early. The sub's impulse peaks later
        // than its true arrival, so lining up arrivals is not enough; the phase fit gets it right.
        let lp = EQFilter(kind: .lowPass, frequency: 100), hp = EQFilter(kind: .highPass, frequency: 100)
        let subIR = impulse(at: 2000, filters: [lp, lp])
        let topIR = impulse(at: 1760, filters: [hp, hp])
        let sub = part(subIR, smoothing: 24), top = part(topIR, smoothing: 24)
        XCTAssertEqual(TimeAlignment.crossover(sub, top, low: 30, high: 1000)!, 100, accuracy: 3)
        let fit = TimeAlignment.fit(moving: sub, to: top, low: 50, high: 200)!
        // The fit moves the sub 240 samples earlier, whatever its detected arrival.
        XCTAssertEqual(fit.delay * fs, -240, accuracy: 2)
        XCTAssertFalse(fit.inverted)
        XCTAssertGreaterThan(fit.summation, -0.1)
        // Aligned, the pair sums flat; unaligned, it does not.
        let aligned = TimeAlignment.sum([sub, top], settings: [.init(delay: fit.delay), .init()], reference: top.arrival)!
        let unaligned = TimeAlignment.sum([sub, top], settings: [.init(), .init()], reference: top.arrival)!
        let band = grid.indices.filter { grid[$0] >= 30 && grid[$0] <= 1000 }
        for i in band { XCTAssertEqual(aligned.level(i), 0, accuracy: 0.3, "\(grid[i]) Hz") }
        XCTAssertLessThan(band.map { unaligned.level($0) }.min()!, -6)
    }

    func testEQIsAppliedWithItsPhase() {
        let hp = EQFilter(kind: .highPass, frequency: 500, q: 0.707)
        let peak = EQFilter(kind: .peak, frequency: 3000, gain: 6, q: 2)
        let off = EQFilter(kind: .lowPass, frequency: 100, enabled: false)
        let filtered = part(impulse(at: 960, filters: [hp, peak]), arrival: 0.02)
        let predicted = part(impulse(at: 960), arrival: 0.02).applying([hp, peak, off], sampleRate: fs)
        for i in stride(from: 0, to: grid.count, by: 5) {
            XCTAssertEqual(predicted.level(i), filtered.level(i), accuracy: 0.01, "\(grid[i]) Hz")
            let dp = abs(predicted.phase(i) - filtered.phase(i))
            XCTAssertLessThan(min(dp, 360 - dp), 0.2, "\(grid[i]) Hz")
        }
    }

    func testCrossoverNeedsACrossing() {
        let a = part(impulse(at: 100))
        var b = a
        for i in grid.indices { b.re[i] *= 0.5; b.im[i] *= 0.5 }
        XCTAssertNil(TimeAlignment.crossover(a, b))
        XCTAssertEqual(TimeAlignment.grid(pointsPerOctave: 3, low: 100, high: 800).count, 10)
    }
}
