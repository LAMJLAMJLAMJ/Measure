#if os(macOS)
import Foundation
import MeasureAudio
import MeasureDSP
import Observation

/// One SPL meter on the SPL view: which mic, which weighting and which average.
struct MeterSettings: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Index into the mics of Measurement Setup, from 0.
    var mic = 0
    var weighting: SoundLevel.FrequencyWeighting = .a
    var average: LevelAverage = .fast
}

/// Live monitoring settings, remembered between launches.
struct MonitorSettings: Codable, Equatable {
    var meters: [MeterSettings] = [MeterSettings(weighting: .a, average: .slow),
                                   MeterSettings(weighting: .a, average: .fifteenMinutes),
                                   MeterSettings(weighting: .c, average: .slow)]
    /// Levels not to exceed for A-weighted and C-weighted meters, dB (SPL when the mics are
    /// calibrated). Meters above their limit turn red, and the history draws both as lines. Nil for none.
    var limitA: Double?
    var limitC: Double?
    /// dB added to each mic's levels, by mic index, on top of its calibration: for a mic without a
    /// calibrator reading, or to refer a level measured at one place to another.
    var micOffsets: [Double] = []
    /// Seconds of history shown; 0 shows everything since the start.
    var historyRange = 900
    var rtaMic = 0
    /// Bands per octave: 1, 3, 6, 12 or 24.
    var rtaFraction = 3
    var rtaAveraging: RealTimeAnalyzer.Averaging = .fast
    var rtaWeighting: SoundLevel.FrequencyWeighting = .z
    var rtaFFTSize = 16_384

    init() {}

    /// The limit for meters with weighting `w`; Z-weighted meters have none.
    func limit(_ w: SoundLevel.FrequencyWeighting) -> Double? {
        switch w {
        case .a: return limitA
        case .c: return limitC
        case .z: return nil
        }
    }

    func micOffset(_ index: Int) -> Double { index >= 0 && index < micOffsets.count ? micOffsets[index] : 0 }

    mutating func setMicOffset(_ value: Double, for index: Int) {
        guard index >= 0 else { return }
        while micOffsets.count <= index { micOffsets.append(0) }
        micOffsets[index] = value
    }

    enum CodingKeys: String, CodingKey {
        case meters, limitA, limitC, micOffsets, historyRange, rtaMic, rtaFraction, rtaAveraging, rtaWeighting, rtaFFTSize
    }

    /// Settings saved by an earlier version lack some keys; those keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings()
        meters = try c.decodeIfPresent([MeterSettings].self, forKey: .meters) ?? d.meters
        limitA = try c.decodeIfPresent(Double.self, forKey: .limitA)
        limitC = try c.decodeIfPresent(Double.self, forKey: .limitC)
        micOffsets = try c.decodeIfPresent([Double].self, forKey: .micOffsets) ?? []
        historyRange = try c.decodeIfPresent(Int.self, forKey: .historyRange) ?? d.historyRange
        rtaMic = try c.decodeIfPresent(Int.self, forKey: .rtaMic) ?? d.rtaMic
        rtaFraction = try c.decodeIfPresent(Int.self, forKey: .rtaFraction) ?? d.rtaFraction
        rtaAveraging = try c.decodeIfPresent(RealTimeAnalyzer.Averaging.self, forKey: .rtaAveraging) ?? d.rtaAveraging
        rtaWeighting = try c.decodeIfPresent(SoundLevel.FrequencyWeighting.self, forKey: .rtaWeighting) ?? d.rtaWeighting
        rtaFFTSize = try c.decodeIfPresent(Int.self, forKey: .rtaFFTSize) ?? d.rtaFFTSize
    }
}

/// What the views draw, copied from the engine about ten times a second.
struct MonitorSnapshot {
    struct Mic {
        /// Level now, highest level since the start, per weighting and average (dB re full scale).
        var levels: [SoundLevel.FrequencyWeighting: [LevelAverage: Double]] = [:]
        var maxima: [SoundLevel.FrequencyWeighting: [LevelAverage: Double]] = [:]
        var peaks: [SoundLevel.FrequencyWeighting: Double] = [:]
        /// Highest sample over the last update, dB re full scale.
        var recentPeak = -200.0

        func level(_ w: SoundLevel.FrequencyWeighting, _ a: LevelAverage) -> Double { levels[w]?[a] ?? -200 }
        func maximum(_ w: SoundLevel.FrequencyWeighting, _ a: LevelAverage) -> Double { maxima[w]?[a] ?? -200 }
    }

    var mics: [Mic] = []
    var seconds = 0
    var bands: [RealTimeAnalyzer.Band] = []
    var rtaLevels: [Double] = []
    var rtaPeaks: [Double] = []
}

/// Live monitoring: SPL meters on every mic and a real-time analyser on one. The input is read and
/// analysed off the main thread; the views get a snapshot about ten times a second, and the level
/// histories once a second.
@Observable @MainActor
final class MonitorAnalyzer {
    var settings: MonitorSettings { didSet { save() } }
    var isRunning = false
    var startDate: Date?
    var snapshot = MonitorSnapshot()
    /// One value a second per meter on the SPL view, by meter id, dB re full scale.
    var histories: [UUID: [Double]] = [:]
    var sampleRate = 48_000.0
    /// Names of the mics being monitored, by index, for labels.
    var micNames: [String] = []
    /// Each mic's record second by second since the start or the last reset, for export. Kept after
    /// stopping, until monitoring starts again.
    @ObservationIgnored private(set) var levelLogs: [LevelLog] = []

    @ObservationIgnored private var engine: MonitorEngine?
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "monitor"), let s = try? JSONDecoder().decode(MonitorSettings.self, from: data) {
            settings = s
        } else {
            settings = MonitorSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "monitor") }
    }

    /// Starts listening on every mic input from Measurement Setup. Nothing is played.
    func start(_ model: AppModel) async {
        guard !isRunning else { return }
        let s = model.settings
        guard let input = model.inputDevice else {
            model.errorMessage = "Choose an input device in Measurement Setup."
            return
        }
        guard let first = s.mics.first else {
            model.errorMessage = "Add a mic input in Measurement Setup."
            return
        }
        model.live.stop(model)
        model.generator.stop()
        model.levelCheck.stop()
        let engine = MonitorEngine(sampleRate: s.sampleRate, micCount: s.mics.count)
        // The stream always records a reference channel; the first mic stands in for it.
        let routing = LiveRouting(inputDevice: input, referenceChannel: first.channel - 1,
                                  micChannels: s.mics.map { $0.channel - 1 },
                                  outputDevice: nil, outputChannel: 0, loopbackOutputChannel: nil)
        do {
            try await engine.stream.start(routing: routing, sampleRate: s.sampleRate, signal: nil, level: 0)
        } catch {
            model.errorMessage = "\(error)"
            return
        }
        model.errorMessage = nil
        model.status = "Live monitoring: \(input.name), \(s.mics.count) mic\(s.mics.count == 1 ? "" : "s")"
        sampleRate = s.sampleRate
        micNames = s.mics.map { $0.micName ?? "Input \($0.channel)" }
        self.engine = engine
        snapshot = MonitorSnapshot()
        histories = [:]
        levelLogs = []
        startDate = Date()
        isRunning = true
        loop = Task.detached(priority: .userInitiated) { [weak self] in
            var lastSecond = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let settings = await self?.settings else { return }
                let snap = engine.update(settings)
                var histories: [UUID: [Double]]?
                var logs: [LevelLog]?
                if snap.seconds != lastSecond {
                    lastSecond = snap.seconds
                    histories = engine.histories(settings)
                    logs = engine.logs()
                }
                await self?.apply(snap, histories: histories, logs: logs)
            }
        }
    }

    /// Takes the engine's latest results, unless monitoring has stopped since.
    private func apply(_ snap: MonitorSnapshot, histories: [UUID: [Double]]?, logs: [LevelLog]?) {
        guard isRunning else { return }
        snapshot = snap
        if let histories { self.histories = histories }
        if let logs { levelLogs = logs }
    }

    /// The level log as CSV, a row per second, with each mic's calibration and offset applied.
    func logCSV(_ model: AppModel) -> String {
        let columns = levelLogs.indices.map { i in
            LevelLog.Column(name: i < micNames.count ? micNames[i] : "Mic \(i + 1)", offset: offset(model, mic: i) ?? 0,
                            unit: unit(model, mic: i), log: levelLogs[i])
        }
        return LevelLog.csv(columns, start: startDate)
    }

    func stop(_ model: AppModel? = nil) {
        guard isRunning else { return }
        loop?.cancel()
        loop = nil
        engine?.stream.stop()
        engine = nil
        isRunning = false
        model?.status = nil
    }

    /// Starts the meters, averages and histories again; keeps listening.
    func reset() {
        engine?.reset()
        snapshot = MonitorSnapshot()
        histories = [:]
        levelLogs = []
        startDate = Date()
    }

    func resetPeaks() { engine?.resetPeaks() }

    /// The SPL offset from mic `index`'s calibration (Setup > Calibrate…), if it has one.
    func calibration(_ model: AppModel, mic index: Int) -> Double? {
        let mics = model.settings.mics
        guard index >= 0, index < mics.count, let name = mics[index].micName else { return nil }
        return model.micProfiles.first { $0.name == name }?.splOffset
    }

    /// dB added to mic `index`'s levels: its calibration plus the offset typed in here. Nil when it has
    /// neither, so the levels are shown re full scale.
    func offset(_ model: AppModel, mic index: Int) -> Double? {
        let cal = calibration(model, mic: index)
        let typed = settings.micOffset(index)
        if cal == nil && typed == 0 { return nil }
        return (cal ?? 0) + typed
    }

    /// "dB SPL" for a calibrated mic, "dB" for one with only a typed offset, "dBFS" otherwise.
    func unit(_ model: AppModel, mic index: Int) -> String {
        if calibration(model, mic: index) != nil { return "dB SPL" }
        return settings.micOffset(index) != 0 ? "dB" : "dBFS"
    }
}

/// The audio and analysis behind live monitoring, used from one background task at a time.
final class MonitorEngine {
    let stream = LiveStream()
    let sampleRate: Double
    private let lock = NSLock()
    private var meters: [SoundLevelMeter]
    private var positions: [Int]
    private var rta: RealTimeAnalyzer?
    private var rtaKey = ""
    private var rtaPosition = 0
    private var resetRequested = false
    private var peaksResetRequested = false

    init(sampleRate: Double, micCount: Int) {
        self.sampleRate = sampleRate
        meters = (0..<micCount).map { _ in SoundLevelMeter(sampleRate: sampleRate) }
        positions = [Int](repeating: 0, count: micCount)
    }

    func reset() {
        lock.lock()
        resetRequested = true
        lock.unlock()
    }

    func resetPeaks() {
        lock.lock()
        peaksResetRequested = true
        lock.unlock()
    }

    /// Reads what has arrived since the last call, runs it through the meters and the analyser, and
    /// returns what the views show.
    func update(_ settings: MonitorSettings) -> MonitorSnapshot {
        lock.lock()
        let reset = resetRequested, resetPeaks = peaksResetRequested
        resetRequested = false
        peaksResetRequested = false
        lock.unlock()
        if reset {
            meters = meters.map { _ in SoundLevelMeter(sampleRate: sampleRate) }
            rta?.reset()
        }
        if resetPeaks { rta?.resetPeaks() }

        var snap = MonitorSnapshot()
        for i in meters.indices {
            let (x, end) = stream.samples(mic: i, from: positions[i])
            positions[i] = end
            meters[i].process(x)
            var mic = MonitorSnapshot.Mic()
            for w in SoundLevel.FrequencyWeighting.allCases {
                var levels: [LevelAverage: Double] = [:]
                var maxima: [LevelAverage: Double] = [:]
                for a in LevelAverage.allCases {
                    levels[a] = meters[i].level(w, a)
                    // The Leqs' maxima come from their histories, which the view has once a second.
                    if a == .fast || a == .slow { maxima[a] = meters[i].maximum(w, a) }
                }
                mic.levels[w] = levels
                mic.maxima[w] = maxima
                mic.peaks[w] = meters[i].peakLevel(w)
            }
            mic.recentPeak = 20 * log10(max(x.map(abs).max() ?? 0, 1e-10))
            snap.mics.append(mic)
        }
        snap.seconds = meters.first?.seconds ?? 0

        // The analyser takes the latest block whenever it has moved on.
        let mic = min(max(0, settings.rtaMic), max(0, meters.count - 1))
        let key = "\(settings.rtaFFTSize)-\(settings.rtaFraction)-\(mic)"
        if key != rtaKey || rta == nil {
            rta = RealTimeAnalyzer(fftSize: settings.rtaFFTSize, sampleRate: sampleRate, fraction: settings.rtaFraction)
            rtaKey = key
        }
        if let rta, let block = stream.block(rta.fftSize, mic: mic, delay: 0)?.mic {
            let now = stream.capturedFrames
            rta.process(block, hop: max(1, now - rtaPosition), averaging: settings.rtaAveraging)
            rtaPosition = now
            snap.bands = rta.bands
            snap.rtaLevels = rta.levels
            snap.rtaPeaks = rta.peaks
        }
        return snap
    }

    /// Each mic's record second by second.
    func logs() -> [LevelLog] { meters.map { LevelLog($0) } }

    /// Each meter's history, one value a second.
    func histories(_ settings: MonitorSettings) -> [UUID: [Double]] {
        var out: [UUID: [Double]] = [:]
        for m in settings.meters where m.mic < meters.count {
            out[m.id] = meters[m.mic].history(m.weighting, m.average)
        }
        return out
    }
}
#endif
