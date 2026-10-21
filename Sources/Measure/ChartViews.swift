#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI

private let frequencyTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

private func frequencyLabel(_ f: Double) -> String {
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
    @State private var range: Double = 50

    var body: some View {
        @Bindable var model = model
        let traces = model.visibleTraces
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
                Text("Levels in dBFS; mic calibration applied where set").font(.caption).foregroundStyle(.secondary)
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

// MARK: - Impulse and ETC

struct ImpulseView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case etc = "ETC", impulse = "Impulse"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .etc
    @State private var span: Double = 300

    var body: some View {
        let traces = model.visibleTraces.filter { $0.impulseResponse != nil }
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
            if traces.isEmpty {
                EmptyState(text: "No impulse responses shown")
            } else {
                // All traces share the time axis of the selected (or first) trace, so relative arrivals show.
                let reference = traces.first { $0.id == model.selection } ?? traces[0]
                let zero = reference.onset
                Chart {
                    ForEach(traces) { trace in
                        ForEach(points(trace, zero: zero)) { p in
                            LineMark(x: .value("Time", p.x), y: .value(mode == .etc ? "Level" : "Amplitude", p.y),
                                     series: .value("Trace", trace.id.uuidString))
                                .foregroundStyle(trace.color)
                                .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    }
                }
                .chartYScale(domain: mode == .etc ? -100...0 : -1...1)
                .chartXAxisLabel("ms")
                .chartYAxisLabel(mode == .etc ? "dB" : "normalised")
                .chartLegend(.hidden)
                .clipped()
            }
        }
    }

    private func points(_ trace: Trace, zero: Int) -> [ChartPoint] {
        guard let ir = trace.impulseResponse else { return [] }
        let fs = trace.info.sampleRate
        let start = max(0, zero - Int(0.005 * fs))
        let end = span == 0 ? ir.count : start + Int(span / 1000 * fs)
        if mode == .etc {
            return ChartData.points(trace.energyTime, range: start..<end, zero: zero, sampleRate: fs, envelope: true)
        }
        let peak = max(ir.map(abs).max() ?? 1, .leastNonzeroMagnitude)
        return ChartData.points(ir, range: start..<end, zero: zero, sampleRate: fs).map { ChartPoint(x: $0.x, y: $0.y / peak) }
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
                    fitLine(params.edtFit, name: "EDT", color: .gray)
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
                .chartForegroundStyleScale(["EDT": Color.gray, "T20": Color.orange, "T30": Color.red])
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

// MARK: - Acoustics table and band comparison

struct BandRow: Identifiable {
    let id: Int
    let label: String
    let p: BandParameters
}

struct AcousticsView: View {
    enum Metric: String, CaseIterable, Identifiable {
        case t30 = "T30", t20 = "T20", edt = "EDT", c50 = "C50", c80 = "C80"
        var id: String { rawValue }
        func value(_ p: BandParameters) -> Double? {
            switch self {
            case .t30: return p.t30
            case .t20: return p.t20
            case .edt: return p.edt
            case .c50: return p.c50
            case .c80: return p.c80
            }
        }
        var unit: String { self == .c50 || self == .c80 ? "dB" : "s" }
    }

    @Environment(AppModel.self) private var model
    @State private var metric: Metric = .t30

    var body: some View {
        let traces = model.visibleTraces.filter { $0.acoustics != nil }
        VStack(alignment: .leading, spacing: 12) {
            if let trace = model.selectedTrace, let a = trace.acoustics {
                Text("\(trace.info.name): ISO 3382-1, octave bands").font(.headline)
                let rows = a.bands.enumerated().map { BandRow(id: $0.offset, label: $0.element.band!.description, p: $0.element) }
                    + [BandRow(id: -1, label: "Broadband", p: a.broadband)]
                Table(rows) {
                    TableColumn("Band") { Text($0.label) }
                    TableColumn("EDT s") { Text(fmt($0.p.edt)) }
                    TableColumn("T20 s") { Text(fmt($0.p.t20)) }
                    TableColumn("T30 s") { Text(fmt($0.p.t30)) }
                    TableColumn("C50 dB") { Text(fmt($0.p.c50, 1)) }
                    TableColumn("C80 dB") { Text(fmt($0.p.c80, 1)) }
                    TableColumn("D50 %") { Text(fmt($0.p.d50 * 100, 1)) }
                    TableColumn("Ts ms") { Text(fmt($0.p.ts * 1000, 0)) }
                    TableColumn("PNR dB") { Text(fmt($0.p.peakToNoise, 0)) }
                }
                .font(.body.monospacedDigit())
                .frame(minHeight: 260)
                HStack {
                    Button("Copy as CSV") { copyCSV(rows) }
                    Spacer()
                }
            } else {
                EmptyState(text: "Select a measured or imported impulse response")
            }

            if traces.count > 1 {
                HStack {
                    Text("Compare shown traces").font(.headline)
                    Picker("Metric", selection: $metric) { ForEach(Metric.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 300)
                }
                Chart {
                    ForEach(traces) { trace in
                        ForEach(trace.acoustics!.bands, id: \.band!.nominal) { p in
                            if let v = metric.value(p) {
                                LineMark(x: .value("Band", p.band!.description), y: .value(metric.rawValue, v),
                                         series: .value("Trace", trace.id.uuidString))
                                    .foregroundStyle(trace.color)
                                PointMark(x: .value("Band", p.band!.description), y: .value(metric.rawValue, v))
                                    .foregroundStyle(trace.color)
                            }
                        }
                    }
                }
                .chartYAxisLabel(metric.unit)
                .frame(minHeight: 180)
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
                context.draw(Text(frequencyLabel(f)).font(.caption2).foregroundStyle(.white), at: CGPoint(x: 18, y: y))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("0 to \(Int((grid.times.last ?? 0) * 1000)) ms →").font(.caption2).foregroundStyle(.white).padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Maps 0 dB (loudest) to -60 dB onto a dark-to-bright scale.
    private func color(_ level: Double) -> Color {
        let t = max(0, min(1, (level + 60) / 60))
        return Color(hue: 0.7 - 0.7 * t, saturation: 0.9, brightness: 0.15 + 0.85 * t)
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
