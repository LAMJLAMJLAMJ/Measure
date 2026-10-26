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
    /// The selected trace's curve, kept until the selection or the smoothing changes.
    @ObservationIgnored private var curveCache: (key: String, curve: RemoteCurve?)?

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
            model.status = "\(device) connected as a remote."
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
            model.visible.insert(id)
        }
        broadcast()
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

        s.liveRunning = model.live.isRunning
        s.liveCurves = model.calibratedLiveCurves.map { curve in
            RemoteCurve.thinned(name: liveName(model, mic: curve.0),
                                color: Self.liveColors[curve.0 % Self.liveColors.count],
                                frequencies: curve.1.map(\.x), levels: curve.1.map(\.y))
        }

        let generator = model.generator
        s.generatorRunning = generator.isRunning
        s.generatorLevel = generator.settings.level
        s.generatorMaxLevel = generator.maximumLevel
        s.generatorSignal = generator.settings.signal.kind.rawValue

        s.monitorRunning = model.monitor.isRunning
        s.meters = model.monitor.isRunning ? meters(model) : []

        let measured = model.traces.filter(\.hasResponse).suffix(30)
        s.traces = measured.map { trace in
            RemoteTrace(id: trace.id, name: trace.info.name, detail: detail(trace),
                        color: trace.color.hex ?? "#808080")
        }
        s.selected = model.selection
        s.selectedCurve = selectedCurve(model)
        return s
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

    private func selectedCurve(_ model: AppModel) -> RemoteCurve? {
        let ticked = model.visibleTraces.filter(\.hasResponse)
        guard let trace = model.selectedTrace.flatMap({ $0.hasResponse ? $0 : nil })
                ?? ticked.last ?? model.traces.last(where: \.hasResponse) else { return nil }
        let key = "\(trace.id) \(model.smoothing) \(trace.info.colorHex ?? "") \(trace.info.colorIndex)"
        if let cache = curveCache, cache.key == key { return cache.curve }
        let points = trace.displayResponse(smoothing: model.smoothing, calibration: model.calibration(for: trace))
        let curve = RemoteCurve.thinned(name: trace.info.name, color: trace.color.hex ?? "#808080",
                                        frequencies: points.map(\.x), levels: points.map(\.y))
        curveCache = (key, curve)
        return curve
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
