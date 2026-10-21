import XCTest
@testable import MeasureDSP

final class SweepProcessingTests: XCTestCase {
    let fs = 48_000.0

    /// A recording of `played` delayed by `delay` samples and scaled by `gain`, same length as `played`.
    func delayed(_ played: [Double], by delay: Int, gain: Double) -> [Double] {
        var out = [Double](repeating: 0, count: played.count)
        for i in 0..<(played.count - delay) { out[i + delay] = gain * played[i] }
        return out
    }

    func testLoopbackGivesAbsoluteDelays() {
        let sweep = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 1, sampleRate: fs)
        let played = sweep.samples(silence: 0.5)
        let latency = 300, acoustic = 480
        let loopback = delayed(played, by: latency, gain: 0.9)
        let mic1 = delayed(played, by: latency + acoustic, gain: 0.2)
        let mic2 = delayed(played, by: latency + 2 * acoustic, gain: 0.1)

        let result = SweepProcessing.process(mics: [mic1, mic2], loopback: loopback, sweep: sweep, played: played)
        XCTAssertEqual(result.timingReference, .loopback)
        XCTAssertEqual(result.loopbackLatency!, Double(latency), accuracy: 0.05)
        XCTAssertEqual(Peak.index(of: result.impulseResponses[0]), Double(acoustic), accuracy: 0.05)
        XCTAssertEqual(Peak.index(of: result.impulseResponses[1]), Double(2 * acoustic), accuracy: 0.05)
        XCTAssertEqual(result.micPeakLevels[0], 20 * log10(0.2 * 0.5), accuracy: 0.1)
    }

    func testWithoutLoopbackDelaysIncludeLatency() {
        let sweep = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 1, sampleRate: fs)
        let played = sweep.samples(silence: 0.5)
        let mic = delayed(played, by: 780, gain: 0.2)
        let result = SweepProcessing.process(mics: [mic], loopback: nil, sweep: sweep, played: played)
        XCTAssertEqual(result.timingReference, .generated)
        XCTAssertNil(result.loopbackLatency)
        XCTAssertEqual(Peak.index(of: result.impulseResponses[0]), 780, accuracy: 0.05)
        // The response covers the silence after the sweep.
        XCTAssertEqual(Double(result.impulseResponses[0].count), 0.5 * fs, accuracy: 16)
    }
}
