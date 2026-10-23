#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI

/// Side panel next to the frequency response for trying parametric EQ on the selected trace. The
/// Frequency view draws the predicted result; nothing is sent to a processor.
struct VirtualEQPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let trace = model.selectedTrace, trace.hasResponse {
            editor(trace)
        } else {
            ContentUnavailableView {
                Label("Virtual EQ", systemImage: "slider.vertical.3")
            } description: {
                Text("Select a trace with a frequency response to try EQ on it. The Frequency view shows the predicted result. Prediction only: nothing is sent to a processor.")
            }
        }
    }

    private func editor(_ trace: Trace) -> some View {
        let filters = trace.info.eq ?? []
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Virtual EQ").font(.headline)
                Text(trace.info.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            eqCurve(trace).frame(height: 110)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(filters) { filter in
                        FilterRow(filter: binding(trace.id, filter), index: (filters.firstIndex { $0.id == filter.id } ?? 0) + 1) {
                            model.setEQ(filters.filter { $0.id != filter.id }, for: trace.id)
                        }
                    }
                    if filters.isEmpty {
                        Text("No filters yet. Add one below.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                Menu("Add Filter") {
                    ForEach(EQFilter.Kind.allCases) { kind in
                        Button(kind.rawValue) { model.setEQ(filters + [defaultFilter(kind)], for: trace.id) }
                    }
                }
                .fixedSize()
                Spacer()
                Menu("More") {
                    Button("Copy Parameters") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(trace.info.name)\n" + ParametricEQ.description(filters), forType: .string)
                    }
                    Button("Add Predicted Response as Trace") { model.addEQPrediction(for: trace.id) }
                    Divider()
                    Button("Remove All Filters", role: .destructive) { model.setEQ([], for: trace.id) }
                }
                .fixedSize()
                .disabled(filters.isEmpty)
            }
            Text("Biquads as in the Audio EQ Cookbook at \(String(format: "%g", trace.eqSampleRate / 1000)) kHz. The Frequency view draws the predicted response dashed while this panel is open. Prediction only: nothing is sent to a processor.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    /// The filters' combined response on its own, with each filter's centre marked.
    private func eqCurve(_ trace: Trace) -> some View {
        let filters = trace.activeEQ
        let fs = trace.eqSampleRate
        let points = stride(from: 0.0, through: log2(20_000.0 / 20), by: 1.0 / 24).map { o -> ChartPoint in
            let f = 20 * pow(2, o)
            return ChartPoint(x: f, y: ParametricEQ.gainDB(filters, at: f, sampleRate: fs))
        }
        let extreme = max(6, (points.map { abs($0.y) }.max() ?? 0).rounded(.up) + 2)
        return Chart {
            RuleMark(y: .value("0 dB", 0)).foregroundStyle(.secondary.opacity(0.5))
            ForEach(points) { p in
                LineMark(x: .value("Frequency", p.x), y: .value("Gain", max(-extreme, p.y)))
                    .foregroundStyle(trace.color)
            }
        }
        .chartXScale(domain: 20...20_000, type: .log)
        .chartYScale(domain: -extreme...extreme)
        .chartXAxis {
            AxisMarks(values: [20, 100, 1000, 10_000]) { value in
                AxisGridLine()
                AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
            }
        }
        .chartYAxisLabel("dB")
        .clipped()
    }

    private func defaultFilter(_ kind: EQFilter.Kind) -> EQFilter {
        switch kind {
        case .peak: return EQFilter(kind: .peak, frequency: 1000, gain: -3, q: 2)
        case .lowShelf: return EQFilter(kind: .lowShelf, frequency: 120, gain: -3, q: 0.707)
        case .highShelf: return EQFilter(kind: .highShelf, frequency: 8000, gain: -3, q: 0.707)
        case .highPass: return EQFilter(kind: .highPass, frequency: 40, q: 0.707)
        case .lowPass: return EQFilter(kind: .lowPass, frequency: 16_000, q: 0.707)
        case .notch: return EQFilter(kind: .notch, frequency: 60, q: 10)
        }
    }

    /// One filter of one trace, bound by id so removing a row never leaves a stale index behind.
    private func binding(_ traceID: UUID, _ filter: EQFilter) -> Binding<EQFilter> {
        Binding(get: { model.traces.first { $0.id == traceID }?.info.eq?.first { $0.id == filter.id } ?? filter },
                set: { new in
                    guard var filters = model.traces.first(where: { $0.id == traceID })?.info.eq,
                          let i = filters.firstIndex(where: { $0.id == filter.id }), filters[i] != new else { return }
                    filters[i] = new
                    model.setEQ(filters, for: traceID)
                })
    }
}

private struct FilterRow: View {
    @Binding var filter: EQFilter
    let index: Int
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("\(index)", isOn: $filter.enabled)
                    .toggleStyle(.checkbox)
                    .help("Turn this filter on or off")
                Picker("Type", selection: $filter.kind) {
                    ForEach(EQFilter.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this filter")
            }
            HStack(spacing: 6) {
                field("Hz", value: $filter.frequency, format: .number.precision(.fractionLength(0...1)))
                field("dB", value: $filter.gain, format: .number.precision(.fractionLength(1)))
                    .disabled(!filter.kind.hasGain)
                    .opacity(filter.kind.hasGain ? 1 : 0.4)
                field("Q", value: $filter.q, format: .number.precision(.fractionLength(2)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private func field(_ unit: String, value: Binding<Double>, format: FloatingPointFormatStyle<Double>) -> some View {
        HStack(spacing: 3) {
            TextField(unit, value: value, format: format)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
