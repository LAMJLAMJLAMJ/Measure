#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI

let frequencyTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

func frequencyLabel(_ f: Double) -> String {
    guard f >= 1000 else { return "\(Int(f.rounded()))" }
    let k = f / 1000
    return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
}

struct EmptyState: View {
    let text: String
    var body: some View {
        ContentUnavailableView(text, systemImage: "chart.xyaxis.line")
    }
}

// MARK: - Frequency response

struct FrequencyResponseView: View {
    @Environment(AppModel.self) private var model
    @Binding var showVirtualEQ: Bool
    @AppStorage("showTarget") private var showTarget = false
    @State private var range: Double = 50
    @State private var zoom = ChartZoom()

    /// The whole frequency axis, Hz.
    static let fullFrequencies: ClosedRange<Double> = 10...20_000

    var body: some View {
        @Bindable var model = model
        let traces = model.visibleTraces.filter(\.hasResponse)
        let series = traces.map { ($0, $0.displayResponse(smoothing: model.smoothing, calibration: model.calibration(for: $0))) }
        let predicted = showVirtualEQ ? self.predicted(series) : nil
        // The target sits on the selected trace, or on the first shown one.
        let targetPoints: [TargetPoint]? = showTarget
            ? (traces.first { $0.id == model.selection } ?? traces.first).map { model.targetPoints(alignedTo: model.calibratedResponse($0)) }
            : nil
        let top = (series.flatMap { $0.1.filter { $0.x >= 20 }.map(\.y) }.max() ?? 0).rounded(.up) + 5
        // Zooming out goes past the preset range, down to 150 dB.
        let yFull = (top - 150)...(top + 10)
        let yShown = zoom.y == nil ? (top - range)...top : zoom.yDomain(yFull)

        VStack(alignment: .leading) {
            HStack {
                Picker("Smoothing", selection: $model.smoothing) {
                    ForEach(Smoothing.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 180)
                Picker("Range", selection: $range) {
                    Text("30 dB").tag(30.0)
                    Text("50 dB").tag(50.0)
                    Text("80 dB").tag(80.0)
                }
                .frame(width: 140)
                .onChange(of: range) { zoom.y = nil }
                ZoomControls(zoom: $zoom, xFull: FrequencyResponseView.fullFrequencies,
                             yFull: yFull, xLog: true, yStart: (top - range)...top)
                Spacer()
                // One line, cut short when the Virtual EQ panel narrows the view: wrapping made it tall
                // enough to push the whole window out of shape.
                Text("Levels in dBFS; mic calibration applied where set\(windowNote)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .help("Levels in dBFS; mic calibration applied where set\(windowNote)")
                Menu {
                    ForEach(FrequencyResponse.AverageMethod.allCases) { method in
                        Button("\(method.rawValue) Average of Shown") { model.average(traces.map(\.id), method: method) }
                    }
                } label: {
                    Label("Average", systemImage: "sum")
                }
                .fixedSize()
                .disabled(traces.count < 2)
                .help("Add a trace with the average of the ticked traces' responses: power (RMS) for a spatial average, or dB")
                TargetControl()
                Toggle(isOn: $showVirtualEQ) { Label("Virtual EQ", systemImage: "slider.vertical.3") }
                    .toggleStyle(.button)
                    .help("Show the Virtual EQ panel")
            }
            if series.isEmpty {
                EmptyState(text: "Tick a trace in the list to show it")
            } else {
                Chart {
                    if let targetPoints {
                        TargetMarks(points: targetPoints, tolerance: model.target.tolerance > 0)
                    }
                    ForEach(series, id: \.0.id) { item in
                        let trace = item.0
                        ForEach(item.1) { p in
                            LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y),
                                     series: .value("Trace", trace.id.uuidString))
                                .foregroundStyle(trace.color)
                                .lineStyle(StrokeStyle(lineWidth: trace.id == model.selection ? 2 : 1.2))
                        }
                    }
                    if let predicted {
                        ForEach(predicted.1) { p in
                            LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y),
                                     series: .value("Trace", "eq-prediction"))
                                .foregroundStyle(predicted.0.color)
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        }
                    }
                }
                .chartXScale(domain: zoom.xDomain(FrequencyResponseView.fullFrequencies), type: .log)
                .chartYScale(domain: yShown)
                .chartPlotStyle { $0.clipped() }
                .chartXAxis {
                    AxisMarks(values: zoomedFrequencyTicks(in: zoom.xDomain(FrequencyResponseView.fullFrequencies))) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
                    }
                }
                .chartXAxisLabel("Hz")
                .chartYAxisLabel("dB")
                .chartLegend(.hidden)
                .frequencyDataTip(series.map { TipSeries(id: $0.0.id.uuidString, name: $0.0.info.name, color: $0.0.color, points: $0.1) }
                                  + (predicted.map { [TipSeries(id: "eq", name: "\($0.0.info.name) with EQ", color: $0.0.color, points: $0.1)] } ?? [])
                                  + targetTip(targetPoints), zoom: $zoom)
                .clipped()
                .zoomScrollBars($zoom, xFull: FrequencyResponseView.fullFrequencies, yFull: yFull, xLog: true, yShown: yShown)
            }
        }
    }
}

extension FrequencyResponseView {
    /// The selected trace with its Virtual EQ added, drawn dashed while the panel is open.
    func predicted(_ series: [(Trace, [ChartPoint])]) -> (Trace, [ChartPoint])? {
        guard let item = series.first(where: { $0.0.id == model.selection }), !item.0.activeEQ.isEmpty else { return nil }
        let trace = item.0
        return (trace, item.1.map { ChartPoint(x: $0.x, y: $0.y + ParametricEQ.gainDB(trace.activeEQ, at: $0.x, sampleRate: trace.eqSampleRate)) })
    }

    /// The target as a data tip series.
    func targetTip(_ points: [TargetPoint]?) -> [TipSeries] {
        guard let points else { return [] }
        return [TipSeries(id: "target", name: "Target", color: .gray, points: points.map { ChartPoint(x: $0.x, y: $0.y) })]
    }

    /// The selected trace's window, when it is not the standard one.
    var windowNote: String {
        guard let trace = model.selectedTrace, trace.impulseResponse != nil, trace.window != .standard else { return "" }
        return String(format: "; %@ window %g to %g ms", trace.info.name, -trace.window.left * 1000, trace.window.right * 1000)
    }
}

// MARK: - Phase

struct PhaseView: View {
    @Environment(AppModel.self) private var model
    @State private var zoom = ChartZoom()
    private let yFull: ClosedRange<Double> = -180...180

    var body: some View {
        let series = model.visibleTraces.compactMap { t in t.displayPhase().map { (t, $0) } }
        VStack(alignment: .leading) {
            HStack {
                ZoomControls(zoom: $zoom, xFull: FrequencyResponseView.fullFrequencies, yFull: yFull, xLog: true)
                Spacer()
                Text("Wrapped phase, with the delay to each trace's direct sound removed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if series.isEmpty {
                EmptyState(text: "Tick a trace with phase in the list to show it")
            } else {
                Chart {
                    ForEach(series, id: \.0.id) { item in
                        let trace = item.0
                        ForEach(item.1) { p in
                            LineMark(x: .value("Frequency", p.x), y: .value("Phase", p.y),
                                     series: .value("Trace", trace.id.uuidString))
                                .foregroundStyle(trace.color)
                                .lineStyle(StrokeStyle(lineWidth: trace.id == model.selection ? 2 : 1.2))
                        }
                    }
                }
                .chartXScale(domain: zoom.xDomain(FrequencyResponseView.fullFrequencies), type: .log)
                .chartYScale(domain: zoom.yDomain(yFull))
                .chartPlotStyle { $0.clipped() }
                .chartXAxis {
                    AxisMarks(values: zoomedFrequencyTicks(in: zoom.xDomain(FrequencyResponseView.fullFrequencies))) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
                    }
                }
                .chartYAxis {
                    if zoom.y == nil { AxisMarks(values: [-180, -90, 0, 90, 180]) } else { AxisMarks() }
                }
                .chartXAxisLabel("Hz")
                .chartYAxisLabel("degrees")
                .chartLegend(.hidden)
                .frequencyDataTip(series.map { TipSeries(id: $0.0.id.uuidString, name: $0.0.info.name, color: $0.0.color, points: $0.1) },
                                  unit: "°", zoom: $zoom)
                .clipped()
                .zoomScrollBars($zoom, xFull: FrequencyResponseView.fullFrequencies, yFull: yFull, xLog: true)
                Text("Phase within each trace's window. Shorten the window on the Impulse view to leave out reflections and clean it up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Delay

struct DelayView: View {
    @Environment(AppModel.self) private var model

    /// Speed of sound at 20 °C, m/s.
    private let speedOfSound = 343.0

    var body: some View {
        let traces = model.visibleTraces.filter { $0.impulseResponse != nil }
        let reference = traces.first { $0.id == model.selection } ?? traces.first
        VStack(alignment: .leading, spacing: 12) {
            if let reference {
                Text("Arrival of the direct sound, relative to \(reference.info.name)").font(.headline)
                Table(traces) {
                    TableColumn("Trace") { Text($0.info.name) }
                    TableColumn("Arrival ms") { Text(String(format: "%.2f", arrival($0) * 1000)) }
                    TableColumn("Relative ms") { Text(String(format: "%+.2f", (arrival($0) - arrival(reference)) * 1000)) }
                    TableColumn("Relative m") { Text(String(format: "%+.2f", (arrival($0) - arrival(reference)) * speedOfSound)) }
                    TableColumn("Timing") { Text(timing($0)).foregroundStyle(.secondary) }
                }
                .font(.body.monospacedDigit())
                .frame(minHeight: 120, maxHeight: 220)
                ImpulseView(initialMode: .etc, initialSpan: 20, storageKey: "delay")
            } else {
                EmptyState(text: "Tick impulse responses in the list to compare their arrival times")
            }
        }
    }

    private func arrival(_ trace: Trace) -> Double { Double(trace.onset) / trace.info.sampleRate }

    private func timing(_ trace: Trace) -> String {
        switch trace.info.timingReference {
        case .loopback: return "Absolute (loopback)"
        case .generated: return "Includes interface latency"
        case nil: return "From the file start"
        }
    }
}

// MARK: - Impulse and ETC

struct ImpulseView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case etc = "ETC", impulse = "Impulse"
        var id: String { rawValue }
    }

    private enum Edge { case left, right }

    @Environment(AppModel.self) private var model
    // Remembered between visits and launches, separately for each place the view is used.
    @AppStorage private var mode: Mode
    @AppStorage private var span: Double
    /// Show the frequency response window of the selected trace and let it be dragged.
    let editsWindow: Bool
    @State private var dragging: Edge?
    @State private var liveWindow: ResponseWindow?
    @State private var zoom = ChartZoom()
    @State private var box: ZoomBox?

    init(initialMode: Mode = .etc, initialSpan: Double = 300, editsWindow: Bool = false, storageKey: String = "impulse") {
        _mode = AppStorage(wrappedValue: initialMode, "\(storageKey).mode")
        _span = AppStorage(wrappedValue: initialSpan, "\(storageKey).span")
        self.editsWindow = editsWindow
    }

    var body: some View {
        let traces = model.visibleTraces.filter { $0.impulseResponse != nil }
        // All traces share the time axis of the selected (or first) trace, so relative arrivals show.
        let reference = traces.first { $0.id == model.selection } ?? traces.first
        let window = editsWindow ? reference.map { liveWindow ?? $0.window } : nil
        VStack(alignment: .leading) {
            HStack {
                Picker("Show", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 180)
                Picker("Span", selection: $span) {
                    Text("20 ms").tag(20.0)
                    Text("100 ms").tag(100.0)
                    Text("300 ms").tag(300.0)
                    Text("1 s").tag(1000.0)
                    Text("All").tag(0.0)
                }
                .frame(width: 140)
                .onChange(of: span) { zoom = ChartZoom() }
                .onChange(of: mode) { zoom = ChartZoom() }
                if let reference {
                    ZoomControls(zoom: $zoom, xFull: timeRange(reference, window: window), yFull: levelRange)
                }
                Spacer()
                Text("Time from the selected trace's direct sound").font(.caption).foregroundStyle(.secondary)
            }
            if let reference, let window {
                windowControls(reference, window, traces: traces)
            }
            if let reference {
                let zero = reference.onset
                let xFull = timeRange(reference, window: window)
                let shown = zoom.xDomain(xFull)
                let yLabel = mode == .etc ? "Level" : "Amplitude"
                let yRange = levelRange
                Chart {
                    ForEach(traces) { trace in
                        ForEach(points(trace, zero: zero, shown: shown)) { p in
                            LineMark(x: .value("Time", p.x), y: .value(yLabel, p.y),
                                     series: .value("Trace", trace.id.uuidString))
                                .foregroundStyle(trace.color)
                                .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    }
                    if let window {
                        ForEach(windowCurve(window)) { p in
                            LineMark(x: .value("Time", p.x),
                                     y: .value(yLabel, mode == .etc ? max(-100, 20 * log10(max(p.y, 1e-10))) : p.y),
                                     series: .value("Trace", "window"))
                                .foregroundStyle(Color.accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        RectangleMark(xStart: .value("Time", -window.left * 1000), xEnd: .value("Time", window.right * 1000),
                                      yStart: .value(yLabel, yRange.lowerBound), yEnd: .value(yLabel, yRange.upperBound))
                            .foregroundStyle(Color.accentColor.opacity(0.08))
                        RuleMark(x: .value("Time", -window.left * 1000))
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: dragging == .left ? 2.5 : 1.5))
                        RuleMark(x: .value("Time", window.right * 1000))
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: dragging == .right ? 2.5 : 1.5))
                    }
                }
                .chartXScale(domain: shown)
                .chartYScale(domain: zoom.yDomain(yRange))
                .chartPlotStyle { $0.clipped() }
                .chartXAxisLabel("ms")
                .chartYAxisLabel(mode == .etc ? "dB" : "normalised")
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(dragGesture(proxy: proxy, geo: geo, window: window, reference: reference))
                        if let box, let anchor = proxy.plotFrame {
                            box.view(in: geo[anchor])
                        }
                    }
                }
                .clipped()
                .zoomScrollBars($zoom, xFull: xFull, yFull: yRange)
                if let window {
                    WindowPreview(trace: reference, window: window)
                        .frame(height: 150)
                }
            } else {
                EmptyState(text: "No impulse responses shown")
            }
        }
    }

    @ViewBuilder
    private func windowControls(_ reference: Trace, _ window: ResponseWindow, traces: [Trace]) -> some View {
        let id = reference.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Window for \(reference.info.name)").fontWeight(.medium)
                Spacer()
                Button("Apply to All Shown") { commit(window, to: Set(traces.map(\.id))) }
                    .help("Use this window for every ticked impulse response")
                Button("Reset") { commit(.standard, to: [id]) }
                    .help("Back to Hann 5 ms before and Tukey 1 s after the direct sound")
            }
            sideControls("Left", shape: binding(window, \.leftShape, id),
                         ms: scaled(binding(window, \.left, id), by: 1000, in: 0...500),
                         taper: scaled(binding(window, \.leftTaper, id), by: 100, in: 0...100),
                         showsTaper: window.leftShape == .tukey, suffix: "ms before the direct sound")
            sideControls("Right", shape: binding(window, \.rightShape, id),
                         ms: scaled(binding(window, \.right, id), by: 1000, in: 1...60_000),
                         taper: scaled(binding(window, \.rightTaper, id), by: 100, in: 0...100),
                         showsTaper: window.rightShape == .tukey, suffix: "ms after the direct sound")
        }
        .font(.callout)
        .textFieldStyle(.roundedBorder)
    }

    private func sideControls(_ title: String, shape: Binding<ResponseWindow.Shape>, ms: Binding<Double>,
                              taper: Binding<Double>, showsTaper: Bool, suffix: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 40, alignment: .leading)
            Picker(title, selection: shape) {
                ForEach(ResponseWindow.Shape.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            TextField(title, value: ms, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 70)
            Text(suffix)
            if showsTaper {
                TextField("Taper", value: taper, format: .number.precision(.fractionLength(0)))
                    .frame(width: 50)
                Text("% taper")
            }
            Spacer()
        }
    }

    /// A binding to one field of the window that saves the whole window to the trace when set.
    private func binding<T>(_ window: ResponseWindow, _ path: WritableKeyPath<ResponseWindow, T>, _ id: UUID) -> Binding<T> {
        Binding(get: { window[keyPath: path] },
                set: { var w = window; w[keyPath: path] = $0; commit(w, to: [id]) })
    }

    /// Shows a value multiplied by `factor` (seconds as ms, fractions as %), clamped to `range` when set.
    private func scaled(_ value: Binding<Double>, by factor: Double, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue * factor },
                set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) / factor })
    }

    /// The window's gain for drawing, in ms from the onset, dropping to zero just outside its edges.
    private func windowCurve(_ w: ResponseWindow) -> [ChartPoint] {
        let n = 400
        var points = [ChartPoint(x: -w.left * 1000 - 0.001, y: 0)]
        for k in 0...n {
            let t = -w.left + (w.left + w.right) * Double(k) / Double(n)
            let g = t < 0 ? w.leftShape.gain((t + w.left) / w.left, taper: w.leftTaper)
                          : w.rightShape.gain((w.right - t) / w.right, taper: w.rightTaper)
            points.append(ChartPoint(x: t * 1000, y: g))
        }
        points.append(ChartPoint(x: w.right * 1000 + 0.001, y: 0))
        return points
    }

    private func commit(_ window: ResponseWindow, to ids: Set<UUID>) {
        model.setWindow(window, for: ids)
    }

    /// The level axis, whole.
    private var levelRange: ClosedRange<Double> { mode == .etc ? -100...0 : -1...1 }

    /// How far before the direct sound the chart starts: a little, and before the window's left edge.
    private func preRoll(_ window: ResponseWindow?) -> Double { max(0.005, (window?.left ?? 0) + 0.002) }

    /// The time axis, whole, in ms from the reference's direct sound.
    private func timeRange(_ reference: Trace, window: ResponseWindow?) -> ClosedRange<Double> {
        let zero = reference.onset
        let fs = reference.info.sampleRate
        let lo = -min(preRoll(window), Double(zero) / fs) * 1000
        let hi = span == 0 ? Double((reference.impulseResponse?.count ?? zero) - zero) / fs * 1000 : lo + span
        return lo...max(hi, lo + 1)
    }

    /// Drags whichever window edge the drag starts near; anywhere else it drags out a box to zoom into.
    /// The response is recomputed when a window drag ends.
    private func dragGesture(proxy: ChartProxy, geo: GeometryProxy, window: ResponseWindow?, reference: Trace) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let anchor = proxy.plotFrame else { return }
                let origin = geo[anchor].origin.x
                if dragging == nil && box == nil {
                    let startX = value.startLocation.x - origin
                    let leftX = window.flatMap { proxy.position(forX: -$0.left * 1000) } ?? .infinity
                    let rightX = window.flatMap { proxy.position(forX: $0.right * 1000) } ?? .infinity
                    let dl = abs(startX - leftX), dr = abs(startX - rightX)
                    if min(dl, dr) < 12 { dragging = dl <= dr ? .left : .right }
                }
                guard dragging != nil, let window else {
                    box = ZoomBox(start: value.startLocation, end: value.location)
                    return
                }
                guard let ms: Double = proxy.value(atX: value.location.x - origin) else { return }
                var w = liveWindow ?? window
                switch dragging {
                case .left: w.left = min(max(0, -ms / 1000), 0.5)
                case .right: w.right = max(0.001, ms / 1000)
                case nil: return
                }
                liveWindow = w
            }
            .onEnded { value in
                if let liveWindow { commit(liveWindow, to: [reference.id]) }
                if box != nil, let anchor = proxy.plotFrame {
                    ZoomBox(start: value.startLocation, end: value.location).apply(to: &zoom, proxy: proxy, plot: geo[anchor])
                }
                liveWindow = nil
                dragging = nil
                box = nil
            }
    }

    /// The trace's points across `shown`, ms from sample `zero`, so a zoomed chart keeps its detail.
    private func points(_ trace: Trace, zero: Int, shown: ClosedRange<Double>) -> [ChartPoint] {
        guard let ir = trace.impulseResponse else { return [] }
        let fs = trace.info.sampleRate
        let start = min(max(0, zero + Int((shown.lowerBound / 1000 * fs).rounded(.down))), ir.count)
        // Another trace can be shorter than the selected one's onset, so never let the range run backwards.
        let end = max(start, min(ir.count, zero + Int((shown.upperBound / 1000 * fs).rounded(.up)) + 1))
        if mode == .etc {
            return ChartData.points(trace.energyTime, range: start..<end, zero: zero, sampleRate: fs, envelope: true)
        }
        let peak = max(ir.map(abs).max() ?? 1, .leastNonzeroMagnitude)
        return ChartData.points(ir, range: start..<end, zero: zero, sampleRate: fs).map { ChartPoint(x: $0.x, y: $0.y / peak) }
    }
}

/// Small frequency response of one trace under the impulse chart. While a window edge is dragged it
/// shows the response with the new window over the current one in grey.
struct WindowPreview: View {
    private struct Key: Hashable {
        let trace: UUID
        let window: ResponseWindow
        let smoothing: Smoothing
    }

    @Environment(AppModel.self) private var model
    let trace: Trace
    let window: ResponseWindow
    @State private var preview: [ChartPoint] = []
    @State private var previewFor: ResponseWindow?

    var body: some View {
        let current = trace.displayResponse(smoothing: model.smoothing, calibration: model.calibration(for: trace))
        let moving = window != trace.window && previewFor == window
        let levels = (moving ? preview + current : current).filter { $0.x >= 20 }.map(\.y)
        let top = (levels.max() ?? 0).rounded(.up) + 5
        Chart {
            ForEach(current) { p in
                LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Response", "current"))
                    .foregroundStyle(moving ? Color.gray.opacity(0.6) : trace.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            if moving {
                ForEach(preview) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Response", "preview"))
                        .foregroundStyle(trace.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartXScale(domain: 20...20_000, type: .log)
        .chartYScale(domain: (top - 50)...top)
        .chartXAxis {
            AxisMarks(values: frequencyTicks) { value in
                AxisGridLine()
                AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
            }
        }
        .chartYAxisLabel("dB")
        .chartLegend(.hidden)
        .clipped()
        .task(id: Key(trace: trace.id, window: window, smoothing: model.smoothing)) { await compute() }
    }

    private func compute() async {
        guard window != trace.window, let ir = trace.impulseResponse else { return }
        // Let a fast drag settle before recomputing.
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        let onset = trace.onset, fs = trace.info.sampleRate, w = window
        let smoothing = model.smoothing, calibration = model.calibration(for: trace)
        let points = await Task.detached(priority: .userInitiated) {
            Trace.displayPoints(Trace.windowedResponse(ir, onset: onset, sampleRate: fs, window: w).0,
                                smoothing: smoothing, calibration: calibration)
        }.value
        guard !Task.isCancelled else { return }
        preview = points
        previewFor = w
    }
}

// MARK: - Decay

struct DecayView: View {
    @Environment(AppModel.self) private var model
    @State private var bandIndex = -1
    @State private var zoom = ChartZoom()
    private let levelRange: ClosedRange<Double> = -80...0

    var body: some View {
        if let trace = model.selectedTrace, let acoustics = trace.acoustics {
            let params = bandIndex >= 0 && bandIndex < acoustics.bands.count ? acoustics.bands[bandIndex] : acoustics.broadband
            let fs = trace.info.sampleRate
            let timeRange = 0...max(Double(params.decayCurve.count) / fs * 1000, 1)
            let shown = zoom.xDomain(timeRange)
            let first = min(max(0, Int((shown.lowerBound / 1000 * fs).rounded(.down))), params.decayCurve.count)
            let last = max(first, min(params.decayCurve.count, Int((shown.upperBound / 1000 * fs).rounded(.up)) + 1))
            VStack(alignment: .leading) {
                HStack {
                    Picker("Band", selection: $bandIndex) {
                        Text("Broadband").tag(-1)
                        ForEach(acoustics.bands.indices, id: \.self) { i in Text("\(acoustics.bands[i].band!.description) Hz").tag(i) }
                    }
                    .frame(width: 200)
                    ZoomControls(zoom: $zoom, xFull: timeRange, yFull: levelRange)
                    Spacer()
                    Text(summary(params)).font(.callout.monospacedDigit())
                }
                Chart {
                    ForEach(ChartData.points(params.decayCurve, range: first..<last, zero: 0, sampleRate: fs, envelope: true)) { p in
                        LineMark(x: .value("Time", p.x), y: .value("Level", p.y), series: .value("Curve", "Schroeder"))
                            .foregroundStyle(trace.color)
                    }
                    fitLine(params.edtFit, name: "EDT", color: .secondary)
                    fitLine(params.t20Fit, name: "T20", color: .orange)
                    fitLine(params.t30Fit, name: "T30", color: .red)
                    RuleMark(y: .value("Noise", params.noiseFloor))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        .annotation(position: .top, alignment: .trailing) { Text("noise floor").font(.caption2).foregroundStyle(.secondary) }
                }
                .chartXScale(domain: shown)
                .chartYScale(domain: zoom.yDomain(levelRange))
                .chartPlotStyle { $0.clipped() }
                .chartXAxisLabel("ms from onset")
                .chartYAxisLabel("dB")
                .chartForegroundStyleScale(["EDT": Color.secondary, "T20": Color.orange, "T30": Color.red])
                .chartZoomDrag($zoom)
                .clipped()
                .zoomScrollBars($zoom, xFull: timeRange, yFull: levelRange)
                .frame(minHeight: 80)
                Text("Schroeder decay of \(trace.info.name) with the fitted lines (EDT 0 to -10 dB, T20 -5 to -25 dB, T30 -5 to -35 dB). The curve ends where the decay meets the noise. Drag across the chart to zoom in.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            EmptyState(text: "Select a measured or imported impulse response")
        }
    }

    @ChartContentBuilder
    private func fitLine(_ fit: DecayFit?, name: String, color: Color) -> some ChartContent {
        if let fit {
            // Extend each line a little past the range it was fitted over.
            let t0 = max(0, fit.start - 0.02), t1 = fit.end + 0.05
            ForEach([t0, t1], id: \.self) { t in
                LineMark(x: .value("Time", t * 1000), y: .value("Level", fit.intercept + fit.slope * t), series: .value("Fit", name))
                    .foregroundStyle(by: .value("Fit", name))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            }
        }
    }

    private func summary(_ p: BandParameters) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? "–" }
        return "EDT \(f(p.edt))   T20 \(f(p.t20))   T30 \(f(p.t30))   PNR \(Int(p.peakToNoise)) dB"
    }
}

// MARK: - Acoustics tables and band comparison

struct BandRow: Identifiable {
    let id: Int
    let label: String
    let p: BandParameters
}

enum Metric: String, CaseIterable, Identifiable {
    case t30 = "T30", t20 = "T20", edt = "EDT", c50 = "C50", c80 = "C80", d50 = "D50", ts = "Ts"
    var id: String { rawValue }
    func value(_ p: BandParameters) -> Double? {
        switch self {
        case .t30: return p.t30
        case .t20: return p.t20
        case .edt: return p.edt
        case .c50: return p.c50
        case .c80: return p.c80
        case .d50: return p.d50 * 100
        case .ts: return p.ts * 1000
        }
    }
    var unit: String {
        switch self {
        case .c50, .c80: return "dB"
        case .d50: return "%"
        case .ts: return "ms"
        default: return "s"
        }
    }
}

/// Decay curve above the reverberation table.
struct ReverbView: View {
    var body: some View {
        ParametersPanel(set: .reverb, showsDecay: true)
    }
}

/// ISO 3382-1 table for the selected trace, plus a band-by-band comparison of the shown traces.
struct ParametersPanel: View {
    enum ParameterSet {
        case reverb, clarity
        var metrics: [Metric] { self == .reverb ? [.t30, .t20, .edt] : [.c50, .c80, .d50, .ts] }
    }

    let set: ParameterSet
    /// Show the selected trace's decay curve above the table.
    var showsDecay = false
    @Environment(AppModel.self) private var model
    @State private var metric: Metric?

    // The sections are panes with small minimum heights, so all of them fit in a short window; drag
    // the dividers to give one more room.
    var body: some View {
        // The ticked traces, or the selected one when none is ticked.
        let ticked = model.visibleTraces.filter { $0.acoustics != nil }
        let traces = ticked.isEmpty ? [model.selectedTrace].compactMap { $0?.acoustics == nil ? nil : $0 } : ticked
        VSplitView {
            if showsDecay {
                DecayView()
                    .frame(minHeight: 150, idealHeight: 300, maxHeight: .infinity)
                    .padding(.bottom, 6)
            }
            tableSection
                .frame(minHeight: 110, idealHeight: 220, maxHeight: .infinity)
                .padding(.vertical, 6)
            if !traces.isEmpty {
                comparison(traces)
                    .frame(minHeight: 120, idealHeight: 200, maxHeight: .infinity)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var tableSection: some View {
        if let trace = model.selectedTrace, let a = trace.acoustics {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(trace.info.name): ISO 3382-1, octave bands").font(.headline).lineLimit(1)
                    Spacer()
                    Button("Copy All as CSV") { copyCSV(rows(a)) }
                }
                table(rows(a))
                    .font(.body.monospacedDigit())
                    .frame(minHeight: 60)
            }
        } else {
            EmptyState(text: "Select a measured or imported impulse response")
        }
    }

    private func comparison(_ traces: [Trace]) -> some View {
        let shown = metric.flatMap { set.metrics.contains($0) ? $0 : nil } ?? set.metrics[0]
        return VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(traces.count > 1 ? "Compare shown traces" : "\(traces[0].info.name) by band").font(.headline).lineLimit(1)
                    Picker("Metric", selection: Binding(get: { shown }, set: { metric = $0 })) {
                        ForEach(set.metrics) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: CGFloat(70 * set.metrics.count))
                }
                Chart {
                    ForEach(traces) { trace in
                        ForEach(trace.acoustics!.bands, id: \.band!.nominal) { p in
                            if let v = shown.value(p) {
                                LineMark(x: .value("Band", p.band!.description), y: .value(shown.rawValue, v),
                                         series: .value("Trace", trace.id.uuidString))
                                    .foregroundStyle(trace.color)
                                PointMark(x: .value("Band", p.band!.description), y: .value(shown.rawValue, v))
                                    .foregroundStyle(trace.color)
                            }
                        }
                    }
                }
                .chartYAxisLabel(shown.unit)
                .frame(minHeight: 80)
        }
    }

    private func rows(_ a: RoomAcousticsResult) -> [BandRow] {
        a.bands.enumerated().map { BandRow(id: $0.offset, label: $0.element.band!.description, p: $0.element) }
            + [BandRow(id: -1, label: "Broadband", p: a.broadband)]
    }

    @ViewBuilder private func table(_ rows: [BandRow]) -> some View {
        switch set {
        case .reverb:
            Table(rows) {
                TableColumn("Band") { Text($0.label) }
                TableColumn("EDT s") { Text(fmt($0.p.edt)) }
                TableColumn("T20 s") { Text(fmt($0.p.t20)) }
                TableColumn("T30 s") { Text(fmt($0.p.t30)) }
                TableColumn("PNR dB") { Text(fmt($0.p.peakToNoise, 0)) }
            }
        case .clarity:
            Table(rows) {
                TableColumn("Band") { Text($0.label) }
                TableColumn("C50 dB") { Text(fmt($0.p.c50, 1)) }
                TableColumn("C80 dB") { Text(fmt($0.p.c80, 1)) }
                TableColumn("D50 %") { Text(fmt($0.p.d50 * 100, 1)) }
                TableColumn("Ts ms") { Text(fmt($0.p.ts * 1000, 0)) }
            }
        }
    }

    private func fmt(_ v: Double?, _ digits: Int = 2) -> String {
        guard let v, v.isFinite else { return "–" }
        return String(format: "%.\(digits)f", v)
    }

    private func copyCSV(_ rows: [BandRow]) {
        var text = "Band,EDT s,T20 s,T30 s,C50 dB,C80 dB,D50 %,Ts ms,PNR dB\n"
        for r in rows {
            text += [r.label, fmt(r.p.edt), fmt(r.p.t20), fmt(r.p.t30), fmt(r.p.c50, 1), fmt(r.p.c80, 1),
                     fmt(r.p.d50 * 100, 1), fmt(r.p.ts * 1000, 0), fmt(r.p.peakToNoise, 0)].joined(separator: ",") + "\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Spectrogram and waterfall

struct SpectrogramView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case spectrogram = "Spectrogram", waterfall = "Waterfall"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .spectrogram
    /// Seconds analysed from just before the direct sound.
    @AppStorage("spectrogram.length") private var length = 1.0
    /// The spectrogram's frequency axis, Hz.
    @AppStorage("spectrogram.low") private var lowFrequency = 20.0
    @AppStorage("spectrogram.high") private var highFrequency = 20_000.0
    /// The waterfall's window length and the time between its slices, ms, and how many slices.
    @AppStorage("waterfall.window") private var waterfallWindow = 300.0
    @AppStorage("waterfall.step") private var waterfallStep = 10.0
    @AppStorage("waterfall.slices") private var waterfallSlices = 25
    @State private var grid: TimeFrequency.Grid?
    @State private var computedFor: String = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 8) {
                Picker("Show", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 260)
                if mode == .spectrogram {
                    Text("Length")
                    TextField("Length", value: Binding(get: { length }, set: { length = min(max($0, 0.02), 60) }),
                              format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .help("How much of the impulse response to analyse, in seconds from just before the direct sound: 0.02 to 60")
                    Text("s")
                    frequencyFields
                } else {
                    waterfallControls
                }
            }
            if let trace = model.selectedTrace, trace.impulseResponse != nil {
                Group {
                    if let grid, computedFor == key(trace) {
                        if mode == .spectrogram {
                            Heatmap(grid: grid, low: lowFrequency, high: highFrequency)
                        } else { Waterfall(grid: grid) }
                    } else {
                        ProgressView("Computing…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .task(id: key(trace)) { await compute(trace) }
                Text(mode == .spectrogram
                     ? "Level over time and frequency for \(lengthText) from 5 ms before the direct sound (\(TimeFrequencySettings(length: length, sampleRate: trace.info.sampleRate).windowSize)-point Hann window)."
                     : "Cumulative spectral decay: the spectrum from successively later start times, \(number(waterfallStep)) ms apart, \(number(waterfallWindow)) ms windows, coloured from the first slice (dark blue) to the last (yellow).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                EmptyState(text: "Select a measured or imported impulse response")
            }
        }
    }

    private func key(_ trace: Trace) -> String {
        let settings = mode == .spectrogram ? "\(length)" : "\(waterfallWindow)-\(waterfallStep)-\(waterfallSlices)"
        return "\(trace.id)-\(mode.rawValue)-\(settings)"
    }

    private func number(_ v: Double) -> String { String(format: "%g", v) }

    /// Lowest and highest frequency shown, kept at least an octave apart within 1 Hz to 96 kHz.
    private var frequencyFields: some View {
        HStack(spacing: 6) {
            Text("   From")
            TextField("From", value: Binding(get: { lowFrequency },
                                             set: { lowFrequency = min(max($0, 1), highFrequency / 2) }),
                      format: .number.precision(.fractionLength(0...1)))
                .frame(width: 65)
                .help("Lowest frequency shown, Hz")
            Text("to")
            TextField("To", value: Binding(get: { highFrequency },
                                           set: { highFrequency = min(max($0, lowFrequency * 2), 96_000) }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 70)
                .help("Highest frequency shown, Hz. Above half the sample rate there is nothing to show.")
            Text("Hz")
        }
        .textFieldStyle(.roundedBorder)
        .fixedSize()
    }

    private var waterfallControls: some View {
        HStack(spacing: 6) {
            Text("Window")
            TextField("Window", value: Binding(get: { waterfallWindow }, set: { waterfallWindow = min(max($0, 2), 2000) }),
                      format: .number.precision(.fractionLength(0...1)))
                .frame(width: 60)
                .help("Length of each slice's window, ms: 2 to 2000. Longer windows resolve lower frequencies.")
            Text("ms   Step")
            TextField("Step", value: Binding(get: { waterfallStep }, set: { waterfallStep = min(max($0, 0.1), 500) }),
                      format: .number.precision(.fractionLength(0...1)))
                .frame(width: 60)
                .help("Time between the start of one slice and the next, ms: 0.1 to 500")
            Text("ms   Slices")
            TextField("Slices", value: Binding(get: { waterfallSlices }, set: { waterfallSlices = min(max($0, 2), 100) }),
                      format: .number)
                .frame(width: 45)
                .help("How many slices: 2 to 100")
        }
        .textFieldStyle(.roundedBorder)
        .fixedSize()
    }

    private var lengthText: String { length == 1 ? "the first second" : String(format: "%g s", length) }

    private func compute(_ trace: Trace) async {
        guard let ir = trace.impulseResponse else { return }
        let fs = trace.info.sampleRate, onset = trace.onset, mode = mode, k = key(trace), length = length
        let window = waterfallWindow / 1000, step = waterfallStep / 1000, slices = waterfallSlices
        let result = await Task.detached(priority: .userInitiated) { () -> TimeFrequency.Grid in
            let start = max(0, onset - Int(0.005 * fs))
            if mode == .spectrogram {
                let settings = TimeFrequencySettings(length: length, sampleRate: fs)
                let slice = Array(ir[start..<min(ir.count, start + Int(length * fs))])
                return TimeFrequency.spectrogram(slice, sampleRate: fs, windowSize: settings.windowSize, hop: settings.hop)
            }
            return TimeFrequency.waterfall(ir, sampleRate: fs, start: start, windowLength: window, slices: slices, step: step)
        }.value
        grid = result
        computedFor = k
    }
}

/// The spectrogram's analysis for a length of impulse response: a 2048-point window, shorter for very
/// short lengths so there are still several columns, and a hop that keeps about 300 columns.
struct TimeFrequencySettings {
    let windowSize: Int
    let hop: Int

    init(length: Double, sampleRate fs: Double) {
        let samples = max(1, Int(length * fs))
        var window = 2048
        while window > 256 && window * 4 > samples { window /= 2 }
        windowSize = window
        hop = max(32, samples / 300)
    }
}

/// Draws a spectrogram grid on a log frequency axis.
struct Heatmap: View {
    let grid: TimeFrequency.Grid
    var low = 20.0
    var high = 20_000.0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let rows = 160
            let fHigh = min(high, grid.frequencies.last ?? high)
            let fLow = min(low, fHigh / 2)
            let top = grid.levels.flatMap { $0 }.max() ?? 0
            let cols = grid.times.count
            guard cols > 0 else { return }
            let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
            let binWidth = grid.frequencies.count > 1 ? grid.frequencies[1] : 1
            for c in 0..<cols {
                for r in 0..<rows {
                    let f = fLow * pow(fHigh / fLow, (Double(r) + 0.5) / Double(rows))
                    let bin = min(grid.levels[c].count - 1, Int((f / binWidth).rounded()))
                    let level = grid.levels[c][bin] - top // 0 at the loudest point
                    let x = CGFloat(c) * w, y = size.height - CGFloat(r + 1) * h
                    context.fill(Path(CGRect(x: x, y: y, width: w + 0.5, height: h + 0.5)), with: .color(color(level)))
                }
            }
            for f in zoomedFrequencyTicks(in: fLow...fHigh) {
                let y = size.height * (1 - CGFloat(log(f / fLow) / log(fHigh / fLow)))
                context.draw(Text(frequencyLabel(f)).font(.caption2).foregroundStyle(labelColor), at: CGPoint(x: 18, y: y))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("0 to \(Int((grid.times.last ?? 0) * 1000)) ms →").font(.caption2).foregroundStyle(labelColor).padding(4)
        }
        .overlay(alignment: .topTrailing) { legend.padding(6) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The colour scale: level below the loudest point, and the axes.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("−60 dB").font(.caption2)
                LinearGradient(colors: stride(from: -60.0, through: 0, by: 7.5).map { color($0) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 110, height: 8)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("0 dB").font(.caption2)
            }
            Text("Level re the loudest point · Hz up · time across").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
    }

    private var labelColor: Color { colorScheme == .dark ? .white : .black }

    /// Maps -60 dB to 0 dB (loudest). Quiet is dark in dark mode and light in light mode, so the
    /// heat map sits naturally on the window background in either appearance.
    private func color(_ level: Double) -> Color {
        let t = max(0, min(1, (level + 60) / 60))
        let hue = 0.7 - 0.7 * t
        if colorScheme == .dark {
            return Color(hue: hue, saturation: 0.9, brightness: 0.15 + 0.85 * t)
        }
        return Color(hue: hue, saturation: 0.1 + 0.9 * t, brightness: 1 - 0.15 * t)
    }
}

/// Draws waterfall slices as lines on a log frequency axis, later slices lighter.
struct Waterfall: View {
    let grid: TimeFrequency.Grid

    var body: some View {
        let slices: [(Int, [ChartPoint])] = grid.levels.enumerated().map { i, levels in
            let fr = FrequencyResponse(frequencies: Array(grid.frequencies.dropFirst()), magnitude: Array(levels.dropFirst()))
                .smoothed(fraction: 6).logResampled(pointsPerOctave: 24, low: 20, high: min(20_000, grid.frequencies.last ?? 20_000))
            return (i, zip(fr.frequencies, fr.magnitude).map { ChartPoint(x: $0, y: $1) })
        }
        Chart {
            ForEach(slices, id: \.0) { slice in
                let i = slice.0
                ForEach(slice.1) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Slice", i))
                        .foregroundStyle(parula(Double(i) / Double(max(1, slices.count - 1))))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
        }
        .chartXScale(domain: 20...20_000, type: .log)
        .chartYScale(domain: -60...5)
        .chartXAxis {
            AxisMarks(values: frequencyTicks) { value in
                AxisGridLine()
                AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
            }
        }
        .chartYAxisLabel("dB")
        .clipped()
        .overlay(alignment: .topTrailing) { colourBar.padding(.top, 4).padding(.trailing, 40) }
    }

    /// The slices' colours from first to last, with their start times.
    private var colourBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("0 ms").font(.caption2)
                LinearGradient(colors: (0...8).map { parula(Double($0) / 8) }, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 90, height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("\(Int(((grid.times.last ?? 0) * 1000).rounded())) ms").font(.caption2)
            }
            Text("Slice start after the direct sound").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
    }
}

/// The parula colour map (MATLAB's default), from dark blue at 0 through teal and green to yellow at 1:
/// ten samples of it, interpolated linearly.
func parula(_ t: Double) -> Color {
    let stops: [(Double, Double, Double)] = [
        (0.2422, 0.1504, 0.6603), (0.2803, 0.2782, 0.9221), (0.2440, 0.4358, 0.9988), (0.1540, 0.5902, 0.9218),
        (0.0297, 0.7082, 0.8163), (0.1938, 0.7758, 0.6251), (0.5044, 0.7993, 0.3480), (0.8634, 0.7406, 0.1596),
        (0.9892, 0.8136, 0.1885), (0.9769, 0.9839, 0.0805),
    ]
    let x = min(max(t, 0), 1) * Double(stops.count - 1)
    let i = min(Int(x), stops.count - 2)
    let f = x - Double(i)
    let a = stops[i], b = stops[i + 1]
    return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
}
#endif
