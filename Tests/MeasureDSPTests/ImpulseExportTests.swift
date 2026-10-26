import XCTest
@testable import MeasureDSP

final class ImpulseExportTests: XCTestCase {
    private let fs = 48_000.0

    private func impulse(at onset: Int, count: Int = 48_000, peak: Double = 0.5) -> [Double] {
        var x = [Double](repeating: 0.001, count: count)
        x[onset] = peak
        return x
    }

    func testAsMeasuredKeepsEverything() {
        let ir = impulse(at: 1000)
        let out = ImpulseExport().prepare(ir, onset: 1000, sampleRate: fs)
        XCTAssertEqual(out.samples, ir)
        XCTAssertEqual(out.gain, 0)
    }

    func testStartsAtDirectSoundWithPreRoll() {
        let out = ImpulseExport(start: .directSound, preRoll: 0.005).prepare(impulse(at: 1000), onset: 1000, sampleRate: fs)
        XCTAssertEqual(out.samples.count, 48_000 - (1000 - 240))
        XCTAssertEqual(out.samples[240], 0.5)
    }

    func testLengthTrimsAndFadesTheEnd() {
        let out = ImpulseExport(length: 0.1).prepare(impulse(at: 100), onset: 100, sampleRate: fs)
        XCTAssertEqual(out.samples.count, 4800)
        XCTAssertEqual(out.samples.last!, 0, accuracy: 1e-12)
        XCTAssertEqual(out.samples[100], 0.5)
    }

    func testNormalizesThePeak() {
        let out = ImpulseExport(normalizeTo: -1).prepare(impulse(at: 100), onset: 100, sampleRate: fs)
        XCTAssertEqual(out.samples.map(abs).max()!, pow(10, -1.0 / 20), accuracy: 1e-12)
        XCTAssertEqual(out.gain, -1 - 20 * log10(0.5), accuracy: 1e-9)
    }

    func testFixedPointNeverClips() {
        let loud = impulse(at: 100, peak: 4)
        XCTAssertEqual(ImpulseExport(format: .float32).prepare(loud, onset: 100, sampleRate: fs).gain, 0)
        let out = ImpulseExport(format: .pcm24).prepare(loud, onset: 100, sampleRate: fs)
        XCTAssertEqual(out.samples.map(abs).max()!, 1, accuracy: 1e-12)
        XCTAssertEqual(out.gain, -20 * log10(4), accuracy: 1e-9)
    }

    func testChannelsShareOneGain() {
        let out = ImpulseExport(normalizeTo: 0).levelled([[0.5, 0], [0.25, 0]])
        XCTAssertEqual(out.channels[0][0], 1, accuracy: 1e-12)
        XCTAssertEqual(out.channels[1][0], 0.5, accuracy: 1e-12)
    }

    func testFileNames() {
        XCTAssertEqual(ImpulseExport.fileName("Seat A/12: left"), "Seat A-12- left.wav")
        XCTAssertEqual(ImpulseExport.fileName("Mic 1", taken: ["mic 1.wav"]), "Mic 1 2.wav")
        XCTAssertEqual(ImpulseExport.fileName("  "), "Impulse response.wav")
    }
}
