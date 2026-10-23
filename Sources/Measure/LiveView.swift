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
    /// Noise level, dB re its peak (the noise's RMS is about 12 dB lower).
    var level: Double = -30
    /// Delay of each mic behind the reference, in samples.
    var delays: [Int] = []

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
        guard let reference = s.loopbackInput else {
            model.errorMessage = "The live mode needs a reference: set the loopback input in Measurement Setup to the input that carries the signal fed to the system."
            return
        }
        sampleRate = s.sampleRate
        // The noise repeats every 65 536 samples, so every FFT size up to that sees whole periods.
        let noise = settings.generator ? PinkNoise.periodic(count: 65_536, sampleRate: s.sampleRate) : nil
        let routing = LiveRouting(inputDevice: input, referenceChannel: reference - 1,
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
        model.status = settings.generator ? "Live: playing pink noise" : "Live: listening to the reference"
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
                                 notes: String(format: "Live transfer function, input %d against reference input %d, %d-point FFT, %d averages, reference delayed %.2f ms",
                                               slot.channel, s.loopbackInput ?? 0, settings.fftSize, settings.averages, delayMS),
                                 colorIndex: model.traces.count)
            model.add(Trace(info: info, impulseResponse: rotated))
            if i == 0 { model.selection = info.id }
        }
        model.status = "Captured the live response of \(spectra.count) mic\(spectra.count == 1 ? "" : "s")."
    }
}

/// Live magnitude, coherence and phase of every mic against the reference.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Double = 50

    var body: some View {
        let live = model.live
        VStack(alignment: .leading, spacing: 8) {
            controls(live)
            if model.settings.loopbackInput == nil {
                EmptyState(text: "Set the loopback input in Measurement Setup. It carries the reference: the signal fed to the system.")
            } else if !live.isRunning && live.curves.isEmpty {
                EmptyState(text: "Press Start to measure live. Shown traces are drawn in grey for comparison.")
            } else {
                magnitudeChart(live)
                coherenceChart(live).frame(height: 70)
                phaseChart(live).frame(height: 150)
            }
        }
    }

    private func controls(_ live: LiveAnalyzer) -> some View {
        @Bindable var live = live
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(live.isRunning ? "Stop" : "Start") {
                    if live.isRunning { live.stop(model) } else { Task { await live.start(model) } }
                }
                Toggle("Pink noise", isOn: $live.settings.generator)
                    .disabled(live.isRunning)
                    .help("Play pink noise on the measurement output. Off: measure with programme or any signal fed to the reference input.")
                if live.settings.generator {
                    Slider(value: $live.settings.level, in: -60...0, step: 1).frame(width: 120)
                    Text("\(Int(live.settings.level)) dBFS peak").monospacedDigit().frame(width: 100, alignment: .leading)
                }
                Spacer()
                Button("Capture") { live.capture(model) }
                    .disabled(live.blocks == 0)
                    .help("Add each mic's current response to the list as an impulse response")
            }
            HStack {
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
                Spacer()
                Text(statusText(live)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
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

    private func color(_ mic: Int) -> Color { TracePalette.color(mic) }

    private func magnitudeChart(_ live: LiveAnalyzer) -> some View {
        let shown = model.visibleTraces.filter(\.hasResponse).map {
            ($0, $0.displayResponse(smoothing: model.smoothing, calibration: model.calibration(for: $0)))
        }
        // Each mic's calibration, by the mic assigned to its input.
        let calibrated: [(Int, [ChartPoint])] = live.curves.map { c in
            let mic = c.mic < model.settings.mics.count ? model.settings.mics[c.mic].micName : nil
            guard let cal = model.calibration(mic: mic) else { return (c.mic, c.magnitude) }
            return (c.mic, c.magnitude.map { ChartPoint(x: $0.x, y: $0.y - cal.magnitude(at: $0.x)) })
        }
        let top = ((calibrated.flatMap { $0.1.filter { $0.x >= 20 }.map(\.y) }.max() ?? 0) + 5).rounded(.up)
        return Chart {
            ForEach(shown, id: \.0.id) { item in
                ForEach(item.1) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Trace", item.0.id.uuidString))
                        .foregroundStyle(.gray.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            ForEach(calibrated, id: \.0) { mic, points in
                ForEach(points) { p in
                    LineMark(x: .value("Frequency", p.x), y: .value("Level", p.y), series: .value("Mic", "mic\(mic)"))
                        .foregroundStyle(color(mic))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartXScale(domain: 10...20_000, type: .log)
        .chartYScale(domain: (top - range)...top)
        .chartXAxis { frequencyAxis }
        .chartYAxisLabel("dB re reference")
        .chartLegend(.hidden)
        .clipped()
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
        Chart {
            ForEach(live.curves) { c in
                ForEach(c.phase) { p in
                    PointMark(x: .value("Frequency", p.x), y: .value("Phase", p.y))
                        .foregroundStyle(color(c.mic))
                        .symbolSize(6)
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
