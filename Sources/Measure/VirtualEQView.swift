#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI

/// Side panel next to the frequency response for trying parametric EQ on the selected trace. The
/// Frequency view draws the predicted result; nothing is sent to a processor.
struct VirtualEQPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("tuningSource") private var source: TuningSource = .sweep

    /// What the panel edits: the selected trace's EQ, or the live curves' EQ.
    private struct Target {
        let title: String
        let filters: [EQFilter]
        let sampleRate: Double
        let color: Color
        /// The response Auto EQ fits, with its mic calibration.
        let response: FrequencyResponse?
        let set: ([EQFilter]) -> Void
        let addPrediction: (() -> Void)?
    }

    var body: some View {
        if let target {
            editor(target)
        } else {
            ContentUnavailableView {
                Label("Virtual EQ", systemImage: "slider.vertical.3")
            } description: {
                Text("Select a trace with a frequency response to try EQ on it. The Frequency view shows the predicted result. Prediction only: nothing is sent to a processor.")
            }
        }
    }

    private var target: Target? {
        if source == .crossSpectrum {
            let live = model.live
            return Target(title: "Live curves", filters: live.settings.eq ?? [], sampleRate: model.settings.sampleRate,
                          color: .primary, response: model.liveAverageResponse, set: { live.settings.eq = $0.isEmpty ? nil : $0 }, addPrediction: nil)
        }
        guard let trace = model.selectedTrace, trace.hasResponse else { return nil }
        let id = trace.id
        return Target(title: trace.info.name, filters: trace.info.eq ?? [], sampleRate: trace.eqSampleRate,
                      color: trace.color, response: model.calibratedResponse(trace), set: { model.setEQ($0, for: id) }, addPrediction: { model.addEQPrediction(for: id) })
    }

    private func editor(_ target: Target) -> some View {
        let filters = target.filters
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Virtual EQ").font(.headline)
                Text(target.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            eqCurve(target).frame(height: 110)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(filters) { filter in
                        FilterRow(filter: binding(filter), index: (filters.firstIndex { $0.id == filter.id } ?? 0) + 1) {
                            target.set(filters.filter { $0.id != filter.id })
                        }
                    }
                    if filters.isEmpty {
                        Text("No filters yet. Add one below.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            AutoEQSection(response: target.response, filters: filters, sampleRate: target.sampleRate, set: target.set)
            HStack {
                Menu("Add Filter") {
                    ForEach(EQFilter.Kind.allCases) { kind in
                        Button(kind.rawValue) { target.set(filters + [defaultFilter(kind)]) }
                    }
                }
                .fixedSize()
                Spacer()
                Menu("More") {
                    Button("Copy Parameters") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(target.title)\n" + ParametricEQ.description(filters), forType: .string)
                    }
                    if let add = target.addPrediction {
                        Button("Add Predicted Response as Trace") { add() }
                    }
                    Divider()
                    Button("Remove All Filters", role: .destructive) { target.set([]) }
                }
                .fixedSize()
                .disabled(filters.isEmpty)
            }
            Text(footnote(target))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func footnote(_ target: Target) -> String {
        let rate = "Biquads as in the Audio EQ Cookbook at \(String(format: "%g", target.sampleRate / 1000)) kHz."
        let what = target.addPrediction == nil
            ? " The live view draws each live curve with this EQ added, dashed, while this panel is open. Capture saves the EQ with the captured traces."
            : " The Frequency view draws the predicted response dashed while this panel is open."
        return rate + what + " Prediction only: nothing is sent to a processor."
    }

    /// The filters' combined response on its own.
    private func eqCurve(_ target: Target) -> some View {
        let filters = target.filters.filter(\.enabled)
        let fs = target.sampleRate
        let points = stride(from: 0.0, through: log2(20_000.0 / 20), by: 1.0 / 24).map { o -> ChartPoint in
            let f = 20 * pow(2, o)
            return ChartPoint(x: f, y: ParametricEQ.gainDB(filters, at: f, sampleRate: fs))
        }
        let extreme = max(6, (points.map { abs($0.y) }.max() ?? 0).rounded(.up) + 2)
        return Chart {
            RuleMark(y: .value("0 dB", 0)).foregroundStyle(.secondary.opacity(0.5))
            ForEach(points) { p in
                LineMark(x: .value("Frequency", p.x), y: .value("Gain", max(-extreme, p.y)))
                    .foregroundStyle(target.color)
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

    /// One filter, bound by id so removing a row never leaves a stale index behind. Reads the
    /// current target each time, so it follows changes to the selection or the source.
    private func binding(_ filter: EQFilter) -> Binding<EQFilter> {
        Binding(get: { target?.filters.first { $0.id == filter.id } ?? filter },
                set: { new in
                    guard let target, let i = target.filters.firstIndex(where: { $0.id == filter.id }),
                          target.filters[i] != new else { return }
                    var filters = target.filters
                    filters[i] = new
                    target.set(filters)
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
                if filter.auto == true {
                    Button("Auto") { filter.auto = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Added by Auto EQ, so the next Auto EQ run replaces it. Click to keep it as your own.")
                }
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
