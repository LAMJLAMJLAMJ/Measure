import XCTest
@testable import MeasureDSP

final class FFTTests: XCTestCase {
    func testMatchesDirectDFT() {
        let n = 64
        var rng = SeededRandom(seed: 7)
        let x = (0..<n).map { _ in rng.gaussian() }
        let X = FFT(size: n).forward(x)
        for k in 0...(n / 2) {
            var re = 0.0, im = 0.0
            for i in 0..<n {
                let w = -2 * Double.pi * Double(k * i) / Double(n)
                re += x[i] * cos(w)
                im += x[i] * sin(w)
            }
            XCTAssertEqual(X.real[k], re, accuracy: 1e-9)
            XCTAssertEqual(X.imag[k], im, accuracy: 1e-9)
        }
    }

    func testRoundTrip() {
        var rng = SeededRandom(seed: 3)
        let x = (0..<4096).map { _ in rng.gaussian() }
        let fft = FFT(size: 4096)
        let y = fft.inverse(fft.forward(x))
        for i in x.indices { XCTAssertEqual(y[i], x[i], accuracy: 1e-10) }
    }

    func testSineLandsInItsBin() {
        let fs = 48_000.0, n = 4800 * 2
        let fft = FFT(size: FFT.size(atLeast: n))
        let bin = 100
        let f = Double(bin) * fs / Double(fft.size)
        let p = fft.forward(TestSignals.sine(frequency: f, sampleRate: fs, count: fft.size)).power
        XCTAssertEqual(p.indices.max { p[$0] < p[$1] }, bin)
    }

    func testSizeAtLeast() {
        XCTAssertEqual(FFT.size(atLeast: 1), 16)
        XCTAssertEqual(FFT.size(atLeast: 1000), 1024)
        XCTAssertEqual(FFT.size(atLeast: 1024), 1024)
    }
}
