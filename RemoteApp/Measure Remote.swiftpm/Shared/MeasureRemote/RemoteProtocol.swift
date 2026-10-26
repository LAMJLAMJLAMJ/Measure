import Foundation

/// Messages between the Mac app and the iPad remote. The iPad sends commands and the Mac
/// answers with its whole state whenever something changes, so the remote never has to keep
/// track of anything itself.
public enum RemoteMessage: Codable, Equatable, Sendable {
    case command(RemoteCommand)
    case state(RemoteState)
}

/// Bumped when a change to the messages would break an older remote.
public let remoteProtocolVersion = 1

/// The Bonjour service type the Mac advertises. It must also be listed under NSBonjourServices
/// in both apps' Info.plist.
public let remoteServiceType = "_measure-remote._tcp"

public enum RemoteCommand: Codable, Equatable, Sendable {
    case hello(device: String, version: Int)
    case measure
    case setPosition(String)
    case startLive
    case stopLive
    case startGenerator
    case stopGenerator
    case setGeneratorLevel(Double)
    case startMonitor
    case stopMonitor
    case resetMonitor
    case select(UUID)
}

/// A curve thinned for the network: frequencies in Hz and levels in dB.
public struct RemoteCurve: Codable, Equatable, Sendable {
    public var name: String
    /// Colour as "#RRGGBB".
    public var color: String
    public var frequencies: [Double]
    public var levels: [Double]

    public init(name: String, color: String, frequencies: [Double], levels: [Double]) {
        self.name = name
        self.color = color
        self.frequencies = frequencies
        self.levels = levels
    }

    /// Keeps at most one point per `fraction` of an octave between 20 Hz and 20 kHz, taking the
    /// point nearest each band centre, so a curve stays a few kilobytes.
    public static func thinned(name: String, color: String, frequencies: [Double], levels: [Double],
                               pointsPerOctave: Double = 24) -> RemoteCurve {
        let count = min(frequencies.count, levels.count)
        var outF: [Double] = []
        var outL: [Double] = []
        var lastBand = Int.min
        for i in 0..<count {
            let f = frequencies[i]
            let level = levels[i]
            guard f >= 20, f <= 20_000, level.isFinite else { continue }
            let band = Int((log2(f / 20) * pointsPerOctave).rounded())
            if band != lastBand {
                // Rounded so the JSON stays short: 0.1 Hz and 0.01 dB are finer than any chart shows.
                outF.append((f * 10).rounded() / 10)
                outL.append((level * 100).rounded() / 100)
                lastBand = band
            }
        }
        return RemoteCurve(name: name, color: color, frequencies: outF, levels: outL)
    }
}

public struct RemoteMeter: Codable, Equatable, Sendable {
    public var label: String
    public var value: Double?
    public var unit: String
    public var maximum: Double?
    public var overLimit: Bool

    public init(label: String, value: Double?, unit: String, maximum: Double? = nil, overLimit: Bool = false) {
        self.label = label
        self.value = value
        self.unit = unit
        self.maximum = maximum
        self.overLimit = overLimit
    }
}

public struct RemoteTrace: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var detail: String
    public var color: String

    public init(id: UUID, name: String, detail: String, color: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.color = color
    }
}

/// Everything the remote shows.
public struct RemoteState: Codable, Equatable, Sendable {
    public var projectName: String = ""
    public var status: String = ""
    public var error: String?

    public var isMeasuring = false
    public var position = ""

    public var liveRunning = false
    public var liveCurves: [RemoteCurve] = []

    public var generatorRunning = false
    public var generatorLevel: Double = -20
    public var generatorMaxLevel: Double = 0
    public var generatorSignal = ""

    public var monitorRunning = false
    public var meters: [RemoteMeter] = []

    /// The most recent measurements, newest last.
    public var traces: [RemoteTrace] = []
    public var selected: UUID?
    public var selectedCurve: RemoteCurve?

    public init() {}
}

/// Frames messages on a byte stream: a 4-byte big-endian length, then that many bytes of JSON.
public enum RemoteFraming {
    /// Frames larger than this are treated as a broken stream.
    public static let maximumLength = 8 << 20

    public static func encode(_ message: RemoteMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }
}

public enum RemoteFramingError: Error, Equatable {
    case frameTooLarge(Int)
}

/// Collects bytes as they arrive and hands back whole messages.
public struct RemoteFrameDecoder {
    private var buffer = Data()

    public init() {}

    /// Adds received bytes and returns the messages they complete. A frame that is not valid
    /// JSON is skipped, so one bad message does not end the connection.
    public mutating func append(_ data: Data) throws -> [RemoteMessage] {
        buffer.append(data)
        var messages: [RemoteMessage] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= RemoteFraming.maximumLength else {
                throw RemoteFramingError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            let body = buffer[start + 4..<start + 4 + length]
            if let message = try? JSONDecoder().decode(RemoteMessage.self, from: Data(body)) {
                messages.append(message)
            }
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return messages
    }
}
