#if os(macOS)
import AppKit
import Charts
import MeasureDSP
import SwiftUI

/// One point of the target as drawn: its level and the tolerance band around it.
struct TargetPoint: Identifiable {
    let x: Double
    let y: Double
    let low: Double
    let high: Double
    var id: Double { x }
}

extension AppModel {
    /// The target's points for a chart, aligned to `response` (calibrated, any smoothing).
    func targetPoints(alignedTo response: FrequencyResponse) -> [TargetPoint] {
        let t = target
        let shift = t.alignment(to: response.smoothed(fraction: 6))
        return t.grid(perOctave: 12).map { f in
            let y = t.level(at: f) + shift
            return TargetPoint(x: f, y: y, low: y - t.tolerance, high: y + t.tolerance)
        }
    }

    /// A trace's response with its mic calibration: what Auto EQ fits and the target is aligned to.
    func calibratedResponse(_ trace: Trace) -> FrequencyResponse {
        calibration(for: trace).map { trace.rawResponse.applyingCalibration($0) } ?? trace.rawResponse
    }

    /// Runs Auto EQ on `response`. Filters an earlier run added are replaced; the others stay, and the
    /// enabled ones are taken into account. Returns the new filter list and a line saying how it went.
    func autoEQ(_ filters: [EQFilter], response: FrequencyResponse, sampleRate: Double) -> ([EQFilter], String) {
        let kept = filters.filter { $0.auto != true }
        let t = target
        let result = AutoEQ.fit(response: response, target: t, alignment: t.alignment(to: response.smoothed(fraction: 6)),
                                fixed: kept.filter(\.enabled), settings: autoEQSettings, sampleRate: sampleRate)
        let added = result.filters.map { filter -> EQFilter in
            var f = filter
            f.auto = true
            return f
        }
        let n = added.count
        let range = "\(frequencyText(t.low)) to \(frequencyText(t.high))"
        let summary = n == 0
            ? String(format: "No filter would help: the deviation from the target is %.1f dB RMS from %@.", result.rmsBefore, range)
            : String(format: "%d filter%@ added. Deviation from the target, %@: %.1f dB RMS before, %.1f dB after.",
                     n, n == 1 ? "" : "s", range, result.rmsBefore, result.rmsAfter)
        return (kept + added, summary)
    }

    /// Makes the selected trace's response (with its mic calibration, at 1/6 octave) the target, to match
    /// other systems to it.
    func useAsTarget(_ trace: Trace) {
        let response = calibratedResponse(trace)
        guard let first = response.frequencies.first, let last = response.frequencies.last else { return }
        let low = max(20, first), high = min(20_000, last)
        guard high > low else { return }
        let smooth = response.smoothed(fraction: 6).logResampled(pointsPerOctave: 12, low: low, high: high)
        var t = target
        t.name = trace.info.name
        t.points = zip(smooth.frequencies, smooth.magnitude).map { TargetCurve.Point(frequency: $0, level: $1) }
        t.low = max(t.low, low)
        t.high = min(t.high, high)
        if t.high <= t.low { (t.low, t.high) = (low, high) }
        t.offset = 0
        target = t
    }
}

/// The target on a frequency chart: a thick grey line, in the tolerance band when there is one.
struct TargetMarks: ChartContent {
    let points: [TargetPoint]
    let tolerance: Bool

    var body: some ChartContent {
        ForEach(tolerance ? points : []) { p in
            AreaMark(x: .value("Frequency", p.x), yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                .foregroundStyle(Color.gray.opacity(0.18))
        }
        ForEach(points) { p in
            LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Trace", "target"))
                .foregroundStyle(Color.gray.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 2.5))
        }
    }
}

private func frequencyText(_ f: Double) -> String {
    f >= 1000 ? String(format: "%g kHz", (f / 100).rounded() / 10) : String(format: "%g Hz", f.rounded())
}

/// The toolbar control for the target: a toggle to show it, and a button that opens its editor.
struct TargetControl: View {
    @AppStorage("showTarget") private var showTarget = false
    @State private var editing = false

    var body: some View {
        HStack(spacing: 2) {
            Toggle(isOn: $showTarget) { Label("Target", systemImage: "scope") }
                .toggleStyle(.button)
                .help("Show the target curve, at the level of the selected trace")
            Button { editing = true } label: { Image(systemName: "ellipsis.circle") }
                .buttonStyle(.borderless)
                .help("Edit the target curve")
                .popover(isPresented: $editing, arrowEdge: .bottom) { TargetEditor() }
        }
        .fixedSize()
    }
}

/// Edits the target: a shape built from a tilt, a bass shelf and a treble fall, or points from a file.
struct TargetEditor: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showTarget") private var showTarget = false
    @State private var importError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show the target", isOn: $showTarget)
                TextField("Name", text: $model.target.name)
                Menu("Start From") {
                    ForEach(TargetCurve.Preset.allCases) { preset in
                        Button(preset.rawValue) { model.target = preset.curve; showTarget = true }
                    }
                    Divider()
                    Button("Selected Trace's Response") {
                        if let trace = model.selectedTrace, trace.hasResponse { model.useAsTarget(trace); showTarget = true }
                    }
                    .disabled(!(model.selectedTrace?.hasResponse ?? false))
                    Button("Import File…") { importFile() }
                }
                if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            }
            if let points = model.target.points {
                Section("Shape") {
                    LabeledContent("Points", value: "\(points.count), from a file or a trace")
                    Button("Use a Built Shape Instead") { model.target.points = nil }
                }
            } else {
                Section("Shape") {
                    number("Tilt", $model.target.tilt, unit: "dB/oct", help: "dB per octave about 1 kHz; negative falls towards the treble")
                    number("Bass shelf", $model.target.bassGain, unit: "dB", help: "Level of the bass shelf well below its midpoint")
                    number("Shelf midpoint", $model.target.bassFrequency, unit: "Hz", help: "Where the shelf is at half its level")
                    number("Treble fall", $model.target.trebleSlope, unit: "dB/oct", help: "How fast the target falls above the next frequency")
                    number("Falls above", $model.target.trebleCorner, unit: "Hz", help: "Where the treble fall starts")
                }
            }
            Section("Range and level") {
                number("From", $model.target.low, unit: "Hz", help: "The target applies, is aligned and is fitted from here")
                number("To", $model.target.high, unit: "Hz", help: "The target applies, is aligned and is fitted up to here")
                number("Tolerance ±", $model.target.tolerance, unit: "dB", help: "Half-width of the band drawn around the target; 0 for none")
                number("Offset", $model.target.offset, unit: "dB", help: "Moves the target up or down from where it is aligned")
            }
            Section {
                Text("The target is a shape, not a level. It is drawn on the selected trace (or the live curves): the median difference between the two over the range sets its level, so peaks and dips do not move it. The offset moves it from there. Auto EQ in the Virtual EQ panel fits filters to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 560)
    }

    private func number(_ label: String, _ value: Binding<Double>, unit: String, help: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            }
        }
        .help(help)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a target curve: a text file of frequency and level pairs, as REW exports"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            var imported = try TargetCurve.parse(text, name: url.deletingPathExtension().lastPathComponent)
            imported.tolerance = model.target.tolerance
            model.target = imported
            showTarget = true
            importError = nil
        } catch {
            importError = "\(url.lastPathComponent): \(error)"
        }
    }
}

/// Auto EQ settings and the button that runs it, in the Virtual EQ panel.
struct AutoEQSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showTarget") private var showTarget = false
    /// The response to fit (with its mic calibration), or nil when there is none yet.
    let response: FrequencyResponse?
    let filters: [EQFilter]
    let sampleRate: Double
    let set: ([EQFilter]) -> Void
    @State private var summary: String?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Auto EQ to Target") { run() }
                    .disabled(response == nil)
                    .help("Add filters that bring the response close to the target. Filters you added yourself stay and are taken into account; filters from an earlier Auto EQ are replaced.")
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Auto EQ settings")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
                Spacer()
                Text(model.target.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.selection) { summary = nil }
    }

    private func run() {
        guard let response else { return }
        let (new, text) = model.autoEQ(filters, response: response, sampleRate: sampleRate)
        set(new)
        summary = text
        showTarget = true
    }

    private var settings: some View {
        @Bindable var model = model
        return Form {
            Stepper("Up to \(model.autoEQSettings.maxFilters) filters", value: $model.autoEQSettings.maxFilters, in: 1...20)
            LabeledContent("Largest boost") { field($model.autoEQSettings.maxBoost, unit: "dB") }
            LabeledContent("Largest cut") { field($model.autoEQSettings.maxCut, unit: "dB") }
            LabeledContent("Narrowest Q") { field($model.autoEQSettings.maxQ, unit: "") }
            Toggle("Shelves at the ends", isOn: $model.autoEQSettings.shelves)
            Picker("Fit to the response at", selection: $model.autoEQSettings.smoothing) {
                Text("1/3 octave").tag(3.0)
                Text("1/6 octave").tag(6.0)
                Text("1/12 octave").tag(12.0)
                Text("1/24 octave").tag(24.0)
            }
            Text("Boosts are kept small because a dip is often a cancellation that boosting cannot fill. The fit is a starting point: check it by ear and measure again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 320, height: 330)
    }

    private func field(_ value: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
        }
    }
}
#endif
