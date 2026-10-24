#if os(macOS)
import MeasureAudio
import MeasureDSP
import SwiftUI

/// The signal generator's settings, remembered between launches.
struct GeneratorSettings: Codable, Equatable {
    var signal = TestSignal()
    /// RMS level re full scale, dB. Kept low enough that the peak does not clip.
    var level = -20.0
    var muted = false
    /// The output device; nil uses the one in Measurement Setup.
    var outputUID: String?
    /// Outputs that play the signal, from 1. Nil uses the sweep channel from Measurement Setup.
    var outputs: [Int]?
}

/// A meter's reading over the last update, dB re full scale.
struct MeterReading {
    var rms = -200.0
    var peak = -200.0
    /// The highest peak lately, falling back 10 dB a second.
    var hold = -200.0

    mutating func update(_ x: [Double]) {
        guard !x.isEmpty else { return }
        rms = SignalLevel.rms(x)
        peak = SignalLevel.peak(x)
        hold = max(peak, hold - 1)
    }
}

/// Plays a test signal on any outputs and meters it, with every mic input from Measurement Setup, to
/// check that the signal gets through the system.
@Observable @MainActor
final class GeneratorModel {
    var settings: GeneratorSettings {
        didSet {
            save()
            applyWhileRunning(oldValue)
        }
    }
    var isRunning = false
    var output = MeterReading()
    var mics: [MeterReading] = []
    var micNames: [String] = []
    /// Peak over RMS of the current signal, dB: the level can go up to minus this before it clips.
    private(set) var crestFactor = 0.0
    var errorMessage: String?

    @ObservationIgnored private let stream = LiveStream()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var outputPosition = 0
    @ObservationIgnored private var micPositions: [Int] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "generator"),
           let s = try? JSONDecoder().decode(GeneratorSettings.self, from: data) {
            settings = s
        } else {
            settings = GeneratorSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "generator") }
    }

    /// The highest RMS level that does not clip, dBFS.
    var maximumLevel: Double { -crestFactor }

    func outputDevice(_ model: AppModel) -> AudioDevice? {
        guard let uid = settings.outputUID else { return model.outputDevice }
        return model.devices.first { $0.uid == uid } ?? model.outputDevice
    }

    /// Outputs that play the signal, from 1.
    func outputs(_ model: AppModel) -> [Int] {
        settings.outputs ?? [model.settings.outputChannel]
    }

    /// Gain applied to the signal, dB: its level, or silence when muted.
    private var gain: Double { settings.muted ? -400 : min(settings.level, maximumLevel) }

    func start(_ model: AppModel) async {
        guard !isRunning else { return }
        self.model = model
        guard let input = model.inputDevice else {
            errorMessage = "Choose an input device in Measurement Setup: the meters listen on it."
            return
        }
        guard let out = outputDevice(model) else {
            errorMessage = "Choose an output device."
            return
        }
        model.live.stop(model)
        model.monitor.stop(model)
        let s = model.settings
        let signal = settings.signal.samples(sampleRate: s.sampleRate)
        crestFactor = TestSignal.crestFactor(signal)
        let channels = outputs(model).map { $0 - 1 }.filter { $0 >= 0 && $0 < out.outputChannels }
        // The internal reference (the signal as played) feeds the output meter.
        let routing = LiveRouting(inputDevice: input, referenceChannel: nil, micChannels: s.mics.map { $0.channel - 1 },
                                  outputDevice: out, outputChannel: channels.first ?? 0, loopbackOutputChannel: nil,
                                  extraOutputChannels: Array(channels.dropFirst()))
        do {
            try await stream.start(routing: routing, sampleRate: s.sampleRate, signal: signal, level: gain)
        } catch {
            errorMessage = "\(error)"
            return
        }
        if channels.isEmpty { stream.setOutputChannels([]) }
        errorMessage = nil
        micNames = s.mics.map { $0.micName ?? "Input \($0.channel)" }
        output = MeterReading()
        mics = Array(repeating: MeterReading(), count: s.mics.count)
        outputPosition = 0
        micPositions = Array(repeating: 0, count: s.mics.count)
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.updateMeters()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        loop?.cancel()
        loop = nil
        stream.stop()
        isRunning = false
        output = MeterReading()
        mics = mics.map { _ in MeterReading() }
    }

    private func updateMeters() {
        guard isRunning else { return }
        let (signal, end) = stream.referenceSamples(from: outputPosition)
        outputPosition = end
        output.update(signal)
        for i in mics.indices {
            let (x, end) = stream.samples(mic: i, from: micPositions[i])
            micPositions[i] = end
            mics[i].update(x)
        }
    }

    /// Changes the level and outputs at once; a new signal restarts the stream.
    private func applyWhileRunning(_ old: GeneratorSettings) {
        guard isRunning, let model else { return }
        if settings.signal != old.signal || settings.outputUID != old.outputUID {
            stop()
            Task { await start(model) }
            return
        }
        if settings.level != old.level || settings.muted != old.muted { stream.setLevel(gain) }
        if settings.outputs != old.outputs { stream.setOutputChannels(outputs(model).map { $0 - 1 }) }
    }

    /// The crest factor of a signal before it plays, so the level control knows its limit.
    func prepare(sampleRate: Double) {
        crestFactor = TestSignal.crestFactor(settings.signal.samples(sampleRate: sampleRate))
    }
}

// MARK: - Window

/// The signal generator window: a test signal on any outputs, with meters for it and every mic input.
struct GeneratorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let generator = model.generator
        VStack(alignment: .leading, spacing: 14) {
            SignalControls()
            Divider()
            OutputControls()
            Divider()
            HStack {
                Button(generator.isRunning ? "Stop" : "Start") {
                    if generator.isRunning { generator.stop() } else { Task { await generator.start(model) } }
                }
                .keyboardShortcut(.space, modifiers: [])
                .controlSize(.large)
                .help("Play the signal and start the meters (Space)")
                Toggle("Mute", isOn: Binding(get: { generator.settings.muted }, set: { generator.settings.muted = $0 }))
                    .help("Silence the output and keep the meters running, to hear what the mics pick up without it")
                Spacer()
                if let error = generator.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                }
            }
            GeneratorMeters()
            Spacer(minLength: 0)
        }
        .padding(16)
        .onAppear { generator.prepare(sampleRate: model.settings.sampleRate) }
        .onDisappear { generator.stop() }
    }
}

private struct SignalControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let generator = model.generator
        let signal = Binding(get: { generator.settings.signal }, set: { generator.settings.signal = $0 })
        let fs = model.settings.sampleRate
        VStack(alignment: .leading, spacing: 8) {
            Picker("Signal", selection: signal.kind) {
                ForEach(TestSignal.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            HStack(spacing: 12) {
                switch generator.settings.signal.kind {
                case .pink, .white:
                    field("From", signal.low, unit: "Hz")
                    field("To", signal.high, unit: "Hz")
                case .sine:
                    field("Frequency", signal.frequency, unit: "Hz")
                    Text(String(format: "Plays %.0f Hz", generator.settings.signal.sineFrequency(sampleRate: fs)))
                        .font(.caption).foregroundStyle(.secondary)
                case .sweep:
                    field("From", signal.low, unit: "Hz")
                    field("To", signal.high, unit: "Hz")
                    field("Length", signal.sweepDuration, unit: "s", digits: 1)
                    field("Gap", signal.sweepGap, unit: "s", digits: 1)
                case .polarity:
                    field("Every", signal.pulseInterval, unit: "s", digits: 2)
                    Text("A 1 ms positive pulse").font(.caption).foregroundStyle(.secondary)
                }
            }
            LevelControl()
        }
        .onChange(of: generator.settings.signal) { generator.prepare(sampleRate: fs) }
    }

    private func field(_ title: String, _ value: Binding<Double>, unit: String, digits: Int = 0) -> some View {
        HStack(spacing: 4) {
            Text(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...digits)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text(unit).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

private struct LevelControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let generator = model.generator
        let top = min(0, generator.maximumLevel)
        let level = Binding(get: { min(generator.settings.level, top) }, set: { generator.settings.level = $0 })
        let shown = min(generator.settings.level, top)
        HStack(spacing: 10) {
            Text("Level")
            Slider(value: level, in: -80...max(top, -79))
                .frame(minWidth: 160)
            Text(String(format: "%.1f dBFS RMS, peak %.1f dBFS", shown, shown + generator.crestFactor))
                .font(.body.monospacedDigit())
                .lineLimit(1)
        }
        .help("RMS level of the signal at the output. It stops where the peaks would reach full scale.")
    }
}

private struct OutputControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let generator = model.generator
        let devices = model.devices.filter { $0.outputChannels > 0 }
        let device = generator.outputDevice(model)
        let selected = Set(generator.outputs(model))
        VStack(alignment: .leading, spacing: 8) {
            Picker("Output", selection: Binding(get: { generator.settings.outputUID ?? "" },
                                                set: { generator.settings.outputUID = $0.isEmpty ? nil : $0 })) {
                Text("Measurement Setup's (\(model.outputDevice?.name ?? "none"))").tag("")
                ForEach(devices) { Text($0.name).tag($0.uid) }
            }
            .fixedSize()
            if let device {
                HStack(alignment: .top, spacing: 10) {
                    Text("Channels")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], alignment: .leading, spacing: 4) {
                        ForEach(1...max(device.outputChannels, 1), id: \.self) { c in
                            Toggle("\(c)", isOn: Binding(get: { selected.contains(c) }, set: { on in toggle(c, on: on) }))
                                .toggleStyle(.button)
                        }
                    }
                }
                .help("The outputs that play the signal")
            }
        }
    }

    private func toggle(_ channel: Int, on: Bool) {
        var set = Set(model.generator.outputs(model))
        if on { set.insert(channel) } else { set.remove(channel) }
        model.generator.settings.outputs = set.sorted()
    }
}

/// A meter for the signal and one for each mic input.
private struct GeneratorMeters: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let generator = model.generator
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            MeterRow(name: "Signal", reading: generator.output, offset: nil, unit: "dBFS")
            ForEach(Array(generator.micNames.enumerated()), id: \.offset) { i, name in
                if i < generator.mics.count {
                    MeterRow(name: name, reading: generator.mics[i], offset: model.monitor.offset(model, mic: i),
                             unit: model.monitor.unit(model, mic: i))
                }
            }
        }
        if generator.micNames.isEmpty {
            Text(generator.isRunning ? "No mic inputs in Measurement Setup." : "Start to see the signal and every mic input from Measurement Setup.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MeterRow: View {
    let name: String
    let reading: MeterReading
    /// dB added to show SPL (the mic's calibration and offset), or nil to show dBFS.
    let offset: Double?
    let unit: String

    var body: some View {
        let shift = offset ?? 0
        let rms: Double? = reading.rms > -150 ? reading.rms + shift : nil
        let clipping = reading.hold > -0.5
        GridRow {
            Text(name).lineLimit(1).frame(minWidth: 70, maxWidth: 160, alignment: .leading)
            LevelBar(level: rms, limit: offset == nil ? -6 : nil, spl: offset != nil)
                .frame(minWidth: 160, maxWidth: .infinity)
                .frame(height: 12)
            Text(rms.map { String(format: "%.1f %@", $0, unit) } ?? "–")
                .font(.body.monospacedDigit())
                .frame(width: 110, alignment: .trailing)
            Text(reading.hold > -150 ? String(format: "peak %.1f dBFS", reading.hold) : "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(clipping ? Color.red : Color.secondary)
                .frame(width: 100, alignment: .leading)
                .help(clipping ? "Clipping: the input or output is at full scale" : "Highest sample lately, re full scale")
        }
    }
}
#endif
