#if os(macOS)
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
    /// Frequency response within the window (or as imported).
    private(set) var rawResponse: FrequencyResponse
    /// Energy-time curve in dB, one value per sample.
    let energyTime: [Double]
    /// Sample index of the onset (direct sound).
    let onset: Int
    /// Seconds from the start of the frequency response window to the onset, removed from the phase.
    private(set) var responseDelay: Double

    var id: UUID { info.id }
    var color: Color { TracePalette.color(info.colorIndex) }
    var window: ResponseWindow { info.window ?? .standard }

    /// Sets the frequency response window and recomputes the response. Does nothing for an imported response.
    mutating func setWindow(_ window: ResponseWindow) {
        guard let ir = impulseResponse else { return }
        info.window = window
        (rawResponse, responseDelay) = Trace.windowedResponse(ir, onset: onset, sampleRate: info.sampleRate, window: window)
    }

    /// Frequency response of `ir` within `window`, and the seconds from the window start to the onset.
    static func windowedResponse(_ ir: [Double], onset: Int, sampleRate fs: Double,
                                         window: ResponseWindow) -> (FrequencyResponse, Double) {
        let (samples, start) = window.apply(to: ir, onset: onset, sampleRate: fs)
        // Zero-pad to at least a second so short windows still draw as smooth curves.
        let response = FrequencyResponse(impulseResponse: samples, sampleRate: fs,
                                         fftSize: FFT.size(atLeast: max(samples.count, Int(fs))))
        return (response, Double(onset - start) / fs)
    }

    init(info: TraceInfo, impulseResponse: [Double]) {
        self.info = info
        self.impulseResponse = impulseResponse
        self.importedResponse = nil
        self.recording = nil
        let fs = info.sampleRate
        onset = RoomAcoustics.onsetIndex(impulseResponse)
        acoustics = RoomAcoustics.analyze(impulseResponse: impulseResponse, sampleRate: fs)
        (rawResponse, responseDelay) = Trace.windowedResponse(impulseResponse, onset: onset, sampleRate: fs,
                                                              window: info.window ?? .standard)
        energyTime = TimeFrequency.energyTimeCurve(impulseResponse)
    }

    init(info: TraceInfo, frequencyResponse: FrequencyResponse) {
        self.info = info
        self.impulseResponse = nil
        self.importedResponse = frequencyResponse
        self.recording = nil
        acoustics = nil
        rawResponse = frequencyResponse
        energyTime = []
        onset = 0
        responseDelay = 0
    }

    init(info: TraceInfo, recording: [Double]) {
        self.info = info
        self.impulseResponse = nil
        self.importedResponse = nil
        self.recording = recording
        acoustics = nil
        rawResponse = FrequencyResponse(frequencies: [], magnitude: [])
        energyTime = []
        onset = 0
        responseDelay = 0
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

    /// Phase for the chart in degrees, with the delay to the direct sound removed, at log-spaced points.
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
            var p = (phase[i] + 360 * f[i] * responseDelay).truncatingRemainder(dividingBy: 360)
            if p > 180 { p -= 360 } else if p <= -180 { p += 360 }
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
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
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

/// A project is a folder: one WAV (or text) file and one JSON file per trace.
enum ProjectStore {
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
