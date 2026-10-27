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
            Toggle("Average", isOn: Binding(get: { state.showAverage },
                                            set: { client.send(.showAverage($0)) }))
                .fixedSize()
                .disabled(state.traces.filter(\.visible).count < 2)
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
            if state.levelCheckRunning {
                ForEach(Array(state.levelMeters.enumerated()), id: \.offset) { _, meter in
                    PeakMeterRow(meter: meter)
                }
            }
        } header: {
            Text("Input levels")
        } footer: {
            Text(state.levelCheckRunning
                 ? "Peaks over the last sweep. Aim for -20 to -6 dBFS; red means the input clipped since the check started."
                 : "Plays the sweep in a loop at its level and meters each input. Measure stops it.")
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StartStopButton(running: state.liveRunning, start: "Start Live", stop: "Stop Live") {
                    client.send(state.liveRunning ? .stopLive : .startLive)
                }
                Spacer()
                ForEach(state.liveCurves, id: \.name) { curve in
                    HStack(spacing: 4) {
                        Circle().fill(Color(remoteHex: curve.color)).frame(width: 8, height: 8)
                        Text(curve.name).font(.caption)
                    }
                }
            }
            ResponseChart(curves: state.liveCurves,
                          empty: state.liveRunning ? "Waiting for audio…" : "Live is stopped")
        }
        .padding()
    }
}

// MARK: - Generator

struct GeneratorTab: View {
    let client: RemoteClient
    let state: RemoteState
    @State private var level: Double = -20
    @State private var dragging = false

    private var range: ClosedRange<Double> {
        let top = max(state.generatorMaxLevel, -79)
        return -80...top
    }

    var body: some View {
        VStack(spacing: 24) {
            if !state.generatorSignal.isEmpty {
                Text(state.generatorSignal).font(.title3).foregroundStyle(.secondary)
            }
            Text(String(format: "%.1f dBFS", level))
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
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
            StartStopButton(running: state.generatorRunning, start: "Start Generator", stop: "Stop Generator") {
                client.send(state.generatorRunning ? .stopGenerator : .startGenerator)
            }
            Spacer()
        }
        .padding(32)
        .onAppear { level = state.generatorLevel }
        .onChange(of: state.generatorLevel) { _, new in
            if !dragging { level = new }
        }
    }

    private func nudge(_ step: Double) {
        level = min(max(level + step, range.lowerBound), range.upperBound)
        client.send(.setGeneratorLevel(level))
    }
}

// MARK: - SPL monitor

struct MonitorTab: View {
    let client: RemoteClient
    let state: RemoteState

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                StartStopButton(running: state.monitorRunning, start: "Start Monitoring", stop: "Stop Monitoring") {
                    client.send(state.monitorRunning ? .stopMonitor : .startMonitor)
                }
                Button("Reset") { client.send(.resetMonitor) }
                    .buttonStyle(.bordered)
                Spacer()
            }
            if state.meters.isEmpty {
                ContentUnavailableView("No meters", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Start monitoring to see the levels."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(state.meters.enumerated()), id: \.offset) { _, meter in
                            MeterTile(meter: meter)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct MeterTile: View {
    let meter: RemoteMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meter.label).font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(meter.value.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(meter.unit).foregroundStyle(.secondary)
            }
            .foregroundStyle(meter.overLimit ? Color.red : Color.primary)
            if let maximum = meter.maximum {
                Text(String(format: "Max %.1f", maximum)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
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

    private var points: [Point] {
        var result: [Point] = []
        for (n, curve) in curves.enumerated() {
            let width = curve.name == highlighted ? 2.5 : 1.5
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
        let levels = curves.flatMap(\.levels) + (average?.levels ?? [])
        guard let high = levels.max(), let low = levels.min() else { return 40...100 }
        let top = (high / 10).rounded(.up) * 10 + 5
        let bottom = max((low / 10).rounded(.down) * 10, top - 60)
        return bottom...top
    }

    var body: some View {
        if curves.isEmpty {
            ContentUnavailableView(empty, systemImage: "chart.xyaxis.line")
        } else {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Frequency", point.frequency),
                             y: .value("Level", point.level),
                             series: .value("Curve", point.series))
                        .foregroundStyle(by: .value("Curve", point.series))
                        .lineStyle(StrokeStyle(lineWidth: point.width))
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
                        .annotation(position: .top, alignment: .center, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            DataTip(frequency: touched, rows: tipRows(at: touched))
                        }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
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
                }
            }
            .chartForegroundStyleScale(domain: curves.indices.map { seriesName($0) },
                                       range: curves.map { Color(remoteHex: $0.color) })
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
            .chartYAxisLabel("dB")
            .chartPlotStyle { $0.clipped() }
        }
    }
}

extension ResponseChart {
    /// Each curve's level at `frequency`, for the data tip, average last.
    func tipRows(at frequency: Double) -> [DataTip.Row] {
        var rows = curves.compactMap { curve in
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
                    Text(String(format: "%.1f dB", row.level)).monospacedDigit()
                }
                .font(.caption)
            }
            if rows.count > 10 {
                Text("and \(rows.count - 10) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(minWidth: 150, maxWidth: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
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
