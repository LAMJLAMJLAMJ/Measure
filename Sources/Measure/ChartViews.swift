#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI

let frequencyTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

func frequencyLabel(_ f: Double) -> String {
    f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
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
    @State private var range: Double = 50

    var body: some View {
        @Bindable var model = model
        let traces = model.visibleTraces.filter(\.hasResponse)
        let series = traces.map { ($0, $0.displayResponse(smoothing: model.smoothing, calibration: model.calibration(for: $0))) }
        let top = (series.flatMap { $0.1.filter { $0.x >= 20 }.map(\.y) }.max() ?? 0).rounded(.up) + 5

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
                Spacer()
                Text("Levels in dBFS; mic calibration applied where set\(windowNote)").font(.caption).foregroundStyle(.secondary)
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
                Toggle(isOn: $showVirtualEQ) { Label("Virtual EQ", systemImage: "slider.vertical.3") }
                    .toggleStyle(.button)
                    .help("Show the Virtual EQ panel")
            }
            if series.isEmpty {
                EmptyState(text: "Tick a trace in the list to show it")
            } else {
                Chart {
                    ForEach(series, id: \.0.id) { item in
                        let trace = item.0
                        ForEach(item.1) { p in
                            LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y),
                                     series: .value("Trace", trace.id.uuidString))
                                .foregroundStyle(trace.color)
                                .lineStyle(StrokeStyle(lineWidth: trace.id == model.selection ? 2 : 1.2))
                        }
                    }
                }
                .chartXScale(domain: 10...20_000, type: .log)
                .chartYScale(domain: (top - range)...top)
                .chartXAxis {
                    AxisMarks(values: frequencyTicks) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
                    }
                }
                .chartXAxisLabel("Hz")
                .chartYAxisLabel("dB")
                .chartLegend(.hidden)
                .clipped()
            }
        }
    }
}

extension FrequencyResponseView {
    /// The selected trace's window, when it is not the standard one.
    var windowNote: String {
        guard let trace = model.selectedTrace, trace.impulseResponse != nil, trace.window != .standard else { return "" }
        return String(format: "; %@ window %g to %g ms", trace.info.name, -trace.window.left * 1000, trace.window.right * 1000)
    }
}

// MARK: - Phase

struct PhaseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let series = model.visibleTraces.compactMap { t in t.displayPhase().map { (t, $0) } }
        VStack(alignment: .leading) {
            HStack {
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
                .chartXScale(domain: 10...20_000, type: .log)
                .chartYScale(domain: -180...180)
                .chartXAxis {
                    AxisMarks(values: frequencyTicks) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
                    }
                }
                .chartYAxis { AxisMarks(values: [-180, -90, 0, 90, 180]) }
                .chartXAxisLabel("Hz")
                .chartYAxisLabel("degrees")
                .chartLegend(.hidden)
                .clipped()
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
                Spacer()
                Text("Time from the selected trace's direct sound").font(.caption).foregroundStyle(.secondary)
            }
            if let reference, let window {
                windowControls(reference, window, traces: traces)
            }
            if let reference {
                let zero = reference.onset
                let fs = reference.info.sampleRate
                // Start a little before the direct sound, and before the window's left edge.
                let preRoll = max(0.005, (window?.left ?? 0) + 0.002)
                let lo = -min(preRoll, Double(zero) / fs) * 1000
                let hi = span == 0 ? Double(reference.impulseResponse!.count - zero) / fs * 1000 : lo + span
                let yLabel = mode == .etc ? "Level" : "Amplitude"
                let yRange: ClosedRange<Double> = mode == .etc ? -100...0 : -1...1
                Chart {
                    ForEach(traces) { trace in
                        ForEach(points(trace, zero: zero, preRoll: preRoll)) { p in
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
                .chartXScale(domain: lo...max(hi, lo + 1))
                .chartYScale(domain: yRange)
                .chartXAxisLabel("ms")
                .chartYAxisLabel(mode == .etc ? "dB" : "normalised")
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    if let window {
                        GeometryReader { geo in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .gesture(dragGesture(proxy: proxy, geo: geo, window: window, reference: reference))
                        }
                    }
                }
                .clipped()
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

    /// Drags whichever window edge the drag starts near. The response is recomputed when the drag ends.
    private func dragGesture(proxy: ChartProxy, geo: GeometryProxy, window: ResponseWindow, reference: Trace) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let anchor = proxy.plotFrame else { return }
                let origin = geo[anchor].origin.x
                if dragging == nil {
                    let startX = value.startLocation.x - origin
                    let leftX = proxy.position(forX: -window.left * 1000) ?? .infinity
                    let rightX = proxy.position(forX: window.right * 1000) ?? .infinity
                    let dl = abs(startX - leftX), dr = abs(startX - rightX)
                    guard min(dl, dr) < 12 else { return }
                    dragging = dl <= dr ? .left : .right
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
            .onEnded { _ in
                if let liveWindow { commit(liveWindow, to: [reference.id]) }
                liveWindow = nil
                dragging = nil
            }
    }

    private func points(_ trace: Trace, zero: Int, preRoll: Double) -> [ChartPoint] {
        guard let ir = trace.impulseResponse else { return [] }
        let fs = trace.info.sampleRate
        let start = max(0, zero - Int(preRoll * fs))
        // Another trace can be shorter than the selected one's onset, so never let the range run backwards.
        let end = max(start, span == 0 ? ir.count : start + Int(span / 1000 * fs))
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

    var body: some View {
        if let trace = model.selectedTrace, let acoustics = trace.acoustics {
            let params = bandIndex >= 0 && bandIndex < acoustics.bands.count ? acoustics.bands[bandIndex] : acoustics.broadband
            let fs = trace.info.sampleRate
            VStack(alignment: .leading) {
                HStack {
                    Picker("Band", selection: $bandIndex) {
                        Text("Broadband").tag(-1)
                        ForEach(acoustics.bands.indices, id: \.self) { i in Text("\(acoustics.bands[i].band!.description) Hz").tag(i) }
                    }
                    .frame(width: 200)
                    Spacer()
                    Text(summary(params)).font(.callout.monospacedDigit())
                }
                Chart {
                    ForEach(ChartData.points(params.decayCurve, range: 0..<params.decayCurve.count, zero: 0, sampleRate: fs, envelope: true)) { p in
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
                .chartYScale(domain: -80...0)
                .chartXAxisLabel("ms from onset")
                .chartYAxisLabel("dB")
                .chartForegroundStyleScale(["EDT": Color.secondary, "T20": Color.orange, "T30": Color.red])
                .clipped()
                Text("Schroeder decay of \(trace.info.name) with the fitted lines (EDT 0 to -10 dB, T20 -5 to -25 dB, T30 -5 to -35 dB). The curve ends where the decay meets the noise.")
                    .font(.caption).foregroundStyle(.secondary)
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
        VSplitView {
            DecayView().frame(minHeight: 220).padding(.bottom, 8)
            ParametersPanel(set: .reverb).frame(minHeight: 220).padding(.top, 8)
        }
    }
}

/// ISO 3382-1 table for the selected trace, plus a band-by-band comparison of the shown traces.
struct ParametersPanel: View {
    enum ParameterSet {
        case reverb, clarity
        var metrics: [Metric] { self == .reverb ? [.t30, .t20, .edt] : [.c50, .c80, .d50, .ts] }
    }

    let set: ParameterSet
    @Environment(AppModel.self) private var model
    @State private var metric: Metric?

    var body: some View {
        let traces = model.visibleTraces.filter { $0.acoustics != nil }
        let shown = metric.flatMap { set.metrics.contains($0) ? $0 : nil } ?? set.metrics[0]
        VStack(alignment: .leading, spacing: 12) {
            if let trace = model.selectedTrace, let a = trace.acoustics {
                HStack {
                    Text("\(trace.info.name): ISO 3382-1, octave bands").font(.headline)
                    Spacer()
                    Button("Copy All as CSV") { copyCSV(rows(a)) }
                }
                table(rows(a))
                    .font(.body.monospacedDigit())
                    .frame(minHeight: 180)
            } else {
                EmptyState(text: "Select a measured or imported impulse response")
            }

            if traces.count > 1 {
                HStack {
                    Text("Compare shown traces").font(.headline)
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
                .frame(minHeight: 160)
            }
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
    @State private var grid: TimeFrequency.Grid?
    @State private var computedFor: String = ""

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Show", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 260)
            if let trace = model.selectedTrace, trace.impulseResponse != nil {
                Group {
                    if let grid, computedFor == key(trace) {
                        if mode == .spectrogram { Heatmap(grid: grid) } else { Waterfall(grid: grid) }
                    } else {
                        ProgressView("Computing…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .task(id: key(trace)) { await compute(trace) }
                Text(mode == .spectrogram
                     ? "Level over time and frequency for the first second after the direct sound (2048-point Hann window)."
                     : "Cumulative spectral decay: the spectrum from successively later start times, 10 ms apart, 300 ms windows.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                EmptyState(text: "Select a measured or imported impulse response")
            }
        }
    }

    private func key(_ trace: Trace) -> String { "\(trace.id)-\(mode.rawValue)" }

    private func compute(_ trace: Trace) async {
        guard let ir = trace.impulseResponse else { return }
        let fs = trace.info.sampleRate, onset = trace.onset, mode = mode, k = key(trace)
        let result = await Task.detached(priority: .userInitiated) { () -> TimeFrequency.Grid in
            let start = max(0, onset - Int(0.005 * fs))
            if mode == .spectrogram {
                let slice = Array(ir[start..<min(ir.count, start + Int(fs))])
                return TimeFrequency.spectrogram(slice, sampleRate: fs, windowSize: 2048, hop: 256)
            }
            return TimeFrequency.waterfall(ir, sampleRate: fs, start: start, windowLength: 0.3, slices: 25, step: 0.01)
        }.value
        grid = result
        computedFor = k
    }
}

/// Draws a spectrogram grid on a log frequency axis.
struct Heatmap: View {
    let grid: TimeFrequency.Grid
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let rows = 160
            let fLow = 20.0, fHigh = min(20_000, grid.frequencies.last ?? 20_000)
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
            for f in frequencyTicks where f >= fLow && f <= fHigh {
                let y = size.height * (1 - CGFloat(log(f / fLow) / log(fHigh / fLow)))
                context.draw(Text(frequencyLabel(f)).font(.caption2).foregroundStyle(labelColor), at: CGPoint(x: 18, y: y))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("0 to \(Int((grid.times.last ?? 0) * 1000)) ms →").font(.caption2).foregroundStyle(labelColor).padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
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
                        .foregroundStyle(Color.accentColor.opacity(1 - 0.85 * Double(i) / Double(max(1, slices.count - 1))))
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
    }
}
#endif
