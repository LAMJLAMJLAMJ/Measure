#if canImport(SwiftUI) && canImport(Network)
import Charts
import MeasureRemote
import SwiftUI

/// The whole remote: a search screen until a Mac is found, then tabs for each part of Measure.
public struct RemoteRootView: View {
    @State private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            if let state = client.state, client.connectedHost != nil {
                RemoteTabs(client: client, state: state)
            } else {
                RemoteSearchView(client: client)
            }
        }
        .task { client.start() }
        .onChange(of: scenePhase) { old, phase in
            if phase == .background { client.pause() }
            if phase == .active && old == .background { client.resume() }
        }
    }
}

// MARK: - Searching

struct RemoteSearchView: View {
    let client: RemoteClient

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            if let host = client.connectingHost {
                ProgressView("Connecting to \(host)…")
            } else if client.hosts.count > 1 {
                Text("Choose a Mac").font(.title2)
                VStack(spacing: 8) {
                    ForEach(client.hosts) { host in
                        Button(host.name) { client.connect(to: host) }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ProgressView("Looking for Measure on your Mac…")
                Text("In Measure on the Mac, turn on iPad Remote in the toolbar or the Measurement menu. Keep the Mac and this iPad on the same Wi-Fi network.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            if let problem = client.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            Button("Search Again") { client.searchAgain() }
        }
        .padding()
    }
}

// MARK: - Connected

struct RemoteTabs: View {
    let client: RemoteClient
    let state: RemoteState

    var body: some View {
        VStack(spacing: 0) {
            RemoteStatusBar(client: client, state: state)
            Divider()
            TabView {
                SweepTab(client: client, state: state)
                    .tabItem { Label("Sweep", systemImage: "waveform.path.ecg") }
                LiveTab(client: client, state: state)
                    .tabItem { Label("Live", systemImage: "waveform") }
                GeneratorTab(client: client, state: state)
                    .tabItem { Label("Generator", systemImage: "speaker.wave.3") }
                MonitorTab(client: client, state: state)
                    .tabItem { Label("SPL", systemImage: "gauge.with.dots.needle.50percent") }
            }
        }
    }
}

struct RemoteStatusBar: View {
    let client: RemoteClient
    let state: RemoteState

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.connectedHost ?? "").font(.headline)
                if !state.projectName.isEmpty {
                    Text(state.projectName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(state.status).foregroundStyle(.secondary).lineLimit(1)
            }
            Menu {
                Button("Disconnect") { client.forget() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Sweep

struct SweepTab: View {
    let client: RemoteClient
    let state: RemoteState
    @State private var position = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            List {
                Section("Position") {
                    TextField("Position name", text: $position)
                        .focused($editing)
                        .onSubmit { client.send(.setPosition(position)) }
                    Button {
                        if position != state.position { client.send(.setPosition(position)) }
                        editing = false
                        client.send(.measure)
                    } label: {
                        Label(state.isMeasuring ? "Measuring…" : "Measure", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(state.isMeasuring)
                }
                SweepSettings(client: client, state: state)
                LevelCheckSection(client: client, state: state)
                Section {
                    ForEach(Array(state.traces.reversed())) { trace in
                        TraceRow(client: client, trace: trace, selected: trace.id == state.selected)
                    }
                } header: {
                    HStack {
                        Text("Measurements")
                        Spacer()
                        if state.traces.contains(where: \.visible) {
                            Button("Untick All") {
                                for trace in state.traces where trace.visible { client.send(.setVisible(trace.id, false)) }
                            }
                            .textCase(nil)
                        }
                    }
                }
            }
            .remoteListStyle()
            .frame(width: 360)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                chartControls
                ResponseChart(curves: state.curves, average: state.averageCurve,
                              highlighted: state.curves.count > 1 ? selectedName : nil,
                              empty: "No measurement yet")
                Text(chartNote).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .onAppear { position = state.position }
        .onChange(of: state.position) { _, new in
            if !editing { position = new }
        }
    }

    private var chartControls: some View {
        HStack(spacing: 16) {
            Picker("Smoothing", selection: Binding(get: { state.smoothing },
                                                   set: { client.send(.setSmoothing($0)) })) {
                ForEach(state.smoothingOptions, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            AverageControls(client: client, state: state)
            Spacer()
        }
    }

    private var selectedName: String? {
        state.traces.first { $0.id == state.selected }?.name
    }

    private var chartNote: String {
        let ticked = state.traces.filter(\.visible).count
        if ticked == 0 { return "Showing the selected measurement. Tick measurements to draw them together." }
        var note = "\(ticked) ticked measurement\(ticked == 1 ? "" : "s")"
        if state.averageCurve != nil { note += ", with their power average in the thick line" }
        return note + ". Smoothing \(state.smoothing)."
    }
}

/// Shows the power average of the ticked measurements, and saves it to the Mac's list.
struct AverageControls: View {
    let client: RemoteClient
    let state: RemoteState

    private var enough: Bool { state.traces.filter(\.visible).count >= 2 }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Average", isOn: Binding(get: { state.showAverage },
                                            set: { client.send(.showAverage($0)) }))
                .fixedSize()
            Button("Save Average") { client.send(.saveAverage) }
                .buttonStyle(.bordered)
        }
        .disabled(!enough)
    }
}

/// Sweep level, length and which mic inputs it records.
struct SweepSettings: View {
    let client: RemoteClient
    let state: RemoteState
    @State private var level: Double = -30
    @State private var dragging = false

    var body: some View {
        Section("Sweep") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Level")
                    Spacer()
                    Text(String(format: "%.0f dBFS", level)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Button { nudge(-1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                    Slider(value: $level, in: -80...0, step: 1, onEditingChanged: { editing in
                        dragging = editing
                        if !editing { client.send(.setSweepLevel(level)) }
                    })
                    Button { nudge(1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                }
            }
            Picker("Length", selection: Binding(get: { state.sweepLength },
                                                set: { client.send(.setSweepLength($0)) })) {
                ForEach(state.sweepLengthOptions, id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            ForEach(Array(state.mics.enumerated()), id: \.offset) { i, mic in
                Toggle(mic.name, isOn: Binding(get: { mic.active },
                                               set: { client.send(.setMicActive(i, $0)) }))
                    .disabled(mic.active && state.mics.filter(\.active).count <= 1)
            }
        }
        .onAppear { level = state.sweepLevel }
        .onChange(of: state.sweepLevel) { _, new in
            if !dragging { level = new }
        }
    }

    private func nudge(_ step: Double) {
        level = min(max(level + step, -80), 0)
        client.send(.setSweepLevel(level))
    }
}

/// Plays the sweep in a loop and shows each input's peak, to set the gains before measuring.
struct LevelCheckSection: View {
    let client: RemoteClient
    let state: RemoteState

    var body: some View {
        Section {
            Button {
                client.send(state.levelCheckRunning ? .stopLevelCheck : .startLevelCheck)
            } label: {
                Label(state.levelCheckRunning ? "Stop Level Check" : "Check Levels",
                      systemImage: state.levelCheckRunning ? "stop.fill" : "speaker.wave.2")
            }
            .disabled(state.isMeasuring)
            // The Mac's input meters run all the time; a Mac without them sends the level check's.
            ForEach(Array(meters.enumerated()), id: \.offset) { _, meter in
                PeakMeterRow(meter: meter)
            }
        } header: {
            Text("Input levels")
        } footer: {
            Text(state.levelCheckRunning
                 ? "Peaks over the last few seconds. Aim for -20 to -6 dBFS; red means the input clipped."
                 : "Check Levels plays the sweep in a loop at its level, to set the gains on these meters. Measure stops it.")
        }
    }
}

extension LevelCheckSection {
    private var meters: [RemoteMeter] {
        if !state.inputMeters.isEmpty { return state.inputMeters }
        return state.levelCheckRunning ? state.levelMeters : []
    }
}

struct PeakMeterRow: View {
    let meter: RemoteMeter

    private var color: Color {
        guard let value = meter.value else { return .gray }
        if meter.overLimit { return .red }
        if value < -40 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meter.label).lineLimit(1)
                Spacer()
                if meter.overLimit { Text("Clipped").font(.caption.bold()).foregroundStyle(.red) }
                // Below -90 dBFS peak: unplugged, unpowered or gain at zero, as the Mac's meters say.
                if (meter.value ?? -200) < -90 { Text("No signal").font(.caption.bold()).foregroundStyle(.orange) }
                Text(meter.value.map { String(format: "%.1f", $0) } ?? "–").monospacedDigit()
                Text("dBFS").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let fraction = min(max(((meter.value ?? -80) + 60) / 60, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 6)
        }
    }
}

/// One measurement in the list: a tick box in its colour, then its name. Tapping the name selects it.
struct TraceRow: View {
    let client: RemoteClient
    let trace: RemoteTrace
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                client.send(.setVisible(trace.id, !trace.visible))
            } label: {
                Image(systemName: trace.visible ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(Color(remoteHex: trace.color))
            }
            .buttonStyle(.borderless)
            Button {
                client.send(.select(trace.id))
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(trace.name).fontWeight(selected ? .semibold : .regular)
                        Text(trace.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let warning = trace.warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel(warning)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
        }
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

// MARK: - Live

struct LiveTab: View {
    let client: RemoteClient
    let state: RemoteState

    /// The ticked measurements, drawn thin under the live curves.
    private var ticked: [RemoteCurve] { state.traces.contains(where: \.visible) ? state.curves : [] }
    private var tickedPhase: [RemoteCurve] { state.traces.contains(where: \.visible) ? state.tracePhases : [] }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            List {
                if !state.inputMeters.isEmpty {
                    Section("Input levels") {
                        ForEach(Array(state.inputMeters.enumerated()), id: \.offset) { _, meter in
                            PeakMeterRow(meter: meter)
                        }
                    }
                }
                Section {
                    ForEach(Array(state.traces.reversed())) { trace in
                        TraceRow(client: client, trace: trace, selected: trace.id == state.selected)
                    }
                } header: {
                    HStack {
                        Text("Measurements")
                        Spacer()
                        if state.traces.contains(where: \.visible) {
                            Button("Untick All") {
                                for trace in state.traces where trace.visible { client.send(.setVisible(trace.id, false)) }
                            }
                            .textCase(nil)
                        }
                    }
                } footer: {
                    Text("Ticked measurements are drawn thin under the live curves. Capture saves each mic's live response to the list, where it can be ticked and averaged.")
                }
            }
            .remoteListStyle()
            .frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StartStopButton(running: state.liveRunning, start: "Start Live", stop: "Stop Live") {
                        client.send(state.liveRunning ? .stopLive : .startLive)
                    }
                    Button {
                        client.send(.captureLive)
                    } label: {
                        Label("Capture", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!state.liveCanCapture)
                    Button("Find Delay") { client.send(.findLiveDelay) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!state.liveCanFindDelay)
                    Button("Reset") { client.send(.resetLiveDelay) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Spacer()
                    ForEach(Array(state.liveCurves.enumerated()), id: \.offset) { i, curve in
                        HStack(spacing: 4) {
                            Circle().fill(Color(remoteHex: curve.color)).frame(width: 8, height: 8)
                            Text(curve.name).font(.caption)
                            if i < state.liveDelays.count {
                                Text(String(format: "%.2f ms", state.liveDelays[i]))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                HStack {
                    AverageControls(client: client, state: state)
                    Spacer()
                }
                ResponseChart(curves: state.liveCurves, average: ticked.isEmpty ? nil : state.averageCurve,
                              background: ticked,
                              empty: state.liveRunning ? "Waiting for audio…" : "Live is stopped")
                    .frame(minHeight: 200)
                Text("Coherence").font(.caption).foregroundStyle(.secondary)
                ResponseChart(curves: state.liveCoherence, yFixed: 0...1, yLabel: "", unit: "", empty: "")
                    .frame(height: 80)
                Text("Phase").font(.caption).foregroundStyle(.secondary)
                ResponseChart(curves: state.livePhase, background: tickedPhase, yFixed: -180...180,
                              yLabel: "°", unit: "°", dots: true, empty: "")
                    .frame(height: 150)
            }
            .padding()
        }
    }
}

// MARK: - Generator

struct GeneratorTab: View {
    let client: RemoteClient
    let state: RemoteState
    @State private var level: Double = -20
    @State private var dragging = false
    @State private var frequency: Double = 1000
    @State private var low: Double = 20
    @State private var high: Double = 20_000

    private var range: ClosedRange<Double> {
        let top = max(state.generatorMaxLevel, -79)
        return -80...top
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Picker("Signal", selection: Binding(get: { state.generatorSignal },
                                                    set: { client.send(.setGeneratorSignal($0)) })) {
                    ForEach(state.generatorSignals, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 640)
                signalSettings
                Text(String(format: "%.1f dBFS RMS", level))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.generatorMuted ? .secondary : .primary)
                HStack(spacing: 16) {
                    Button { nudge(-1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.bordered)
                    Slider(value: $level, in: range, onEditingChanged: { editing in
                        dragging = editing
                        if !editing { client.send(.setGeneratorLevel(level)) }
                    })
                    Button { nudge(1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: 560)
                HStack(spacing: 16) {
                    StartStopButton(running: state.generatorRunning, start: "Start Generator", stop: "Stop Generator") {
                        client.send(state.generatorRunning ? .stopGenerator : .startGenerator)
                    }
                    Toggle(isOn: Binding(get: { state.generatorMuted }, set: { client.send(.setGeneratorMuted($0)) })) {
                        Label("Mute", systemImage: state.generatorMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    }
                    .toggleStyle(.button)
                    .controlSize(.large)
                }
                outputs
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            level = state.generatorLevel
            frequency = state.generatorFrequency
            low = state.generatorLow
            high = state.generatorHigh
        }
        .onChange(of: state.generatorLevel) { _, new in
            if !dragging { level = new }
        }
        .onChange(of: state.generatorFrequency) { _, new in frequency = new }
        .onChange(of: state.generatorLow) { _, new in low = new }
        .onChange(of: state.generatorHigh) { _, new in high = new }
    }

    /// The sine's frequency, or the band of the noise and the sweep.
    @ViewBuilder private var signalSettings: some View {
        switch state.generatorSignal {
        case "Sine":
            HStack(spacing: 12) {
                NumberField(title: "Frequency", value: $frequency, unit: "Hz") { client.send(.setGeneratorFrequency(frequency)) }
                ForEach([63.0, 125, 250, 500, 1000, 2000, 4000, 8000], id: \.self) { f in
                    Button(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))") {
                        frequency = f
                        client.send(.setGeneratorFrequency(f))
                    }
                    .buttonStyle(.bordered)
                }
            }
        case "Pink noise", "White noise", "Sweep":
            HStack(spacing: 16) {
                NumberField(title: "From", value: $low, unit: "Hz") { client.send(.setGeneratorBand(low: low, high: high)) }
                NumberField(title: "To", value: $high, unit: "Hz") { client.send(.setGeneratorBand(low: low, high: high)) }
                Button("Full Range") {
                    low = 20
                    high = 20_000
                    client.send(.setGeneratorBand(low: 20, high: 20_000))
                }
                .buttonStyle(.bordered)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var outputs: some View {
        if state.generatorOutputCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Outputs").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(1...state.generatorOutputCount, id: \.self) { c in
                        Toggle("\(c)", isOn: Binding(get: { state.generatorOutputs.contains(c) },
                                                     set: { client.send(.setGeneratorOutput(channel: c, on: $0)) }))
                            .toggleStyle(.button)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func nudge(_ step: Double) {
        level = min(max(level + step, range.lowerBound), range.upperBound)
        client.send(.setGeneratorLevel(level))
    }
}

/// A number typed in, sent when Return is pressed or the field is left.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    let unit: String
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .focused($focused)
                .numberKeyboard()
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
            Text(unit).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

// MARK: - SPL monitor

struct MonitorTab: View {
    let client: RemoteClient
    let state: RemoteState

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    StartStopButton(running: state.monitorRunning, start: "Start Monitoring", stop: "Stop Monitoring") {
                        client.send(state.monitorRunning ? .stopMonitor : .startMonitor)
                    }
                    Button {
                        client.send(state.monitorPaused ? .resumeMonitor : .pauseMonitor)
                    } label: {
                        Label(state.monitorPaused ? "Resume" : "Pause",
                              systemImage: state.monitorPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!state.monitorRunning)
                    Button("Reset") { client.send(.resetMonitor) }
                        .buttonStyle(.bordered)
                    if state.monitorPaused {
                        Text("Paused: the levels are held and the paused time is left out.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if state.meters.isEmpty {
                    ContentUnavailableView("No meters", systemImage: "gauge.with.dots.needle.0percent",
                                           description: Text("Start monitoring to see the levels, the RTA and the history."))
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(state.meters.enumerated()), id: \.offset) { i, meter in
                            MeterTile(client: client, state: state, meter: meter, index: i)
                        }
                    }
                    RTASection(client: client, state: state)
                    HistorySection(client: client, state: state)
                }
            }
            .padding()
        }
    }
}

struct RTASection: View {
    let client: RemoteClient
    let state: RemoteState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("RTA").font(.headline)
                Picker("Mic", selection: Binding(get: { state.rtaMic }, set: { client.send(.setRTAMic($0)) })) {
                    ForEach(Array(state.mics.enumerated()), id: \.offset) { i, mic in Text(mic.name).tag(i) }
                }
                Picker("Bands", selection: Binding(get: { state.rtaFraction }, set: { client.send(.setRTAFraction($0)) })) {
                    ForEach([1, 3, 6, 12, 24], id: \.self) { Text("1/\($0) oct").tag($0) }
                }
                Picker("Weighting", selection: Binding(get: { state.rtaWeighting }, set: { client.send(.setRTAWeighting($0)) })) {
                    ForEach(state.rtaWeightings, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button("Reset Peaks") { client.send(.resetRTAPeaks) }
                    .buttonStyle(.bordered)
            }
            if let rta = state.rta {
                RTAChart(rta: rta, fraction: state.rtaFraction)
                    .frame(height: 260)
            } else {
                Text("Waiting for the analyser…").foregroundStyle(.secondary)
            }
        }
    }
}

struct RTAChart: View {
    let rta: RemoteRTA
    let fraction: Int

    private struct Bar: Identifiable {
        let id: Int
        let low: Double
        let high: Double
        let level: Double
        let peak: Double
    }

    private var bars: [Bar] {
        let half = pow(2, 1 / (2 * Double(max(fraction, 1))))
        return rta.centers.indices.compactMap { i in
            guard i < rta.levels.count, i < rta.peaks.count else { return nil }
            let c = rta.centers[i]
            return Bar(id: i, low: max(c / half, 20), high: min(c * half, 20_000), level: rta.levels[i], peak: rta.peaks[i])
        }
    }

    private var yDomain: ClosedRange<Double> {
        let top = ((rta.peaks.max() ?? 0) / 10).rounded(.up) * 10 + 5
        return (top - 75)...top
    }

    var body: some View {
        let domain = yDomain
        Chart(bars) { bar in
            RectangleMark(xStart: .value("Low", bar.low), xEnd: .value("High", bar.high),
                          yStart: .value("Bottom", domain.lowerBound), yEnd: .value("Level", max(bar.level, domain.lowerBound)))
                .foregroundStyle(Color.accentColor.opacity(0.8))
            RectangleMark(xStart: .value("Low", bar.low), xEnd: .value("High", bar.high),
                          yStart: .value("Peak", bar.peak - 0.4), yEnd: .value("Peak", bar.peak + 0.4))
                .foregroundStyle(Color.secondary)
        }
        .chartXScale(domain: 20.0...20_000.0, type: .log)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let f = value.as(Double.self) {
                        Text(f >= 1000 ? "\(Int(f / 1000))k" : (f == 31.5 ? "31.5" : "\(Int(f))"))
                    }
                }
            }
        }
        .chartYAxisLabel(rta.unit)
        .chartPlotStyle { $0.clipped() }
    }
}

struct HistorySection: View {
    let client: RemoteClient
    let state: RemoteState

    private struct Point: Identifiable {
        let id: Int
        let series: String
        let minutes: Double
        let level: Double
    }

    private var points: [Point] {
        var result: [Point] = []
        for (n, history) in state.histories.enumerated() {
            let count = history.levels.count
            for (j, level) in history.levels.enumerated() {
                let secondsAgo = Double((count - 1 - j) * history.secondsPerPoint)
                result.append(Point(id: result.count, series: "\(n)", minutes: -secondsAgo / 60, level: level))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("History").font(.headline)
                Picker("Range", selection: Binding(get: { state.historyRange }, set: { client.send(.setHistoryRange($0)) })) {
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("1 h").tag(3600)
                    Text("4 h").tag(14_400)
                    Text("All").tag(0)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                ForEach(Array(state.histories.enumerated()), id: \.offset) { _, history in
                    HStack(spacing: 4) {
                        Circle().fill(Color(remoteHex: history.color)).frame(width: 8, height: 8)
                        Text(history.label).font(.caption)
                    }
                }
            }
            if state.histories.isEmpty {
                Text("The history starts after the first second.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("Minutes", p.minutes), y: .value("Level", p.level),
                                 series: .value("Meter", p.series))
                            .foregroundStyle(by: .value("Meter", p.series))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    if let a = state.limitA {
                        RuleMark(y: .value("Limit A", a))
                            .foregroundStyle(state.limitAColor.map { Color(remoteHex: $0) } ?? .red)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    if let c = state.limitC {
                        RuleMark(y: .value("Limit C", c))
                            .foregroundStyle(state.limitCColor.map { Color(remoteHex: $0) } ?? .purple)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartForegroundStyleScale(domain: state.histories.indices.map { "\($0)" },
                                           range: state.histories.map { Color(remoteHex: $0.color) })
                .chartLegend(.hidden)
                .chartXAxisLabel("minutes ago")
                .chartYAxisLabel("dB")
                .frame(height: 220)
            }
        }
    }
}

/// One SPL meter, laid out as the Mac's card and Smaart's: a vertical tube on the left, the mic's name
/// over a big number, the maximum with a status light, and "dB SPL A Slow". The name and that line are
/// menus that change the meter on the Mac. A Mac without the card's fields gets the plain tile.
struct MeterTile: View {
    let client: RemoteClient
    let state: RemoteState
    let meter: RemoteMeter
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                micMenu
                Spacer(minLength: 4)
                if meter.clipping == true {
                    Text("Overload")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
                unitMenu
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(meter.value.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.system(size: 46, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(meter.overLimit ? Color.red : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(meter.unit).font(.title3).foregroundStyle(.secondary)
            }
            RemoteScaleBar(level: meter.value, maximum: meter.maximum, limit: meter.limit,
                           spl: meter.unit == "dB SPL", limitTint: limitTint)
            HStack {
                Text("Max " + (meter.maximum.map { String(format: "%.1f", $0) } ?? "–")).monospacedDigit()
                Spacer()
                Text(statusText).foregroundStyle(statusColor)
            }
            .font(.callout)
        }
        .padding(.vertical, 12)
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 170)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(tint)
                .frame(width: 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(meter.overLimit ? Color.red : nearLimit ? Color.yellow : Color.clear,
                          lineWidth: meter.overLimit ? 4 : 2.5))
    }

    /// Within 5 dB of the limit.
    private var nearLimit: Bool {
        guard let value = meter.value, let limit = meter.limit else { return false }
        return value > limit - 5
    }

    /// The meter's colour on the Mac, which its history line carries.
    private var tint: Color {
        index < state.histories.count ? Color(remoteHex: state.histories[index].color) : .accentColor
    }

    /// The limit's colour on the Mac: the C limit's for a C-weighted meter, otherwise the A limit's.
    private var limitTint: Color {
        if meter.detail?.contains(" C ") == true { return state.limitCColor.map { Color(remoteHex: $0) } ?? .purple }
        return state.limitAColor.map { Color(remoteHex: $0) } ?? .red
    }

    /// "Over limit", "Near limit" within 5 dB, "Overload" while clipping, otherwise the limit.
    private var statusText: String {
        if meter.clipping == true { return "Overload" }
        guard let limit = meter.limit else { return "No limit" }
        guard let value = meter.value else { return String(format: "Limit %.0f", limit) }
        return value >= limit ? "Over limit" : value > limit - 5 ? "Near limit" : String(format: "Limit %.0f", limit)
    }

    /// Secondary while the level is fine, yellow within 5 dB of the limit, red over it or while clipping.
    private var statusColor: Color {
        guard let value = meter.value else { return .secondary }
        if meter.clipping == true || meter.overLimit { return .red }
        if let limit = meter.limit, value > limit - 5 { return .yellow }
        return .secondary
    }

    @ViewBuilder private var micMenu: some View {
        let name = meter.name ?? meter.label
        if meter.name != nil && state.mics.count > 1 {
            Menu {
                ForEach(Array(state.mics.enumerated()), id: \.offset) { i, mic in
                    Button(mic.name) { client.send(.setMeterMic(index: index, mic: i)) }
                }
            } label: {
                Text(name).font(.headline).lineLimit(1)
            }
        } else {
            Text(name).font(.headline).lineLimit(1)
        }
    }

    @ViewBuilder private var unitMenu: some View {
        if let detail = meter.detail {
            Menu {
                Section("Weighting") {
                    ForEach(state.rtaWeightings, id: \.self) { w in
                        Button("\(w) weighting") { client.send(.setMeterWeighting(index: index, weighting: w)) }
                    }
                }
                Section("Average") {
                    ForEach(state.meterAverages, id: \.self) { a in
                        Button(a) { client.send(.setMeterAverage(index: index, average: a)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(chipText(detail)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        } else {
            Text(meter.unit).foregroundStyle(.secondary)
        }
    }

    /// "A · Slow" from "dB SPL A Slow": the unit is shown beside the number.
    private func chipText(_ detail: String) -> String {
        let rest = detail.hasPrefix(meter.unit + " ") ? String(detail.dropFirst(meter.unit.count + 1)) : detail
        return rest.replacingOccurrences(of: " ", with: " · ")
    }
}

/// A horizontal scale from 30 to 130 dB SPL (or -100 to 0 dB): the level as a bar,
/// green, yellow within 5 dB of the limit and red over it, a mark at the limit and a small triangle
/// over the maximum.
struct RemoteScaleBar: View {
    let level: Double?
    let maximum: Double?
    let limit: Double?
    let spl: Bool
    let limitTint: Color

    private var range: ClosedRange<Double> { spl ? 30...130 : -100...0 }

    private func x(_ value: Double, _ width: CGFloat) -> CGFloat {
        width * CGFloat(min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }

    private var fill: Color {
        guard let level, let limit else { return .green }
        return level >= limit ? .red : level > limit - 5 ? .yellow : .green
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3).fill(fill.gradient).frame(width: level.map { x($0, w) } ?? 0)
                    if let limit {
                        Rectangle().fill(limitTint).frame(width: 2, height: 16).offset(x: x(limit, w) - 1)
                    }
                    if let maximum, maximum > range.lowerBound {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .offset(x: x(maximum, w) - 4, y: -11)
                    }
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(Int(range.lowerBound))")
                Spacer()
                Text("\(Int((range.lowerBound + range.upperBound) / 2))")
                Spacer()
                Text("\(Int(range.upperBound))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(.top, 8)
    }
}

// MARK: - Shared pieces

struct StartStopButton: View {
    let running: Bool
    let start: String
    let stop: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(running ? stop : start, systemImage: running ? "stop.fill" : "play.fill")
                .frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent)
        .tint(running ? .red : .accentColor)
        .controlSize(.large)
    }
}

/// Frequency response on a log axis from 20 Hz to 20 kHz.
struct ResponseChart: View {
    let curves: [RemoteCurve]
    /// Drawn thick, in the text colour, over the curves.
    var average: RemoteCurve? = nil
    /// The name of a curve to draw thicker than the others.
    var highlighted: String? = nil
    /// Drawn thin under the curves: the ticked measurements under the live curves.
    var background: [RemoteCurve] = []
    /// A fixed level axis (phase, coherence); nil fits the levels shown.
    var yFixed: ClosedRange<Double>? = nil
    var yLabel = "dB"
    /// Unit in the data tip.
    var unit = "dB"
    /// Draws the curves as dots, as the Mac draws live phase.
    var dots = false
    /// Shown when there is nothing to draw; empty shows a blank chart area.
    let empty: String
    /// The frequency under the finger, while it is on the chart.
    @State private var touched: Double?

    private struct Point: Identifiable {
        let id: Int
        let series: String
        let frequency: Double
        let level: Double
        let width: Double
    }

    /// Series names are numbered, as two measurements can share a name.
    private func seriesName(_ index: Int) -> String { "\(index)" }

    private func backgroundName(_ index: Int) -> String { "b\(index)" }

    private var backgroundPoints: [Point] {
        var result: [Point] = []
        for (n, curve) in background.enumerated() {
            for i in curve.frequencies.indices where i < curve.levels.count {
                result.append(Point(id: result.count, series: backgroundName(n),
                                    frequency: curve.frequencies[i], level: curve.levels[i], width: 1))
            }
        }
        return result
    }

    private var points: [Point] {
        var result: [Point] = []
        for (n, curve) in curves.enumerated() {
            let width = curve.name == highlighted || !background.isEmpty ? 2.5 : 1.5
            for i in curve.frequencies.indices where i < curve.levels.count {
                result.append(Point(id: result.count, series: seriesName(n),
                                    frequency: curve.frequencies[i], level: curve.levels[i], width: width))
            }
        }
        return result
    }

    private var averagePoints: [Point] {
        guard let average else { return [] }
        return average.frequencies.indices.compactMap { i in
            i < average.levels.count
                ? Point(id: i, series: "average", frequency: average.frequencies[i], level: average.levels[i], width: 3)
                : nil
        }
    }

    private var yDomain: ClosedRange<Double> {
        if let yFixed { return yFixed }
        let levels = curves.flatMap(\.levels) + background.flatMap(\.levels) + (average?.levels ?? [])
        guard let high = levels.max(), let low = levels.min() else { return 40...100 }
        let top = (high / 10).rounded(.up) * 10 + 5
        let bottom = max((low / 10).rounded(.down) * 10, top - 60)
        return bottom...top
    }

    var body: some View {
        if curves.isEmpty && background.isEmpty && average == nil {
            if empty.isEmpty {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3))
            } else {
                ContentUnavailableView(empty, systemImage: "chart.xyaxis.line")
            }
        } else {
            Chart {
                ForEach(backgroundPoints) { point in
                    LineMark(x: .value("Frequency", point.frequency),
                             y: .value("Level", point.level),
                             series: .value("Curve", point.series))
                        .foregroundStyle(by: .value("Curve", point.series))
                        .lineStyle(StrokeStyle(lineWidth: point.width))
                        .opacity(0.8)
                }
                ForEach(points) { point in
                    if dots {
                        PointMark(x: .value("Frequency", point.frequency),
                                  y: .value("Level", point.level))
                            .foregroundStyle(by: .value("Curve", point.series))
                            .symbolSize(10)
                    } else {
                        LineMark(x: .value("Frequency", point.frequency),
                                 y: .value("Level", point.level),
                                 series: .value("Curve", point.series))
                            .foregroundStyle(by: .value("Curve", point.series))
                            .lineStyle(StrokeStyle(lineWidth: point.width))
                    }
                }
                ForEach(averagePoints) { point in
                    LineMark(x: .value("Frequency", point.frequency),
                             y: .value("Level", point.level),
                             series: .value("Curve", point.series))
                        .foregroundStyle(Color.primary)
                        .lineStyle(StrokeStyle(lineWidth: point.width))
                }
                if let touched {
                    RuleMark(x: .value("Frequency", touched))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard let anchor = proxy.plotFrame else { return }
                                let x = drag.location.x - geo[anchor].origin.x
                                if let f: Double = proxy.value(atX: x) {
                                    touched = min(max(f, 20), 20_000)
                                }
                            }
                            .onEnded { _ in touched = nil })
                    if let touched, let anchor = proxy.plotFrame, let x = proxy.position(forX: touched) {
                        let plot = geo[anchor]
                        // Inside the plot, beside the finger: to its right on the left half, to its left on the right.
                        let width: CGFloat = 200
                        let onLeft = x > plot.width / 2
                        let left = plot.minX + (onLeft ? x - width - 12 : x + 12)
                        DataTip(frequency: touched, rows: tipRows(at: touched), unit: unit)
                            .frame(width: width)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(x: min(max(left, plot.minX), plot.maxX - width), y: plot.minY + 4)
                            .allowsHitTesting(false)
                    }
                    }
                }
            }
            .chartForegroundStyleScale(domain: curves.indices.map { seriesName($0) } + background.indices.map { backgroundName($0) },
                                       range: (curves + background).map { Color(remoteHex: $0.color) })
            .chartLegend(.hidden)
            .chartXScale(domain: 20.0...20_000.0, type: .log)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let f = value.as(Double.self) {
                            Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                        }
                    }
                }
            }
            .chartYAxisLabel(yLabel)
            .chartPlotStyle { $0.clipped() }
        }
    }
}

extension ResponseChart {
    /// Each curve's level at `frequency`, for the data tip, average last.
    func tipRows(at frequency: Double) -> [DataTip.Row] {
        var rows = (curves + background).compactMap { curve in
            curve.level(at: frequency).map { DataTip.Row(name: curve.name, color: Color(remoteHex: curve.color), level: $0) }
        }
        if let average, let level = average.level(at: frequency) {
            rows.append(DataTip.Row(name: "Average", color: .primary, level: level))
        }
        return rows
    }
}

extension RemoteCurve {
    /// The level at `frequency`, interpolated on a log frequency axis. Nil outside the curve.
    func level(at frequency: Double) -> Double? {
        let count = min(frequencies.count, levels.count)
        guard count > 0, frequency >= frequencies[0], frequency <= frequencies[count - 1] else { return nil }
        var lo = 0
        var hi = count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= frequency { lo = mid } else { hi = mid }
        }
        let f0 = frequencies[lo]
        let f1 = frequencies[hi]
        guard f1 > f0 else { return levels[lo] }
        let w = log(frequency / f0) / log(f1 / f0)
        return levels[lo] + w * (levels[hi] - levels[lo])
    }
}

/// The readout under the finger: the frequency, then each curve's level in its colour.
struct DataTip: View {
    struct Row: Identifiable {
        let name: String
        let color: Color
        let level: Double
        var id: String { name }
    }

    let frequency: Double
    let rows: [Row]
    var unit = "dB"

    private func levelText(_ level: Double) -> String {
        switch unit {
        case "": return String(format: "%.2f", level)
        case "°": return String(format: "%.0f°", level)
        default: return String(format: "%.1f %@", level, unit)
        }
    }

    private var frequencyText: String {
        frequency >= 1000 ? String(format: "%.2f kHz", frequency / 1000) : String(format: "%.0f Hz", frequency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(frequencyText).font(.callout.bold()).monospacedDigit()
            ForEach(Array(rows.prefix(10).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(row.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(levelText(row.level)).monospacedDigit()
                }
                .font(.caption)
            }
            if rows.count > 10 {
                Text("and \(rows.count - 10) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    /// A keyboard with digits and a Return key on the iPad.
    @ViewBuilder func numberKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }

    /// Grouped sections on the iPad; the closest style on the Mac, where this library is also built.
    @ViewBuilder func remoteListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}

extension Color {
    /// Reads "#RRGGBB"; anything else is grey.
    init(remoteHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
#endif
