#if os(macOS)
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("mode") private var mode: AppMode = .tuning
    @AppStorage("tuningTab") private var tuningTab: TuningTab = .frequency
    @AppStorage("acousticsTab") private var acousticsTab: AcousticsTab = .reverb
    @AppStorage("monitoringTab") private var monitoringTab: MonitoringTab = .spl
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
                    case .monitoring: monitoringContent
                    }
                }
                .padding([.horizontal, .bottom], 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBar()
            }
            .inspector(isPresented: Binding(get: { mode == .tuning && tuningTab == .frequency && showVirtualEQ },
                                            set: { showVirtualEQ = $0 })) {
                VirtualEQPanel().inspectorColumnWidth(min: 300, ideal: 340, max: 480)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("System tuning (⌥⌘1), acoustic analysis (⌥⌘2) or live monitoring (⌥⌘3)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showSetup = true } label: { Label("Setup", systemImage: "slider.horizontal.3") }
                    .help("Devices, channels, mics and sweep settings")
                switch mode {
                case .tuning: tuningActions
                case .acoustics: acousticsActions
                case .monitoring: monitoringActions
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
        case .monitoring:
            Picker("View", selection: $monitoringTab) { ForEach(MonitoringTab.allCases) { Text($0.rawValue).tag($0) } }
        }
    }

    @ViewBuilder private var tuningContent: some View {
        switch tuningTab {
        case .impulse: ImpulseView(editsWindow: true)
        case .frequency:
            if source == .crossSpectrum { LiveView(showsEQ: true) } else { FrequencyResponseView(showVirtualEQ: $showVirtualEQ) }
        case .phase:
            if source == .crossSpectrum { LiveView() } else { PhaseView() }
        case .delay: DelayView()
        case .alignment: AlignmentView()
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
        // Segmented with short labels: a menu-style picker in the toolbar can shrink to a bare arrow.
        Picker("Source", selection: $source) {
            ForEach(TuningSource.allCases) { Text($0.shortName).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Sweep, or Live: the cross-spectrum analyser on the Frequency and Phase views")
        .onChange(of: source) { if source != .crossSpectrum { model.live.stop(model) } }
        Button { importFiles(model) } label: { Label("Import", systemImage: "square.and.arrow.down") }
            .help("Import WAV impulse responses or REW text exports (⌘I)")
        if source == .crossSpectrum {
            Button {
                if model.live.isRunning { model.live.stop(model) } else {
                    if tuningTab != .frequency && tuningTab != .phase { tuningTab = .frequency }
                    Task { await model.live.start(model) }
                }
            } label: {
                Label(model.live.isRunning ? "Stop" : "Start", systemImage: model.live.isRunning ? "stop.circle" : "play.circle")
            }
            .disabled(model.isMeasuring)
            .help("Start or stop the live analyser")
        } else {
            Button { Task { await model.measure() } } label: {
                Label(model.isMeasuring ? "Measuring" : "Measure", systemImage: model.isMeasuring ? "waveform" : "record.circle")
            }
            .disabled(model.isMeasuring || model.live.isRunning)
            .help("Play the sweep and record (⌘M)")
        }
    }

    @ViewBuilder private var monitoringContent: some View {
        switch monitoringTab {
        case .rta: RTAView()
        case .spl: SPLView()
        }
    }

    @ViewBuilder private var monitoringActions: some View {
        Button {
            if model.monitor.isRunning { model.monitor.stop(model) } else { Task { await model.monitor.start(model) } }
        } label: {
            Label(model.monitor.isRunning ? "Stop" : "Start", systemImage: model.monitor.isRunning ? "stop.circle" : "play.circle")
        }
        .disabled(model.isMeasuring)
        .help("Start or stop listening on the mics from Measurement Setup")
        Button { model.monitor.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            .disabled(!model.monitor.isRunning)
            .help("Start the meters, averages, maxima and history again")
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

    /// ⌘1 to ⌘7 pick a view in the current mode; ⌥⌘1 to ⌥⌘3 switch mode.
    private var shortcuts: some View {
        let count: Int
        switch mode {
        case .tuning: count = TuningTab.allCases.count
        case .acoustics: count = AcousticsTab.allCases.count
        case .monitoring: count = MonitoringTab.allCases.count
        }
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                Button("") {
                    switch mode {
                    case .tuning: tuningTab = TuningTab.allCases[i]
                    case .acoustics: acousticsTab = AcousticsTab.allCases[i]
                    case .monitoring: monitoringTab = MonitoringTab.allCases[i]
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
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var choosingColour: UUID?
    @FocusState private var nameFocused: Bool

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
                    Button { choosingColour = trace.id } label: {
                        Circle().fill(trace.color).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Choose this measurement's colour")
                    .popover(isPresented: Binding(get: { choosingColour == trace.id },
                                                  set: { if !$0 { choosingColour = nil } })) {
                        colourChooser(trace)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if renaming == trace.id {
                            TextField("Name", text: $newName)
                                .textFieldStyle(.roundedBorder)
                                .focused($nameFocused)
                                .onSubmit { commitRename(trace.id) }
                                .onExitCommand { renaming = nil }
                                .onChange(of: nameFocused) { _, focused in if !focused { commitRename(trace.id) } }
                        } else {
                            Text(trace.info.name).lineLimit(1)
                                .onTapGesture(count: 2) { startRename(trace) }
                        }
                        Text(subtitle(trace)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let names = trace.info.averagedFrom {
                            Text("Average of " + names.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                .help(trace.info.notes)
                .tag(trace.id)
                .contextMenu {
                    Button("Rename") { startRename(trace) }
                    Button("Edit…") { editing = trace.info }
                    Button("Show Only This") { model.visible = [trace.id] }
                    Menu("Colour") {
                        ForEach(TracePalette.names.indices, id: \.self) { i in
                            Button(TracePalette.names[i]) { setColor(trace, index: i) }
                        }
                    }
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

    private func startRename(_ trace: Trace) {
        newName = trace.info.name
        renaming = trace.id
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename(_ id: UUID) {
        guard renaming == id else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var info = model.traces.first(where: { $0.id == id })?.info, info.name != name else { return }
        info.name = name
        model.update(info)
    }

    /// The palette as swatches, plus a colour well for any other colour.
    private func colourChooser(_ trace: Trace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 6), count: 5), spacing: 6) {
                ForEach(TracePalette.colors.indices, id: \.self) { i in
                    Button { setColor(trace, index: i); choosingColour = nil } label: {
                        Circle().fill(TracePalette.colors[i]).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(TracePalette.names[i])
                }
            }
            ColorPicker("Other…", selection: colorBinding(trace), supportsOpacity: false)
        }
        .padding(10)
    }

    /// The trace's colour, as a binding for the colour well. Choosing one stores it with the trace.
    private func colorBinding(_ trace: Trace) -> Binding<Color> {
        Binding(get: { model.traces.first { $0.id == trace.id }?.color ?? trace.color },
                set: { color in
                    guard var info = model.traces.first(where: { $0.id == trace.id })?.info, let hex = color.hex,
                          hex != info.colorHex else { return }
                    info.colorHex = hex
                    model.update(info)
                })
    }

    private func setColor(_ trace: Trace, index: Int) {
        guard var info = model.traces.first(where: { $0.id == trace.id })?.info else { return }
        info.colorHex = nil
        info.colorIndex = index
        model.update(info)
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
