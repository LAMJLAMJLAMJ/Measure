import Foundation
import XCTest
@testable import MeasureDSP

final class ResponseWindowTests: XCTestCase {
    let fs = 48_000.0

    func testShape() {
        let w = ResponseWindow(left: 0.001, right: 0.010, rightTaper: 0.5) // 48 samples left, 480 right, fade over the last 240
        XCTAssertEqual(w.gain(atOffset: -49, sampleRate: fs), 0)
        XCTAssertEqual(w.gain(atOffset: -48, sampleRate: fs), 0, accuracy: 1e-12)
        XCTAssertEqual(w.gain(atOffset: -24, sampleRate: fs), 0.5, accuracy: 1e-12)
        XCTAssertEqual(w.gain(atOffset: 0, sampleRate: fs), 1)
        XCTAssertEqual(w.gain(atOffset: 239, sampleRate: fs), 1)
        XCTAssertEqual(w.gain(atOffset: 240, sampleRate: fs), 1, accuracy: 1e-12)
        XCTAssertEqual(w.gain(atOffset: 360, sampleRate: fs), 0.5, accuracy: 1e-12)
        XCTAssertEqual(w.gain(atOffset: 480, sampleRate: fs), 0)
    }

    func testImpulseAtOnsetStaysFlat() {
        var ir = [Double](repeating: 0, count: 96_000)
        ir[1000] = 1
        let (samples, start) = ResponseWindow.standard.apply(to: ir, onset: 1000, sampleRate: fs)
        XCTAssertEqual(start, 1000 - 240)
        XCTAssertEqual(samples.count, 240 + 48_000)
        XCTAssertEqual(samples[240], 1)
        let fr = FrequencyResponse(impulseResponse: samples, sampleRate: fs)
        for m in fr.magnitude { XCTAssertEqual(m, 0, accuracy: 1e-9) }
    }

    func testShortWindowRemovesLateReflection() {
        var ir = [Double](repeating: 0, count: 48_000)
        ir[500] = 1
        ir[500 + 480] = 0.5 // reflection 10 ms later
        let full = ResponseWindow.standard.apply(to: ir, onset: 500, sampleRate: fs).samples
        let short = ResponseWindow(left: 0.001, right: 0.005).apply(to: ir, onset: 500, sampleRate: fs).samples
        XCTAssertEqual(full.max(by: { abs($0) < abs($1) }).map(abs), 1)
        XCTAssertTrue(full.contains(0.5))
        XCTAssertFalse(short.contains { abs($0) > 0 && abs($0) < 1 })
    }

    func testClampsAtTheStartAndEnd() {
        let ir = [Double](repeating: 1, count: 100)
        let (samples, start) = ResponseWindow(left: 0.01, right: 0.01).apply(to: ir, onset: 10, sampleRate: fs)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(samples.count, 100)
        XCTAssertEqual(samples[10], 1)
        XCTAssertLessThan(samples[0], 1)
    }

    func testShapes() {
        for shape in ResponseWindow.Shape.allCases {
            XCTAssertEqual(shape.gain(1, taper: 0.25), 1, accuracy: 1e-12, "\(shape) at the onset")
        }
        XCTAssertEqual(ResponseWindow.Shape.rectangular.gain(0, taper: 0), 1)
        XCTAssertEqual(ResponseWindow.Shape.hann.gain(0, taper: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(ResponseWindow.Shape.hamming.gain(0, taper: 0), 0.08, accuracy: 1e-12)
        XCTAssertEqual(ResponseWindow.Shape.blackman.gain(0, taper: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(ResponseWindow.Shape.blackman.gain(0.5, taper: 0), 0.34, accuracy: 1e-12)
        XCTAssertEqual(ResponseWindow.Shape.tukey.gain(0.1, taper: 0.4), 0.5 - 0.5 * cos(Double.pi / 4), accuracy: 1e-12)
        XCTAssertEqual(ResponseWindow.Shape.tukey.gain(0.5, taper: 0.4), 1)
        XCTAssertEqual(ResponseWindow.Shape.tukey.gain(0, taper: 0), 1) // no taper is a hard cut

        // A rectangular right side keeps the last sample at full level.
        let w = ResponseWindow(left: 0, right: 0.01, leftShape: .rectangular, rightShape: .rectangular)
        XCTAssertEqual(w.gain(atOffset: 479, sampleRate: fs), 1)
        XCTAssertEqual(w.gain(atOffset: 480, sampleRate: fs), 0)
    }

    func testDecodesWindowsSavedBeforeShapes() throws {
        let old = #"{"left":0.002,"right":0.3,"rightTaper":0.1}"#.data(using: .utf8)!
        let w = try JSONDecoder().decode(ResponseWindow.self, from: old)
        XCTAssertEqual(w, ResponseWindow(left: 0.002, right: 0.3, rightTaper: 0.1))
        let new = ResponseWindow(left: 0.001, right: 0.5, leftShape: .blackman, rightShape: .hamming, leftTaper: 0.2, rightTaper: 0.3)
        XCTAssertEqual(try JSONDecoder().decode(ResponseWindow.self, from: JSONEncoder().encode(new)), new)
    }
}
