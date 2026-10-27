import XCTest
@testable import MeasureRemote

final class RemoteProtocolTests: XCTestCase {
    private func sampleState() -> RemoteState {
        var state = RemoteState()
        state.projectName = "Hall"
        state.position = "Seat A1"
        state.liveRunning = true
        state.liveCurves = [RemoteCurve(name: "Mic 1", color: "#FF0000", frequencies: [100, 1000], levels: [80, 82.5])]
        state.meters = [RemoteMeter(label: "LAeq", value: 74.2, unit: "dB", maximum: 90, overLimit: false),
                        RemoteMeter(label: "LCpeak", value: nil, unit: "dB")]
        let id = UUID()
        state.traces = [RemoteTrace(id: id, name: "Seat A1", detail: "10:42", color: "#00AAFF")]
        state.selected = id
        state.error = "Input clipped"
        state.mics = [RemoteMic(name: "Mic 1", active: true), RemoteMic(name: "Input 2", active: false)]
        state.averageCurve = RemoteCurve(name: "Average", color: "#000000", frequencies: [100], levels: [70])
        return state
    }

    func testRoundTripThroughFrames() throws {
        let messages: [RemoteMessage] = [
            .command(.hello(device: "iPad", version: remoteProtocolVersion)),
            .command(.setPosition("Seat B4")),
            .command(.setGeneratorLevel(-12.5)),
            .command(.select(UUID())),
            .command(.measure),
            .command(.setVisible(UUID(), true)),
            .command(.setSmoothing("1/6")),
            .command(.setMicActive(1, false)),
            .command(.setSweepLength(5)),
            .state(sampleState()),
        ]
        var stream = Data()
        for message in messages { stream.append(try RemoteFraming.encode(message)) }

        var decoder = RemoteFrameDecoder()
        XCTAssertEqual(try decoder.append(stream), messages)
    }

    func testFramesSplitAcrossReads() throws {
        let message = RemoteMessage.state(sampleState())
        let data = try RemoteFraming.encode(message) + RemoteFraming.encode(.command(.stopLive))
        var decoder = RemoteFrameDecoder()
        var received: [RemoteMessage] = []
        // Feed a few bytes at a time, as TCP may deliver them.
        var index = data.startIndex
        while index < data.endIndex {
            let end = min(index + 7, data.endIndex)
            received += try decoder.append(data[index..<end])
            index = end
        }
        XCTAssertEqual(received, [message, .command(.stopLive)])
    }

    func testBadFrameIsSkipped() throws {
        var junk = Data([0, 0, 0, 3])
        junk.append(contentsOf: Array("{x}".utf8))
        let good = try RemoteFraming.encode(.command(.startMonitor))
        var decoder = RemoteFrameDecoder()
        XCTAssertEqual(try decoder.append(junk + good), [.command(.startMonitor)])
    }

    func testOversizedFrameThrows() {
        var decoder = RemoteFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }

    func testThinnedCurveKeepsOnePointPerBand() {
        let frequencies = stride(from: 1.0, through: 24_000, by: 1).map { $0 }
        let levels = frequencies.map { _ in 70.0 }
        let curve = RemoteCurve.thinned(name: "A", color: "#000000", frequencies: frequencies, levels: levels)
        // Ten octaves from 20 Hz to 20 kHz at 1/24 octave is about 240 points.
        XCTAssertLessThanOrEqual(curve.frequencies.count, 241)
        XCTAssertGreaterThan(curve.frequencies.count, 200)
        XCTAssertEqual(curve.frequencies.count, curve.levels.count)
        XCTAssertGreaterThanOrEqual(curve.frequencies.first ?? 0, 20)
        XCTAssertLessThanOrEqual(curve.frequencies.last ?? .infinity, 20_000)
    }

    func testThinnedCurveDropsNonFiniteLevels() {
        let curve = RemoteCurve.thinned(name: "A", color: "#000000",
                                        frequencies: [100, 200, 400], levels: [60, -.infinity, .nan])
        XCTAssertEqual(curve.frequencies, [100])
    }
}
