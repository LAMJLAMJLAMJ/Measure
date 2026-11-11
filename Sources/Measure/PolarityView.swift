#if os(macOS)
import Charts
import MeasureDSP
import SwiftUI

/// A polarity checker, as on a handheld analyser: play the generator's polarity pulse through a
/// speaker and each mic says whether the speaker pushed (positive) or pulled (negative) first, over
/// the full range and in a low, mid and high band, so a driver wired the wrong way round shows up.
struct PolarityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let meters = model.inputMeters
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(pulsePlaying ? "Stop Pulse" : "Play Polarity Pulse") { togglePulse() }
                    .help("Plays the generator's polarity pulse on its outputs, at its level. Set them in the Signal Generator.")
                Button("Generator…") { openWindow(id: "generator") }
                    .help("Outputs and level of the pulse")
                Button("Clear") { meters.resetPolarity() }
                    .help("Forget the pulses so far and start counting again")
                Spacer()
            }
            Text("Each mic reads the polarity pulse from the generator (or another polarity checker's generator): positive means the speaker pushed first. The last \(PolarityDetector.votes) pulses vote. Put the mic close to the driver you are checking, as reflections arrive later and are not counted.")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !meters.enabled {
                EmptyState(text: "Turn on Input Meters in the Measurement menu: the polarity check listens on their input.")
            } else if let problem = meters.problem {
                EmptyState(text: problem)
            } else if meters.mics.isEmpty {
                EmptyState(text: "Add a mic input in Measurement Setup.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(meters.mics) { mic in
                            PolarityCard(name: name(mic.id, input: mic.input), report: meters.polarity[mic.id])
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { meters.polarityOn = true }
        .onDisappear { meters.polarityOn = false }
    }

    private var pulsePlaying: Bool {
        model.generator.isRunning && model.generator.settings.signal.kind == .polarity
    }

    private func togglePulse() {
        let generator = model.generator
        if pulsePlaying {
            generator.stop()
            return
        }
        generator.settings.signal.kind = .polarity
        if !generator.isRunning { Task { await generator.start(model) } }
    }

    private func name(_ index: Int, input: Int) -> String {
        let mics = model.settings.mics
        return index < mics.count ? (mics[index].micName ?? "Input \(input)") : "Input \(input)"
    }
}

private struct PolarityCard: View {
    let name: String
    let report: PolarityReport?

    /// Agreement needed among the votes to call it, as a fraction.
    private static let sure = 0.75

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.headline).lineLimit(1)
                Spacer()
                Text(pulsesText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            verdict(report?.readings[.full])
            VStack(spacing: 4) {
                ForEach(PolarityDetector.Band.allCases.filter { $0 != .full }) { band in
                    bandRow(band, report?.readings[band])
                }
            }
            if let pulse = report?.lastPulse, !pulse.isEmpty {
                pulseChart(pulse)
                    .frame(height: 70)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var pulsesText: String {
        guard let report, report.pulses > 0 else { return "No pulses yet" }
        return "\(report.pulses) pulse\(report.pulses == 1 ? "" : "s")"
    }

    private enum Call { case positive, negative, unsure, none }

    private func call(_ reading: PolarityDetector.Reading?) -> Call {
        guard let reading, let polarity = reading.polarity, reading.count > 0 else { return .none }
        guard Double(reading.agreeing) / Double(reading.count) >= Self.sure else { return .unsure }
        return polarity == .positive ? .positive : .negative
    }

    private func verdict(_ reading: PolarityDetector.Reading?) -> some View {
        let c = call(reading)
        let (symbol, text, color): (String, String, Color) = {
            switch c {
            case .positive: return ("plus.circle.fill", "Positive", .green)
            case .negative: return ("minus.circle.fill", "Negative", .red)
            case .unsure: return ("questionmark.circle.fill", "Unsure", .orange)
            case .none: return ("circle.dashed", "Waiting for pulses", .secondary)
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.title2.weight(.semibold))
                if let reading, reading.count > 0 {
                    Text("Full range, \(reading.agreeing) of \(reading.count) pulses agree")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bandRow(_ band: PolarityDetector.Band, _ reading: PolarityDetector.Reading?) -> some View {
        let c = call(reading)
        let sign: String = {
            switch c {
            case .positive: return "+"
            case .negative: return "−"
            case .unsure: return "?"
            case .none: return "–"
            }
        }()
        let color: Color = c == .positive ? .green : (c == .negative ? .red : (c == .unsure ? .orange : .secondary))
        return HStack {
            Text(band.rawValue).frame(width: 40, alignment: .leading)
            Text(band.range).foregroundStyle(.secondary)
            Spacer()
            if let reading, reading.count > 0 {
                Text("\(reading.agreeing)/\(reading.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(sign).font(.headline.monospaced()).foregroundStyle(color).frame(width: 20)
        }
        .font(.callout)
        .help(c == .none ? "No pulse strong enough in this band yet: the speaker may not reproduce it, or the mic is too far." : "")
    }

    private func pulseChart(_ pulse: [Double]) -> some View {
        Chart {
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.5))
            ForEach(Array(pulse.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("Sample", i), y: .value("Level", v))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: -1.05...1.05)
        .help("The last pulse, full range: up is the speaker pushing")
    }
}
#endif
