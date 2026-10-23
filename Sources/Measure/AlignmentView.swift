#if os(macOS)
import Charts
import MeasureDSP
import SwiftUI

/// What the Alignment view remembers: each trace's delay, polarity and gain, and how the sum is shown.
struct AlignmentSettings: Codable {
    var parts: [UUID: TimeAlignment.Setting] = [:]
    /// Traces left out of the sum.
    var off: Set<UUID> = []
    /// The range the alignment is judged over: usually an octave either side of the crossover.
    var low = 60.0
    var high = 200.0
    /// Fractional-octave complex smoothing; 0 for none.
    var smoothing = 12.0
    /// How far either side of the arrivals the automatic alignment looks, ms.
    var span = 10.0
    /// Include each trace's Virtual EQ, with its phase.
    var includeEQ = true

    func setting(_ id: UUID) -> TimeAlignment.Setting { parts[id] ?? TimeAlignment.Setting() }
}

/// One curve on an alignment chart.
private struct AlignmentCurve: Identifiable {
    let id: String
    let name: String
    let color: Color
    let width: CGFloat
    let points: [ChartPoint]
}

/// The traces as alignment parts, ready for the view.
private struct AlignmentData {
    var traces: [Trace] = []
    /// Each trace's part, with its calibration and (when included) its EQ, before its setting.
    var parts: [TimeAlignment.Part] = []
    /// The time the phase is shown relative to: the reference trace's arrival after its delay.
    var reference = 0.0
    var referenceIndex = 0
}

/// Lines up any number of sources (subs and tops, mains and fills, delays and the stage) by delay,
/// polarity and gain, and shows how they sum, from measurements of each one alone at the same mic.
struct AlignmentView: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?

    var body: some View {
        let data = makeData()
        VStack(alignment: .leading, spacing: 10) {
            if data.traces.count < 2 {
                EmptyState(text: "Tick two or more traces with phase (impulse responses) to align them")
            } else {
                controls(data)
                ScrollView(.vertical) { partsGrid(data) }
                    .frame(minHeight: 70, idealHeight: CGFloat(32 * (data.traces.count + 1)), maxHeight: 200)
                summary(data)
                charts(data)
            }
        }
    }

    // MARK: - Data

    private func makeData() -> AlignmentData {
        let traces = model.visibleTraces.filter { $0.hasResponse && $0.rawResponse.phase != nil }
        guard traces.count >= 2 else { return AlignmentData(traces: traces) }
        let settings = model.alignment
        let high = traces.map { $0.rawResponse.frequencies.last ?? 20_000 }.min() ?? 20_000
        let grid = TimeAlignment.grid(pointsPerOctave: 48, low: 10, high: min(20_000, high))
        var data = AlignmentData()
        for trace in traces {
            let calibration = model.calibration(for: trace)
            let arrival = Double(trace.onset) / max(trace.info.sampleRate, 1)
            let start = arrival - trace.responseDelay
            var gain: ((Double) -> Double)? = nil
            if let calibration { gain = { f in -calibration.magnitude(at: f) } }
            let smoothing: Double? = settings.smoothing > 0 ? settings.smoothing : nil
            guard var part = TimeAlignment.Part(response: trace.rawResponse, start: start, arrival: arrival, grid: grid,
                                            smoothing: smoothing, gain: gain) else { continue }
            if settings.includeEQ, !trace.activeEQ.isEmpty {
                part = part.applying(trace.activeEQ, sampleRate: trace.eqSampleRate)
            }
            data.traces.append(trace)
            data.parts.append(part)
        }
        let index = data.traces.firstIndex { $0.id == model.selection } ?? 0
        data.referenceIndex = index
        if index < data.parts.count {
            data.reference = data.parts[index].arrival + settings.setting(data.traces[index].id).delay
        }
        return data
    }

    /// The parts that are switched on, with their settings.
    private func included(_ data: AlignmentData, except skipped: UUID? = nil) -> ([TimeAlignment.Part], [TimeAlignment.Setting]) {
        var parts: [TimeAlignment.Part] = []
        var settings: [TimeAlignment.Setting] = []
        for (trace, part) in zip(data.traces, data.parts) {
            if model.alignment.off.contains(trace.id) || trace.id == skipped { continue }
            parts.append(part)
            settings.append(model.alignment.setting(trace.id))
        }
        return (parts, settings)
    }

    // MARK: - Controls

    private func controls(_ data: AlignmentData) -> some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Align over")
                numberField($model.alignment.low, width: 56)
                Text("to")
                numberField($model.alignment.high, width: 60)
                Text("Hz").foregroundStyle(.secondary)
            }
            .fixedSize()
            .help("The range the automatic alignment and the summation figure look at: about an octave either side of the crossover")
            Button("Find Crossover") { findCrossover(data) }
                .help("Set the range to an octave either side of where the reference trace and the next one are at the same level")
            Spacer(minLength: 0)
            Button("Match Arrivals") { matchArrivals(data) }
                .help("Delay the earlier traces so every direct sound arrives with the last one")
            Button("Reset") { reset(data) }
                .help("No delay, normal polarity and no gain on every ticked trace")
        }
    }

    private func numberField(_ value: Binding<Double>, width: CGFloat, digits: Int = 0) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...digits)))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }

    // MARK: - Parts

    private func partsGrid(_ data: AlignmentData) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("In sum")
                Text("Trace")
                Text("Arrival")
                Text("Delay ms")
                Text("Distance")
                Text("Polarity")
                Text("Gain dB")
                Text("")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(data.traces.enumerated()), id: \.element.id) { index, trace in
                partRow(data, index: index, trace: trace)
            }
        }
        .font(.body.monospacedDigit())
    }

    private func partRow(_ data: AlignmentData, index: Int, trace: Trace) -> some View {
        let id = trace.id
        let setting = model.alignment.setting(id)
        let isReference = index == data.referenceIndex
        let arrival = data.parts[index].arrival * 1000
        let distance = setting.delay * TimeAlignment.speedOfSound
        return GridRow {
            Toggle("", isOn: inSum(id)).labelsHidden()
            HStack(spacing: 6) {
                Circle().fill(trace.color).frame(width: 9, height: 9)
                Text(trace.info.name).lineLimit(1).fontWeight(isReference ? .semibold : .regular)
                if isReference { Text("reference").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
            Text(String(format: "%.2f ms", arrival)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                numberField(delayMS(id), width: 64, digits: 2)
                Stepper("", value: delayMS(id), step: 0.1).labelsHidden()
            }
            Text(String(format: "%.2f m", distance)).foregroundStyle(.secondary)
            Toggle(isOn: inverted(id)) { Text(setting.inverted ? "Inverted" : "Normal") }
                .toggleStyle(.button)
                .help("Invert the polarity of this trace")
            numberField(gain(id), width: 52, digits: 1)
            Button("Align") { align(data, index: index) }
                .disabled(included(data, except: id).0.isEmpty)
                .help("Find the delay and polarity that make this trace add best to the others in the sum, over the range")
        }
    }

    private func inSum(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !model.alignment.off.contains(id) },
                set: { on in if on { model.alignment.off.remove(id) } else { model.alignment.off.insert(id) } })
    }

    private func delayMS(_ id: UUID) -> Binding<Double> {
        Binding(get: { model.alignment.setting(id).delay * 1000 },
                set: { value in
                    var s = model.alignment.setting(id)
                    s.delay = value / 1000
                    model.alignment.parts[id] = s
                })
    }

    private func inverted(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.alignment.setting(id).inverted },
                set: { value in
                    var s = model.alignment.setting(id)
                    s.inverted = value
                    model.alignment.parts[id] = s
                })
    }

    private func gain(_ id: UUID) -> Binding<Double> {
        Binding(get: { model.alignment.setting(id).gain },
                set: { value in
                    var s = model.alignment.setting(id)
                    s.gain = value
                    model.alignment.parts[id] = s
                })
    }

    // MARK: - Actions

    private func align(_ data: AlignmentData, index: Int) {
        let trace = data.traces[index]
        let (others, otherSettings) = included(data, except: trace.id)
        guard let first = others.first else { return }
        let reference = first.arrival + (otherSettings.first?.delay ?? 0)
        guard let sum = TimeAlignment.sum(others, settings: otherSettings, reference: reference) else { return }
        let a = model.alignment
        var setting = a.setting(trace.id)
        guard let fit = TimeAlignment.fit(moving: data.parts[index], gain: setting.gain, to: sum, low: a.low, high: a.high,
                                      span: a.span / 1000) else {
            message = "Nothing to align between \(Int(a.low)) and \(Int(a.high)) Hz."
            return
        }
        setting.delay = fit.delay
        setting.inverted = fit.inverted
        var parts = a.parts
        parts[trace.id] = setting
        normalize(&parts, ids: data.traces.map(\.id))
        model.alignment.parts = parts
        let polarity = fit.inverted ? ", polarity inverted" : ""
        message = String(format: "%@ aligned%@: the sum is %.1f dB from a perfect addition over the range. The best phase match is %.2f ms from lining up the arrivals.",
                         trace.info.name, polarity, fit.summation, fit.fromArrival * 1000)
    }

    /// Shifts the delays so the smallest is zero: a processor can add delay but not take it away.
    private func normalize(_ parts: inout [UUID: TimeAlignment.Setting], ids: [UUID]) {
        let settings = ids.map { parts[$0] ?? TimeAlignment.Setting() }
        let normalized = TimeAlignment.normalized(settings)
        for (id, s) in zip(ids, normalized) { parts[id] = s }
    }

    private func matchArrivals(_ data: AlignmentData) {
        guard let last = data.parts.map(\.arrival).max() else { return }
        var parts = model.alignment.parts
        for (trace, part) in zip(data.traces, data.parts) {
            var s = model.alignment.setting(trace.id)
            s.delay = last - part.arrival
            parts[trace.id] = s
        }
        model.alignment.parts = parts
        message = "Arrivals matched, from each direct sound's onset. For a crossover, Align then refines it by phase."
    }

    private func reset(_ data: AlignmentData) {
        var parts = model.alignment.parts
        for trace in data.traces { parts[trace.id] = TimeAlignment.Setting() }
        model.alignment.parts = parts
        message = nil
    }

    private func findCrossover(_ data: AlignmentData) {
        let r = data.referenceIndex
        let other = r == 0 ? 1 : 0
        guard let f = TimeAlignment.crossover(data.parts[r], data.parts[other], low: 20, high: 20_000) else {
            message = "\(data.traces[r].info.name) and \(data.traces[other].info.name) do not cross: set the range by hand."
            return
        }
        model.alignment.low = (f / 2).rounded()
        model.alignment.high = (f * 2).rounded()
        message = String(format: "Crossover between %@ and %@ at %.0f Hz.", data.traces[r].info.name,
                         data.traces[other].info.name, f)
    }

    // MARK: - Summary

    private func summary(_ data: AlignmentData) -> some View {
        @Bindable var model = model
        let (parts, settings) = included(data)
        let a = model.alignment
        let figure = TimeAlignment.summation(parts, settings: settings, low: a.low, high: a.high)
        var line = String(format: "Over %.0f to %.0f Hz", a.low, a.high)
        if let figure {
            line += String(format: ", the sum is %.1f dB from a perfect addition", figure)
        }
        line += ". Set on the processor: " + processorText(data)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line).lineLimit(2).help(line)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(message) }
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
            Picker("Smoothing", selection: $model.alignment.smoothing) {
                Text("None").tag(0.0)
                Text("1/24").tag(24.0)
                Text("1/12").tag(12.0)
                Text("1/6").tag(6.0)
                Text("1/3").tag(3.0)
            }
            .fixedSize()
            .help("Complex smoothing, which keeps the phase")
            Toggle("Virtual EQ", isOn: $model.alignment.includeEQ)
                .fixedSize()
                .help("Include each trace's Virtual EQ, magnitude and phase, as a processor would apply it")
        }
    }

    private func processorText(_ data: AlignmentData) -> String {
        var items: [String] = []
        for trace in data.traces where !model.alignment.off.contains(trace.id) {
            let s = model.alignment.setting(trace.id)
            var item = String(format: "%@ %.2f ms", trace.info.name, s.delay * 1000)
            if s.inverted { item += " inverted" }
            if s.gain != 0 { item += String(format: " %+.1f dB", s.gain) }
            items.append(item)
        }
        return items.joined(separator: "; ")
    }

    // MARK: - Charts

    private func curves(_ data: AlignmentData) -> (magnitude: [AlignmentCurve], phase: [AlignmentCurve]) {
        var magnitude: [AlignmentCurve] = []
        var phase: [AlignmentCurve] = []
        let low = 15.0
        for (trace, part) in zip(data.traces, data.parts) where !model.alignment.off.contains(trace.id) {
            let adjusted = part.adjusted(model.alignment.setting(trace.id), reference: data.reference)
            let id = trace.id.uuidString
            magnitude.append(AlignmentCurve(id: id, name: trace.info.name, color: trace.color, width: 1.2,
                                            points: points(adjusted, low: low, phase: false)))
            phase.append(AlignmentCurve(id: id, name: trace.info.name, color: trace.color, width: 1.2,
                                        points: points(adjusted, low: low, phase: true)))
        }
        let (parts, settings) = included(data)
        if parts.count > 1, let sum = TimeAlignment.sum(parts, settings: settings, reference: data.reference) {
            magnitude.append(AlignmentCurve(id: "sum", name: "Sum", color: .primary, width: 2.4,
                                            points: points(sum, low: low, phase: false)))
            phase.append(AlignmentCurve(id: "sum", name: "Sum", color: .primary, width: 2.4,
                                        points: points(sum, low: low, phase: true)))
        }
        return (magnitude, phase)
    }

    private func points(_ part: TimeAlignment.Part, low: Double, phase: Bool) -> [ChartPoint] {
        var out: [ChartPoint] = []
        out.reserveCapacity(part.frequencies.count)
        for i in part.frequencies.indices where part.frequencies[i] >= low {
            let y = phase ? part.phase(i) : part.level(i)
            out.append(ChartPoint(x: part.frequencies[i], y: y))
        }
        return out
    }

    private func charts(_ data: AlignmentData) -> some View {
        let (magnitude, phase) = curves(data)
        let top = magnitude.flatMap { $0.points.map(\.y) }.max() ?? 0
        let ceiling = (top / 6).rounded(.up) * 6 + 6
        let floor = ceiling - 60
        let levelTicks: [Double] = Array(stride(from: floor, through: ceiling, by: 6))
        return VStack(alignment: .leading, spacing: 6) {
            AlignmentChart(curves: magnitude, low: model.alignment.low, high: model.alignment.high,
                           yDomain: floor...ceiling, yLabel: "dB", yTicks: levelTicks, unit: "dB")
                .frame(minHeight: 160, maxHeight: .infinity)
            AlignmentChart(curves: phase, low: model.alignment.low, high: model.alignment.high,
                           yDomain: -180...180, yLabel: "degrees", yTicks: [-180, -90, 0, 90, 180], unit: "°")
                .frame(minHeight: 120, maxHeight: .infinity)
            Text("Phase relative to the reference trace's arrival after its delay. In the shaded range, curves that lie on each other add fully. Each trace is taken within its window on the Impulse view: give subs a window long enough for the low end.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// A frequency chart of alignment curves, with the alignment range shaded.
private struct AlignmentChart: View {
    let curves: [AlignmentCurve]
    let low: Double
    let high: Double
    let yDomain: ClosedRange<Double>
    let yLabel: String
    let yTicks: [Double]
    let unit: String

    var body: some View {
        let tips: [TipSeries] = curves.map { TipSeries(id: $0.id, name: $0.name, color: $0.color, points: $0.points) }
        Chart {
            RectangleMark(xStart: .value("From", max(low, 15)), xEnd: .value("To", min(max(high, low * 1.01), 20_000)),
                          yStart: .value("Bottom", yDomain.lowerBound), yEnd: .value("Top", yDomain.upperBound))
                .foregroundStyle(Color.accentColor.opacity(0.08))
            ForEach(curves) { curve in
                ForEach(curve.points) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value(yLabel, p.y), series: .value("Trace", curve.id))
                        .foregroundStyle(curve.color)
                        .lineStyle(StrokeStyle(lineWidth: curve.width))
                }
            }
        }
        .chartXScale(domain: 15...20_000, type: .log)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: frequencyTicks) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
            }
        }
        .chartYAxis { AxisMarks(values: yTicks) }
        .chartYAxisLabel(yLabel)
        .chartLegend(.hidden)
        .frequencyDataTip(tips, unit: unit)
        .clipped()
    }
}
#endif
