#if os(macOS)
import Foundation
import MeasureAudio
import MeasureDSP
import Observation

/// A measurement microphone and its calibration, kept with the mic rather than with the input it uses.
struct MicProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var calibrationPath: String?
    /// dB, from the calibration file's "Sens Factor" line if it has one.
    var sensitivity: Double?
}

/// One mic input in a measurement: which input channel, and which mic is plugged into it.
struct MicSlot: Codable, Identifiable, Hashable {
    var id = UUID()
    /// From 1, as printed on the interface.
    var channel: Int
    var micName: String?
}

/// Routing and sweep settings, remembered between launches. Devices are stored by UID so they are
/// found again after reconnecting.
struct MeasurementSettings: Codable, Equatable {
    var outputUID: String?
    var outputChannel = 1
    var inputUID: String?
    var mics: [MicSlot] = [MicSlot(channel: 1)]
    var loopbackInput: Int?
    var loopbackOutput: Int?
    var sampleRate: Double = 48_000
    var startFrequency: Double = 20
    var endFrequency: Double = 20_000
    var sweepLength: Double = 3
    var silence: Double = 2
    var level: Double = -12
    var position = ""
}

@Observable @MainActor
final class AppModel {
    var traces: [Trace] = []
    /// Traces drawn in the views (the overlay).
    var visible: Set<UUID> = []
    /// The trace whose details (acoustics table, decay) are shown.
    var selection: UUID?
    var projectFolder: URL

    var devices: [AudioDevice] = []
    var settings: MeasurementSettings { didSet { save(settings, key: "settings") } }
    var micProfiles: [MicProfile] { didSet { save(micProfiles, key: "mics"); calibrations = [:] } }
    var smoothing: Smoothing = .sixth

    var isMeasuring = false
    var status: String?
    var errorMessage: String?

    @ObservationIgnored private var calibrations: [String: FrequencyResponse] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init() {
        projectFolder = ProjectStore.defaultFolder
        settings = AppModel.load(key: "settings") ?? MeasurementSettings()
        micProfiles = AppModel.load(key: "mics") ?? []
        refreshDevices()
        openProject(projectFolder)
    }

    var selectedTrace: Trace? { traces.first { $0.id == selection } }
    var visibleTraces: [Trace] { traces.filter { visible.contains($0.id) } }

    // MARK: - Devices

    func refreshDevices() {
        devices = (try? AudioDevices.all()) ?? []
        if settings.outputUID == nil || !devices.contains(where: { $0.uid == settings.outputUID }) {
            settings.outputUID = devices.first { $0.outputChannels > 0 && $0.inputChannels > 0 }?.uid
                ?? devices.first { $0.outputChannels > 0 }?.uid
        }
        if let uid = settings.inputUID, !devices.contains(where: { $0.uid == uid }) {
            settings.inputUID = nil
        }
    }

    var outputDevice: AudioDevice? { devices.first { $0.uid == settings.outputUID } }
    /// The input device, which defaults to the output device.
    var inputDevice: AudioDevice? { devices.first { $0.uid == (settings.inputUID ?? settings.outputUID) } }

    // MARK: - Measuring

    func measure() async {
        guard !isMeasuring else { return }
        guard let out = outputDevice, let input = inputDevice else {
            errorMessage = "Choose an output and an input device in Measurement Setup."
            return
        }
        let s = settings
        isMeasuring = true
        errorMessage = nil
        status = "Measuring…"
        defer { isMeasuring = false }

        do {
            let sweep = ExponentialSweep(startFrequency: s.startFrequency, endFrequency: min(s.endFrequency, s.sampleRate / 2),
                                         duration: s.sweepLength, sampleRate: s.sampleRate,
                                         amplitude: pow(10, s.level / 20))
            let played = sweep.samples(silence: s.silence)
            let routing = SweepRouting(outputDevice: out, outputChannel: s.outputChannel - 1,
                                       inputDevice: input, micChannels: s.mics.map { $0.channel - 1 },
                                       loopbackChannel: s.loopbackInput.map { $0 - 1 },
                                       loopbackOutputChannel: s.loopbackOutput.map { $0 - 1 })
            let recording = try await SweepRecorder().record(played, sampleRate: s.sampleRate, routing: routing)
            status = "Analysing…"

            let count = traces.count
            let date = Date()
            let timingNote: String
            if let ppm = recording.driftPPM {
                timingNote = String(format: ". Separate devices, clock difference %.1f ppm corrected", ppm)
            } else if recording.separateDevices {
                timingNote = ". Separate devices, clock difference not corrected"
            } else {
                timingNote = ""
            }
            let made: [Trace] = await Task.detached(priority: .userInitiated) {
                let result = SweepProcessing.process(mics: recording.mics, loopback: recording.loopback,
                                                     sweep: sweep, played: recording.played,
                                                     clockRatio: recording.clockRatio ?? 1)
                return result.impulseResponses.enumerated().map { i, ir in
                    let slot = s.mics[i]
                    let label = s.position.isEmpty ? "Mic \(i + 1)" : "\(s.position) · Mic \(i + 1)"
                    let info = TraceInfo(name: label, date: date, source: .sweep, sampleRate: s.sampleRate,
                                         mic: slot.micName, position: s.position,
                                         notes: "Input \(slot.channel), output \(s.outputChannel), \(Int(s.sweepLength)) s sweep at \(Int(s.level)) dBFS" + timingNote,
                                         timingReference: result.timingReference,
                                         peakLevel: result.micPeakLevels[i], colorIndex: count + i)
                    return Trace(info: info, impulseResponse: ir)
                }
            }.value

            for trace in made { add(trace) }
            selection = made.first?.id
            let peaks = made.compactMap(\.info.peakLevel)
            if let worst = peaks.max(), worst > -1 {
                status = "Done, but a mic clipped (peak \(String(format: "%.1f", worst)) dBFS). Lower the level."
            } else if let quiet = peaks.min(), quiet < -50 {
                status = "Done, but the level was low (peak \(String(format: "%.1f", quiet)) dBFS). Raise the level or gain."
            } else {
                var text = "Measured \(made.count) mic\(made.count == 1 ? "" : "s")."
                if let ppm = recording.driftPPM { text += String(format: " Input and output clocks differ by %.1f ppm (corrected).", ppm) }
                if recording.separateDevices && recording.loopback == nil {
                    text += " Separate devices without a loopback: arrival times are approximate."
                }
                status = text
            }
        } catch {
            status = nil
            errorMessage = "\(error)"
        }
    }

    // MARK: - Library

    func add(_ trace: Trace) {
        traces.append(trace)
        visible.insert(trace.id)
        do { try ProjectStore.save(trace, in: projectFolder) } catch { errorMessage = "Could not save \(trace.info.name): \(error)" }
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids { ProjectStore.delete(id, in: projectFolder) }
        traces.removeAll { ids.contains($0.id) }
        visible.subtract(ids)
        if let s = selection, ids.contains(s) { selection = traces.last?.id }
    }

    func update(_ info: TraceInfo) {
        guard let i = traces.firstIndex(where: { $0.id == info.id }) else { return }
        traces[i].info = info
        try? ProjectStore.saveInfo(info, in: projectFolder)
    }

    /// Opens a project folder. Loading analyses every trace, so it runs off the main thread.
    func openProject(_ folder: URL) {
        projectFolder = folder
        traces = []
        visible = []
        selection = nil
        status = "Loading \(folder.lastPathComponent)…"
        loadTask?.cancel()
        loadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) { ProjectStore.load(from: folder) }.value
            guard !Task.isCancelled, projectFolder == folder else { return }
            // Keep anything measured while the project was loading.
            let loadedIDs = Set(loaded.map(\.id))
            traces = loaded + traces.filter { !loadedIDs.contains($0.id) }
            visible.formUnion(loaded.suffix(4).map(\.id))
            selection = selection ?? traces.last?.id
            status = nil
        }
    }

    /// Imports WAV impulse responses and REW text frequency responses.
    func importFiles(_ urls: [URL]) async {
        status = "Importing…"
        var next = traces.count
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let colorIndex = next
            let trace: Trace? = await Task.detached(priority: .userInitiated) {
                if url.pathExtension.lowercased() == "wav", let audio = try? WAV.read(contentsOf: url), let ir = audio.channels.first {
                    let info = TraceInfo(name: name, source: .importedImpulseResponse, sampleRate: audio.sampleRate,
                                         notes: "Imported from \(url.lastPathComponent)", colorIndex: colorIndex)
                    return Trace(info: info, impulseResponse: ir)
                }
                if let parsed = try? FrequencyResponseText.parse(contentsOf: url) {
                    let info = TraceInfo(name: name, source: .importedFrequencyResponse, sampleRate: 0,
                                         notes: "Imported from \(url.lastPathComponent)", colorIndex: colorIndex)
                    return Trace(info: info, frequencyResponse: parsed.response)
                }
                return nil
            }.value
            if let trace {
                add(trace)
                selection = trace.id
                next += 1
            } else {
                errorMessage = "Could not read \(url.lastPathComponent). Import WAV impulse responses or REW text exports."
            }
        }
        status = nil
    }

    // MARK: - Calibration

    /// The calibration curve of the mic a trace was measured with, if one is set.
    func calibration(for trace: Trace) -> FrequencyResponse? {
        guard let mic = trace.info.mic, let profile = micProfiles.first(where: { $0.name == mic }),
              let path = profile.calibrationPath else { return nil }
        if let cached = calibrations[path] { return cached }
        guard let parsed = try? FrequencyResponseText.parse(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        calibrations[path] = parsed.response
        return parsed.response
    }

    // MARK: - Persistence

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
#endif
