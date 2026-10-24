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
    /// dB added to a level re full scale to give dB SPL, from a calibrator or typed in. It holds only
    /// while the interface gain stays where it was.
    var splOffset: Double?
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
    var level: Double = -30
    var position = ""
}

/// Speech and noise levels for STI, remembered between launches.
struct STISettings: Codable, Equatable {
    /// A-weighted speech level, dB(A). Sets the octave levels when `customSpeech` is off.
    var speechLevelA: Double = 60
    var customSpeech = false
    /// Octave speech levels, dB SPL, 125 Hz to 8 kHz. Used when `customSpeech` is on.
    var speechLevels = SpeechTransmission.speechLevels(aWeighted: 60)
    var includeNoise = false
    /// Octave background noise levels, dB SPL, 125 Hz to 8 kHz.
    var noiseLevels: [Double] = [45, 40, 35, 30, 25, 20, 15]
    var auditoryEffects = true

    var conditions: SpeechTransmission.Conditions {
        SpeechTransmission.Conditions(
            speechLevels: customSpeech ? speechLevels : SpeechTransmission.speechLevels(aWeighted: speechLevelA),
            noiseLevels: includeNoise ? noiseLevels : nil,
            auditoryEffects: auditoryEffects)
    }
}

struct SetupError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
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
    var sti: STISettings { didSet { save(sti, key: "sti") } }
    /// The target curve drawn on the frequency views and used by Auto EQ.
    var target: TargetCurve { didSet { save(target, key: "target") } }
    var autoEQSettings: AutoEQ.Settings { didSet { save(autoEQSettings, key: "autoEQ") } }
    /// Delays, polarities and gains tried on the Alignment view, and its range.
    var alignment: AlignmentSettings { didSet { save(alignment, key: "alignment") } }
    /// The live cross-spectrum analyser.
    let live: LiveAnalyzer
    /// Live monitoring: SPL meters and the RTA.
    let monitor: MonitorAnalyzer
    /// The signal generator window's test signal and meters.
    let generator: GeneratorModel

    var isMeasuring = false
    var status: String?
    var errorMessage: String?

    @ObservationIgnored private var calibrations: [String: FrequencyResponse] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init() {
        projectFolder = ProjectStore.defaultFolder
        settings = AppModel.load(key: "settings") ?? MeasurementSettings()
        micProfiles = AppModel.load(key: "mics") ?? []
        sti = AppModel.load(key: "sti") ?? STISettings()
        target = AppModel.load(key: "target") ?? TargetCurve.Preset.flat.curve
        autoEQSettings = AppModel.load(key: "autoEQ") ?? AutoEQ.Settings()
        alignment = AppModel.load(key: "alignment") ?? AlignmentSettings()
        live = LiveAnalyzer()
        monitor = MonitorAnalyzer()
        generator = GeneratorModel()
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
        live.stop()
        monitor.stop()
        generator.stop()
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
            let end = min(s.endFrequency, s.sampleRate / 2)
            if let problem = ExponentialSweep.validationError(startFrequency: s.startFrequency, endFrequency: end,
                                                              duration: s.sweepLength, sampleRate: s.sampleRate,
                                                              amplitude: pow(10, s.level / 20)) {
                throw SetupError(message: problem)
            }
            if Set(s.mics.map(\.channel)).count != s.mics.count {
                throw SetupError(message: "Two mics use the same input channel.")
            }
            let sweep = ExponentialSweep(startFrequency: s.startFrequency, endFrequency: end,
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
            let (made, loopbackPeak): ([Trace], Double?) = await Task.detached(priority: .userInitiated) {
                let result = SweepProcessing.process(mics: recording.mics, loopback: recording.loopback,
                                                     sweep: sweep, played: recording.played,
                                                     clockRatio: recording.clockRatio ?? 1)
                let traces = result.impulseResponses.enumerated().map { i, ir -> Trace in
                    let slot = s.mics[i]
                    let label = s.position.isEmpty ? "Mic \(i + 1)" : "\(s.position) · Mic \(i + 1)"
                    let info = TraceInfo(name: label, date: date, source: .sweep, sampleRate: s.sampleRate,
                                         mic: slot.micName, position: s.position,
                                         notes: "Input \(slot.channel), output \(s.outputChannel), \(Int(s.sweepLength)) s sweep at \(Int(s.level)) dBFS" + timingNote,
                                         timingReference: result.timingReference,
                                         peakLevel: result.micPeakLevels[i], colorIndex: count + i)
                    return Trace(info: info, impulseResponse: ir)
                }
                return (traces, result.loopbackPeakLevel)
            }.value

            for trace in made { add(trace) }
            selection = made.first?.id
            let peaks = made.compactMap(\.info.peakLevel)
            if let loop = loopbackPeak, loop > -1 {
                status = "Done, but the loopback input clipped (peak \(String(format: "%.1f", loop)) dBFS). Lower the level or the loopback gain."
            } else if let worst = peaks.max(), worst > -1 {
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

    // MARK: - Plain recordings

    /// Routing for a plain recording: the mic inputs only. The output plays silence, which keeps the
    /// devices running the same way as for a sweep.
    private func recordingRouting() throws -> SweepRouting {
        guard let out = outputDevice, let input = inputDevice else {
            throw SetupError(message: "Choose an output and an input device in Measurement Setup.")
        }
        if Set(settings.mics.map(\.channel)).count != settings.mics.count {
            throw SetupError(message: "Two mics use the same input channel.")
        }
        return SweepRouting(outputDevice: out, outputChannel: settings.outputChannel - 1, inputDevice: input,
                            micChannels: settings.mics.map { $0.channel - 1 })
    }

    /// Records every mic input for `duration` seconds and adds one trace per mic.
    func recordPlain(duration: Double, label: String) async {
        guard !isMeasuring else { return }
        live.stop()
        monitor.stop()
        generator.stop()
        let s = settings
        isMeasuring = true
        errorMessage = nil
        status = "Recording \(Int(duration)) s…"
        defer { isMeasuring = false }
        do {
            let routing = try recordingRouting()
            let silence = [Double](repeating: 0, count: Int(duration * s.sampleRate))
            let recording = try await SweepRecorder().record(silence, sampleRate: s.sampleRate, routing: routing)
            let date = Date()
            let count = traces.count
            var peaks: [Double] = []
            for (i, samples) in recording.mics.enumerated() {
                let slot = s.mics[i]
                let peak = 20 * log10(max(samples.map { abs($0) }.max() ?? 0, 1e-12))
                peaks.append(peak)
                let base = label.isEmpty ? "Recording" : label
                let info = TraceInfo(name: recording.mics.count > 1 ? "\(base) · Mic \(i + 1)" : base, date: date,
                                     source: .recording, sampleRate: s.sampleRate, mic: slot.micName, position: label,
                                     notes: "Input \(slot.channel), \(Int(duration)) s plain recording",
                                     peakLevel: peak, colorIndex: count + i,
                                     splOffset: micProfiles.first { $0.name == slot.micName }?.splOffset)
                add(Trace(info: info, recording: samples))
                if i == 0 { selection = info.id }
            }
            if let worst = peaks.max(), worst > -1 {
                status = "Recorded, but a mic clipped (peak \(String(format: "%.1f", worst)) dBFS). Lower the gain."
            } else {
                status = "Recorded \(peaks.count) mic\(peaks.count == 1 ? "" : "s"), \(Int(duration)) s."
            }
        } catch {
            status = nil
            errorMessage = "\(error)"
        }
    }

    /// Records a calibrator on the input `mic` is assigned to and sets the mic's SPL offset so the
    /// calibrator reads `reference` dB.
    func calibrateSPL(mic id: UUID, reference: Double) async {
        guard !isMeasuring, let mic = micProfiles.first(where: { $0.id == id }) else { return }
        live.stop()
        monitor.stop()
        generator.stop()
        guard let index = settings.mics.firstIndex(where: { $0.micName == mic.name }) else {
            errorMessage = "Assign \(mic.name) to a mic input first."
            return
        }
        isMeasuring = true
        errorMessage = nil
        status = "Calibrating \(mic.name)…"
        defer { isMeasuring = false }
        do {
            let fs = settings.sampleRate
            let routing = try recordingRouting()
            let silence = [Double](repeating: 0, count: Int(3 * fs))
            let recording = try await SweepRecorder().record(silence, sampleRate: fs, routing: routing)
            // Skip the first half second while the calibrator and the interface settle.
            let samples = Array(recording.mics[index].dropFirst(Int(0.5 * fs)))
            let level = SoundLevel.analyze(samples, sampleRate: fs, weighting: .z, timeWeighting: .slow).leq
            if level < -70 {
                throw SetupError(message: String(format: "The calibrator read only %.1f dBFS on input %d. Check it is on the mic and switched on.",
                                                 level, settings.mics[index].channel))
            }
            if let i = micProfiles.firstIndex(where: { $0.id == id }) {
                micProfiles[i].splOffset = reference - level
            }
            status = String(format: "Calibrated %@: %.1f dBFS reads %.1f dB SPL.", mic.name, level, reference)
        } catch {
            status = nil
            errorMessage = "\(error)"
        }
    }

    /// dB to add to a trace's level re full scale for dB SPL. Nil when its mic has not been calibrated.
    func splOffset(for trace: Trace) -> Double? {
        trace.info.splOffset ?? micProfiles.first { $0.name == trace.info.mic }?.splOffset
    }

    /// Uses octave noise levels (125 Hz to 8 kHz, dB SPL) as the background noise for STI.
    func useNoiseForSTI(_ levels: [Double]) {
        sti.noiseLevels = levels
        sti.includeNoise = true
        status = "STI now includes this background noise."
    }

    /// Uses octave levels (125 Hz to 8 kHz, dB SPL) as the STI speech levels, in place of the
    /// male speech spectrum.
    func useSpeechForSTI(_ levels: [Double]) {
        sti.speechLevels = levels
        sti.customSpeech = true
        status = "STI now uses this recording's octave levels as the speech level."
    }

    // MARK: - Averaging

    /// Adds a trace with the average frequency response of the given traces, each within its window
    /// and with its mic's calibration applied (so the average itself has no mic).
    func average(_ ids: [UUID], method: FrequencyResponse.AverageMethod) {
        let sources = traces.filter { ids.contains($0.id) && $0.hasResponse }
        guard sources.count >= 2 else {
            errorMessage = "Tick two or more traces with a frequency response to average them."
            return
        }
        let responses = sources.map { t in calibration(for: t).map { t.rawResponse.applyingCalibration($0) } ?? t.rawResponse }
        guard let avg = FrequencyResponse.average(responses, method: method) else {
            errorMessage = "These traces have no frequency range in common."
            return
        }
        let names = sources.map(\.info.name)
        let kind = method == .power ? "power" : "dB"
        // Name the measurements when there are few enough to read in the list.
        let name = names.count <= 3 ? "Avg (\(kind)): " + names.joined(separator: " + ") : "Average of \(names.count) (\(kind))"
        var info = TraceInfo(name: name, source: .average, sampleRate: sources.first?.info.sampleRate ?? 0,
                             position: sources.first?.info.position ?? "",
                             notes: "\(method.rawValue) average of " + names.joined(separator: ", "),
                             colorIndex: traces.count)
        info.averagedFrom = names
        let trace = Trace(info: info, frequencyResponse: avg)
        add(trace)
        selection = trace.id
        status = "Averaged \(sources.count) traces."
    }

    // MARK: - Virtual EQ

    func setEQ(_ filters: [EQFilter], for id: UUID) {
        guard var info = traces.first(where: { $0.id == id })?.info else { return }
        info.eq = filters.isEmpty ? nil : filters
        update(info)
        // The Frequency view draws the prediction only for a shown trace, so show the one being equalised.
        if !filters.isEmpty { visible.insert(id) }
    }

    /// Adds a trace with the predicted response of `id` with its Virtual EQ, for comparison.
    func addEQPrediction(for id: UUID) {
        guard let trace = traces.first(where: { $0.id == id }), let filters = trace.info.eq, !filters.isEmpty else { return }
        let measured = calibration(for: trace).map { trace.rawResponse.applyingCalibration($0) } ?? trace.rawResponse
        let predicted = ParametricEQ.apply(filters, to: measured, sampleRate: trace.eqSampleRate)
        let info = TraceInfo(name: "\(trace.info.name) + EQ", source: .eqPrediction, sampleRate: trace.info.sampleRate,
                             position: trace.info.position,
                             notes: "Predicted with Virtual EQ (\(Int(trace.eqSampleRate)) Hz biquads):\n" + ParametricEQ.description(filters),
                             colorIndex: traces.count)
        let made = Trace(info: info, frequencyResponse: predicted)
        add(made)
        status = "Added the predicted response of \(trace.info.name)."
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

    /// Sets the frequency response window of the given traces. Imported frequency responses are skipped.
    func setWindow(_ window: ResponseWindow, for ids: Set<UUID>) {
        for i in traces.indices where ids.contains(traces[i].id) && traces[i].impulseResponse != nil {
            traces[i].setWindow(window)
            try? ProjectStore.saveInfo(traces[i].info, in: projectFolder)
        }
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

    /// Imports WAV files as plain recordings, for levels and noise ratings.
    func importRecordings(_ urls: [URL]) async {
        status = "Importing…"
        var next = traces.count
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            guard let audio = try? WAV.read(contentsOf: url), let samples = audio.channels.first else {
                errorMessage = "Could not read \(url.lastPathComponent). Load WAV recordings."
                continue
            }
            let info = TraceInfo(name: name, source: .recording, sampleRate: audio.sampleRate,
                                 notes: "Imported from \(url.lastPathComponent)", colorIndex: next)
            let trace = Trace(info: info, recording: samples)
            add(trace)
            selection = trace.id
            next += 1
        }
        status = nil
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
        calibration(mic: trace.info.mic)
    }

    /// The calibration curve of a mic by name, if one is set. Files are read once and cached.
    func calibration(mic: String?) -> FrequencyResponse? {
        guard let mic, let profile = micProfiles.first(where: { $0.name == mic }),
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
