#if os(macOS)
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
                BandEdges(meters: meters)
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12)], spacing: 12) {
                        ForEach(meters.mics) { mic in
                            PolarityCard(name: name(mic.id, input: mic.input), report: meters.polarity[mic.id], crossovers: meters.crossovers)
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

/// The edges of the low, mid and high bands, typed in Hz. A change starts the count again.
private struct BandEdges: View {
    let meters: InputMeters
    @State private var low = 0.0
    @State private var high = 0.0

    var body: some View {
        HStack(spacing: 6) {
            Text("Low | Mid").foregroundStyle(.secondary)
            field($low)
            Text("Mid | High").foregroundStyle(.secondary).padding(.leading, 6)
            field($high)
            Button("Reset") { apply(.standard) }
                .disabled(meters.crossovers == .standard)
                .help("Back to 250 Hz and 2.5 kHz")
        }
        .font(.callout)
        .onAppear { show(meters.crossovers) }
        .onChange(of: meters.crossovers) { _, c in show(c) }
        .help("Where the bands split, Hz. Low from \(Int(PolarityDetector.Crossovers.lowRange.lowerBound)) to \(Int(PolarityDetector.Crossovers.lowRange.upperBound)) Hz; the mid band is kept at least an octave wide.")
    }

    private func field(_ value: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .onSubmit { apply(PolarityDetector.Crossovers(low: low, high: high)) }
            Text("Hz").foregroundStyle(.secondary)
        }
    }

    private func show(_ c: PolarityDetector.Crossovers) {
        low = c.low
        high = c.high
    }

    private func apply(_ c: PolarityDetector.Crossovers) {
        meters.crossovers = c
        // Show what was kept after clamping, even when nothing changed.
        show(meters.crossovers)
    }
}

private struct PolarityCard: View {
    let name: String
    let report: PolarityReport?
    let crossovers: PolarityDetector.Crossovers

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
            if let pulse = report?.lastPulse, !pulse.isEmpty {
                PulseTrace(values: pulse)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .background(ZeroLine())
                    .frame(height: 60)
                    .help("The last pulse, full range: up is the speaker pushing")
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(PolarityDetector.Band.allCases.filter { $0 != .full }) { band in
                    bandPanel(band, report?.readings[band], pulse: report?.bandPulses[band])
                }
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

    private func color(_ c: Call) -> Color {
        switch c {
        case .positive: return .green
        case .negative: return .red
        case .unsure: return .orange
        case .none: return .secondary
        }
    }

    /// One band on its own: its verdict, how many pulses agree, its level and its last pulse.
    private func bandPanel(_ band: PolarityDetector.Band, _ reading: PolarityDetector.Reading?, pulse: [Double]?) -> some View {
        let c = call(reading)
        let tint = color(c)
        let symbol: String = {
            switch c {
            case .positive: return "plus.circle.fill"
            case .negative: return "minus.circle.fill"
            case .unsure: return "questionmark.circle.fill"
            case .none: return "circle.dashed"
            }
        }()
        let counted = reading.map { $0.count > 0 } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            Text(band.rawValue).font(.callout.weight(.semibold))
            Text(band.range(crossovers)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(tint)
                if let reading, counted {
                    Text("\(reading.agreeing)/\(reading.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            bandTrace(pulse, tint: tint, show: counted)
                .frame(height: 44)
            if let reading, counted {
                Text(String(format: "%.0f dBFS", reading.level)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
        .help(c == .none ? "No pulse strong enough in this band yet: the speaker may not reproduce it, or the mic is too far." : "The last pulse in this band, scaled to fill: up is the speaker pushing")
    }

    @ViewBuilder
    private func bandTrace(_ pulse: [Double]?, tint: Color, show: Bool) -> some View {
        if let pulse, show, !pulse.isEmpty {
            PulseTrace(values: pulse)
                .stroke(tint, lineWidth: 1.2)
                .background(ZeroLine())
        } else {
            ZeroLine()
        }
    }
}

/// A pulse drawn as a line, values from -1 at the bottom to 1 at the top.
private struct PulseTrace: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let dx = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let clamped = min(max(v, -1.05), 1.05)
            let point = CGPoint(x: rect.minX + CGFloat(i) * dx, y: rect.midY - CGFloat(clamped / 1.05) * rect.height / 2)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The zero line behind a pulse.
private struct ZeroLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                p.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }
            .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
        }
    }
}
#endif
