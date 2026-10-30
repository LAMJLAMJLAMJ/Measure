import Foundation

/// Messages between the Mac app and the iPad remote. The iPad sends commands and the Mac
/// answers with its whole state whenever something changes, so the remote never has to keep
/// track of anything itself.
public enum RemoteMessage: Codable, Equatable, Sendable {
    case command(RemoteCommand)
    case state(RemoteState)
}

/// Bumped when a change to the messages would break an older remote.
public let remoteProtocolVersion = 6

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
    /// Holds the meters, RTA and history; `resumeMonitor` carries on. Paused time is left out.
    case pauseMonitor
    case resumeMonitor
    case select(UUID)
    /// Ticks or unticks a measurement: ticked ones are drawn together.
    case setVisible(UUID, Bool)
    /// One of `RemoteState.smoothingOptions`.
    case setSmoothing(String)
    /// Draws the power average of the ticked measurements.
    case showAverage(Bool)
    /// Plays the sweep in a loop and meters the inputs.
    case startLevelCheck
    case stopLevelCheck
    /// Sweep level, dBFS peak.
    case setSweepLevel(Double)
    /// Sweep length, seconds: one of `RemoteState.sweepLengthOptions`.
    case setSweepLength(Double)
    /// Whether sweeps record mic input `index` (an index into `RemoteState.mics`).
    case setMicActive(Int, Bool)
    /// Adds each mic's live response to the measurements, as the Mac's Capture button does.
    case captureLive
    /// Delays the reference so it lines up with each mic, as the Mac's Find Delay button does.
    case findLiveDelay
    /// Clears the live delays and restarts the averaging, as the Mac's Reset button does.
    case resetLiveDelay
    /// Saves the power average of the ticked measurements as a new measurement, as the Mac's Average does.
    case saveAverage
    /// One of `RemoteState.generatorSignals`.
    case setGeneratorSignal(String)
    case setGeneratorMuted(Bool)
    /// Sine frequency, Hz.
    case setGeneratorFrequency(Double)
    /// Band of the noise and range of the sweep, Hz.
    case setGeneratorBand(low: Double, high: Double)
    /// Turns output `channel` (from 1) on or off.
    case setGeneratorOutput(channel: Int, on: Bool)
    /// The RTA's mic (an index into `RemoteState.mics`), bands per octave and weighting.
    case setRTAMic(Int)
    case setRTAFraction(Int)
    case setRTAWeighting(String)
    case resetRTAPeaks
    /// Seconds of SPL history shown; 0 for everything.
    case setHistoryRange(Int)
    /// SPL meter `index`'s mic (an index into `RemoteState.mics`), weighting (one of
    /// `RemoteState.rtaWeightings`) and average (one of `RemoteState.meterAverages`).
    case setMeterMic(index: Int, mic: Int)
    case setMeterWeighting(index: Int, weighting: String)
    case setMeterAverage(index: Int, average: String)
}

/// The real-time analyser's bands, with the weighting, calibration and offset applied.
public struct RemoteRTA: Codable, Equatable, Sendable {
    /// Band centre frequencies, Hz.
    public var centers: [Double]
    public var levels: [Double]
    /// Peak hold.
    public var peaks: [Double]
    public var unit: String

    public init(centers: [Double], levels: [Double], peaks: [Double], unit: String) {
        self.centers = centers
        self.levels = levels
        self.peaks = peaks
        self.unit = unit
    }
}

/// One SPL meter's level over time, one value per `secondsPerPoint`, oldest first, ending now.
public struct RemoteHistory: Codable, Equatable, Sendable {
    public var label: String
    public var color: String
    public var levels: [Double]
    public var secondsPerPoint: Int

    public init(label: String, color: String, levels: [Double], secondsPerPoint: Int) {
        self.label = label
        self.color = color
        self.levels = levels
        self.secondsPerPoint = secondsPerPoint
    }
}

/// A mic input of the measurement setup.
public struct RemoteMic: Codable, Equatable, Sendable {
    public var name: String
    /// Recorded by sweeps.
    public var active: Bool

    public init(name: String, active: Bool) {
        self.name = name
        self.active = active
    }
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
    /// SPL meters only, for the card laid out as the Mac's: the mic's name; "dB SPL A Slow"; the limit
    /// for the meter's weighting; whether the input is clipping. Optional, so either app can be older.
    public var name: String?
    public var detail: String?
    public var limit: Double?
    public var clipping: Bool?
    /// Leq meters with a limit: how long until the limit is reached, or once over, until it is back
    /// under, as the Mac shows it. The first row is for the level now.
    public var forecast: [RemoteForecastRow]?
    /// The Leq is over its limit, so the forecast counts down to being back under.
    public var forecastOver: Bool?

    public init(label: String, value: Double?, unit: String, maximum: Double? = nil, overLimit: Bool = false,
                name: String? = nil, detail: String? = nil, limit: Double? = nil, clipping: Bool? = nil,
                forecast: [RemoteForecastRow]? = nil, forecastOver: Bool? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.maximum = maximum
        self.overLimit = overLimit
        self.name = name
        self.detail = detail
        self.limit = limit
        self.clipping = clipping
        self.forecast = forecast
        self.forecastOver = forecastOver
    }
}

/// One line of an SPL meter's forecast: "Limit in" and "2:31".
public struct RemoteForecastRow: Codable, Equatable, Sendable {
    public var label: String
    public var time: String
    /// The time is less than a minute away (first row only).
    public var soon: Bool

    public init(label: String, time: String, soon: Bool = false) {
        self.label = label
        self.time = time
        self.soon = soon
    }
}

public struct RemoteTrace: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var detail: String
    public var color: String
    /// Ticked: drawn on the chart.
    public var visible: Bool
    /// Clipping or low signal-to-noise, in a sentence. Nil when the measurement is fine.
    public var warning: String?

    public init(id: UUID, name: String, detail: String, color: String, visible: Bool = false, warning: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.color = color
        self.visible = visible
        self.warning = warning
    }
}

/// Everything the remote shows.
public struct RemoteState: Codable, Equatable, Sendable {
    public var projectName: String = ""
    public var status: String = ""
    public var error: String?

    public var isMeasuring = false
    public var position = ""
    /// Sweep level, dBFS peak, and length, seconds.
    public var sweepLevel: Double = -30
    public var sweepLength: Double = 3
    public var sweepLengthOptions: [Double] = []
    public var mics: [RemoteMic] = []

    public var levelCheckRunning = false
    /// Peak of each input over the last loop of the sweep, loopback first when there is one.
    /// `overLimit` means it clipped since the check started.
    public var levelMeters: [RemoteMeter] = []
    /// Every mic input (and the loopback, first, when there is one): the peak over the last few
    /// seconds, from the Mac's input meters, which run all the time. `overLimit` means it clipped.
    public var inputMeters: [RemoteMeter] = []

    public var liveRunning = false
    public var liveCurves: [RemoteCurve] = []
    /// Each mic's live phase (degrees, -180 to 180) and coherence (0 to 1), in the same order.
    public var livePhase: [RemoteCurve] = []
    public var liveCoherence: [RemoteCurve] = []
    /// True once the analyser has a response to capture.
    public var liveCanCapture = false
    /// True once the analyser has averaged enough to find the delay.
    public var liveCanFindDelay = false
    /// Delay applied to the reference for each mic, ms, in the same order as `liveCurves`.
    public var liveDelays: [Double] = []

    public var generatorRunning = false
    public var generatorLevel: Double = -20
    public var generatorMaxLevel: Double = 0
    public var generatorSignal = ""
    public var generatorSignals: [String] = []
    public var generatorMuted = false
    public var generatorFrequency: Double = 1000
    public var generatorLow: Double = 20
    public var generatorHigh: Double = 20_000
    /// Outputs that play the signal, from 1, and how many the device has.
    public var generatorOutputs: [Int] = []
    public var generatorOutputCount = 0

    public var monitorRunning = false
    public var monitorPaused = false
    public var meters: [RemoteMeter] = []
    /// The averages an SPL meter can use: "Fast", "Slow", "Leq 1 min" and so on.
    public var meterAverages: [String] = []
    public var rta: RemoteRTA?
    public var rtaMic = 0
    public var rtaFraction = 3
    public var rtaWeighting = ""
    public var rtaWeightings: [String] = []
    public var histories: [RemoteHistory] = []
    public var historyRange = 900
    /// Limits for A- and C-weighted meters, drawn on the history.
    public var limitA: Double?
    public var limitC: Double?
    /// The limit lines' colours, "#RRGGBB"; nil for red (A) and purple (C).
    public var limitAColor: String?
    public var limitCColor: String?

    /// The most recent measurements, newest last.
    public var traces: [RemoteTrace] = []
    public var selected: UUID?
    /// The ticked measurements' responses, or the selected one's when none is ticked.
    public var curves: [RemoteCurve] = []
    /// The power average of the ticked measurements, when asked for and more than one is ticked.
    public var averageCurve: RemoteCurve?
    /// The ticked measurements' phase (degrees), for the live phase chart.
    public var tracePhases: [RemoteCurve] = []
    public var showAverage = false
    public var smoothing = ""
    public var smoothingOptions: [String] = []

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
