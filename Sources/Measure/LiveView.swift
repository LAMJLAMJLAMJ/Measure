#if os(macOS)
import Charts
import Foundation
import MeasureAudio
import MeasureDSP
import Observation
import SwiftUI

/// Live analyser settings, remembered between launches.
struct LiveSettings: Codable, Equatable {
    var fftSize = 32_768
    /// Blocks in the average.
    var averages = 8
    /// Play pink noise; off to measure with programme or another external signal.
    var generator = true
    /// Use the generated noise as the reference rather than the loopback input, as Smaart's internal
    /// reference does. Needs the generator, and input and output on one device (one clock).
    var internalReference = true
    /// Noise level, dB re its peak (the noise's RMS is about 12 dB lower).
    var level: Double = -30
    /// Delay of each mic behind the reference, in samples.
    var delays: [Int] = []
    /// Virtual EQ on the live curves: drawn as a prediction, never sent anywhere.
    var eq: [EQFilter]?

    var activeEQ: [EQFilter] { (eq ?? []).filter(\.enabled) }

    func delay(_ mic: Int) -> Int { mic < delays.count ? delays[mic] : 0 }
}

/// The live dual-channel analyser: reference on the loopback input, one transfer function per mic.
@Observable @MainActor
final class LiveAnalyzer {
    /// What the view draws for one mic.
    struct Curve: Identifiable {
        let mic: Int
        let magnitude: [ChartPoint]
        let phase: [ChartPoint]
        let coherence: [ChartPoint]
        /// Delay still left over after the alignment, from the latest impulse response, in samples.
        let residualDelay: Int?
        var id: Int { mic }
    }

    var settings: LiveSettings {
        didSet {
            save()
            if settings.level != oldValue.level { stream.setLevel(settings.level) }
            if settings.fftSize != oldValue.fftSize || settings.delays != oldValue.delays { reset() }
        }
    }
    var isRunning = false
    var curves: [Curve] = []
    /// Peak of the reference and of each mic over the last update, dB re full scale.
    var peaks: [Double] = []
    var blocks = 0

    @ObservationIgnored private let stream = LiveStream()
    @ObservationIgnored private var spectra: [CrossSpectrum] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastBlockEnd = 0
    @ObservationIgnored private var sampleRate = 48_000.0
    /// Settings the current spectra were made with; a change clears them.
    @ObservationIgnored private var generation = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "live"), let s = try? JSONDecoder().decode(LiveSettings.self, from: data) {
            settings = s
        } else {
            settings = LiveSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "live") }
    }

    /// Starts capturing (and the noise, if on) with the routing from Measurement Setup.
    func start(_ model: AppModel) async {
        guard !isRunning else { return }
        let s = model.settings
        guard let input = model.inputDevice else {
            model.errorMessage = "Choose an input device in Measurement Setup."
            return
        }
        let useInternal = settings.internalReference && settings.generator
        if !useInternal && s.loopbackInput == nil {
            model.errorMessage = "Without the internal reference the live mode needs a loopback input: set it in Measurement Setup to the input that carries the signal fed to the system."
            return
        }
        model.monitor.stop(model)
        model.generator.stop()
        sampleRate = s.sampleRate
        // The noise repeats every 65 536 samples, so every FFT size up to that sees whole periods.
        let noise = settings.generator ? PinkNoise.periodic(count: 65_536, sampleRate: s.sampleRate) : nil
        let routing = LiveRouting(inputDevice: input, referenceChannel: useInternal ? nil : s.loopbackInput.map { $0 - 1 },
                                  micChannels: s.mics.map { $0.channel - 1 },
                                  outputDevice: settings.generator ? model.outputDevice : nil,
                                  outputChannel: s.outputChannel - 1,
                                  loopbackOutputChannel: s.loopbackOutput.map { $0 - 1 })
        do {
            try await stream.start(routing: routing, sampleRate: s.sampleRate, signal: noise, level: settings.level)
        } catch {
            model.errorMessage = "\(error)"
            return
        }
        model.errorMessage = nil
        if useInternal, let out = model.outputDevice, out.id != input.id {
            model.status = "Live, internal reference: output and input are different devices, so their clocks drift and the response will smear. Use one device or the loopback input."
        } else {
            model.status = useInternal ? "Live: pink noise, internal reference" : settings.generator ? "Live: pink noise, loopback reference" : "Live: listening to the reference input"
        }
        isRunning = true
        reset()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await self?.update()
            }
        }
    }

    func stop(_ model: AppModel? = nil) {
        loop?.cancel()
        loop = nil
        stream.stop()
        isRunning = false
        // The live curve goes with the measurement: what stays on screen are the saved traces.
        curves = []
        peaks = []
        spectra = []
        blocks = 0
        model?.status = nil
    }

    /// Clears the averages.
    func reset() {
        generation += 1
        spectra = (0..<stream.micCount).map { _ in CrossSpectrum(fftSize: settings.fftSize, sampleRate: sampleRate) }
        lastBlockEnd = stream.capturedFrames
        blocks = 0
    }

    /// Adds the newest block of each mic, half overlapping the last, and redraws.
    private func update() async {
        guard isRunning else { return }
        let n = settings.fftSize
        let written = stream.capturedFrames
        guard written - lastBlockEnd >= n / 2 else { return }
        let pairs = (0..<spectra.count).map { stream.block(n, mic: $0, delay: settings.delay($0)) }
        guard pairs.allSatisfy({ $0 != nil }) else { return }
        lastBlockEnd = written
        peaks = stream.recentPeaks

        let work = spectra
        let averages = settings.averages
        let fs = sampleRate
        let start = generation
        let (updated, made) = await Task.detached(priority: .userInitiated) {
            var spectra = work
            var curves: [Curve] = []
            for i in spectra.indices {
                guard let pair = pairs[i] else { continue }
                spectra[i].add(reference: pair.reference, measurement: pair.mic, averages: averages)
                curves.append(LiveAnalyzer.curve(spectra[i], mic: i, sampleRate: fs))
            }
            return (spectra, curves)
        }.value
        // Settings changed while computing: these belong to the old ones.
        guard start == generation, isRunning else { return }
        spectra = updated
        curves = made
        blocks = updated.first?.blocks ?? 0
    }

    nonisolated private static func curve(_ cs: CrossSpectrum, mic: Int, sampleRate fs: Double) -> Curve {
        let response = cs.response
        let coherence = FrequencyResponse(frequencies: response.frequencies, magnitude: cs.coherence)
        let high = min(20_000, response.frequencies.last ?? 20_000)
        let mag = response.smoothed(fraction: 24).logResampled(pointsPerOctave: 48, low: 10, high: high)
        let coh = coherence.smoothed(fraction: 6).logResampled(pointsPerOctave: 24, low: 10, high: high)
        return Curve(mic: mic,
                     magnitude: zip(mag.frequencies, mag.magnitude).map { ChartPoint(x: $0, y: $1) },
                     phase: LiveAnalyzer.phasePoints(response),
                     coherence: zip(coh.frequencies, coh.magnitude).map { ChartPoint(x: $0, y: $1) },
                     residualDelay: cs.delay)
    }

    /// Phase at 24 log-spaced points per octave, nearest bin.
    nonisolated private static func phasePoints(_ r: FrequencyResponse) -> [ChartPoint] {
        guard let phase = r.phase, let last = r.frequencies.last else { return [] }
        let f = r.frequencies
        var out: [ChartPoint] = []
        var freq = 20.0
        var i = 0
        while freq <= min(20_000, last) {
            while i + 1 < f.count && abs(f[i + 1] - freq) <= abs(f[i] - freq) { i += 1 }
            if out.last?.x != f[i] { out.append(ChartPoint(x: f[i], y: phase[i])) }
            freq *= pow(2, 1.0 / 24)
        }
        return out
    }

    /// Sets each mic's delay so its impulse response peak lines up with the reference.
    func findDelays() {
        var delays = (0..<spectra.count).map { settings.delay($0) }
        for i in spectra.indices { if let d = spectra[i].delay { delays[i] += d } }
        settings.delays = delays
    }

    func clearDelays() { settings.delays = [] }

    /// How the reference was taken, for a captured trace's notes.
    private func referenceText(_ model: AppModel) -> String {
        if settings.internalReference && settings.generator {
            return "the internal reference (delay includes the interface latency)"
        }
        return "reference input \(model.settings.loopbackInput ?? 0)"
    }

    /// Adds the current transfer function of each mic to the library as an impulse response.
    func capture(_ model: AppModel) {
        guard !spectra.isEmpty, blocks > 0 else { return }
        let s = model.settings
        let date = Date()
        let fs = sampleRate
        // Rotate so the direct sound sits 10 ms in, leaving room for the window's left side.
        let pre = Int(0.01 * fs)
        for (i, cs) in spectra.enumerated() {
            let ir = cs.impulseResponse
            let rotated = ir.indices.map { ir[($0 - pre + ir.count) % ir.count] }
            let slot = i < s.mics.count ? s.mics[i] : MicSlot(channel: i + 1)
            let label = s.position.isEmpty ? "Live · Mic \(i + 1)" : "\(s.position) · Live · Mic \(i + 1)"
            let delayMS = Double(settings.delay(i)) / fs * 1000
            let info = TraceInfo(name: label, date: date, source: .transferFunction, sampleRate: fs,
                                 mic: slot.micName, position: s.position,
                                 notes: String(format: "Live transfer function, input %d against %@, %d-point FFT, %d averages, reference delayed %.2f ms",
                                               slot.channel, referenceText(model), settings.fftSize, settings.averages, delayMS),
                                 colorIndex: model.traces.count)
            var withEQ = info
            withEQ.eq = settings.eq
            model.add(Trace(info: withEQ, impulseResponse: rotated))
            if i == 0 { model.selection = info.id }
        }
        model.status = "Captured the live response of \(spectra.count) mic\(spectra.count == 1 ? "" : "s")."
    }
}

/// Live magnitude, coherence and phase of every mic against the reference.
extension AppModel {
    /// Each live curve with the calibration of the mic assigned to its input.
    var calibratedLiveCurves: [(Int, [ChartPoint])] {
        live.curves.map { c in
            let mic = c.mic < settings.mics.count ? settings.mics[c.mic].micName : nil
            guard let cal = calibration(mic: mic) else { return (c.mic, c.magnitude) }
            return (c.mic, c.magnitude.map { ChartPoint(x: $0.x, y: $0.y - cal.magnitude(at: $0.x)) })
        }
    }

    /// The power average of the calibrated live curves, which the target is aligned to and Auto EQ fits.
    /// Nil while the live mode is not running.
    var liveAverageResponse: FrequencyResponse? {
        let responses = calibratedLiveCurves.map { FrequencyResponse(frequencies: $0.1.map(\.x), magnitude: $0.1.map(\.y)) }
        return responses.isEmpty ? nil : FrequencyResponse.average(responses, method: .power)
    }

    /// What the live view's target sits on and Auto EQ fits: the live curves' average while there
    /// are any, otherwise the selected ticked trace (or the first ticked one), with its calibration.
    var liveFitResponse: FrequencyResponse? {
        if let live = liveAverageResponse { return live }
        let ticked = visibleTraces.filter(\.hasResponse)
        return (ticked.first { $0.id == selection } ?? ticked.first).map { calibratedResponse($0) }
    }
}

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showVirtualEQ") private var showVirtualEQ = false
    @AppStorage("showTarget") private var showTarget = false
    @State private var range: Double = 50
    /// Whether this is the Frequency view, which has the Virtual EQ panel.
    var showsEQ = false

    var body: some View {
        let live = model.live
        VStack(alignment: .leading, spacing: 8) {
            controls(live)
            if !(live.settings.internalReference && live.settings.generator) && model.settings.loopbackInput == nil {
                EmptyState(text: "Use the internal reference, or set the loopback input in Measurement Setup to the input that carries the signal fed to the system.")
            } else if live.curves.isEmpty && !model.visibleTraces.contains(where: \.hasResponse) {
                EmptyState(text: "Press Start to measure live. Ticked traces are drawn with it for comparison.")
            } else {
                magnitudeChart(live)
                if !live.curves.isEmpty { coherenceChart(live).frame(height: 70) }
                phaseChart(live).frame(height: 150)
                Text((live.isRunning ? "Thick lines: live. Thin lines: ticked traces, in their colors." : "Stopped. Press Start to measure live; ticked traces are shown in their colors.") + eqNote(live))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func controls(_ live: LiveAnalyzer) -> some View {
        @Bindable var live = live
        // The controls wrap onto further lines when the window (or the Virtual EQ panel beside it)
        // leaves too little width, instead of squeezing labels to a letter a line.
        return VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8, lineSpacing: 6) {
                // Groups keep the builder short; the layout still places each control on its own.
                Group {
                Button(live.isRunning ? "Stop" : "Start") {
                    if live.isRunning { live.stop(model) } else { Task { await live.start(model) } }
                }
                Toggle("Pink noise", isOn: $live.settings.generator)
                    .disabled(live.isRunning)
                    .help("Play pink noise on the measurement output. Off: measure with programme or any signal fed to the reference input.")
                Picker("Reference", selection: $live.settings.internalReference) {
                    Text("Internal").tag(true)
                    Text(model.settings.loopbackInput.map { "Input \($0)" } ?? "Loopback input").tag(false)
                }
                .frame(width: 190)
                .disabled(live.isRunning || !live.settings.generator)
                .help("Internal: the generated noise is the reference, no cable needed. Input: the loopback input carries it, which also works with programme.")
                if live.settings.generator {
                    Slider(value: $live.settings.level, in: -60...0, step: 1).frame(width: 120)
                    Text("\(Int(live.settings.level)) dBFS peak").monospacedDigit().frame(width: 100, alignment: .leading)
                }
                Button("Capture") { live.capture(model) }
                    .disabled(!live.isRunning || live.blocks == 0)
                    .help("Add each mic's current response to the list as an impulse response")
                if showsEQ {
                    TargetControl()
                    Toggle(isOn: $showVirtualEQ) { Label("Virtual EQ", systemImage: "slider.vertical.3") }
                        .toggleStyle(.button)
                        .help("Show the Virtual EQ panel, which applies to the live curves")
                }
                }
                Group {
                Picker("FFT", selection: $live.settings.fftSize) {
                    ForEach([8192, 16_384, 32_768, 65_536], id: \.self) { n in
                        Text("\(n / 1024)k (\(String(format: "%.2f", Double(n) / model.settings.sampleRate)) s)").tag(n)
                    }
                }
                .frame(width: 170)
                Picker("Average", selection: $live.settings.averages) {
                    ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 130)
                Picker("Range", selection: $range) {
                    Text("30 dB").tag(30.0)
                    Text("50 dB").tag(50.0)
                    Text("80 dB").tag(80.0)
                }
                .frame(width: 140)
                Button("Find Delay") { live.findDelays() }
                    .disabled(live.blocks == 0)
                    .help("Line the reference up with each mic, from the peak of its impulse response")
                Button("Reset") { live.clearDelays(); live.reset() }
                }
            }
            HStack {
                Text(statusText(live)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
        }
    }

    /// Says what the dashed lines are while the Virtual EQ panel is open.
    private func eqNote(_ live: LiveAnalyzer) -> String {
        guard showsEQ && showVirtualEQ else { return "" }
        let n = live.settings.activeEQ.count
        if n == 0 { return " Virtual EQ: no filters on yet; add one in the panel." }
        return " Dashed: live curves with the Virtual EQ (\(n) filter\(n == 1 ? "" : "s") on)" + (live.curves.isEmpty ? ", drawn once live is running." : ".")
    }

    private func statusText(_ live: LiveAnalyzer) -> String {
        let fs = model.settings.sampleRate
        var parts: [String] = []
        if let ref = live.peaks.first { parts.append(String(format: "Ref %.0f dBFS", ref)) }
        for (i, p) in live.peaks.dropFirst().enumerated() {
            parts.append(String(format: "Mic %d %.0f dBFS, delay %.2f ms", i + 1, p, Double(live.settings.delay(i)) / fs * 1000))
        }
        if live.isRunning { parts.append("\(live.blocks) blocks") }
        return parts.joined(separator: " · ")
    }

    /// Live curves get their own high-contrast colors, so they stand apart from the traces' palette.
    private func color(_ mic: Int) -> Color {
        let colors: [Color] = [.primary, .red, .cyan, .yellow]
        return colors[mic % colors.count]
    }

    private func magnitudeChart(_ live: LiveAnalyzer) -> some View {
        let shown = model.visibleTraces.filter(\.hasResponse).map {
            ($0, $0.displayResponse(smoothing: model.smoothing, calibration: model.calibration(for: $0)))
        }
        let calibrated = model.calibratedLiveCurves
        // The live curves with the Virtual EQ added, drawn dashed while the panel is open.
        let eq = live.settings.activeEQ
        let fs = model.settings.sampleRate
        let predicted: [(Int, [ChartPoint])] = showsEQ && showVirtualEQ && !eq.isEmpty
            ? calibrated.map { mic, points in
                (mic, points.map { ChartPoint(x: $0.x, y: $0.y + ParametricEQ.gainDB(eq, at: $0.x, sampleRate: fs)) })
            }
            : []
        // A ticked, selected trace with its own EQ is drawn with it too, as on the sweep view.
        let tracePrediction: (Trace, [ChartPoint])? = showsEQ && showVirtualEQ
            ? shown.first { $0.0.id == model.selection && !$0.0.activeEQ.isEmpty }.map { trace, points in
                (trace, points.map { ChartPoint(x: $0.x, y: $0.y + ParametricEQ.gainDB(trace.activeEQ, at: $0.x, sampleRate: trace.eqSampleRate)) })
            }
            : nil
        // The target sits on the live curves' average while measuring, otherwise on the selected trace.
        var targetPoints: [TargetPoint]?
        if showsEQ && showTarget {
            if let response = model.liveFitResponse {
                targetPoints = model.targetPoints(alignedTo: response)
            }
        }
        // Data tip series, built in steps to keep each expression simple for the type checker.
        var tips: [TipSeries] = calibrated.map { TipSeries(id: "mic\($0.0)", name: "Live · Mic \($0.0 + 1)", color: color($0.0), points: $0.1) }
        tips += predicted.map { TipSeries(id: "eq\($0.0)", name: "Mic \($0.0 + 1) with EQ", color: color($0.0), points: $0.1) }
        tips += shown.map { TipSeries(id: $0.0.id.uuidString, name: $0.0.info.name, color: $0.0.color, points: $0.1) }
        if let targetPoints {
            tips.append(TipSeries(id: "target", name: "Target", color: .gray, points: targetPoints.map { ChartPoint(x: $0.x, y: $0.y) }))
        }
        if let tracePrediction {
            tips.append(TipSeries(id: "eq-trace", name: "\(tracePrediction.0.info.name) with EQ", color: tracePrediction.0.color, points: tracePrediction.1))
        }
        // Scale to the live curves while measuring, otherwise to the traces.
        let levels = calibrated.isEmpty ? shown.flatMap { $0.1 } : calibrated.flatMap { $0.1 }
        let top = ((levels.filter { $0.x >= 20 }.map(\.y).max() ?? 0) + 5).rounded(.up)
        let chart = Chart {
            if let targetPoints {
                TargetMarks(points: targetPoints, tolerance: model.target.tolerance > 0)
            }
            ForEach(shown, id: \.0.id) { item in
                ForEach(item.1) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Trace", item.0.id.uuidString))
                        .foregroundStyle(item.0.color)
                        .lineStyle(StrokeStyle(lineWidth: item.0.id == model.selection ? 2 : 1.2))
                }
            }
            ForEach(calibrated, id: \.0) { mic, points in
                ForEach(points) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Mic", "mic\(mic)"))
                        .foregroundStyle(color(mic))
                        .lineStyle(StrokeStyle(lineWidth: 2.8))
                }
            }
            if let tracePrediction {
                ForEach(tracePrediction.1) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Trace", "eq-trace"))
                        .foregroundStyle(tracePrediction.0.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
                }
            }
            ForEach(predicted, id: \.0) { mic, points in
                ForEach(points) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Mic", "eq\(mic)"))
                        .foregroundStyle(color(mic))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
                }
            }
        }
        return chart
        .chartXScale(domain: 10...20_000, type: .log)
        .chartYScale(domain: (top - range)...top)
        .chartXAxis { frequencyAxis }
        .chartYAxisLabel("dB re reference")
        .chartLegend(.hidden)
        .frequencyDataTip(tips)
        .clipped()
        .exportablePlot("Live response")
    }

    private func coherenceChart(_ live: LiveAnalyzer) -> some View {
        Chart {
            ForEach(live.curves) { c in
                ForEach(c.coherence) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Coherence", p.y), series: .value("Mic", "mic\(c.mic)"))
                        .foregroundStyle(color(c.mic).opacity(0.7))
                }
            }
        }
        .chartXScale(domain: 10...20_000, type: .log)
        .chartYScale(domain: 0...1)
        .chartYAxis { AxisMarks(values: [0, 0.5, 1]) }
        .chartXAxis(.hidden)
        .chartYAxisLabel("Coherence")
        .chartLegend(.hidden)
    }

    private func phaseChart(_ live: LiveAnalyzer) -> some View {
        let shown = model.visibleTraces.compactMap { t in t.displayPhase().map { (t, $0) } }
        return Chart {
            ForEach(shown, id: \.0.id) { item in
                ForEach(item.1) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Phase", p.y), series: .value("Trace", item.0.id.uuidString))
                        .foregroundStyle(item.0.color.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            ForEach(live.curves) { c in
                ForEach(c.phase) { p in
                    PointMark(x: .value("Frequency", p.x), y: .value("Phase", p.y))
                        .foregroundStyle(color(c.mic))
                        .symbolSize(10)
                }
            }
        }
        .chartXScale(domain: 10...20_000, type: .log)
        .chartYScale(domain: -180...180)
        .chartYAxis { AxisMarks(values: [-180, -90, 0, 90, 180]) }
        .chartXAxis { frequencyAxis }
        .chartXAxisLabel("Hz")
        .chartYAxisLabel("degrees")
        .chartLegend(.hidden)
        .clipped()
        .exportablePlot("Live phase")
    }

    private var frequencyAxis: some AxisContent {
        AxisMarks(values: frequencyTicks) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel { if let f = value.as(Double.self) { Text(frequencyLabel(f)) } }
        }
    }
}
#endif
