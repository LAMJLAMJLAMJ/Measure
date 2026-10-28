#if os(macOS)
import AppKit
import Foundation
import MeasureAudio
import MeasureDSP
import Observation

/// Traces chosen for the impulse response export sheet.
struct ExportRequest: Identifiable {
    let id = UUID()
    let traces: [UUID]
}

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
    /// True when the input is left out of sweeps (kept for live monitoring and the generator).
    /// Optional so settings saved before it existed still load.
    var off: Bool?

    /// Whether sweeps record this input.
    var active: Bool {
        get { off != true }
        set { off = newValue ? nil : true }
    }
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

    /// The mic inputs that sweeps record.
    var activeMics: [MicSlot] { mics.filter(\.active) }
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

/// What went wrong with a sweep, for the status bar.
struct MeasurementWarning: Equatable {
    var text: String
    /// Clipping, a level too low to use, or too little range even for T20: measure again.
    var severe: Bool

    /// The problems of the traces of one sweep, or nil when there are none.
    init?(_ traces: [Trace], loopbackPeak: Double?) {
        var lines: [String] = []
        var severe = false
        if let loop = loopbackPeak, loop > MeasurementQuality.clipLevel {
            let issue = MeasurementQuality.Issue.loopbackClipped(peak: loop)
            lines.append(issue.message)
            severe = true
        }
        for (i, trace) in traces.enumerated() where !trace.qualityIssues.isEmpty {
            let prefix = traces.count > 1 ? "Mic \(i + 1): " : ""
            lines.append(prefix + trace.qualityIssues.map(\.message).joined(separator: " "))
            severe = severe || trace.qualityIssues.contains(where: \.isSevere)
        }
        guard !lines.isEmpty else { return nil }
        text = lines.joined(separator: "\n")
        self.severe = severe
    }
}

struct SetupError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@Observable @MainActor
final class AppModel {
    var traces: [Trace] = []
    /// Folders in the trace list, top first.
    var folders: [TraceFolder] = []
    /// Traces drawn in the views (the overlay).
    var visible: Set<UUID> = []
    /// The trace whose details (acoustics table, decay) are shown.
    var selection: UUID?
    var projectFolder: URL

    var devices: [AudioDevice] = []
    var settings: MeasurementSettings { didSet { save(settings, key: "settings") } }
    var micProfiles: [MicProfile] { didSet { save(micProfiles, key: "mics"); calibrations = [:]; refreshSums() } }
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
    /// Plays the sweep in a loop and meters the inputs, to set the gains before measuring.
    let levelCheck: LevelCheck
    /// The iPad remote's link to this Mac.
    let remote: RemoteHost

    var isMeasuring = false
    var status: String?
    var errorMessage: String?
    /// Problems found in the last sweep (clipping, low level, low signal-to-noise), shown in the status
    /// bar until dismissed or the next measurement.
    var measurementWarning: MeasurementWarning?

    @ObservationIgnored private var calibrations: [String: FrequencyResponse] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The open project's measurements are still being read.
    @ObservationIgnored private var loading = false

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
        levelCheck = LevelCheck()
        remote = RemoteHost()
        refreshDevices()
        openProject(projectFolder)
        remote.attach(self)
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
        levelCheck.stop()
        guard let out = outputDevice, let input = inputDevice else {
            errorMessage = "Choose an output and an input device in Measurement Setup."
            return
        }
        let s = settings
        let mics = s.activeMics
        guard !mics.isEmpty else {
            errorMessage = "Every mic is switched off for sweeps. Tick at least one in Measurement Setup."
            return
        }
        isMeasuring = true
        errorMessage = nil
        measurementWarning = nil
        status = "Measuring…"
        defer { isMeasuring = false }

        do {
            let end = min(s.endFrequency, s.sampleRate / 2)
            if let problem = ExponentialSweep.validationError(startFrequency: s.startFrequency, endFrequency: end,
                                                              duration: s.sweepLength, sampleRate: s.sampleRate,
                                                              amplitude: pow(10, s.level / 20)) {
                throw SetupError(message: problem)
            }
            if Set(mics.map(\.channel)).count != mics.count {
                throw SetupError(message: "Two mics use the same input channel.")
            }
            let sweep = ExponentialSweep(startFrequency: s.startFrequency, endFrequency: end,
                                         duration: s.sweepLength, sampleRate: s.sampleRate,
                                         amplitude: pow(10, s.level / 20))
            let played = sweep.samples(silence: s.silence)
            let routing = SweepRouting(outputDevice: out, outputChannel: s.outputChannel - 1,
                                       inputDevice: input, micChannels: mics.map { $0.channel - 1 },
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
                    let slot = mics[i]
                    let label = s.position.isEmpty ? "Mic \(i + 1)" : "\(s.position) · Mic \(i + 1)"
                    var info = TraceInfo(name: label, date: date, source: .sweep, sampleRate: s.sampleRate,
                                         mic: slot.micName, position: s.position,
                                         notes: "Input \(slot.channel), output \(s.outputChannel), \(Int(s.sweepLength)) s sweep at \(Int(s.level)) dBFS" + timingNote,
                                         timingReference: result.timingReference,
                                         peakLevel: result.micPeakLevels[i], colorIndex: count + i)
                    info.distortion = result.distortion[i]
                    return Trace(info: info, impulseResponse: ir)
                }
                return (traces, result.loopbackPeakLevel)
            }.value

            for trace in made { add(trace) }
            selection = made.first?.id
            measurementWarning = MeasurementWarning(made, loopbackPeak: loopbackPeak)
            var text = "Measured \(made.count) mic\(made.count == 1 ? "" : "s")."
            if let ppm = recording.driftPPM { text += String(format: " Input and output clocks differ by %.1f ppm (corrected).", ppm) }
            if recording.separateDevices && recording.loopback == nil {
                text += " Separate devices without a loopback: arrival times are approximate."
            }
            status = text
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
        guard let avg = FrequencyResponse.average(sources.map(calibratedRawResponse), method: method) else {
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

    /// A trace's response within its window with its mic's calibration applied, unsmoothed.
    private func calibratedRawResponse(_ t: Trace) -> FrequencyResponse {
        calibration(for: t).map { t.rawResponse.applyingCalibration($0) } ?? t.rawResponse
    }

    // MARK: - Summing folders

    /// Adds a summing folder at the top of the list and returns its id. Measurements put in it are
    /// hidden, and the folder shows their average, remade whenever they change.
    @discardableResult
    func addSummingFolder(named name: String = "Summing Folder", method: FrequencyResponse.AverageMethod = .power) -> UUID {
        let f = TraceFolder(name: name, summing: method, averageID: UUID(), averageColor: traces.count)
        folders.insert(f, at: 0)
        saveFolders()
        return f.id
    }

    func setSumming(_ method: FrequencyResponse.AverageMethod, for id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].summing != method else { return }
        folders[i].summing = method
        saveFolders()
        refreshSums([id])
    }

    /// Shows or hides a summing folder's average (its tick).
    func setAverageShown(_ shown: Bool, for id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].averageHidden = shown ? nil : true
        saveFolders()
        if let average = folders[i].averageID {
            if shown && traces.contains(where: { $0.id == average }) { visible.insert(average) } else { visible.remove(average) }
        }
    }

    func setAverageColor(_ index: Int, for id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].averageColor = index
        saveFolders()
        refreshSums([id])
    }

    /// The average a summing folder shows, if it has measurements to average.
    func average(of folder: TraceFolder) -> Trace? {
        guard let id = folder.averageID else { return nil }
        return traces.first { $0.id == id }
    }

    /// Remakes the averages of the given summing folders, or of all of them.
    func refreshSums(_ ids: Set<UUID>? = nil) {
        for folder in folders where folder.isSumming && (ids?.contains(folder.id) ?? true) {
            refreshSum(folder)
        }
    }

    private func refreshSum(_ folder: TraceFolder) {
        guard let method = folder.summing, let id = folder.averageID else { return }
        let sources = traces.filter { $0.info.folder == folder.id && $0.info.sumFolder == nil && $0.hasResponse }
        let existing = traces.firstIndex { $0.id == id }
        guard let avg = FrequencyResponse.average(sources.map(calibratedRawResponse), method: method) else {
            // Nothing to average (or no frequency range in common): the folder shows nothing.
            if let existing { traces.remove(at: existing) }
            visible.remove(id)
            return
        }
        let names = sources.map(\.info.name)
        let kind = method == .power ? "power" : "dB"
        var info = TraceInfo(name: "\(folder.name) (\(kind) average)", source: .average,
                             sampleRate: sources.first?.info.sampleRate ?? 0, position: sources.first?.info.position ?? "",
                             notes: "\(method.rawValue) average of " + names.joined(separator: ", "),
                             colorIndex: folder.averageColor ?? 0)
        info.id = id
        info.averagedFrom = names
        info.sumFolder = folder.id
        if let existing { info.date = traces[existing].info.date }
        let trace = Trace(info: info, frequencyResponse: avg)
        if let existing {
            traces[existing] = trace
        } else {
            traces.append(trace)
            if folder.averageHidden != true { visible.insert(id) }
        }
    }

    /// The summing folders that hold any of these traces.
    private func summingFolders(of ids: Set<UUID>) -> Set<UUID> {
        let summing = Set(folders.filter(\.isSumming).map(\.id))
        return Set(traces.filter { ids.contains($0.id) }.compactMap(\.info.folder)).intersection(summing)
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
        // A summing folder's average is not a measurement: only its folder removes it.
        let ids = ids.filter { id in traces.first { $0.id == id }?.info.sumFolder == nil }
        let sums = summingFolders(of: ids)
        for id in ids { ProjectStore.delete(id, in: projectFolder) }
        traces.removeAll { ids.contains($0.id) }
        visible.subtract(ids)
        refreshSums(sums)
        if let s = selection, ids.contains(s) { selection = traces.last?.id }
    }

    /// The open project is the working folder, not a saved set or a folder chosen with Open.
    var isWorkingFolder: Bool {
        projectFolder.standardizedFileURL == ProjectStore.defaultFolder.standardizedFileURL
    }

    /// Empties the list. Unsaved measurements (the working folder's) are deleted for good. A saved
    /// set or chosen folder is left as it is on disk: the app goes back to an empty working folder.
    func clearAll() {
        loadTask?.cancel()
        loading = false
        if !isWorkingFolder { projectFolder = ProjectStore.defaultFolder }
        ProjectStore.deleteAll(in: projectFolder)
        traces = []
        visible = []
        selection = nil
        folders = []
        measurementWarning = nil
        status = "Cleared the measurement list."
    }

    /// Sets the frequency response window of the given traces. Imported frequency responses are skipped.
    func setWindow(_ window: ResponseWindow, for ids: Set<UUID>) {
        for i in traces.indices where ids.contains(traces[i].id) && traces[i].impulseResponse != nil {
            traces[i].setWindow(window)
            try? ProjectStore.saveInfo(traces[i].info, in: projectFolder)
        }
        refreshSums(summingFolders(of: ids))
    }

    // MARK: - Folders

    /// Adds a folder at the top of the list and returns its id.
    @discardableResult
    func addFolder(named name: String = "New Folder") -> UUID {
        let f = TraceFolder(name: name)
        folders.insert(f, at: 0)
        saveFolders()
        return f.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        saveFolders()
        refreshSums([id])
    }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].expanded != expanded else { return }
        folders[i].expanded = expanded
        saveFolders()
    }

    /// Removes a folder. Its measurements stay, at the top level; a summing folder's average goes.
    func deleteFolder(_ id: UUID) {
        let average = folders.first { $0.id == id }?.averageID
        move(Set(traces.filter { $0.info.folder == id && $0.info.sumFolder == nil }.map(\.id)), to: nil)
        if let average {
            traces.removeAll { $0.id == average }
            visible.remove(average)
        }
        folders.removeAll { $0.id == id }
        saveFolders()
    }

    /// Puts traces in a folder, or at the top level for nil. Traces put in a summing folder are hidden:
    /// the folder shows their average instead.
    func move(_ ids: Set<UUID>, to folder: UUID?) {
        let ids = ids.filter { id in traces.first { $0.id == id }?.info.sumFolder == nil }
        var changed = summingFolders(of: ids)
        // Measurements taken out of a summing folder are ticked again, as they were before it hid them.
        let leaving = Set(traces.filter { ids.contains($0.id) && changed.contains($0.info.folder ?? UUID()) }.map(\.id))
        if !changed.contains(folder ?? UUID()) { visible.formUnion(leaving) }
        for i in traces.indices where ids.contains(traces[i].id) && traces[i].info.folder != folder {
            traces[i].info.folder = folder
            try? ProjectStore.saveInfo(traces[i].info, in: projectFolder)
        }
        if let folder, folders.first(where: { $0.id == folder })?.isSumming == true {
            visible.subtract(ids)
            changed.insert(folder)
        }
        refreshSums(changed)
        if let folder { setExpanded(folder, true) }
    }

    private func saveFolders() {
        do { try ProjectStore.saveFolders(folders, in: projectFolder) } catch { errorMessage = "Could not save the folders: \(error)" }
    }

    func update(_ info: TraceInfo) {
        guard let i = traces.firstIndex(where: { $0.id == info.id }) else { return }
        let renamed = traces[i].info.name != info.name
        traces[i].info = info
        guard info.sumFolder == nil else { return }
        try? ProjectStore.saveInfo(info, in: projectFolder)
        // A summing folder's average lists its measurements by name.
        if renamed { refreshSums(summingFolders(of: [info.id])) }
    }

    /// Opens a project folder. Loading analyses every trace, so it runs off the main thread.
    func openProject(_ folder: URL) {
        if folder.pathExtension == ProjectStore.setExtension { NSDocumentController.shared.noteNewRecentDocumentURL(folder) }
        projectFolder = folder
        folders = ProjectStore.loadFolders(from: folder)
        traces = []
        visible = []
        selection = nil
        status = "Loading \(folder.lastPathComponent)…"
        loading = true
        loadTask?.cancel()
        loadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) { ProjectStore.load(from: folder) }.value
            guard !Task.isCancelled, projectFolder == folder else { return }
            loading = false
            // Keep anything measured while the project was loading.
            let loadedIDs = Set(loaded.map(\.id))
            traces = loaded + traces.filter { !loadedIDs.contains($0.id) }
            let summing = Set(folders.filter(\.isSumming).map(\.id))
            visible.formUnion(loaded.suffix(4).filter { !($0.info.folder.map(summing.contains) ?? false) }.map(\.id))
            refreshSums()
            selection = selection ?? traces.last?.id
            status = nil
        }
    }

    // MARK: - Export

    /// Impulse responses waiting for the export sheet.
    var exportRequest: ExportRequest?

    /// Opens the export sheet for the ticked impulse responses, or the selected one when none is ticked.
    func requestImpulseExport() {
        let ticked = traces.filter { visible.contains($0.id) && $0.impulseResponse != nil }.map(\.id)
        let ids = ticked.isEmpty ? [selectedTrace].compactMap { $0?.impulseResponse == nil ? nil : $0?.id } : ticked
        guard !ids.isEmpty else {
            errorMessage = "Tick or select a measured impulse response to export."
            return
        }
        exportRequest = ExportRequest(traces: ids)
    }

    /// Writes impulse responses as WAV files: each to its own file in the folder `url`, one to the file
    /// `url`, or all as the channels of the one file `url` when `combine` is set.
    func exportImpulseResponses(_ ids: [UUID], options: ImpulseExport, combine: Bool, to url: URL) {
        let chosen = ids.compactMap { id in traces.first { $0.id == id && $0.impulseResponse != nil } }
        guard let first = chosen.first else { return }
        let trimmed = chosen.map { options.trimmed($0.impulseResponse!, onset: $0.onset, sampleRate: $0.info.sampleRate) }
        var gains: [Double] = []
        do {
            if combine && chosen.count > 1 {
                guard chosen.allSatisfy({ $0.info.sampleRate == first.info.sampleRate }) else {
                    errorMessage = "The impulse responses have different sample rates, so they cannot share one file."
                    return
                }
                // One gain for all, so the channels keep their relative levels; shorter ones are padded.
                let n = trimmed.map(\.count).max() ?? 0
                let padded = trimmed.map { $0 + [Double](repeating: 0, count: n - $0.count) }
                let out = options.levelled(padded)
                gains.append(out.gain)
                try WAV.write(AudioData(sampleRate: first.info.sampleRate, channels: out.channels), to: url, format: options.format)
            } else if chosen.count == 1 {
                let out = options.levelled([trimmed[0]])
                gains.append(out.gain)
                try WAV.write(AudioData(sampleRate: first.info.sampleRate, mono: out.channels[0]), to: url, format: options.format)
            } else {
                var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).map { $0.lowercased() })
                for (trace, x) in zip(chosen, trimmed) {
                    let name = ImpulseExport.fileName(trace.info.name, taken: taken)
                    taken.insert(name.lowercased())
                    let out = options.levelled([x])
                    gains.append(out.gain)
                    try WAV.write(AudioData(sampleRate: trace.info.sampleRate, mono: out.channels[0]),
                                  to: url.appendingPathComponent(name), format: options.format)
                }
            }
        } catch {
            errorMessage = "Could not export: \(error.localizedDescription)"
            return
        }
        let files = combine || chosen.count == 1 ? url.lastPathComponent : "\(chosen.count) files in \(url.lastPathComponent)"
        var note = "Exported \(files)"
        // Scaled down only to keep a fixed-point file from clipping, which the person did not ask for.
        if options.normalizeTo == nil, let g = gains.min(), g < -0.05 {
            note += String(format: ", scaled by %.1f dB to fit the format", g)
        }
        status = note
    }

    // MARK: - Measurement sets

    /// Saves measurements as a set at `url`, a .measure package: all of them, carrying on in the set as
    /// Save As does, or only `ids`, leaving the open project as it is. An existing set there is replaced.
    func saveSet(to url: URL, only ids: Set<UUID>? = nil) {
        let destination = url.standardizedFileURL
        let current = projectFolder.standardizedFileURL
        if ids == nil && destination == current { return }
        guard !loading else {
            errorMessage = "Wait until the project has loaded, then save the set."
            return
        }
        // Replacing the open project, or a folder holding it, would delete the measurements being saved.
        guard destination != current && !current.path.hasPrefix(destination.path + "/") else {
            errorMessage = "Choose another name: \(destination.lastPathComponent) holds the open project."
            return
        }
        let chosen = traces.filter { ids?.contains($0.id) ?? true }
        let used = Set(chosen.compactMap(\.info.folder))
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            for trace in chosen { try ProjectStore.copy(trace.id, from: projectFolder, to: destination) }
            try ProjectStore.saveFolders(folders.filter { used.contains($0.id) }, in: destination)
        } catch {
            errorMessage = "Could not save the set: \(error.localizedDescription)"
            return
        }
        if ids == nil {
            // The traces are already loaded: carry on in the set without analysing them again.
            projectFolder = destination
            status = nil
        } else {
            status = "Saved \(chosen.count) measurement\(chosen.count == 1 ? "" : "s") as \(destination.lastPathComponent)"
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(destination)
    }

    /// Copies the measurements of another set (or project folder) into the open project, with its
    /// folders. Its measurements outside a folder go into a new folder named after it. Measurements
    /// already here are skipped.
    func addSet(from url: URL) {
        let source = url.standardizedFileURL
        guard source != projectFolder.standardizedFileURL else { return }
        let name = source.deletingPathExtension().lastPathComponent
        let destination = projectFolder
        status = "Adding \(name)…"
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { ProjectStore.load(from: source) }.value
            guard projectFolder == destination else { return }
            let have = Set(traces.map(\.id))
            let new = loaded.filter { !have.contains($0.id) }
            status = nil
            guard !new.isEmpty else {
                errorMessage = loaded.isEmpty ? "\(name) has no measurements." : "Every measurement in \(name) is already here."
                return
            }
            let setFolders = ProjectStore.loadFolders(from: source)
            let known = Set(folders.map(\.id))
            let used = Set(new.compactMap(\.info.folder))
            folders.append(contentsOf: setFolders.filter { used.contains($0.id) && !known.contains($0.id) })
            let valid = Set(folders.map(\.id))
            var loose: UUID?
            for var trace in new {
                if trace.info.folder.map({ !valid.contains($0) }) ?? true {
                    if loose == nil { loose = addFolder(named: name) }
                    trace.info.folder = loose
                }
                do {
                    try ProjectStore.copy(trace.id, from: source, to: destination)
                    try ProjectStore.saveInfo(trace.info, in: destination)
                } catch {
                    errorMessage = "Could not add \(trace.info.name): \(error.localizedDescription)"
                    continue
                }
                traces.append(trace)
                if folders.first(where: { $0.id == trace.info.folder })?.isSumming != true { visible.insert(trace.id) }
            }
            saveFolders()
            refreshSums()
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
            } else if url.pathExtension.lowercased() == "zip" {
                errorMessage = "\(url.lastPathComponent) is a zip archive. Unzip it in the Finder, then import the WAV or text files inside."
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
