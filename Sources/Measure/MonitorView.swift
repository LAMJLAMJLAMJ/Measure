#if os(macOS)
import Charts
import MeasureDSP
import SwiftUI

/// Colours of the SPL meters, also used for their lines in the history.
private let meterColors: [Color] = [.orange, .cyan, .pink, .yellow]

private func meterColor(_ index: Int) -> Color { meterColors[index % meterColors.count] }

private func levelText(_ level: Double?) -> String {
    guard let level, level > -150 else { return "–" }
    return String(format: "%.1f", level)
}

private func elapsedText(_ seconds: Int) -> String {
    String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
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
                        monitor.settings.meters.append(new)
                    } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .help("Add a meter")
                }
            }
            .frame(height: 170)
            HStack(spacing: 12) {
                Toggle("Limit", isOn: Binding(get: { monitor.settings.limit != nil },
                                              set: { monitor.settings.limit = $0 ? (monitor.settings.limit ?? 100) : nil }))
                    .help("A level not to exceed: meters above it turn red, and the history draws it as a red line")
                if monitor.settings.limit != nil {
                    TextField("Limit", value: Binding(get: { monitor.settings.limit ?? 100 }, set: { monitor.settings.limit = $0 }),
                              format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("dB").foregroundStyle(.secondary)
                }
                Picker("Show", selection: $monitor.settings.historyRange) {
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("1 h").tag(3600)
                    Text("4 h").tag(14_400)
                    Text("All").tag(0)
                }
                .fixedSize()
                Spacer()
                Text(monitor.isRunning ? "Running \(elapsedText(monitor.snapshot.seconds))" : "Stopped. Press Start in the toolbar to listen on the mics from Measurement Setup.")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            LevelHistoryChart()
            StatisticsRow()
        }
    }
}

/// One meter: a big number, its maximum, and a bar.
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
        let over = monitor.settings.limit.map { (level ?? -200) > $0 } ?? false
        let clipping = (mic?.recentPeak ?? -200) > -1

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(meterColor(index)).frame(width: 9, height: 9)
                Text(micName).font(.headline).lineLimit(1)
                Spacer()
                if clipping { Text("Overload").font(.caption.bold()).foregroundStyle(.red) }
                settingsMenu
            }
            Text(levelText(level))
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(over ? Color.red : Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .center)
            LevelBar(level: level, limit: monitor.settings.limit, spl: offset != nil)
                .frame(height: 8)
            HStack {
                Text("Max \(levelText(maximum))").monospacedDigit()
                Spacer()
                Text("\(offset == nil ? "dBFS" : "dB SPL") \(meter.average.label(meter.weighting))")
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(over ? Color.red : meterColor(index).opacity(0.6), lineWidth: over ? 2 : 1))
    }

    private var micName: String {
        let names = model.settings.mics.map { $0.micName ?? "Input \($0.channel)" }
        return meter.mic < names.count ? names[meter.mic] : "Mic \(meter.mic + 1)"
    }

    /// Fast and Slow keep their maximum sample by sample; the Leqs take theirs from the history.
    private func maximum(_ mic: MonitorSnapshot.Mic?) -> Double? {
        guard let mic else { return nil }
        if meter.average == .fast || meter.average == .slow { return mic.maximum(meter.weighting, meter.average) }
        return model.monitor.histories[meter.id]?.max() ?? mic.level(meter.weighting, meter.average)
    }

    private var settingsMenu: some View {
        let monitor = model.monitor
        let id = meter.id
        func update(_ change: (inout MeterSettings) -> Void) {
            guard let i = monitor.settings.meters.firstIndex(where: { $0.id == id }) else { return }
            change(&monitor.settings.meters[i])
        }
        return Menu {
            Picker("Mic", selection: Binding(get: { meter.mic }, set: { v in update { $0.mic = v } })) {
                ForEach(Array(model.settings.mics.enumerated()), id: \.offset) { i, slot in
                    Text(slot.micName ?? "Input \(slot.channel)").tag(i)
                }
            }
            Picker("Weighting", selection: Binding(get: { meter.weighting }, set: { v in update { $0.weighting = v } })) {
                ForEach(SoundLevel.FrequencyWeighting.allCases) { Text("\($0.rawValue) weighting").tag($0) }
            }
            Picker("Average", selection: Binding(get: { meter.average }, set: { v in update { $0.average = v } })) {
                ForEach(LevelAverage.allCases) { Text($0.rawValue).tag($0) }
            }
            if monitor.settings.meters.count > 1 {
                Divider()
                Button("Remove This Meter", role: .destructive) { monitor.settings.meters.removeAll { $0.id == id } }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Mic, weighting and average")
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
            (meter.id, meterColor(i), points(meter))
        }
        let levels = lines.flatMap { $0.2.map(\.level) }
        let low = ((levels.min() ?? 40) - 5).rounded(.down)
        let high = max(((levels.max() ?? 100) + 5).rounded(.up), (monitor.settings.limit ?? -300) + 3)
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
                if let limit = monitor.settings.limit {
                    RuleMark(y: .value("Limit", limit))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                }
            }
            .chartYScale(domain: low...max(high, low + 10))
            .chartYAxisLabel("dB")
            .chartLegend(.hidden)
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
            return HistoryPoint(id: i, time: start.addingTimeInterval(Double(i + 1)), level: level)
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
        HStack(spacing: 16) {
            Picker("Statistics of", selection: $meterIndex) {
                ForEach(Array(meters.enumerated()), id: \.offset) { i, m in
                    Text("Meter \(i + 1): \(m.average.label(m.weighting))").tag(i)
                }
            }
            .fixedSize()
            stat("Max", values.max())
            stat("L10", percentile(values, exceeded: 10))
            stat("L50", percentile(values, exceeded: 50))
            stat("L90", percentile(values, exceeded: 90))
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

    /// The level exceeded `n` % of the time.
    private func percentile(_ values: [Double], exceeded n: Int) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let i = Int((Double(100 - n) / 100 * Double(sorted.count - 1)).rounded())
        return sorted[min(sorted.count - 1, max(0, i))]
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
            Text("Bands from an FFT of the latest block (Hann window), each bin shared between the bands it overlaps. \(offset == nil ? "dB re full scale: calibrate the mic in Setup for dB SPL." : "dB SPL from the mic's calibration") Grey ticks: peak hold.")
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
        let unit = offset == nil ? "dBFS" : "dB SPL"
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
    }
}
#endif
