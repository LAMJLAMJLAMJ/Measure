import XCTest
@testable import MeasureDSP

final class BandFilterTests: XCTestCase {
    func testIECBandFrequencies() {
        let b = BandResolution.octave.band(nominal: 1000)
        XCTAssertEqual(b.center, 1000, accuracy: 1e-9)
        XCTAssertEqual(b.lower, 707.946, accuracy: 0.01)
        XCTAssertEqual(b.upper, 1412.538, accuracy: 0.01)
        XCTAssertEqual(BandResolution.octave.band(nominal: 125).center, 125.89, accuracy: 0.01)
        XCTAssertEqual(BandResolution.thirdOctave.band(nominal: 31.5).center, 31.62, accuracy: 0.01)
        XCTAssertEqual(BandResolution.octave.band(nominal: 8000).description, "8k")
        XCTAssertEqual(BandResolution.thirdOctave.band(nominal: 31.5).description, "31.5")
    }

    func testBandsBelowNyquist() {
        // The 16 kHz octave reaches 22.6 kHz, so it fits at 48 kHz but not at 44.1 kHz.
        XCTAssertEqual(BandResolution.octave.bands(sampleRate: 48_000).last?.nominal, 16000)
        XCTAssertEqual(BandResolution.octave.bands(sampleRate: 44_100).last?.nominal, 8000)
        XCTAssertFalse(BandResolution.thirdOctave.bands(sampleRate: 44_100).contains { $0.nominal == 20000 })
    }

    func testOctaveFilterResponse() {
        for nominal in [63.0, 1000, 8000] {
            let band = BandResolution.octave.band(nominal: nominal)
            let f = BandPassFilter(band: band, sampleRate: 48_000)
            XCTAssertEqual(f.magnitudeDB(at: band.center), 0, accuracy: 1e-6, "\(band)")
            XCTAssertEqual(f.magnitudeDB(at: band.lower), -3.01, accuracy: 0.05, "\(band)")
            XCTAssertEqual(f.magnitudeDB(at: band.upper), -3.01, accuracy: 0.05, "\(band)")
            XCTAssertLessThan(f.magnitudeDB(at: band.center * 2), -15, "\(band)")
            XCTAssertLessThan(f.magnitudeDB(at: band.center / 2), -15, "\(band)")
            if band.center * 4 < 24_000 {
                XCTAssertLessThan(f.magnitudeDB(at: band.center * 4), -40, "\(band)")
            }
        }
    }

    func testThirdOctaveFilterResponse() {
        let band = BandResolution.thirdOctave.band(nominal: 500)
        let f = BandPassFilter(band: band, sampleRate: 48_000)
        XCTAssertEqual(f.magnitudeDB(at: band.center), 0, accuracy: 1e-6)
        XCTAssertEqual(f.magnitudeDB(at: band.upper), -3.01, accuracy: 0.05)
        XCTAssertLessThan(f.magnitudeDB(at: band.center * 2), -30)
    }

    func testTimeDomainMatchesResponse() {
        let fs = 48_000.0
        let band = BandResolution.octave.band(nominal: 1000)
        let f = BandPassFilter(band: band, sampleRate: fs)
        for (freq, expected) in [(band.center, 0.0), (band.upper, -3.01)] {
            let x = TestSignals.sine(frequency: freq, sampleRate: fs, count: 48_000)
            let y = f.apply(x)
            let tail = y.suffix(24_000)
            let rms = (tail.map { $0 * $0 }.reduce(0, +) / Double(tail.count)).squareRoot()
            XCTAssertEqual(20 * log10(rms * 2.squareRoot()), expected, accuracy: 0.05)
        }
    }
}
