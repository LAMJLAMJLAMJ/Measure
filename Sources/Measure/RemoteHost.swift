#if os(macOS)
import Foundation
import MeasureDSP
import MeasureRemote
import Observation
import SwiftUI

/// Serves the iPad remote: advertises the Mac over Bonjour, sends the app's state to every connected
/// remote when it changes, and carries out the commands they send.
@Observable @MainActor
final class RemoteHost {
    /// Whether the Mac is advertised to remotes. Remembered between launches.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "remoteEnabled")
            enabled ? start() : stop()
        }
    }
    /// Names of the connected remotes.
    private(set) var remotes: [String] = []
    private(set) var error: String?

    @ObservationIgnored private let server = RemoteServer()
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastState: RemoteState?
    @ObservationIgnored private var names: [ObjectIdentifier: String] = [:]
    /// The status line shown when a remote connected, cleared when it goes.
    @ObservationIgnored private var connectedNote: String?
    /// Whether the remote draws the average of the ticked measurements.
    @ObservationIgnored private var showAverage = false
    /// Each trace's curve, by trace id, kept until its smoothing, name or colour changes.
    @ObservationIgnored private var curveCache: [UUID: (key: String, curve: RemoteCurve)] = [:]
    @ObservationIgnored private var phaseCache: [UUID: (key: String, curve: RemoteCurve?)] = [:]
    @ObservationIgnored private var averageCache: (key: String, curve: RemoteCurve?)?

    init() {
        enabled = UserDefaults.standard.bool(forKey: "remoteEnabled")
    }

    /// Starts serving if the remote was left on. Called once the model exists.
    func attach(_ model: AppModel) {
        self.model = model
        server.onConnect = { [weak self] connection in
            guard let self, let model = self.model else { return }
            connection.send(.state(self.state(model)))
        }
        server.onMessage = { [weak self] command, connection in
            self?.handle(command, from: connection)
        }
        server.onChange = { [weak self] in self?.serverChanged() }
        if enabled { start() }
    }

    private func start() {
        guard model != nil, !server.isRunning else { return }
        server.start()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.broadcast()
            }
        }
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        server.stop()
        lastState = nil
    }

    private func serverChanged() {
        error = server.error
        let live = Set(server.connections.map { ObjectIdentifier($0) })
        names = names.filter { live.contains($0.key) }
        remotes = server.connections.filter { $0.status == .ready }.map { names[ObjectIdentifier($0)] ?? "iPad" }
        if !server.connections.isEmpty { lastState = nil }
        // The connection note was only news while that remote was there: the corner label keeps the
        // current list.
        if let note = connectedNote, model?.status == note, !remotes.contains(where: { note.hasPrefix($0 + " ") }) {
            model?.status = nil
            connectedNote = nil
        }
    }

    /// Sends the state to every remote, only when it has changed.
    private func broadcast() {
        guard let model, !server.connections.isEmpty else { return }
        let state = state(model)
        guard state != lastState else { return }
        lastState = state
        server.broadcast(.state(state))
    }

    // MARK: - Commands

    private func handle(_ command: RemoteCommand, from connection: RemoteConnection) {
        guard let model else { return }
        switch command {
        case .hello(let device, _):
            names[ObjectIdentifier(connection)] = device
            serverChanged()
            let note = "\(device) connected as a remote."
            model.status = note
            connectedNote = note
        case .measure:
            Task { await model.measure() }
        case .setPosition(let position):
            model.settings.position = position
        case .startLive:
            Task { await model.live.start(model) }
        case .stopLive:
            model.live.stop(model)
        case .startGenerator:
            Task { await model.generator.start(model) }
        case .stopGenerator:
            model.generator.stop()
        case .setGeneratorLevel(let level):
            model.generator.settings.level = min(max(level, -80), 0)
        case .startMonitor:
            Task { await model.monitor.start(model) }
        case .stopMonitor:
            model.monitor.stop(model)
        case .resetMonitor:
            model.monitor.reset()
        case .select(let id):
            guard model.traces.contains(where: { $0.id == id }) else { return }
            model.selection = id
        case .setVisible(let id, let visible):
            guard model.traces.contains(where: { $0.id == id }) else { return }
            if visible { model.visible.insert(id) } else { model.visible.remove(id) }
        case .setSmoothing(let name):
            if let smoothing = Smoothing(rawValue: name) { model.smoothing = smoothing }
        case .showAverage(let show):
            showAverage = show
        case .setGeneratorSignal(let name):
            guard let kind = TestSignal.Kind(rawValue: name) else { return }
            model.generator.settings.signal.kind = kind
            model.generator.prepare(sampleRate: model.settings.sampleRate)
        case .setGeneratorMuted(let muted):
            model.generator.settings.muted = muted
        case .setGeneratorFrequency(let f):
            guard f.isFinite, f > 0 else { return }
            model.generator.settings.signal.frequency = f
            model.generator.prepare(sampleRate: model.settings.sampleRate)
        case .setGeneratorBand(let low, let high):
            guard low.isFinite, high.isFinite, low > 0, high > low else { return }
            model.generator.settings.signal.low = low
            model.generator.settings.signal.high = high
            model.generator.prepare(sampleRate: model.settings.sampleRate)
        case .setGeneratorOutput(let channel, let on):
            var set = Set(model.generator.outputs(model))
            if on { set.insert(channel) } else { set.remove(channel) }
            model.generator.settings.outputs = set.sorted()
        case .setRTAMic(let index):
            guard model.settings.mics.indices.contains(index) else { return }
            model.monitor.settings.rtaMic = index
        case .setRTAFraction(let fraction):
            guard [1, 3, 6, 12, 24].contains(fraction) else { return }
            model.monitor.settings.rtaFraction = fraction
        case .setRTAWeighting(let name):
            guard let w = SoundLevel.FrequencyWeighting(rawValue: name) else { return }
            model.monitor.settings.rtaWeighting = w
        case .resetRTAPeaks:
            model.monitor.resetPeaks()
        case .setHistoryRange(let seconds):
            guard [300, 900, 3600, 14_400, 0].contains(seconds) else { return }
            model.monitor.settings.historyRange = seconds
        case .captureLive:
            model.live.capture(model)
        case .findLiveDelay:
            guard model.live.blocks > 0 else { return }
            model.live.findDelays()
        case .resetLiveDelay:
            model.live.clearDelays()
            model.live.reset()
        case .saveAverage:
            model.average(Array(model.visible), method: .power)
        case .startLevelCheck:
            Task { await model.levelCheck.start(model) }
        case .stopLevelCheck:
            model.levelCheck.stop()
            model.status = nil
        case .setSweepLevel(let level):
            model.settings.level = min(max(level.rounded(), -80), 0)
            restartLevelCheck(model)
        case .setSweepLength(let length):
            guard Self.sweepLengths.contains(length) else { return }
            model.settings.sweepLength = length
            restartLevelCheck(model)
        case .setMicActive(let index, let active):
            guard model.settings.mics.indices.contains(index) else { return }
            // Keep at least one mic in the sweep.
            if !active && model.settings.activeMics.count <= 1 && model.settings.mics[index].active { return }
            model.settings.mics[index].active = active
            restartLevelCheck(model)
        }
        broadcast()
    }

    /// The sweep lengths offered, as in Measurement Setup.
    static let sweepLengths: [Double] = [1, 2, 3, 5, 10, 20]

    /// Starts the level check again so it plays the new sweep and meters the new set of mics.
    private func restartLevelCheck(_ model: AppModel) {
        guard model.levelCheck.isRunning else { return }
        model.levelCheck.stop()
        Task { await model.levelCheck.start(model) }
    }

    // MARK: - State

    private static let liveColors = ["#007AFF", "#FF3B30", "#32ADE6", "#FF9500"]

    private func state(_ model: AppModel) -> RemoteState {
        var s = RemoteState()
        s.projectName = model.projectFolder.deletingPathExtension().lastPathComponent
        s.status = model.status ?? ""
        s.error = model.errorMessage ?? model.generator.errorMessage ?? model.measurementWarning?.text
        s.isMeasuring = model.isMeasuring
        s.position = model.settings.position
        s.sweepLevel = model.settings.level
        s.sweepLength = model.settings.sweepLength
        s.sweepLengthOptions = Self.sweepLengths
        s.mics = model.settings.mics.map { RemoteMic(name: $0.micName ?? "Input \($0.channel)", active: $0.active) }
        let check = model.levelCheck
        s.levelCheckRunning = check.isRunning
        if check.isRunning {
            let meters = (check.loopback.map { [$0] } ?? []) + check.mics
            s.levelMeters = meters.map { meter in
                RemoteMeter(label: meter.name, value: meter.peak > -150 ? meter.peak.roundedTenth : nil,
                            unit: "dBFS peak", overLimit: meter.clipped)
            }
        }

        s.liveRunning = model.live.isRunning
        s.liveCurves = model.calibratedLiveCurves.map { curve in
            RemoteCurve.thinned(name: liveName(model, mic: curve.0),
                                color: Self.liveColors[curve.0 % Self.liveColors.count],
                                frequencies: curve.1.map(\.x), levels: curve.1.map(\.y))
        }
        s.livePhase = model.live.curves.map { c in
            RemoteCurve.thinned(name: liveName(model, mic: c.mic), color: Self.liveColors[c.mic % Self.liveColors.count],
                                frequencies: c.phase.map(\.x), levels: c.phase.map(\.y))
        }
        s.liveCoherence = model.live.curves.map { c in
            RemoteCurve.thinned(name: liveName(model, mic: c.mic), color: Self.liveColors[c.mic % Self.liveColors.count],
                                frequencies: c.coherence.map(\.x), levels: c.coherence.map(\.y))
        }
        s.liveCanCapture = model.live.isRunning && !model.live.curves.isEmpty
        s.liveCanFindDelay = model.live.blocks > 0
        s.liveDelays = model.live.curves.map { Double(model.live.settings.delay($0.mic)) / model.settings.sampleRate * 1000 }

        let generator = model.generator
        s.generatorRunning = generator.isRunning
        s.generatorLevel = generator.settings.level
        s.generatorMaxLevel = generator.maximumLevel
        s.generatorSignal = generator.settings.signal.kind.rawValue
        s.generatorSignals = TestSignal.Kind.allCases.map(\.rawValue)
        s.generatorMuted = generator.settings.muted
        s.generatorFrequency = generator.settings.signal.sineFrequency(sampleRate: model.settings.sampleRate)
        s.generatorLow = generator.settings.signal.low
        s.generatorHigh = generator.settings.signal.high
        s.generatorOutputs = generator.outputs(model)
        s.generatorOutputCount = generator.outputDevice(model)?.outputChannels ?? 0

        s.monitorRunning = model.monitor.isRunning
        s.meters = model.monitor.isRunning ? meters(model) : []
        let monitor = model.monitor
        s.rtaMic = monitor.settings.rtaMic
        s.rtaFraction = monitor.settings.rtaFraction
        s.rtaWeighting = monitor.settings.rtaWeighting.rawValue
        s.rtaWeightings = SoundLevel.FrequencyWeighting.allCases.map(\.rawValue)
        s.historyRange = monitor.settings.historyRange
        s.limitA = monitor.settings.limitA
        s.limitC = monitor.settings.limitC
        if monitor.isRunning {
            s.rta = rta(model)
            s.histories = histories(model)
        }

        let measured = model.traces.filter(\.hasResponse).suffix(30)
        s.traces = measured.map { trace in
            let warning = trace.qualityIssues.isEmpty ? nil : trace.qualityIssues.map(\.message).joined(separator: " ")
            return RemoteTrace(id: trace.id, name: trace.info.name, detail: detail(trace),
                               color: trace.color.hex ?? "#808080",
                               visible: model.visible.contains(trace.id), warning: warning)
        }
        s.selected = model.selection
        s.smoothing = model.smoothing.rawValue
        s.smoothingOptions = Smoothing.allCases.map(\.rawValue)
        s.showAverage = showAverage
        let ticked = Array(model.visibleTraces.filter(\.hasResponse).suffix(20))
        if ticked.isEmpty {
            let shown = model.selectedTrace.flatMap { $0.hasResponse ? $0 : nil } ?? model.traces.last(where: \.hasResponse)
            s.curves = shown.map { [curve($0, model)] } ?? []
        } else {
            s.curves = ticked.map { curve($0, model) }
        }
        s.averageCurve = showAverage && ticked.count > 1 ? average(ticked, model) : nil
        s.tracePhases = ticked.compactMap { phase($0) }
        // Forget traces that are gone.
        let ids = Set(model.traces.map(\.id))
        curveCache = curveCache.filter { ids.contains($0.key) }
        phaseCache = phaseCache.filter { ids.contains($0.key) }
        return s
    }

    /// The RTA as the Mac draws it: with the weighting, the mic's calibration curve and its offset.
    private func rta(_ model: AppModel) -> RemoteRTA? {
        let monitor = model.monitor
        let snap = monitor.snapshot
        guard !snap.bands.isEmpty, snap.bands.count == snap.rtaLevels.count,
              snap.bands.count == snap.rtaPeaks.count else { return nil }
        let index = monitor.settings.rtaMic
        let mics = model.settings.mics
        let cal = index < mics.count ? model.calibration(mic: mics[index].micName) : nil
        let offset = monitor.offset(model, mic: index) ?? 0
        let w = monitor.settings.rtaWeighting
        let shifts = snap.bands.map { SoundLevel.weightingDB(w, at: $0.center) - (cal?.magnitude(at: $0.center) ?? 0) + offset }
        return RemoteRTA(centers: snap.bands.map(\.center),
                         levels: zip(snap.rtaLevels, shifts).map { ($0 + $1).roundedTenth },
                         peaks: zip(snap.rtaPeaks, shifts).map { ($0 + $1).roundedTenth },
                         unit: monitor.unit(model, mic: index))
    }

    private static let meterColors = ["#FF9500", "#32ADE6", "#FF2D55", "#FFCC00"]

    /// Each meter's history over the range shown, in its units, at most 300 points (the highest
    /// value of each stretch, as the Mac draws it).
    private func histories(_ model: AppModel) -> [RemoteHistory] {
        let monitor = model.monitor
        return monitor.settings.meters.enumerated().compactMap { i, meter in
            guard let history = monitor.histories[meter.id], !history.isEmpty else { return nil }
            let offset = monitor.offset(model, mic: meter.mic) ?? 0
            let range = monitor.settings.historyRange
            let shown = Array(history.suffix(range > 0 ? range : history.count))
            let step = max(1, Int((Double(shown.count) / 300).rounded(.up)))
            let levels = stride(from: 0, to: shown.count, by: step).map { j in
                (shown[j..<min(shown.count, j + step)].max()! + offset).roundedTenth
            }
            let names = model.settings.mics.map { $0.micName ?? "Input \($0.channel)" }
            let name = meter.mic < names.count ? names[meter.mic] : "Mic \(meter.mic + 1)"
            return RemoteHistory(label: "\(name) · \(meter.average.label(meter.weighting))",
                                 color: Self.meterColors[i % Self.meterColors.count],
                                 levels: levels, secondsPerPoint: step)
        }
    }

    private func liveName(_ model: AppModel, mic: Int) -> String {
        let mics = model.settings.mics
        let name = mic < mics.count ? mics[mic].micName : nil
        return name ?? "Mic \(mic + 1)"
    }

    private func detail(_ trace: Trace) -> String {
        let time = trace.info.date.formatted(date: .omitted, time: .shortened)
        return trace.info.position.isEmpty ? time : "\(trace.info.position) · \(time)"
    }

    private func meters(_ model: AppModel) -> [RemoteMeter] {
        let monitor = model.monitor
        let micNames = model.settings.mics.map { $0.micName ?? "Input \($0.channel)" }
        return monitor.settings.meters.map { meter in
            let offset = monitor.offset(model, mic: meter.mic) ?? 0
            let mic: MonitorSnapshot.Mic? = meter.mic < monitor.snapshot.mics.count ? monitor.snapshot.mics[meter.mic] : nil
            let raw = mic?.level(meter.weighting, meter.average)
            let level = raw.flatMap { $0 > -150 ? ($0 + offset).roundedTenth : nil }
            var maximum: Double?
            if let mic {
                let fastOrSlow = meter.average == .fast || meter.average == .slow
                let top = fastOrSlow ? mic.maximum(meter.weighting, meter.average)
                    : monitor.histories[meter.id]?.max() ?? mic.level(meter.weighting, meter.average)
                maximum = top > -150 ? (top + offset).roundedTenth : nil
            }
            let limit = monitor.settings.limit(meter.weighting)
            let over = limit.map { (level ?? -200) > $0 } ?? false
            let name = meter.mic < micNames.count ? micNames[meter.mic] : "Mic \(meter.mic + 1)"
            return RemoteMeter(label: "\(name) · \(meter.average.label(meter.weighting))",
                               value: level, unit: monitor.unit(model, mic: meter.mic),
                               maximum: maximum, overLimit: over)
        }
    }

    /// A trace's response as drawn on the Mac: calibrated, smoothed and in its colour.
    private func curve(_ trace: Trace, _ model: AppModel) -> RemoteCurve {
        let color = trace.color.hex ?? "#808080"
        let key = "\(model.smoothing) \(trace.info.name) \(color) \(String(describing: trace.info.window))"
        if let cached = curveCache[trace.id], cached.key == key { return cached.curve }
        let points = trace.displayResponse(smoothing: model.smoothing, calibration: model.calibration(for: trace))
        let curve = RemoteCurve.thinned(name: trace.info.name, color: color,
                                        frequencies: points.map(\.x), levels: points.map(\.y))
        curveCache[trace.id] = (key, curve)
        return curve
    }

    /// A trace's phase as the Mac's phase chart draws it, with the delay to the direct sound removed.
    private func phase(_ trace: Trace) -> RemoteCurve? {
        let color = trace.color.hex ?? "#808080"
        let key = "\(trace.info.name) \(color) \(String(describing: trace.info.window))"
        if let cached = phaseCache[trace.id], cached.key == key { return cached.curve }
        let curve = trace.displayPhase().map { points in
            RemoteCurve.thinned(name: trace.info.name, color: color,
                                frequencies: points.map(\.x), levels: points.map(\.y))
        }
        phaseCache[trace.id] = (key, curve)
        return curve
    }

    /// The power average of the traces' calibrated responses, smoothed like the traces.
    private func average(_ traces: [Trace], _ model: AppModel) -> RemoteCurve? {
        let key = "\(model.smoothing) " + traces.map(\.id.uuidString).joined(separator: ",")
        if let cache = averageCache, cache.key == key { return cache.curve }
        var result: RemoteCurve?
        if let response = FrequencyResponse.average(traces.map { model.calibratedResponse($0) }, method: .power) {
            let points = Trace.displayPoints(response, smoothing: model.smoothing, calibration: nil)
            result = RemoteCurve.thinned(name: "Average", color: "#000000",
                                         frequencies: points.map(\.x), levels: points.map(\.y))
        }
        averageCache = (key, result)
        return result
    }
}

/// Toolbar button that turns the iPad remote on and off.
struct RemoteToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let remote = model.remote
        Toggle(isOn: Binding(get: { remote.enabled }, set: { remote.enabled = $0 })) {
            Label("iPad Remote", systemImage: "ipad.landscape")
        }
        .toggleStyle(.button)
        .help(helpText(remote))
    }

    private func helpText(_ remote: RemoteHost) -> String {
        if let error = remote.error { return "iPad Remote: \(error)" }
        if !remote.enabled { return "Turn on the iPad remote: Measure Remote on an iPad on the same network finds this Mac" }
        if remote.remotes.isEmpty { return "iPad Remote is on, waiting for an iPad on the same network" }
        return "iPad Remote: connected to \(remote.remotes.joined(separator: ", "))"
    }
}

private extension Double {
    /// Rounded to 0.1 dB, so the state only changes when the shown value does.
    var roundedTenth: Double { (self * 10).rounded() / 10 }
}
#endif
