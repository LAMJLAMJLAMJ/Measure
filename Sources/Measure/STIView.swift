#if os(macOS)
import Charts
import MeasureDSP
import SwiftUI

/// Speech Transmission Index (IEC 60268-16) of the shown impulse responses, with the speech and noise
/// levels it is computed for.
struct STIView: View {
    private struct Key: Hashable {
        let traces: [UUID]
        let conditions: SpeechTransmission.Conditions
    }

    private struct Row: Identifiable {
        let trace: Trace
        let result: SpeechTransmission.Result
        /// Where the response falls short of IEC 60268-16 6.2.
        let notes: String
        var id: UUID { trace.id }
    }

    private struct BandValue: Identifiable {
        let band: String
        let mti: Double
        var id: String { band }
    }

    @Environment(AppModel.self) private var model
    @State private var rows: [Row] = []
    @State private var computedFor: Key?

    var body: some View {
        let traces = model.visibleTraces.filter { $0.impulseResponse != nil }
        let key = Key(traces: traces.map(\.id), conditions: model.sti.conditions)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if traces.isEmpty {
                    EmptyState(text: "Tick measured or imported impulse responses in the list")
                } else if computedFor != key {
                    ProgressView("Computing…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(rows) {
                        TableColumn("Trace") { Text($0.trace.info.name) }
                        TableColumn("STI") { Text(String(format: "%.2f", $0.result.sti)) }
                        TableColumn("Rating") { Text($0.result.rating) }
                        TableColumn("Notes") { Text($0.notes.isEmpty ? "OK" : $0.notes).foregroundStyle($0.notes.isEmpty ? Color.secondary : Color.orange) }
                    }
                    .font(.body.monospacedDigit())
                    .frame(minHeight: 100, maxHeight: 200)
                    if let row = rows.first(where: { $0.id == model.selection }) ?? rows.first {
                        Text("Modulation transfer index per band: \(row.trace.info.name)").font(.headline)
                        mtiChart(row)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            conditionsPanel.frame(width: 300)
        }
        .task(id: key) { await compute(traces, key: key) }
    }

    private func mtiChart(_ row: Row) -> some View {
        let values = zip(SpeechTransmission.bands, row.result.mti).map { BandValue(band: bandLabel($0), mti: $1) }
        return Chart(values) { v in
            BarMark(x: .value("Band", v.band), y: .value("MTI", v.mti))
                .foregroundStyle(row.trace.color)
                .annotation(position: .top) { Text(String(format: "%.2f", v.mti)).font(.caption2.monospacedDigit()) }
        }
        .chartYScale(domain: 0...1)
        .chartXAxisLabel("Hz")
        .chartYAxisLabel("MTI")
        .frame(minHeight: 180)
    }

    @ViewBuilder private var conditionsPanel: some View {
        @Bindable var model = model
        Form {
            Section("Speech") {
                LabeledContent("Level") {
                    HStack {
                        TextField("Level", value: $model.sti.speechLevelA, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .frame(width: 60)
                        Text("dB(A)")
                    }
                }
                .disabled(model.sti.customSpeech)
                Toggle("Own octave levels", isOn: $model.sti.customSpeech)
                if model.sti.customSpeech {
                    levelGrid($model.sti.speechLevels)
                } else {
                    Text("Male speech spectrum, IEC 60268-16:2020 Table A.4. 60 dB(A) is normal effort at 1 m.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Background noise") {
                Toggle("Include noise", isOn: $model.sti.includeNoise)
                if model.sti.includeNoise { levelGrid($model.sti.noiseLevels) }
            }
            Section {
                Toggle("Auditory masking and threshold", isOn: $model.sti.auditoryEffects)
            } footer: {
                Text("IEC 60268-16:2020 (edition 5), indirect method. Levels are dB SPL at the listener. Each band's response is filtered backwards in time and cut where it meets its noise floor, so measurement noise does not lower the result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func levelGrid(_ levels: Binding<[Double]>) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 4) {
            ForEach(SpeechTransmission.bands.indices, id: \.self) { k in
                GridRow {
                    Text(bandLabel(SpeechTransmission.bands[k]) + " Hz").foregroundStyle(.secondary)
                    TextField("dB", value: levels[k], format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .frame(width: 60)
                    Text("dB").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout.monospacedDigit())
    }

    /// The standard asks for at least 1.6 s of response and 20 dB SNR in every band (6.2 b and c).
    private func notes(for trace: Trace) -> String {
        var out: [String] = []
        let length = Double((trace.impulseResponse?.count ?? 0) - trace.onset) / trace.info.sampleRate
        if length < 1.6 { out.append(String(format: "only %.1f s long", length)) }
        let low = SpeechTransmission.bands.filter { nominal in
            guard let p = trace.acoustics?.bands.first(where: { $0.band?.nominal == nominal }) else { return false }
            return p.peakToNoise < 20
        }
        if !low.isEmpty { out.append("under 20 dB SNR at " + low.map { bandLabel($0) }.joined(separator: ", ") + " Hz") }
        return out.joined(separator: "; ")
    }

    private func bandLabel(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }

    private func compute(_ traces: [Trace], key: Key) async {
        let inputs = traces.map { trace -> (Trace, [Double], Int, Double, [Double?]) in
            let truncation = SpeechTransmission.bands.map { nominal in
                trace.acoustics?.bands.first { $0.band?.nominal == nominal }?.truncationTime
            }
            return (trace, trace.impulseResponse!, trace.onset, trace.info.sampleRate, truncation)
        }
        let traceNotes = Dictionary(uniqueKeysWithValues: traces.map { ($0.id, self.notes(for: $0)) })
        let conditions = key.conditions
        let made = await Task.detached(priority: .userInitiated) { () -> [Row] in
            inputs.map { trace, ir, onset, fs, truncation in
                Row(trace: trace, result: SpeechTransmission.analyze(impulseResponse: ir, sampleRate: fs, onset: onset,
                                                                     conditions: conditions, truncation: truncation),
                    notes: traceNotes[trace.id] ?? "")
            }
        }.value
        guard !Task.isCancelled else { return }
        rows = made
        computedFor = key
    }
}
#endif
