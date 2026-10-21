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

    func testLoopbackGainMakesLevelsRelativeToFullScale() {
        let sweep = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 1, sampleRate: fs)
        let played = sweep.samples(silence: 0.5)
        // The loopback cable and input attenuate the sweep by 6 dB; the mic hears it 20 dB down.
        let loopback = delayed(played, by: 300, gain: pow(10, -6.0 / 20))
        let mic = delayed(played, by: 300 + 480, gain: pow(10, -20.0 / 20))
        let result = SweepProcessing.process(mics: [mic], loopback: loopback, sweep: sweep, played: played)
        XCTAssertEqual(20 * log10(result.loopbackGain!), -6, accuracy: 0.1)
        let fr = FrequencyResponse(impulseResponse: result.impulseResponses[0], sampleRate: fs)
        for f in [100.0, 1000, 10_000] {
            XCTAssertEqual(fr.magnitude(at: f), -20, accuracy: 0.3, "\(f) Hz")
        }
    }

    func testClockDriftBetweenDevicesIsCorrected() {
        // The input device's clock runs 80 ppm faster than the output device's, so over this 6 s
        // measurement the recording drifts 24 samples against the nominal timeline.
        let ratio = 1 + 80e-6
        let sweep = ExponentialSweep(startFrequency: 20, endFrequency: 20_000, duration: 4, sampleRate: fs)
        let played = sweep.samples(silence: 2)
        // What the input device records, on its own clock: the played signal stretched, delayed by 480 samples at gain 0.2.
        let stretched = Resampler.resample(played, ratio: ratio)
        var recording = [Double](repeating: 0, count: stretched.count)
        for i in 0..<(stretched.count - 480) { recording[i + 480] = 0.2 * stretched[i] }

        // Share of the impulse response's energy within 3 samples of its peak: close to 1 for a clean pulse.
        func concentration(_ ir: [Double]) -> Double {
            let peak = Int(Peak.index(of: ir).rounded())
            let near = ir[max(0, peak - 3)...min(ir.count - 1, peak + 3)].reduce(0) { $0 + $1 * $1 }
            return near / ir.reduce(0) { $0 + $1 * $1 }
        }
        let corrected = SweepProcessing.process(mics: [recording], loopback: nil, sweep: sweep, played: played, clockRatio: ratio)
        let uncorrected = SweepProcessing.process(mics: [recording], loopback: nil, sweep: sweep, played: played)
        XCTAssertEqual(Peak.index(of: corrected.impulseResponses[0]), 480, accuracy: 0.2)
        XCTAssertGreaterThan(concentration(corrected.impulseResponses[0]), 0.95)
        // Without the correction the arrival time is wrong by most of the drift (16 samples here, 0.33 ms)
        // and the pulse is smeared.
        XCTAssertGreaterThan(abs(Peak.index(of: uncorrected.impulseResponses[0]) - 480), 8)
        XCTAssertLessThan(concentration(uncorrected.impulseResponses[0]), concentration(corrected.impulseResponses[0]) - 0.05)
    }
}
