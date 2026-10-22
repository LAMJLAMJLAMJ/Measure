#if os(macOS)
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("mode") private var mode: AppMode = .tuning
    @AppStorage("tuningTab") private var tuningTab: TuningTab = .frequency
    @AppStorage("acousticsTab") private var acousticsTab: AcousticsTab = .reverb
    @AppStorage("tuningSource") private var source: TuningSource = .sweep
    @AppStorage("showVirtualEQ") private var showVirtualEQ = false
    @State private var showSetup = false
    @State private var showPlainRecording = false

    var body: some View {
        NavigationSplitView {
            TraceList()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                tabPicker
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .padding(12)

                Group {
                    switch mode {
                    case .tuning: tuningContent
                    case .acoustics: acousticsContent
                    }
                }
                .padding([.horizontal, .bottom], 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBar()
            }
            .inspector(isPresented: Binding(get: { mode == .tuning && tuningTab == .frequency && showVirtualEQ },
                                            set: { showVirtualEQ = $0 })) {
                VirtualEQPanel().inspectorColumnWidth(min: 220, ideal: 280)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("System tuning (⌥⌘1) or acoustic analysis (⌥⌘2)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showSetup = true } label: { Label("Setup", systemImage: "slider.horizontal.3") }
                    .help("Devices, channels, mics and sweep settings")
                switch mode {
                case .tuning: tuningActions
                case .acoustics: acousticsActions
                }
            }
        }
        .background { shortcuts }
        .sheet(isPresented: $showSetup) { SetupView() }
        .sheet(isPresented: $showPlainRecording) { PlainRecordingSheet() }
        .navigationTitle(model.projectFolder.lastPathComponent)
    }

    @ViewBuilder private var tabPicker: some View {
        switch mode {
        case .tuning:
            Picker("View", selection: $tuningTab) { ForEach(TuningTab.allCases) { Text($0.rawValue).tag($0) } }
        case .acoustics:
            Picker("View", selection: $acousticsTab) { ForEach(AcousticsTab.allCases) { Text($0.rawValue).tag($0) } }
        }
    }

    @ViewBuilder private var tuningContent: some View {
        switch tuningTab {
        case .impulse: ImpulseView(editsWindow: true)
        case .frequency: FrequencyResponseView(showVirtualEQ: $showVirtualEQ)
        case .phase: PhaseView()
        case .delay: DelayView()
        case .sti: STIView()
        }
    }

    @ViewBuilder private var acousticsContent: some View {
        switch acousticsTab {
        case .reverb: ReverbView()
        case .clarity: ParametersPanel(set: .clarity)
        case .echo: EchoView()
        case .sti: STIView()
        case .levels: LevelsView()
        case .noise: NoiseView()
        case .spectrogram: SpectrogramView()
        }
    }

    @ViewBuilder private var tuningActions: some View {
        Picker("Source", selection: $source) {
            ForEach(TuningSource.allCases) { Text($0.rawValue).tag($0) }
        }
        .help("Sweep, or the live cross-spectrum mode (coming in a later step)")
        Button { importFiles(model) } label: { Label("Import", systemImage: "square.and.arrow.down") }
            .help("Import WAV impulse responses or REW text exports (⌘I)")
        Button { Task { await model.measure() } } label: {
            Label(model.isMeasuring ? "Measuring" : "Measure", systemImage: model.isMeasuring ? "waveform" : "record.circle")
        }
        .disabled(model.isMeasuring || source == .crossSpectrum)
        .help(source == .crossSpectrum ? "The live cross-spectrum mode comes in a later step" : "Play the sweep and record (⌘M)")
    }

    @ViewBuilder private var acousticsActions: some View {
        Menu {
            Button("Sweep (impulse response)") { Task { await model.measure() } }
            Button("Plain recording…") { showPlainRecording = true }
        } label: {
            Label(model.isMeasuring ? "Recording" : "Record", systemImage: model.isMeasuring ? "waveform" : "record.circle")
        }
        .disabled(model.isMeasuring)
        .help("Record a sweep for an impulse response (⌘M), or a plain recording for levels and noise")
        Menu {
            Button("Impulse responses or frequency responses…") { importFiles(model) }
            Button("Recordings…") { importRecordings(model) }
        } label: {
            Label("Load", systemImage: "square.and.arrow.down")
        }
        .help("Load WAV impulse responses or REW text exports (⌘I), or WAV recordings for levels and noise")
    }

    /// ⌘1 to ⌘7 pick a view in the current mode; ⌥⌘1 and ⌥⌘2 switch mode.
    private var shortcuts: some View {
        let count = mode == .tuning ? TuningTab.allCases.count : AcousticsTab.allCases.count
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                Button("") {
                    switch mode {
                    case .tuning: tuningTab = TuningTab.allCases[i]
                    case .acoustics: acousticsTab = AcousticsTab.allCases[i]
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            ForEach(Array(AppMode.allCases.enumerated()), id: \.offset) { i, m in
                Button("") { mode = m }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.isMeasuring { ProgressView().controlSize(.small) }
            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(2)
                Spacer()
                Button("Dismiss") { model.errorMessage = nil }.buttonStyle(.borderless)
            } else {
                Text(model.status ?? setupSummary).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var setupSummary: String {
        guard let out = model.outputDevice, let input = model.inputDevice else { return "No audio device chosen" }
        let s = model.settings
        let mics = s.mics.map { "\($0.channel)" }.joined(separator: ", ")
        let loop = s.loopbackInput.map { ", loopback in \($0)" } ?? ""
        return "\(out.name) out \(s.outputChannel) → \(input.name) in \(mics)\(loop) · \(Int(s.sampleRate / 1000)) kHz, \(Int(s.sweepLength)) s sweep at \(Int(s.level)) dBFS"
    }
}

struct TraceList: View {
    @Environment(AppModel.self) private var model
    @State private var editing: TraceInfo?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.traces.reversed()) { trace in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { model.visible.contains(trace.id) },
                        set: { on in if on { model.visible.insert(trace.id) } else { model.visible.remove(trace.id) } }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Circle().fill(trace.color).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trace.info.name).lineLimit(1)
                        Text(subtitle(trace)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(trace.id)
                .contextMenu {
                    Button("Edit…") { editing = trace.info }
                    Button("Show Only This") { model.visible = [trace.id] }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete([trace.id]) }
                }
            }
        }
        .overlay {
            if model.traces.isEmpty {
                ContentUnavailableView("No measurements", systemImage: "waveform.path",
                                       description: Text("Press Measure (⌘M) or import impulse responses (⌘I)."))
            }
        }
        .onDeleteCommand { if let s = model.selection { model.delete([s]) } }
        .sheet(item: $editing) { info in TraceEditor(info: info) }
    }

    private func subtitle(_ trace: Trace) -> String {
        var parts = [trace.info.date.formatted(date: .abbreviated, time: .shortened)]
        if let t30 = trace.acoustics?.broadband.t30 { parts.append(String(format: "T30 %.2f s", t30)) }
        if trace.info.source == .importedFrequencyResponse { parts.append("imported FR") }
        if let samples = trace.recording {
            parts.append(String(format: "recording, %.0f s", Double(samples.count) / max(1, trace.info.sampleRate)))
        }
        return parts.joined(separator: " · ")
    }
}

struct TraceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var info: TraceInfo

    var body: some View {
        Form {
            TextField("Name", text: $info.name)
            TextField("Position", text: $info.position)
            Picker("Mic", selection: $info.mic) {
                Text("None").tag(String?.none)
                ForEach(model.micProfiles) { Text($0.name).tag(Optional($0.name)) }
            }
            TextField("Notes", text: $info.notes, axis: .vertical).lineLimit(3...6)
        }
        .padding()
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    // A recording's SPL offset belongs to the mic it was recorded with.
                    if info.mic != model.traces.first(where: { $0.id == info.id })?.info.mic { info.splOffset = nil }
                    model.update(info)
                    dismiss()
                }
            }
        }
    }
}

/// Asks how long to record for, then records every mic input with nothing playing.
struct PlainRecordingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recording.duration") private var duration: Double = 30
    @State private var label = ""

    var body: some View {
        Form {
            TextField("Duration (s)", value: $duration, format: .number)
            TextField("Label", text: $label, prompt: Text("e.g. Background noise, seat A12"))
            Text(calibrationNote).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420)
        .onAppear { label = model.settings.position }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Record") {
                    let seconds = min(max(duration, 1), 3600)
                    let name = label
                    dismiss()
                    Task { await model.recordPlain(duration: seconds, label: name) }
                }
                .disabled(!(duration >= 1))
            }
        }
    }

    private var calibrationNote: String {
        let mics = model.settings.mics
        let uncalibrated = mics.filter { slot in model.micProfiles.first { $0.name == slot.micName }?.splOffset == nil }
        if uncalibrated.isEmpty { return "Records every mic input, in dB SPL from each mic's calibration." }
        let inputs = uncalibrated.map { "\($0.channel)" }.joined(separator: ", ")
        return "Input \(inputs) has no SPL calibration, so its levels will be re full scale. Calibrate the mic in Setup for dB SPL. Up to an hour."
    }
}
#endif
