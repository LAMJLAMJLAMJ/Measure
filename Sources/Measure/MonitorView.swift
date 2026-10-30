#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI
import UniformTypeIdentifiers

/// Colours of the SPL meters, also used for their lines in the history.
private let meterColors: [Color] = [.orange, .cyan, .pink, .yellow]

/// The meter's chosen colour, or the default for its place.
private func meterColor(_ meter: MeterSettings, _ index: Int) -> Color {
    meter.colorHex.flatMap(Color.init(hex:)) ?? meterColors[index % meterColors.count]
}

/// The limit line's chosen colour: red for A and purple for C by default.
func limitColor(_ settings: MonitorSettings, _ w: SoundLevel.FrequencyWeighting) -> Color {
    let hex = w == .c ? settings.limitCColorHex : settings.limitAColorHex
    return hex.flatMap(Color.init(hex:)) ?? (w == .c ? .purple : .red)
}

/// A colour well that stores its colour as "#RRGGBB", nil while it shows `standard`.
struct HexColorWell: View {
    @Binding var hex: String?
    let standard: Color
    let help: String

    var body: some View {
        ColorPicker("", selection: Binding(get: { hex.flatMap(Color.init(hex:)) ?? standard },
                                           set: { hex = $0.hex }), supportsOpacity: false)
            .labelsHidden()
            .help(help)
    }
}

private func levelText(_ level: Double?) -> String {
    guard let level, level > -150 else { return "–" }
    return String(format: "%.1f", level)
}

private func elapsedText(_ seconds: Int) -> String {
    String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

/// The SPL view's status: how long it has measured, and whether it is paused.
@MainActor private func runningText(_ monitor: MonitorAnalyzer) -> String {
    guard monitor.isRunning else { return "Stopped. Press Start in the toolbar to listen on the mics from Measurement Setup." }
    let measured = elapsedText(monitor.snapshot.seconds)
    return monitor.isPaused ? "Paused at \(measured) measured. Resume carries on." : "Running \(measured)"
}

// MARK: - SPL

struct SPLView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var monitor = model.monitor
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(monitor.settings.meters.enumerated()), id: \.element.id) { i, meter in
                    MeterCard(meter: meter, index: i)
                }
                if monitor.settings.meters.count < 4 {
                    Button {
                        var new = monitor.settings.meters.last ?? MeterSettings()
                        new.id = UUID()
                        new.colorHex = nil
                        monitor.settings.meters.append(new)
                    } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .help("Add a meter")
                }
            }
            .frame(height: monitor.settings.meters.contains { $0.hasForecast(monitor.settings) } ? 205 : 170)
            HStack(spacing: 12) {
                LimitField(title: "A limit", value: $monitor.settings.limitA, standard: 100,
                           help: "A level not to exceed on A-weighted meters: they turn red above it, and the history draws it as a line")
                if monitor.settings.limitA != nil {
                    HexColorWell(hex: $monitor.settings.limitAColorHex, standard: .red, help: "Colour of the A limit line in the history")
                }
                LimitField(title: "C limit", value: $monitor.settings.limitC, standard: 115,
                           help: "A level not to exceed on C-weighted meters: they turn red above it, and the history draws it as a line")
                if monitor.settings.limitC != nil {
                    HexColorWell(hex: $monitor.settings.limitCColorHex, standard: .purple, help: "Colour of the C limit line in the history")
                }
                Picker("Show", selection: $monitor.settings.historyRange) {
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("1 h").tag(3600)
                    Text("4 h").tag(14_400)
                    Text("All").tag(0)
                }
                .fixedSize()
                Button("Export Log…") { exportLog(monitor) }
                    .disabled(monitor.snapshot.seconds == 0)
                    .help("Save every mic's levels second by second as CSV: LAeq, LAFmax and LAS over each second, and the same for C and Z, with calibrations and offsets applied")
                Spacer()
                Text(runningText(monitor))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            MicOffsetsRow()
            LevelHistoryChart()
            StatisticsRow()
        }
    }
}

extension SPLView {
    private func exportLog(_ monitor: MonitorAnalyzer) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "SPL log \(formatter.string(from: monitor.startDate ?? Date())).csv"
        panel.message = "A row per second since monitoring started or was reset"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try monitor.logCSV(model).write(to: url, atomically: true, encoding: .utf8)
            model.status = "Saved the SPL log as \(url.lastPathComponent)"
        } catch {
            model.errorMessage = "Could not save the SPL log: \(error.localizedDescription)"
        }
    }
}

/// A limit that can be turned on and typed in.
struct LimitField: View {
    let title: String
    @Binding var value: Double?
    /// The value it starts at when turned on.
    let standard: Double
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? standard) : nil }))
            if value != nil {
                TextField(title, value: Binding(get: { value ?? standard }, set: { value = $0 }),
                          format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text("dB").foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help(help)
    }
}

/// An offset field for each mic, added to its levels on top of its calibration.
struct MicOffsetsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.monitor
        HStack(spacing: 14) {
            Text("Mic offsets").foregroundStyle(.secondary)
            ForEach(Array(model.settings.mics.enumerated()), id: \.offset) { i, slot in
                let cal = monitor.calibration(model, mic: i)
                HStack(spacing: 4) {
                    Text(slot.micName ?? "Input \(slot.channel)").lineLimit(1)
                    Text(cal.map { String(format: "cal %.1f dB +", $0) } ?? "not calibrated +")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    TextField("Offset", value: Binding(get: { monitor.settings.micOffset(i) },
                                                       set: { monitor.settings.setMicOffset($0, for: i) }),
                              format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("dB").foregroundStyle(.secondary)
                }
                .fixedSize()
                .help(cal.map { String(format: "Added to the %.1f dB from this mic's calibration", $0) }
                      ?? "This mic has no calibration: its levels are dB re full scale plus this offset. Calibrate it from the Calibration menu for dB SPL.")
            }
            Spacer()
        }
        .font(.callout)
    }
}

/// One meter: a stripe in the meter's colour, the mic's name and the weighting and average as menus,
/// the level large with its unit, a horizontal scale with the limit and maximum, and the maximum and
/// how the level stands against the limit.
struct MeterCard: View {
    @Environment(AppModel.self) private var model
    let meter: MeterSettings
    let index: Int

    var body: some View {
        let monitor = model.monitor
        let offset = monitor.offset(model, mic: meter.mic)
        let mic: MonitorSnapshot.Mic? = meter.mic < monitor.snapshot.mics.count ? monitor.snapshot.mics[meter.mic] : nil
        let level = mic.map { $0.level(meter.weighting, meter.average) + (offset ?? 0) }
        let maximum = self.maximum(mic).map { $0 + (offset ?? 0) }
        let limit = monitor.settings.limit(meter.weighting)
        let over = limit.map { (level ?? -200) >= $0 } ?? false
        let near = limit.map { (level ?? -200) > $0 - 5 } ?? false
        let clipping = (mic?.recentPeak ?? -200) > -1

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HexColorWell(hex: colorHex, standard: meterColors[index % meterColors.count],
                             help: "This meter's colour, on its card and its line in the history")
                micMenu
                Spacer(minLength: 4)
                if clipping { OverloadBadge() }
                unitMenu
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(levelText(level))
                    .font(.system(size: 46, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(over ? Color.red : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(monitor.unit(model, mic: meter.mic)).font(.title3).foregroundStyle(.secondary)
            }
            ScaleBar(level: level, maximum: maximum, limit: limit, spl: offset != nil,
                     limitTint: limitColor(monitor.settings, meter.weighting))
            HStack {
                Text("Max \(levelText(maximum))").monospacedDigit()
                Spacer()
                Text(statusText(level: level, limit: limit, clipping: clipping))
                    .foregroundStyle(statusColor(level: level, limit: limit, clipping: clipping))
                    .help(statusHelp(level: level, limit: limit, clipping: clipping))
            }
            .font(.callout)
            if meter.hasForecast(monitor.settings) {
                Divider()
                ForecastRows(outlook: monitor.outlook(model, meter: meter))
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                .fill(meterColor(meter, index))
                .frame(width: 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(over ? Color.red : near ? Color.yellow : Color.clear, lineWidth: over ? 4 : 2.5))
        .contextMenu {
            if monitor.settings.meters.count > 1 {
                Button("Remove This Meter", role: .destructive) { monitor.settings.meters.removeAll { $0.id == meter.id } }
            }
        }
    }

    private var micNames: [String] { model.settings.mics.map { $0.micName ?? "Input \($0.channel)" } }

    private var micName: String {
        meter.mic < micNames.count ? micNames[meter.mic] : "Mic \(meter.mic + 1)"
    }

    /// Secondary while the level is fine, yellow within 5 dB of the limit, red over it or when the input
    /// clips.
    private func statusColor(level: Double?, limit: Double?, clipping: Bool) -> Color {
        guard let level, level > -150 else { return .secondary }
        if clipping { return .red }
        guard let limit else { return .secondary }
        return level >= limit ? .red : level > limit - 5 ? .yellow : .secondary
    }

    /// "2.3 dB under limit" within 5 dB of it, "1.2 dB over limit" at or over it, otherwise the limit;
    /// "Overload" while the input clips, "No limit" when none is set.
    private func statusText(level: Double?, limit: Double?, clipping: Bool) -> String {
        if clipping { return "Overload" }
        guard let limit else { return "No limit" }
        guard let level, level > -150 else { return String(format: "Limit %.0f", limit) }
        if level >= limit { return String(format: "%.1f dB over limit", level - limit) }
        if level > limit - 5 { return String(format: "%.1f dB under limit", limit - level) }
        return String(format: "Limit %.0f", limit)
    }

    private func statusHelp(level: Double?, limit: Double?, clipping: Bool) -> String {
        if clipping { return "The input is clipping: the levels are not valid. Turn the input gain down." }
        guard let limit else { return "No limit set for this weighting" }
        return String(format: "Yellow within 5 dB of the %.0f dB limit, red at or above it", limit)
    }

    /// Fast and Slow keep their maximum sample by sample; the Leqs take theirs from the history.
    private func maximum(_ mic: MonitorSnapshot.Mic?) -> Double? {
        guard let mic else { return nil }
        if meter.average == .fast || meter.average == .slow { return mic.maximum(meter.weighting, meter.average) }
        return model.monitor.histories[meter.id]?.max() ?? mic.level(meter.weighting, meter.average)
    }

    private var colorHex: Binding<String?> {
        Binding(get: { meter.colorHex }, set: { v in update { $0.colorHex = v } })
    }

    private func update(_ change: (inout MeterSettings) -> Void) {
        let monitor = model.monitor
        guard let i = monitor.settings.meters.firstIndex(where: { $0.id == meter.id }) else { return }
        change(&monitor.settings.meters[i])
    }

    /// The mic's name, which chooses the mic.
    private var micMenu: some View {
        Menu {
            Picker("Mic", selection: Binding(get: { meter.mic }, set: { v in update { $0.mic = v } })) {
                ForEach(Array(micNames.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(micName).font(.headline).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the mic. Right-click the meter to remove it.")
    }

    /// "A · Slow", which chooses the weighting and the average.
    private var unitMenu: some View {
        Menu {
            Picker("Weighting", selection: Binding(get: { meter.weighting }, set: { v in update { $0.weighting = v } })) {
                ForEach(SoundLevel.FrequencyWeighting.allCases) { Text("\($0.rawValue) weighting").tag($0) }
            }
            Picker("Average", selection: Binding(get: { meter.average }, set: { v in update { $0.average = v } })) {
                ForEach(LevelAverage.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Text("\(meter.weighting.rawValue) · \(meter.average.rawValue)").lineLimit(1)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("\(meter.average.label(meter.weighting)): choose the weighting and the average")
    }
}

extension MeterSettings {
    /// An Leq meter with a limit, which shows how long until it reaches the limit or is back under.
    func hasForecast(_ settings: MonitorSettings) -> Bool {
        average != .fast && average != .slow && settings.limit(weighting) != nil
    }
}

/// An Leq meter's forecast against its limit: the time until it reaches the limit at the Fast level
/// now, or once over, until it is back under at that level.
struct ForecastRows: View {
    let outlook: LeqOutlook?

    var body: some View {
        let rows: [(label: String, time: String)] = outlook?.rows ?? [("Limit in (min:s)", "–")]
        VStack(spacing: 3) {
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    Text(rows[i].label).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(rows[i].time)
                        .monospacedDigit()
                        .font(i == 0 ? .title3.weight(.semibold) : .callout)
                        .foregroundStyle(color(i))
                }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .help("If the sound carries on at the Fast level now: how long until this Leq reaches the limit, or once over it, until it is back under.")
    }

    /// The first row red while over the limit, orange when the limit is less than a minute away.
    private func color(_ row: Int) -> Color {
        guard row == 0, let outlook else { return .primary }
        if outlook.over { return .red }
        if let t = outlook.atCurrent, t < 60 { return .orange }
        return .primary
    }
}

/// A horizontal scale from 30 to 130 dB SPL (or -100 to 0 dBFS): the level as a bar,
/// green, yellow within 5 dB of the limit and red over it, a mark at the limit and a small triangle
/// over the maximum.
struct ScaleBar: View {
    let level: Double?
    let maximum: Double?
    let limit: Double?
    let spl: Bool
    let limitTint: Color

    private var range: ClosedRange<Double> { spl ? 30...130 : -100...0 }

    private func x(_ value: Double, _ width: CGFloat) -> CGFloat {
        width * CGFloat(min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }

    private var fill: Color {
        guard let level, let limit else { return .green }
        return level >= limit ? .red : level > limit - 5 ? .yellow : .green
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3).fill(fill.gradient).frame(width: level.map { x($0, w) } ?? 0)
                    if let limit {
                        Rectangle().fill(limitTint).frame(width: 2, height: 16).offset(x: x(limit, w) - 1)
                    }
                    if let maximum, maximum > range.lowerBound {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .offset(x: x(maximum, w) - 4, y: -11)
                    }
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(Int(range.lowerBound))")
                Spacer()
                Text("\(Int((range.lowerBound + range.upperBound) / 2))")
                Spacer()
                Text("\(Int(range.upperBound))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(.top, 8)
        .help(spl ? "30 to 130 dB SPL; the triangle is the maximum, the mark the limit"
                  : "-100 to 0 dBFS; the triangle is the maximum, the mark the limit")
    }
}

/// A red "Overload" capsule, shown while the input clips.
struct OverloadBadge: View {
    var body: some View {
        Text("Overload")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
    }
}

/// A horizontal level bar from 30 to 130 dB SPL (or -100 to 0 dBFS), green, yellow above the limit
/// less 6 dB, red above the limit.
struct LevelBar: View {
    let level: Double?
    let limit: Double?
    let spl: Bool

    var body: some View {
        let range: ClosedRange<Double> = spl ? 30...130 : -100...0
        let fraction = level.map { min(1, max(0, ($0 - range.lowerBound) / (range.upperBound - range.lowerBound))) } ?? 0
        let color: Color = {
            guard let level, let limit else { return .green }
            return level > limit ? .red : level > limit - 6 ? .yellow : .green
        }()
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * fraction)
            }
        }
    }
}

/// One point of a level history.
private struct HistoryPoint: Identifiable {
    let id: Int
    let time: Date
    let level: Double
}

/// The meters' levels over time, one line each, with the limit.
struct LevelHistoryChart: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.monitor
        let lines = monitor.settings.meters.enumerated().map { i, meter in
            (meter.id, meterColor(meter, i), points(meter))
        }
        let levels = lines.flatMap { $0.2.map(\.level) }
        let low = ((levels.min() ?? 40) - 5).rounded(.down)
        let top: Double = ((levels.max() ?? 100) + 5).rounded(.up)
        let limitTop: Double = max(monitor.settings.limitA ?? -300, monitor.settings.limitC ?? -300) + 3
        let high = max(top, limitTop)
        if levels.isEmpty {
            EmptyState(text: monitor.isRunning ? "The history starts after the first second" : "Start live monitoring to see the levels over time")
        } else {
            Chart {
                ForEach(lines, id: \.0) { id, color, points in
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.time), y: .value("Level", p.level), series: .value("Meter", id.uuidString))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                if let limit = monitor.settings.limitA {
                    let color = limitColor(monitor.settings, .a)
                    RuleMark(y: .value("A limit", limit))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("A limit").font(.caption).foregroundStyle(color) }
                }
                if let limit = monitor.settings.limitC {
                    let color = limitColor(monitor.settings, .c)
                    RuleMark(y: .value("C limit", limit))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("C limit").font(.caption).foregroundStyle(color) }
                }
            }
            .chartYScale(domain: low...max(high, low + 10))
            .chartYAxisLabel("dB")
            .chartLegend(.hidden)
            .exportablePlot("SPL history")
        }
    }

    /// The meter's history within the range shown, in its units, thinned to at most 1500 points by
    /// keeping the highest value of each stretch.
    private func points(_ meter: MeterSettings) -> [HistoryPoint] {
        let monitor = model.monitor
        guard let history = monitor.histories[meter.id], let start = monitor.startDate else { return [] }
        let offset = monitor.offset(model, mic: meter.mic) ?? 0
        let range = monitor.settings.historyRange
        let first = range > 0 ? max(0, history.count - range) : 0
        let shown = history[first...]
        let step = max(1, Int((Double(shown.count) / 1500).rounded(.up)))
        return stride(from: first, to: history.count, by: step).map { i in
            let end = min(history.count, i + step)
            let level = history[i..<end].max()! + offset
            // Second i ends i + 1 seconds after the start.
            return HistoryPoint(id: i, time: monitor.endDate(ofSecond: i) ?? start.addingTimeInterval(Double(i + 1)), level: level)
        }
    }
}

/// Max, L10, L50 and L90 of one meter's history over the range shown.
struct StatisticsRow: View {
    @Environment(AppModel.self) private var model
    @State private var meterIndex = 0

    var body: some View {
        let monitor = model.monitor
        let meters = monitor.settings.meters
        let index = min(meterIndex, max(0, meters.count - 1))
        let values = meters.isEmpty ? [] : self.values(meters[index])
        let stats = meters.isEmpty ? [:] : self.statistics(meters[index])
        HStack(spacing: 16) {
            Picker("Statistics of", selection: $meterIndex) {
                ForEach(Array(meters.enumerated()), id: \.offset) { i, m in
                    Text("Meter \(i + 1): \(m.average.label(m.weighting))").tag(i)
                }
            }
            .fixedSize()
            stat("Max", values.max())
            stat("L10", stats[10])
            stat("L50", stats[50])
            stat("L90", stats[90])
            Spacer()
            Text(monitor.settings.historyRange > 0 ? "over the time shown" : "since the start")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func stat(_ name: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary)
            Text(levelText(value)).monospacedDigit().fontWeight(.semibold)
        }
    }

    private func values(_ meter: MeterSettings) -> [Double] {
        let monitor = model.monitor
        guard let history = monitor.histories[meter.id] else { return [] }
        let offset = monitor.offset(model, mic: meter.mic) ?? 0
        let range = monitor.settings.historyRange
        return history.suffix(range > 0 ? range : history.count).map { $0 + offset }
    }

    /// L10, L50 and L90 with the mic's offset: from the level every tenth of a second for Fast and
    /// Slow meters (the history holds each second's highest Fast level, which would read high).
    private func statistics(_ meter: MeterSettings) -> [Int: Double] {
        let monitor = model.monitor
        guard let stats = monitor.statistics[meter.id] else { return [:] }
        let offset = monitor.offset(model, mic: meter.mic) ?? 0
        return stats.mapValues { $0 + offset }
    }
}

// MARK: - RTA

struct RTAView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("rtaRange") private var range: Double = 80

    var body: some View {
        @Bindable var monitor = model.monitor
        let snap = monitor.snapshot
        let offset = monitor.offset(model, mic: monitor.settings.rtaMic)
        let bars = self.bars(snap, offset: offset)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Mic", selection: $monitor.settings.rtaMic) {
                    ForEach(Array(model.settings.mics.enumerated()), id: \.offset) { i, slot in
                        Text(slot.micName ?? "Input \(slot.channel)").tag(i)
                    }
                }
                .fixedSize()
                Picker("Bands", selection: $monitor.settings.rtaFraction) {
                    Text("1/1 octave").tag(1)
                    Text("1/3 octave").tag(3)
                    Text("1/6 octave").tag(6)
                    Text("1/12 octave").tag(12)
                    Text("1/24 octave").tag(24)
                }
                .fixedSize()
                Picker("Weighting", selection: $monitor.settings.rtaWeighting) {
                    ForEach(SoundLevel.FrequencyWeighting.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Average", selection: $monitor.settings.rtaAveraging) {
                    ForEach(RealTimeAnalyzer.Averaging.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            HStack(spacing: 12) {
                Picker("FFT", selection: $monitor.settings.rtaFFTSize) {
                    ForEach([8192, 16_384, 32_768, 65_536], id: \.self) { n in
                        Text("\(n / 1024)k (\(String(format: "%.2f", Double(n) / monitor.sampleRate)) s)").tag(n)
                    }
                }
                .fixedSize()
                .help("Longer blocks resolve the low bands better but react more slowly")
                Picker("Range", selection: $range) {
                    Text("60 dB").tag(60.0)
                    Text("80 dB").tag(80.0)
                    Text("100 dB").tag(100.0)
                    Text("120 dB").tag(120.0)
                }
                .fixedSize()
                Button("Reset Peaks") { monitor.resetPeaks() }
                    .disabled(!monitor.isRunning)
                Spacer()
                Text(summary(bars, offset: offset))
                    .font(.callout).monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if bars.isEmpty {
                EmptyState(text: monitor.isRunning ? "Waiting for the first block" : "Start live monitoring to see the spectrum")
            } else {
                chart(bars, top: offset == nil ? 0 : 130)
            }
            Text("Bands from an FFT of the latest block (Hann window), each bin shared between the bands it overlaps. \(offset == nil ? "dB re full scale: calibrate the mic in Setup for dB SPL." : "Levels include the mic's calibration and offset.") Grey ticks: peak hold.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private struct Bar: Identifiable {
        let id: Int
        let band: RealTimeAnalyzer.Band
        let level: Double
        let peak: Double
    }

    /// Band levels with the weighting, the mic's calibration curve and its SPL offset.
    private func bars(_ snap: MonitorSnapshot, offset: Double?) -> [Bar] {
        let monitor = model.monitor
        guard snap.bands.count == snap.rtaLevels.count, snap.bands.count == snap.rtaPeaks.count else { return [] }
        let mics = model.settings.mics
        let cal = monitor.settings.rtaMic < mics.count ? model.calibration(mic: mics[monitor.settings.rtaMic].micName) : nil
        let w = monitor.settings.rtaWeighting
        return snap.bands.indices.map { i in
            let f = snap.bands[i].center
            let shift = SoundLevel.weightingDB(w, at: f) - (cal?.magnitude(at: f) ?? 0) + (offset ?? 0)
            return Bar(id: i, band: snap.bands[i], level: snap.rtaLevels[i] + shift, peak: snap.rtaPeaks[i] + shift)
        }
    }

    private func summary(_ bars: [Bar], offset: Double?) -> String {
        guard let loudest = bars.max(by: { $0.level < $1.level }), loudest.level > -150 else { return "" }
        let total = 10 * log10(bars.map { pow(10, $0.level / 10) }.reduce(0, +))
        let unit = model.monitor.unit(model, mic: model.monitor.settings.rtaMic)
        let w = model.monitor.settings.rtaWeighting.rawValue
        let f = loudest.band.center
        let band = f >= 1000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f)
        return String(format: "Total %.1f %@ (%@)   Loudest band %@, %.1f", total, unit, w, band, loudest.level)
    }

    private func chart(_ bars: [Bar], top: Double) -> some View {
        let bottom = top - range
        return Chart {
            ForEach(bars) { bar in
                // A small gap between neighbouring bars.
                let gap = pow(bar.band.upper / bar.band.lower, 0.08)
                RectangleMark(xStart: .value("From", bar.band.lower * gap), xEnd: .value("To", bar.band.upper / gap),
                              yStart: .value("Floor", bottom), yEnd: .value("Level", min(top, max(bottom, bar.level))))
                    .foregroundStyle(Color.green.gradient)
            }
            ForEach(bars) { bar in
                RuleMark(xStart: .value("From", bar.band.lower), xEnd: .value("To", bar.band.upper),
                         y: .value("Peak", min(top, max(bottom, bar.peak))))
                    .foregroundStyle(.gray)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXScale(domain: 15...22_000, type: .log)
        .chartYScale(domain: bottom...top)
        .chartXAxis {
            AxisMarks(values: frequencyTicks) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
            }
        }
        .chartXAxisLabel("Hz")
        .chartYAxisLabel("dB")
        .clipped()
        .exportablePlot("RTA")
    }
}
#endif
