#if canImport(SwiftUI) && canImport(Network)
import Charts
import MeasureRemote
import SwiftUI

/// The whole remote: a search screen until a Mac is found, then tabs for each part of Measure.
public struct RemoteRootView: View {
    @State private var client = RemoteClient()

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
                MeasureTab(client: client, state: state)
                    .tabItem { Label("Measure", systemImage: "waveform.path.ecg") }
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

// MARK: - Measure

struct MeasureTab: View {
    let client: RemoteClient
    let state: RemoteState
    @State private var position = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Position").font(.headline)
                TextField("Position name", text: $position)
                    .textFieldStyle(.roundedBorder)
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

                Text("Measurements").font(.headline).padding(.top, 8)
                List(Array(state.traces.reversed())) { trace in
                    Button {
                        client.send(.select(trace.id))
                    } label: {
                        HStack {
                            Circle().fill(Color(remoteHex: trace.color)).frame(width: 10, height: 10)
                            VStack(alignment: .leading) {
                                Text(trace.name)
                                Text(trace.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if trace.id == state.selected {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .listStyle(.plain)
            }
            .frame(width: 300)
            .padding()
            Divider()
            ResponseChart(curves: state.selectedCurve.map { [$0] } ?? [],
                          empty: "No measurement yet")
                .padding()
        }
        .onAppear { position = state.position }
        .onChange(of: state.position) { _, new in
            if !editing { position = new }
        }
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
    let empty: String

    private struct Point: Identifiable {
        let id: Int
        let series: String
        let frequency: Double
        let level: Double
    }

    private var points: [Point] {
        var result: [Point] = []
        for curve in curves {
            for i in curve.frequencies.indices where i < curve.levels.count {
                result.append(Point(id: result.count, series: curve.name,
                                    frequency: curve.frequencies[i], level: curve.levels[i]))
            }
        }
        return result
    }

    private var yDomain: ClosedRange<Double> {
        let levels = curves.flatMap(\.levels)
        guard let high = levels.max(), let low = levels.min() else { return 40...100 }
        let top = (high / 10).rounded(.up) * 10 + 5
        let bottom = max((low / 10).rounded(.down) * 10, top - 60)
        return bottom...top
    }

    var body: some View {
        if curves.isEmpty {
            ContentUnavailableView(empty, systemImage: "chart.xyaxis.line")
        } else {
            Chart(points) { point in
                LineMark(x: .value("Frequency", point.frequency),
                         y: .value("Level", point.level),
                         series: .value("Curve", point.series))
                    .foregroundStyle(by: .value("Curve", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartForegroundStyleScale(domain: curves.map(\.name),
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
