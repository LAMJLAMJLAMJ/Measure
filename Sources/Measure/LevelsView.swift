#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI

/// The plain recordings among the shown traces, and the one the views look at: the selected trace if
/// it is a recording, otherwise the first shown recording.
@MainActor
private func recordings(_ model: AppModel) -> (all: [Trace], current: Trace?) {
    let all = model.visibleTraces.filter { $0.recording != nil }
    return (all, all.first { $0.id == model.selection } ?? all.first)
}

private let noRecording = "Tick a plain recording in the list. Make one with Record ▸ Plain recording, or Load ▸ Recordings."

private func unitNote(_ offset: Double?) -> String {
    offset == nil ? "dB re full scale (mic not calibrated)" : "dB SPL"
}

/// The dB added to a recording's level re full scale to give dB SPL. Typing a value sets it for this
/// recording; clearing it falls back to the mic's calibration.
struct LevelOffsetField: View {
    @Environment(AppModel.self) private var model
    let trace: Trace

    var body: some View {
        let micOffset = model.micProfiles.first { $0.name == trace.info.mic }?.splOffset
        TextField("Offset (dB)", value: Binding(
            get: { model.traces.first { $0.id == trace.id }?.info.splOffset },
            set: { value in
                guard var info = model.traces.first(where: { $0.id == trace.id })?.info else { return }
                info.splOffset = value
                model.update(info)
            }),
            format: .number.precision(.fractionLength(1)),
            prompt: Text(micOffset.map { String(format: "%.1f (mic)", $0) } ?? "None, dB FS"))
            .help("dB added to \(trace.info.name)'s level re full scale to give dB SPL")
    }
}

// MARK: - Statistical levels

/// Leq, Lmax, Lmin and the exceeded levels Ln of the shown recordings, with the level over time.
struct LevelsView: View {
    private struct Key: Hashable {
        let traces: [UUID]
        let offsets: [Double?]
        let weighting: SoundLevel.FrequencyWeighting
        let timeWeighting: SoundLevel.TimeWeighting
    }

    private struct Row: Identifiable {
        let trace: Trace
        let result: SoundLevel.Result
        let calibrated: Bool
        var id: UUID { trace.id }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("levels.weighting") private var weighting: SoundLevel.FrequencyWeighting = .a
    @AppStorage("levels.time") private var timeWeighting: SoundLevel.TimeWeighting = .fast
    @State private var rows: [Row] = []
    @State private var computedFor: Key?

    var body: some View {
        let shown = recordings(model)
        let traces = shown.all
        let current = shown.current
        let key = Key(traces: traces.map(\.id), offsets: traces.map { model.splOffset(for: $0) },
                      weighting: weighting, timeWeighting: timeWeighting)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Frequency weighting", selection: $weighting) {
                    ForEach(SoundLevel.FrequencyWeighting.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Picker("Time weighting", selection: $timeWeighting) {
                    ForEach(SoundLevel.TimeWeighting.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                if let current { LevelOffsetField(trace: current).frame(width: 240) }
                Spacer()
                Text("IEC 61672 weightings. Ln is the level exceeded n % of the time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if traces.isEmpty {
                EmptyState(text: noRecording)
            } else if computedFor != key {
                ProgressView("Computing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A Table takes at most 10 columns; L1 and L5 are in the CSV.
                Table(rows) {
                    TableColumn("Trace") { Text($0.trace.info.name) }
                    TableColumn("Length") { Text(String(format: "%.1f s", $0.result.duration)) }
                    TableColumn("Leq") { Text(level($0.result.leq)) }
                    TableColumn("Lmax") { Text(level($0.result.lmax)) }
                    TableColumn("Lmin") { Text(level($0.result.lmin)) }
                    TableColumn("L10") { Text(level($0.result.l(10))) }
                    TableColumn("L50") { Text(level($0.result.l(50))) }
                    TableColumn("L90") { Text(level($0.result.l(90))) }
                    TableColumn("L95") { Text(level($0.result.l(95))) }
                    TableColumn("Unit") { Text($0.calibrated ? "dB SPL" : "dB FS").foregroundStyle($0.calibrated ? Color.secondary : Color.orange) }
                }
                .font(.body.monospacedDigit())
                .frame(minHeight: 90, maxHeight: 180)
                if let row = rows.first(where: { $0.id == current?.id }) ?? rows.first {
                    HStack {
                        Text("Level over time: \(row.trace.info.name)").font(.headline)
                        Spacer()
                        Button("Copy All as CSV") { copyCSV() }
                    }
                    historyChart(row)
                }
            }
        }
        .task(id: key) { await compute(traces, key: key) }
    }

    private func level(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return String(format: "%.1f", v)
    }

    private func historyChart(_ row: Row) -> some View {
        let r = row.result
        let points = ChartData.points(r.history, range: 0..<r.history.count, zero: 0,
                                      sampleRate: 1 / r.historyStep, maxPoints: 2000)
        let markers: [(String, Double?)] = [("Leq", r.leq), ("L10", r.l(10)), ("L90", r.l(90))]
        let low = ((r.l(95) ?? r.lmin) - 10).rounded(.down)
        let high = (r.lmax + 5).rounded(.up)
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time (s)", p.x / 1000), y: .value("Level", p.y))
                    .foregroundStyle(row.trace.color)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(markers, id: \.0) { name, value in
                if let value, value.isFinite {
                    RuleMark(y: .value(name, value))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(name) \(String(format: "%.1f", value))").font(.caption).foregroundStyle(.secondary)
                        }
                }
            }
        }
        .chartYScale(domain: low...max(high, low + 10))
        .chartXAxisLabel("Time (s)")
        .chartYAxisLabel("\(weighting.rawValue)-weighted, \(timeWeighting.rawValue), \(unitNote(row.calibrated ? 0 : nil))")
    }

    private func compute(_ traces: [Trace], key: Key) async {
        let w = weighting, t = timeWeighting
        let jobs = zip(traces, key.offsets).map { ($0, $1) }
        let made = await Task.detached(priority: .userInitiated) {
            jobs.map { trace, offset in
                Row(trace: trace,
                    result: SoundLevel.analyze(trace.recording ?? [], sampleRate: trace.info.sampleRate,
                                               weighting: w, timeWeighting: t, offset: offset ?? 0),
                    calibrated: offset != nil)
            }
        }.value
        guard !Task.isCancelled else { return }
        rows = made
        computedFor = key
    }

    private func copyCSV() {
        let w = "\(weighting.rawValue)-weighted \(timeWeighting.rawValue)"
        var text = "Trace,Weighting,Unit,Length (s),Leq,Lmax,Lmin,L1,L5,L10,L50,L90,L95\n"
        for row in rows {
            let r = row.result
            let values = [r.leq, r.lmax, r.lmin] + [1, 5, 10, 50, 90, 95].map { r.l($0) ?? .nan }
            text += "\"\(row.trace.info.name)\",\(w),\(row.calibrated ? "dB SPL" : "dB FS"),\(String(format: "%.1f", r.duration)),"
                + values.map { String(format: "%.1f", $0) }.joined(separator: ",") + "\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Noise rating

/// Octave-band background noise of a recording, rated against the NR and NC curves.
struct NoiseView: View {
    private struct Key: Hashable {
        let trace: UUID
        let offset: Double?
    }

    private struct BandLevel: Identifiable {
        let band: Double
        let level: Double
        var id: Double { band }
        var label: String { band >= 1000 ? "\(Int(band / 1000))k" : (band == 31.5 ? "31.5" : "\(Int(band))") }
    }

    private struct Rating {
        let levels: [BandLevel]
        let laeq: Double
        let nr: Double?
        let nc: Double?
    }

    @Environment(AppModel.self) private var model
    @State private var rating: Rating?
    @State private var computedFor: Key?

    var body: some View {
        let current = recordings(model).current
        let offset = current.flatMap { model.splOffset(for: $0) }
        let key = current.map { Key(trace: $0.id, offset: offset) }
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if let current {
                    Text("Octave-band Leq: \(current.info.name)").font(.headline)
                    if let rating, computedFor == key {
                        chart(rating)
                    } else {
                        ProgressView("Computing…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    EmptyState(text: noRecording)
                }
            }
            .frame(maxWidth: .infinity)
            summary(current, offset: offset).frame(width: 260)
        }
        .task(id: key) {
            guard let current, let key else { return }
            await compute(current, key: key)
        }
    }

    private func chart(_ r: Rating) -> some View {
        let nrCurve = r.nr.map { nr -> (String, [BandLevel]) in
            let n = nr.rounded(.up)
            return ("NR \(Int(n))", zip(NoiseRating.nrBands, NoiseRating.nrCurve(n)).map { BandLevel(band: $0, level: $1) })
        }
        let ncCurve = r.nc.map { nc -> (String, [BandLevel]) in
            let n = nc.rounded(.up)
            return ("NC \(Int(n))", zip(NoiseRating.ncBands, NoiseRating.ncCurve(n)).map { BandLevel(band: $0, level: $1) })
        }
        let curves = [nrCurve, ncCurve].compactMap { $0 }
        let all = r.levels.map(\.level) + curves.flatMap { $0.1.map(\.level) }
        let low = min(0, ((all.min() ?? 0) - 5).rounded(.down))
        let high = ((all.max() ?? 60) + 5).rounded(.up)
        return Chart {
            ForEach(r.levels) { b in
                BarMark(x: .value("Band", b.label), yStart: .value("Level", low), yEnd: .value("Level", b.level))
                    .foregroundStyle(by: .value("Series", "Measured"))
            }
            ForEach(curves, id: \.0) { name, points in
                ForEach(points) { p in
                    LineMark(x: .value("Band", p.label), y: .value("Level", p.level), series: .value("Curve", name))
                        .foregroundStyle(by: .value("Series", name))
                        .symbol(.circle)
                }
            }
        }
        .chartXScale(domain: r.levels.map(\.label))
        .chartYScale(domain: low...high)
        .chartXAxisLabel("Octave band (Hz)")
        .chartYAxisLabel(unitNote(computedFor?.offset))
    }

    @ViewBuilder private func summary(_ current: Trace?, offset: Double?) -> some View {
        Form {
            if let current {
                Section {
                    LevelOffsetField(trace: current)
                } footer: {
                    Text("dB added to the recorded level (re full scale) to give dB SPL. Empty uses the mic's calibration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("NR", value: rating?.nr.map { String(format: "%.0f", $0.rounded(.up)) } ?? "–")
                LabeledContent("NC", value: rating?.nc.map { String(format: "%.0f", $0.rounded(.up)) } ?? "–")
                LabeledContent("LAeq", value: rating.map { String(format: "%.1f", $0.laeq) } ?? "–")
            } header: {
                Text("Rating")
            } footer: {
                Text(offset == nil
                     ? "No level offset, so these are levels re full scale and the ratings are not meaningful. Type an offset above, or calibrate the mic in Setup with a 94 dB calibrator."
                     : "NR to ISO R1996 (31.5 Hz to 8 kHz) and NC to Beranek's 1957 curves (63 Hz to 8 kHz), by the tangency method: the lowest curve no band exceeds.")
                    .font(.caption).foregroundStyle(offset == nil ? .orange : .secondary)
            }
            Section {
                let levels = stiLevels
                // Stacked and full width: side by side the labels do not fit the panel.
                VStack(spacing: 8) {
                    Button { if let levels { model.useSpeechForSTI(levels) } } label: {
                        Text("Use as STI Speech").frame(maxWidth: .infinity)
                    }
                    Button { if let levels { model.useNoiseForSTI(levels) } } label: {
                        Text("Use as STI Noise").frame(maxWidth: .infinity)
                    }
                }
                .disabled(levels == nil || offset == nil)
            } header: {
                Text("STI")
            } footer: {
                Text("Copies these octave levels, 125 Hz to 8 kHz, to the STI speech levels (from a recording of the talker or the system playing speech) or to the STI background noise. Needs an offset, as STI works in dB SPL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The 125 Hz to 8 kHz octave levels STI takes, or nil when a band is missing.
    private var stiLevels: [Double]? {
        guard let r = rating else { return nil }
        let levels = SpeechTransmission.bands.compactMap { b in r.levels.first { $0.band == b }?.level }
        return levels.count == SpeechTransmission.bands.count ? levels : nil
    }

    private func compute(_ trace: Trace, key: Key) async {
        let samples = trace.recording ?? []
        let fs = trace.info.sampleRate
        let offset = key.offset ?? 0
        let made = await Task.detached(priority: .userInitiated) {
            let levels = SoundLevel.octaveLevels(samples, sampleRate: fs, offset: offset)
            let laeq = SoundLevel.analyze(samples, sampleRate: fs, weighting: .a, timeWeighting: .fast, offset: offset).leq
            return Rating(levels: levels.map { BandLevel(band: $0.band, level: $0.level) }, laeq: laeq,
                          nr: NoiseRating.nr(levels), nc: NoiseRating.nc(levels))
        }.value
        guard !Task.isCancelled else { return }
        rating = made
        computedFor = key
    }
}
#endif
