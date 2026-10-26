#if os(macOS)
import Charts
import MeasureDSP
import SwiftUI

/// How the Distortion view draws the harmonics.
enum DistortionDisplay: String, CaseIterable, Identifiable {
    /// The fundamental and each harmonic in dB, on the impulse response's scale.
    case levels = "Levels"
    /// Each harmonic and the THD in dB below the fundamental.
    case relative = "dB re Fundamental"
    /// Each harmonic and the THD in percent of the fundamental.
    case percent = "Percent"
    var id: String { rawValue }
}

/// One curve on the distortion chart.
private struct DistortionCurve: Identifiable {
    let id: String
    let name: String
    let color: Color
    let width: CGFloat
    let points: [ChartPoint]
}

/// Harmonic distortion of the selected trace, from the sweep it was measured with: the fundamental,
/// the second to fifth harmonics and the THD against the fundamental's frequency.
struct DistortionView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("distortion.display") private var display: DistortionDisplay = .relative

    private static let harmonicColors: [Color] = [.blue, .green, .orange, .purple, .teal, .brown, .pink, .indigo]

    var body: some View {
        let candidates = model.visibleTraces.filter { $0.info.distortion != nil }
        let trace = candidates.first { $0.id == model.selection } ?? candidates.first
        VStack(alignment: .leading, spacing: 8) {
            if let trace, let d = trace.info.distortion {
                header(trace, d)
                chart(trace, d)
                Text(caption(d))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                EmptyState(text: "Tick a trace measured with a sweep to see its distortion")
                Text("Distortion is separated from the sweep recording when the measurement is made, so sweeps measured before this version, imported files and live captures have none. Measure again to see it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func header(_ trace: Trace, _ d: HarmonicDistortion) -> some View {
        HStack(spacing: 12) {
            Circle().fill(trace.color).frame(width: 9, height: 9)
            Text(trace.info.name).font(.headline).lineLimit(1)
            if let level = d.sweepLevel {
                Text(String(format: "sweep at %.0f dBFS", level)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Picker("Show", selection: $display) {
                ForEach(DistortionDisplay.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Data

    /// The fundamental and harmonics with the mic's calibration taken off, each at its own frequency.
    private func calibrated(_ trace: Trace, _ d: HarmonicDistortion) -> (fundamental: [Double], harmonics: [[Double?]]) {
        guard let cal = model.calibration(for: trace) else { return (d.fundamental, d.harmonics) }
        let fundamental = d.frequencies.indices.map { d.fundamental[$0] - cal.magnitude(at: d.frequencies[$0]) }
        var harmonics: [[Double?]] = []
        for (n, levels) in d.harmonics.enumerated() {
            let k = Double(n + 2)
            var row: [Double?] = []
            for (i, level) in levels.enumerated() {
                row.append(level.map { $0 - cal.magnitude(at: k * d.frequencies[i]) })
            }
            harmonics.append(row)
        }
        return (fundamental, harmonics)
    }

    private func curves(_ trace: Trace, _ d: HarmonicDistortion) -> [DistortionCurve] {
        let (fundamental, harmonics) = calibrated(trace, d)
        let f = d.frequencies
        var out: [DistortionCurve] = []
        if display == .levels {
            let points = f.indices.map { ChartPoint(x: f[$0], y: fundamental[$0]) }
            out.append(DistortionCurve(id: "h1", name: "Fundamental", color: trace.color, width: 2, points: points))
        }
        for (n, levels) in harmonics.enumerated() {
            var points: [ChartPoint] = []
            for i in f.indices {
                guard let level = levels[i] else { continue }
                points.append(ChartPoint(x: f[i], y: value(level, fundamental: fundamental[i])))
            }
            let color = DistortionView.harmonicColors[n % DistortionView.harmonicColors.count]
            out.append(DistortionCurve(id: "h\(n + 2)", name: "H\(n + 2)", color: color, width: 1.2, points: points))
        }
        if display != .levels {
            var points: [ChartPoint] = []
            for i in f.indices {
                let column = harmonics.map { $0[i] }
                guard let ratio = HarmonicDistortion.thd(fundamental: fundamental[i], harmonics: column) else { continue }
                let y = display == .percent ? 100 * ratio : 20 * log10(max(ratio, 1e-10))
                points.append(ChartPoint(x: f[i], y: y))
            }
            out.append(DistortionCurve(id: "thd", name: "THD", color: .red, width: 2.2, points: points))
        }
        return out
    }

    /// A harmonic's level as the display shows it.
    private func value(_ level: Double, fundamental: Double) -> Double {
        switch display {
        case .levels: return level
        case .relative: return level - fundamental
        case .percent: return 100 * pow(10, (level - fundamental) / 20)
        }
    }

    // MARK: - Chart

    private func chart(_ trace: Trace, _ d: HarmonicDistortion) -> some View {
        let curves = curves(trace, d)
        let values = curves.flatMap { $0.points.map(\.y) }
        let yDomain = domain(values)
        let low = d.frequencies.first ?? 20
        let high = max(d.frequencies.last ?? 20_000, low * 2)
        let unit = display == .percent ? "%" : "dB"
        let tips: [TipSeries] = curves.map { TipSeries(id: $0.id, name: $0.name, color: $0.color, points: $0.points) }
        return VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(curves) { curve in
                    ForEach(curve.points) { p in
                        LineMark(x: .value("Frequency", p.x), y: .value(unit, p.y), series: .value("Curve", curve.id))
                            .foregroundStyle(curve.color)
                            .lineStyle(StrokeStyle(lineWidth: curve.width))
                    }
                }
            }
            .chartXScale(domain: low...high, type: .log)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: frequencyTicks) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
                }
            }
            .chartXAxisLabel("Hz (fundamental)")
            .chartYAxisLabel(unit)
            .chartLegend(.hidden)
            .frequencyDataTip(tips, unit: unit)
            .clipped()
            .exportablePlot("Distortion")
            .frame(minHeight: 220, maxHeight: .infinity)
            legend(curves)
        }
    }

    private func domain(_ values: [Double]) -> ClosedRange<Double> {
        switch display {
        case .percent:
            let top = values.max() ?? 1
            return 0...max(1, (top * 1.1).rounded(.up))
        case .relative:
            let bottom = min(max(values.min() ?? -80, -100), -10)
            let top = max(values.max() ?? 0, 0)
            return (bottom / 10).rounded(.down) * 10...(top / 10).rounded(.up) * 10
        case .levels:
            let top = values.max() ?? 0
            let ceiling = (top / 10).rounded(.up) * 10 + 5
            return (ceiling - 100)...ceiling
        }
    }

    private func legend(_ curves: [DistortionCurve]) -> some View {
        HStack(spacing: 14) {
            ForEach(curves) { curve in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(curve.color).frame(width: 14, height: 3)
                    Text(curve.name).font(.caption)
                }
            }
        }
    }

    private func caption(_ d: HarmonicDistortion) -> String {
        "Harmonic k of a tone at f sounds at k·f and is drawn at f, so each harmonic stops where k·f leaves the sweep's range. THD is the root of the harmonics' summed power over the fundamental's, from H2 to H\(d.highestOrder). Below about \(Int(d.frequencies.first ?? 20)) Hz the windows that keep the harmonics apart are too short to resolve. Distortion rises with level: compare traces measured at the same sweep level, and keep the noise well below the harmonics."
    }
}
#endif
