#if os(macOS)
import MeasureAudio
import MeasureDSP
import Observation
import SwiftUI

/// Meters every mic input and the loopback input from Measurement Setup, all the time, as Smaart
/// does beside each engine, so a dead mic, a gain set too low or a clipping input shows before and
/// while measuring. It listens on a stream of its own, alongside whatever else is running (sweeps,
/// live, the generator, monitoring): Core Audio lets several clients read one input device.
@Observable @MainActor
final class InputMeters {
    struct Channel: Identifiable {
        /// Index into the mics of Measurement Setup, or -1 for the loopback input.
        let id: Int
        /// Input on the interface, from 1.
        let input: Int
        var reading = MeterReading()
        /// Highest peak over the last few seconds, dBFS.
        var recentPeak = -200.0
        /// Peaked above `MeasurementQuality.clipLevel` since the clip marks were last cleared.
        var clipped = false
    }

    /// Off stops the stream and hides the meters. Remembered between launches.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "inputMeters") }
    }
    private(set) var mics: [Channel] = []
    private(set) var loopback: Channel?
    private(set) var isRunning = false
    /// Why the meters are not running, when they should be.
    private(set) var problem: String?

    @ObservationIgnored private let stream = LiveStream()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private weak var model: AppModel?
    /// The routing the stream was started with (or failed to start with), to restart when it changes.
    @ObservationIgnored private var routingKey = ""
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var positions: [Int] = []
    /// Each channel's peaks over the last few seconds, one per update.
    @ObservationIgnored private var recent: [[Double]] = []

    /// A routing key no setup has, so the next update starts the stream again.
    private static let stale = "stale"
    static let updateInterval = 0.1
    /// How long the peak readout holds, seconds.
    static let peakHold = 3.0

    init() {
        enabled = UserDefaults.standard.object(forKey: "inputMeters") as? Bool ?? true
    }

    /// Starts checking the setup and reading the meters, ten times a second, for the app's lifetime.
    func attach(_ model: AppModel) {
        self.model = model
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.updateInterval * 1e9))
            }
        }
    }

    /// Clears the clip marks.
    func resetClips() {
        for i in mics.indices { mics[i].clipped = false }
        loopback?.clipped = false
    }

    /// The meter of mic `index` of Measurement Setup, when it is being metered.
    func mic(_ index: Int) -> Channel? { mics.first { $0.id == index } }

    private func tick() {
        guard let model else { return }
        let key = enabled ? Self.key(model) : ""
        if key != routingKey {
            routingKey = key
            restart(model, key: key)
            return
        }
        guard isRunning else { return }
        var channel = 0
        if var meter = loopback {
            update(&meter, channel: channel, samples: read(channel) { stream.referenceSamples(from: $0) })
            loopback = meter
            channel += 1
        }
        for i in mics.indices {
            let c = channel + i
            update(&mics[i], channel: c, samples: read(c) { stream.samples(mic: i, from: $0) })
        }
    }

    /// What the stream depends on: the input device, its sample rate and the channels.
    private static func key(_ model: AppModel) -> String {
        guard let input = model.inputDevice else { return "none" }
        let s = model.settings
        let mics = s.mics.map { "\($0.channel)" }.joined(separator: ",")
        let loopback = s.loopbackInput.map(String.init(describing:)) ?? "-"
        return "\(input.uid)|\(s.sampleRate)|\(mics)|\(loopback)"
    }

    private func restart(_ model: AppModel, key: String) {
        // A start under way sees the new key when it finishes, and starts again.
        guard !starting else { return }
        stream.stop()
        isRunning = false
        problem = nil
        guard enabled else {
            mics = []
            loopback = nil
            return
        }
        let s = model.settings
        guard let input = model.inputDevice else {
            mics = []
            loopback = nil
            problem = "No input device chosen"
            return
        }
        // The stream always has a reference channel: the loopback input, or else the first mic again,
        // which is then not shown twice.
        let micChannels = s.mics.map { $0.channel - 1 }
        guard let reference = s.loopbackInput.map({ $0 - 1 }) ?? micChannels.first else {
            mics = []
            loopback = nil
            return
        }
        let routing = LiveRouting(inputDevice: input, referenceChannel: reference, micChannels: micChannels,
                                  outputDevice: nil, outputChannel: 0, loopbackOutputChannel: nil)
        starting = true
        Task {
            defer { starting = false }
            do {
                try await stream.start(routing: routing, sampleRate: s.sampleRate, signal: nil, level: 0)
            } catch {
                problem = "Input meters: \(error)"
                return
            }
            // The setup changed while the stream started: start again with the new one.
            guard routingKey == key else {
                routingKey = Self.stale
                return
            }
            mics = s.mics.enumerated().map { Channel(id: $0.offset, input: $0.element.channel) }
            loopback = s.loopbackInput.map { Channel(id: -1, input: $0) }
            let channels = mics.count + (loopback == nil ? 0 : 1)
            // Start reading from now, not from the start of the buffer.
            positions = Array(repeating: stream.capturedFrames, count: channels)
            recent = Array(repeating: [], count: channels)
            isRunning = true
        }
    }

    private func read(_ channel: Int, _ get: (Int) -> (samples: [Double], end: Int)) -> [Double] {
        guard channel < positions.count else { return [] }
        let (samples, end) = get(positions[channel])
        positions[channel] = end
        return samples
    }

    private func update(_ meter: inout Channel, channel: Int, samples: [Double]) {
        guard !samples.isEmpty, channel < recent.count else { return }
        meter.reading.update(samples)
        let peak = meter.reading.peak
        let held = Int(Self.peakHold / Self.updateInterval)
        recent[channel].append(peak)
        if recent[channel].count > held { recent[channel].removeFirst(recent[channel].count - held) }
        meter.recentPeak = recent[channel].max() ?? peak
        if peak > MeasurementQuality.clipLevel { meter.clipped = true }
    }
}

// MARK: - Views

/// A narrow vertical meter, as Smaart draws beside each engine: the RMS level as a bar, the recent
/// peak as a line, green up to -12 dBFS, yellow to -3 dBFS and red above, with a red cap once the
/// input has clipped.
struct VerticalInputMeter: View {
    let channel: InputMeters.Channel
    /// The scale's bottom, dBFS.
    static let floor = -60.0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let capHeight: CGFloat = 4
            let scale = h - capHeight - 1
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary)
                // The RMS level, coloured by the peak.
                Rectangle()
                    .fill(Self.color(channel.reading.peak))
                    .frame(height: scale * Self.fraction(channel.reading.rms))
                // The peak just now, as a thin bar over the RMS one.
                Rectangle()
                    .fill(Self.color(channel.reading.peak).opacity(0.45))
                    .frame(height: scale * Self.fraction(channel.reading.peak))
                // The highest peak over the last few seconds.
                Rectangle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(height: 1.5)
                    .offset(y: -scale * Self.fraction(channel.recentPeak))
                    .opacity(channel.recentPeak > Self.floor ? 1 : 0)
                // The clip mark.
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(channel.clipped ? Color.red : Color.secondary.opacity(0.25))
                        .frame(height: capHeight)
                    Spacer(minLength: 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .frame(width: 7)
    }

    static func fraction(_ level: Double) -> CGFloat {
        CGFloat(min(max((level - floor) / -floor, 0), 1))
    }

    static func color(_ peak: Double) -> Color {
        if peak > -3 { return .red }
        if peak > -12 { return .yellow }
        return .green
    }
}

/// The recent peak as a number beside the meter, red once the input has clipped.
struct InputMeterReadout: View {
    let channel: InputMeters.Channel

    var body: some View {
        Text(channel.recentPeak > VerticalInputMeter.floor - 30 ? String(format: "%.0f", channel.recentPeak) : "–")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(channel.clipped ? Color.red : Color.secondary)
            .frame(width: 24, alignment: .trailing)
    }
}

/// The meter and its readout, for the end of a row in the measurement list. Click to clear the clip marks.
struct InputMeterView: View {
    @Environment(AppModel.self) private var model
    let channel: InputMeters.Channel

    var body: some View {
        HStack(spacing: 4) {
            InputMeterReadout(channel: channel)
            VerticalInputMeter(channel: channel)
                .frame(height: 26)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.inputMeters.resetClips() }
        .help(help)
    }

    private var help: String {
        let peak = channel.recentPeak > -150 ? String(format: "%.1f dBFS", channel.recentPeak) : "no signal"
        let rms = channel.reading.rms > -150 ? String(format: "%.1f dBFS", channel.reading.rms) : "no signal"
        let clip = channel.clipped ? "\nClipped (above \(Int(MeasurementQuality.clipLevel)) dBFS). Click to clear." : ""
        return "Input \(channel.input): peak over the last \(Int(InputMeters.peakHold)) s \(peak), RMS \(rms). Green to -12 dBFS, yellow to -3, red above.\(clip)"
    }
}

/// Every mic input and the loopback with their meters, at the top of the measurement list. In Live
/// the live mics' rows carry the meters instead.
struct InputsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("inputsExpanded") private var expanded = true

    var body: some View {
        let meters = model.inputMeters
        Section(isExpanded: $expanded) {
            if let problem = meters.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            ForEach(Array(model.settings.mics.enumerated()), id: \.element.id) { i, slot in
                row(name: slot.micName ?? "Mic \(i + 1)",
                    detail: "Input \(slot.channel)" + (slot.active ? "" : " · not in sweeps"),
                    channel: meters.mic(i), dimmed: !slot.active)
            }
            if let loopback = model.settings.loopbackInput {
                row(name: "Loopback", detail: "Input \(loopback)", channel: meters.loopback, dimmed: false)
            }
        } header: {
            Text("Inputs")
                .contextMenu { InputMetersMenu() }
        }
    }

    private func row(name: String, detail: String, channel: InputMeters.Channel?, dimmed: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(dimmed ? 0.6 : 1)
            Spacer(minLength: 0)
            if let channel { InputMeterView(channel: channel) }
        }
        .contextMenu { InputMetersMenu() }
    }
}

/// Clear Clips and the switch that turns the meters off, for context menus and the Measurement menu.
struct InputMetersMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Clear Clip Marks") { model.inputMeters.resetClips() }
            .disabled(!model.inputMeters.isRunning)
        Toggle("Input Meters", isOn: Binding(get: { model.inputMeters.enabled }, set: { model.inputMeters.enabled = $0 }))
    }
}
#endif
