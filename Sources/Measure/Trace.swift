#if os(macOS)
import AppKit
import Foundation
import MeasureDSP
import SwiftUI

/// Saved description of a trace. The samples live next to it in a WAV file.
struct TraceInfo: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case sweep, importedImpulseResponse, importedFrequencyResponse
        /// A plain recording of the sound itself (background noise or programme), for levels and noise ratings.
        case recording
        /// The impulse response of a live transfer function, captured in the cross-spectrum mode.
        case transferFunction
        /// The average of several traces' frequency responses.
        case average
        /// A trace's response with its Virtual EQ applied: a prediction, not a measurement.
        case eqPrediction
    }

    var id = UUID()
    var name: String
    var date = Date()
    var source: Source
    var sampleRate: Double
    /// Microphone name, used to find its calibration file.
    var mic: String?
    /// Measurement position, such as "Seat A12".
    var position = ""
    var notes = ""
    var timingReference: TimingReference?
    var peakLevel: Double?
    var colorIndex = 0
    /// Window for the frequency response. Nil means `ResponseWindow.standard`.
    var window: ResponseWindow?
    /// dB added to a recording's level re full scale to give dB SPL, from the mic's calibration when it
    /// was recorded. Nil falls back to the mic's current calibration.
    var splOffset: Double?
    /// For an average, the names of the traces it was made from.
    var averagedFrom: [String]?
    /// A colour chosen by the user, as sRGB hex ("#RRGGBB"). Nil uses the palette colour `colorIndex`.
    var colorHex: String?
    /// Virtual EQ filters tried on this trace. A prediction only; the response itself is unchanged.
    var eq: [EQFilter]?
    /// Harmonic distortion separated from the sweep recording. Only for sweeps measured by this app.
    var distortion: HarmonicDistortion?
    /// The folder the trace is in, in the list. Nil at the top level.
    var folder: UUID?
    /// For the average a summing folder shows, that folder. Such a trace is made from the folder's
    /// measurements whenever they change, and is never saved.
    var sumFolder: UUID?
}

/// A folder in the trace list, to group measurements. Only a label: the files stay where they are.
struct TraceFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var expanded = true
    /// For a summing folder, how its measurements are averaged; nil for a plain folder. Measurements put
    /// in a summing folder are hidden, and the folder shows their average in their place.
    var summing: FrequencyResponse.AverageMethod?
    /// The id of the summing folder's average, kept so the average stays shown and selected as it is remade.
    var averageID: UUID?
    /// The summing folder's tick: whether its average is shown.
    var averageHidden: Bool?
    /// The average's palette colour.
    var averageColor: Int?
    /// The Virtual EQ tried on the average, kept here because the average itself is never saved.
    var averageEQ: [EQFilter]?

    var isSumming: Bool { summing != nil }
}

/// One measurement in the trace library: an impulse response, an imported frequency response or a plain
/// recording, plus everything derived from it for the views.
struct Trace: Identifiable {
    var info: TraceInfo
    /// Nil for an imported frequency response, which has no time data.
    let impulseResponse: [Double]?
    let importedResponse: FrequencyResponse?
    /// The samples of a plain recording. Nil for everything else.
    let recording: [Double]?

    // Derived once, when the trace is made.
    let acoustics: RoomAcousticsResult?
    /// Clipping, low level or too little range above the noise for the reverberation times.
    let qualityIssues: [MeasurementQuality.Issue]
    /// Frequency response within the window (or as imported).
    private(set) var rawResponse: FrequencyResponse
    /// Energy-time curve in dB, one value per sample.
    let energyTime: [Double]
    /// The energy-time curve's peak, dB re a full-scale sample: added to `energyTime` to draw it
    /// unnormalised.
    let energyTimePeak: Double
    /// The largest sample of the impulse response, for drawing it unnormalised.
    let impulsePeak: Double
    /// Sample index of the onset (direct sound).
    let onset: Int
    /// Seconds from the start of the frequency response window to the onset.
    private(set) var responseDelay: Double
    /// Seconds from the start of the frequency response window to the impulse's peak, removed from the phase.
    private(set) var phaseDelay: Double

    var id: UUID { info.id }
    var color: Color { info.colorHex.flatMap(Color.init(hex:)) ?? TracePalette.color(info.colorIndex) }
    var window: ResponseWindow { info.window ?? .standard }
    /// The sample rate the Virtual EQ's filters are designed at: the trace's own, or 48 kHz for an
    /// imported response that has none.
    var eqSampleRate: Double { info.sampleRate > 0 ? info.sampleRate : 48_000 }
    var activeEQ: [EQFilter] { (info.eq ?? []).filter(\.enabled) }

    /// Sets the frequency response window and recomputes the response. Does nothing for an imported response.
    mutating func setWindow(_ window: ResponseWindow) {
        guard let ir = impulseResponse else { return }
        info.window = window
        setResponse(window.response(of: ir, onset: onset, sampleRate: info.sampleRate))
    }

    private mutating func setResponse(_ r: ResponseWindow.Response) {
        rawResponse = r.response
        responseDelay = r.onsetDelay
        phaseDelay = r.peakDelay
    }

    init(info: TraceInfo, impulseResponse: [Double]) {
        self.info = info
        self.impulseResponse = impulseResponse
        self.importedResponse = nil
        self.recording = nil
        let fs = info.sampleRate
        onset = RoomAcoustics.onsetIndex(impulseResponse)
        acoustics = RoomAcoustics.analyze(impulseResponse: impulseResponse, sampleRate: fs)
        // Only sweeps measured here: an imported response may have been trimmed before its noise.
        qualityIssues = info.source == .sweep
            ? MeasurementQuality.check(micPeak: info.peakLevel, acoustics: acoustics) : []
        let r = (info.window ?? .standard).response(of: impulseResponse, onset: onset, sampleRate: fs)
        rawResponse = r.response
        responseDelay = r.onsetDelay
        phaseDelay = r.peakDelay
        (energyTime, energyTimePeak) = TimeFrequency.energyTimeCurveAndPeak(impulseResponse)
        impulsePeak = impulseResponse.map(abs).max() ?? 0
    }

    init(info: TraceInfo, frequencyResponse: FrequencyResponse) {
        self.info = info
        self.impulseResponse = nil
        self.importedResponse = frequencyResponse
        self.recording = nil
        acoustics = nil
        qualityIssues = []
        rawResponse = frequencyResponse
        energyTime = []
        energyTimePeak = 0
        impulsePeak = 0
        onset = 0
        responseDelay = 0
        phaseDelay = 0
    }

    init(info: TraceInfo, recording: [Double]) {
        self.info = info
        self.impulseResponse = nil
        self.importedResponse = nil
        self.recording = recording
        acoustics = nil
        qualityIssues = []
        rawResponse = FrequencyResponse(frequencies: [], magnitude: [])
        energyTime = []
        energyTimePeak = 0
        impulsePeak = 0
        onset = 0
        responseDelay = 0
        phaseDelay = 0
    }

    /// True for anything with a frequency response to draw (not a plain recording).
    var hasResponse: Bool { recording == nil }

    /// Magnitude for the chart: calibrated, smoothed and thinned to log-spaced points.
    func displayResponse(smoothing: Smoothing, calibration: FrequencyResponse?) -> [ChartPoint] {
        Trace.displayPoints(rawResponse, smoothing: smoothing, calibration: calibration)
    }

    static func displayPoints(_ response: FrequencyResponse, smoothing: Smoothing, calibration: FrequencyResponse?) -> [ChartPoint] {
        var fr = response
        if let calibration { fr = fr.applyingCalibration(calibration) }
        if let fraction = smoothing.fraction { fr = fr.smoothed(fraction: fraction) }
        let high = min(20_000, fr.frequencies.last ?? 20_000)
        let resampled = fr.logResampled(pointsPerOctave: 48, low: 10, high: high)
        return zip(resampled.frequencies, resampled.magnitude).map { ChartPoint(x: $0, y: $1) }
    }

    /// Phase for the chart in degrees, with the delay to the impulse's peak removed, at log-spaced points.
    /// Nil when the trace has no phase (an imported response without a phase column).
    func displayPhase() -> [ChartPoint]? {
        guard let phase = rawResponse.phase else { return nil }
        let f = rawResponse.frequencies
        guard !f.isEmpty else { return nil }
        let high = min(20_000, f.last!)
        var points: [ChartPoint] = []
        var freq = 10.0
        var i = 0
        while freq <= high {
            while i + 1 < f.count && abs(f[i + 1] - freq) <= abs(f[i] - freq) { i += 1 }
            let p = ResponseWindow.phase(phase[i], frequency: f[i], removingDelay: phaseDelay)
            points.append(ChartPoint(x: f[i], y: p))
            freq *= pow(2, 1.0 / 48)
        }
        // Low frequencies share a bin; keep one point per frequency.
        var seen = Set<Double>()
        return points.filter { seen.insert($0.x).inserted }
    }
}

struct ChartPoint: Identifiable {
    let x: Double
    let y: Double
    var id: Double { x }
}

enum Smoothing: String, CaseIterable, Identifiable {
    case none = "None", third = "1/3", sixth = "1/6", twelfth = "1/12", twentyFourth = "1/24", fortyEighth = "1/48"
    var id: String { rawValue }
    var fraction: Double? {
        switch self {
        case .none: return nil
        case .third: return 3
        case .sixth: return 6
        case .twelfth: return 12
        case .twentyFourth: return 24
        case .fortyEighth: return 48
        }
    }
}

enum TracePalette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .red, .indigo, .mint]
    static let names = ["Blue", "Orange", "Green", "Pink", "Purple", "Teal", "Brown", "Red", "Indigo", "Mint"]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

extension Color {
    /// A colour from "#RRGGBB" (sRGB).
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" in sRGB, or nil when the colour cannot be converted.
    var hex: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// Thins long signals to a number of points a chart can draw quickly.
enum ChartData {
    /// Points for `x[range]`, with times in milliseconds relative to sample `zero`.
    /// Keeps the minimum and maximum of each bucket so peaks survive (for waveforms),
    /// or only the maximum when `envelope` is true (for level curves in dB).
    static func points(_ x: [Double], range: Range<Int>, zero: Int, sampleRate: Double,
                       maxPoints: Int = 1500, envelope: Bool = false) -> [ChartPoint] {
        let r = range.clamped(to: 0..<x.count)
        guard !r.isEmpty else { return [] }
        func time(_ i: Int) -> Double { Double(i - zero) / sampleRate * 1000 }
        if r.count <= maxPoints { return r.map { ChartPoint(x: time($0), y: x[$0]) } }

        let buckets = envelope ? maxPoints : maxPoints / 2
        let size = Int((Double(r.count) / Double(buckets)).rounded(.up))
        var out: [ChartPoint] = []
        out.reserveCapacity(maxPoints + 2)
        var i = r.lowerBound
        while i < r.upperBound {
            let end = min(r.upperBound, i + size)
            var lo = i, hi = i
            for j in i..<end {
                if x[j] < x[lo] { lo = j }
                if x[j] > x[hi] { hi = j }
            }
            if envelope {
                out.append(ChartPoint(x: time(i), y: x[hi]))
            } else {
                out.append(ChartPoint(x: time(min(lo, hi)), y: x[min(lo, hi)]))
                if lo != hi { out.append(ChartPoint(x: time(max(lo, hi)), y: x[max(lo, hi)])) }
            }
            i = end
        }
        return out
    }
}

// MARK: - Storage

/// A project is a folder: one WAV (or text) file and one JSON file per trace, and folders.json for the
/// list's folders. A measurement set is the same thing in a folder named *.measure, which the Mac shows
/// as a single file (a package) once Measure.app has declared the type.
enum ProjectStore {
    /// The extension of a measurement set.
    static let setExtension = "measure"

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Measure Projects/Default", isDirectory: true)
    }

    static func save(_ trace: Trace, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = folder.appendingPathComponent(trace.id.uuidString)
        if let samples = trace.impulseResponse ?? trace.recording {
            try WAV.write(AudioData(sampleRate: trace.info.sampleRate, mono: samples), to: base.appendingPathExtension("wav"))
        } else if let fr = trace.importedResponse {
            var text = "* Frequency response imported into Measure\n"
            for i in fr.frequencies.indices {
                text += "\(fr.frequencies[i]) \(fr.magnitude[i])" + (fr.phase.map { " \($0[i])" } ?? "") + "\n"
            }
            try text.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
        try saveInfo(trace.info, in: folder)
    }

    static func saveInfo(_ info: TraceInfo, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: folder.appendingPathComponent(info.id.uuidString).appendingPathExtension("json"))
    }

    /// The project's list folders, in folders.json (which the trace loader skips: it is not a trace).
    static func saveFolders(_ folders: [TraceFolder], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(folders).write(to: folder.appendingPathComponent("folders.json"))
    }

    static func loadFolders(from folder: URL) -> [TraceFolder] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("folders.json")) else { return [] }
        return (try? JSONDecoder().decode([TraceFolder].self, from: data)) ?? []
    }

    /// Copies one trace's files (its WAV or text file and its JSON) from one project to another.
    static func copy(_ id: UUID, from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for ext in ["json", "wav", "txt"] {
            let from = source.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
            guard manager.fileExists(atPath: from.path) else { continue }
            let to = destination.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
            try? manager.removeItem(at: to)
            try manager.copyItem(at: from, to: to)
        }
    }

    /// Deletes every measurement in the folder (files named by a trace id) and its folder list.
    static func deleteAll(in folder: URL) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where ["json", "wav", "txt"].contains(url.pathExtension)
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            try? manager.removeItem(at: url)
        }
        try? manager.removeItem(at: folder.appendingPathComponent("folders.json"))
    }

    static func delete(_ id: UUID, in folder: URL) {
        for ext in ["json", "wav", "txt"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString).appendingPathExtension(ext))
        }
    }

    /// Loads every trace in the folder, oldest first. Unreadable files are skipped.
    static func load(from folder: URL) -> [Trace] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let traces: [Trace] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let info = try? decoder.decode(TraceInfo.self, from: data) else { return nil }
            let base = url.deletingPathExtension()
            if let audio = try? WAV.read(contentsOf: base.appendingPathExtension("wav")), let samples = audio.channels.first {
                return info.source == .recording ? Trace(info: info, recording: samples) : Trace(info: info, impulseResponse: samples)
            }
            if let parsed = try? FrequencyResponseText.parse(contentsOf: base.appendingPathExtension("txt")) {
                return Trace(info: info, frequencyResponse: parsed.response)
            }
            return nil
        }
        return traces.sorted { $0.info.date < $1.info.date }
    }
}
#endif
