import XCTest
@testable import MeasureDSP

final class WAVTests: XCTestCase {
    let audio: AudioData = {
        var rng = SeededRandom(seed: 11)
        let a = (0..<1000).map { _ in 0.5 * (rng.uniform() * 2 - 1) }
        let b = (0..<1000).map { _ in 0.25 * (rng.uniform() * 2 - 1) }
        return AudioData(sampleRate: 48_000, channels: [a, b])
    }()

    func testFloat32RoundTrip() throws {
        let back = try WAV.read(data: WAV.data(for: audio, format: .float32))
        XCTAssertEqual(back.sampleRate, 48_000)
        XCTAssertEqual(back.channelCount, 2)
        XCTAssertEqual(back.frameCount, 1000)
        for c in 0..<2 {
            for i in 0..<1000 { XCTAssertEqual(back.channels[c][i], audio.channels[c][i], accuracy: 1e-7) }
        }
    }

    func testPCM24RoundTrip() throws {
        let back = try WAV.read(data: WAV.data(for: audio, format: .pcm24))
        for i in 0..<1000 { XCTAssertEqual(back.channels[1][i], audio.channels[1][i], accuracy: 1.0 / 8_388_608) }
    }

    func testPCM16RoundTrip() throws {
        let back = try WAV.read(data: WAV.data(for: audio, format: .pcm16))
        for i in 0..<1000 { XCTAssertEqual(back.channels[0][i], audio.channels[0][i], accuracy: 1.0 / 32768) }
    }

    func testRejectsNonWAV() {
        XCTAssertThrowsError(try WAV.read(data: Data("hello world, not a wav".utf8)))
    }
}
