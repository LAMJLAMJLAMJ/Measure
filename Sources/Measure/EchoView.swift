#if os(macOS)
import Charts
import MeasureDSP
import SwiftUI

/// Echo criterion after Dietsch and Kraak for the shown impulse responses.
struct EchoView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case octave1k = "1 kHz octave", octave2k = "2 kHz octave", broadband = "Broadband"
        var id: String { rawValue }
        var nominal: Double? {
            switch self {
            case .octave1k: return 1000
            case .octave2k: return 2000
            case .broadband: return nil
            }
        }
    }

    private struct Key: Hashable {
        let traces: [UUID]
        let programme: EchoCriterion.Programme
        let filter: Filter
    }

    private struct Row: Identifiable {
        let trace: Trace
        let result: EchoCriterion.Result
        let points: [ChartPoint]
        var id: UUID { trace.id }
    }

    /// One line of the table: an echo, or a trace without any.
    private struct TableLine: Identifiable {
        let id: String
        let trace: Trace
        let time: Double?
        let ek: Double
        let share: Int
    }

    @Environment(AppModel.self) private var model
    @AppStorage("echo.programme") private var programme: EchoCriterion.Programme = .speech
    @AppStorage("echo.filter") private var filter: Filter = .octave1k
    @State private var rows: [Row] = []
    @State private var computedFor: Key?

    var body: some View {
        let traces = model.visibleTraces.filter { $0.impulseResponse != nil }
        let key = Key(traces: traces.map(\.id), programme: programme, filter: filter)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Programme", selection: $programme) {
                    ForEach(EchoCriterion.Programme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 180)
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 200)
                Spacer()
                Text(String(format: "n = %@, Δτ = %g ms", programme == .speech ? "2/3" : "1", programme.interval * 1000))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if traces.isEmpty {
                EmptyState(text: "Tick measured or imported impulse responses in the list")
            } else if computedFor != key {
                ProgressView("Computing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
                Table(tableLines) {
                    TableColumn("Trace") { Text($0.trace.info.name) }
                    TableColumn("EK") { Text(String(format: "%.2f", $0.ek)) }
                    TableColumn("At ms") { Text($0.time.map { String(format: "%.0f", $0 * 1000) } ?? "–") }
                    TableColumn("Echo") { line in
                        Text(verdict(line))
                            .foregroundStyle(line.share == 50 ? Color.red : line.share == 10 ? Color.orange : Color.secondary)
                    }
                }
                .font(.body.monospacedDigit())
                .frame(minHeight: 100, maxHeight: 220)
                Text("EK is the rise of the centre time over Δτ, from the direct sound. Above the red line an echo is likely to be heard by 50 % of listeners, above the orange line by 10 %. Dietsch and Kraak filter to the 1 kHz octave.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) { await compute(traces, key: key) }
    }

    private var chart: some View {
        Chart {
            ForEach(rows) { row in
                ForEach(row.points) { p in
                    LineMark(x: .value("Time", p.x), y: .value("EK", p.y), series: .value("Trace", row.id.uuidString))
                        .foregroundStyle(row.trace.color)
                        .lineStyle(StrokeStyle(lineWidth: row.id == model.selection ? 2 : 1.2))
                }
            }
            ForEach(rows) { row in
                ForEach(row.result.echoes, id: \.time) { echo in
                    PointMark(x: .value("Time", echo.time * 1000), y: .value("EK", echo.ek))
                        .foregroundStyle(row.trace.color)
                        .symbolSize(40)
                }
            }
                        RuleMark(y: .value("EK", programme.limit50))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .annotation(position: .top, alignment: .trailing) { Text("50 %").font(.caption2).foregroundStyle(.red) }
            RuleMark(y: .value("EK", programme.limit10))
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .annotation(position: .bottom, alignment: .trailing) { Text("10 %").font(.caption2).foregroundStyle(.orange) }
        }
        .chartXAxisLabel("ms from direct sound")
        .chartYAxisLabel("EK")
        .chartLegend(.hidden)
        .clipped()
        .exportablePlot("Echo")
    }

    /// Every echo of every trace in time order, and one line with the highest EK for a trace without any.
    private var tableLines: [TableLine] {
        rows.flatMap { row -> [TableLine] in
            if row.result.echoes.isEmpty {
                return [TableLine(id: "\(row.id)", trace: row.trace, time: nil, ek: row.result.maxEK, share: 0)]
            }
            return row.result.echoes.enumerated().map { i, echo in
                TableLine(id: "\(row.id)-\(i)", trace: row.trace, time: echo.time, ek: echo.ek, share: echo.audibleShare)
            }
        }
    }

    private func verdict(_ line: TableLine) -> String {
        switch line.share {
        case 50: return "Likely (50 % of listeners)"
        case 10: return "Possible (10 % of listeners)"
        default: return "None (highest EK shown)"
        }
    }

    private func compute(_ traces: [Trace], key: Key) async {
        let programme = key.programme, nominal = key.filter.nominal
        let inputs = traces.map { ($0, $0.impulseResponse!, $0.onset, $0.info.sampleRate) }
        let made = await Task.detached(priority: .userInitiated) { () -> [Row] in
            inputs.map { trace, ir, onset, fs in
                var signal = ir
                if let nominal {
                    signal = BandPassFilter(band: BandResolution.octave.band(nominal: nominal), sampleRate: fs).apply(ir)
                }
                let result = EchoCriterion.analyze(signal, sampleRate: fs, onset: onset, programme: programme)
                let points = zip(result.times, result.ek).map { ChartPoint(x: $0 * 1000, y: $1) }
                return Row(trace: trace, result: result, points: points)
            }
        }.value
        guard !Task.isCancelled else { return }
        rows = made
        computedFor = key
    }
}
#endif
