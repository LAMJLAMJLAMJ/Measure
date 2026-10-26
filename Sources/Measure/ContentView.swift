#if os(macOS)
import MeasureDSP
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
    @Environment(\.openWindow) private var openWindow

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
            ToolbarItem(placement: .navigation) {
                Button { openWindow(id: "generator") } label: {
                    Label("Signal Generator", systemImage: model.generator.isRunning ? "waveform.circle.fill" : "waveform.circle")
                }
                .help("Open the signal generator: a test signal on any outputs, with meters for it and every mic input")
            }
            ToolbarItem(placement: .navigation) {
                RemoteToggle()
            }
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
        .sheet(item: Binding(get: { model.exportRequest }, set: { model.exportRequest = $0 })) { request in
            ImpulseExportSheet(ids: request.traces)
        }
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
        case .distortion: DistortionView()
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
            } else if let warning = model.measurementWarning, !model.isMeasuring {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(warning.severe ? Color.red : Color.orange)
                Text(warning.text).lineLimit(4)
                    .help(warning.text)
                Spacer()
                Button("Dismiss") { model.measurementWarning = nil }.buttonStyle(.borderless)
            } else {
                Text(model.status ?? setupSummary).foregroundStyle(.secondary)
                Spacer()
            }
            if !model.remote.remotes.isEmpty {
                Label(model.remote.remotes.joined(separator: ", "), systemImage: "ipad.landscape")
                    .foregroundStyle(.secondary)
                    .help("Connected remotes")
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
    @State private var renamingFolder: UUID?
    @State private var folderName = ""
    @FocusState private var folderFocused: Bool

    var body: some View {
        @Bindable var model = model
        let folderIDs = Set(model.folders.map(\.id))
        let topLevel = model.traces.reversed().filter { trace in
            guard let id = trace.info.folder else { return true }
            return !folderIDs.contains(id)
        }
        List(selection: $model.selection) {
            ForEach(model.folders) { folder in
                DisclosureGroup(isExpanded: expanded(folder.id)) {
                    ForEach(model.traces.reversed().filter { trace in trace.info.folder == folder.id }) { trace in
                        row(trace)
                    }
                } label: {
                    folderLabel(folder)
                }
            }
            ForEach(topLevel) { trace in
                row(trace)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay {
            if model.traces.isEmpty && model.folders.isEmpty {
                ContentUnavailableView("No measurements", systemImage: "waveform.path",
                                       description: Text("Press Measure (⌘M) or import impulse responses (⌘I)."))
            }
        }
        .onDeleteCommand { if let s = model.selection { model.delete([s]) } }
        .sheet(item: $editing) { info in TraceEditor(info: info) }
    }

    /// One measurement: tick to show it, its colour, name and details. Drag it onto a folder to file it.
    /// A warning triangle for a measurement that clipped or has too little range above the noise.
    private func qualityBadge(_ issues: [MeasurementQuality.Issue]) -> some View {
        let severe = issues.contains(where: \.isSevere)
        return HStack {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(severe ? Color.red : Color.orange)
                .help(issues.map(\.message).joined(separator: "\n"))
        }
    }

    private func row(_ trace: Trace) -> some View {
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
            if !trace.qualityIssues.isEmpty { qualityBadge(trace.qualityIssues) }
        }
        .help(trace.info.notes)
        .tag(trace.id)
        .draggable(trace.id.uuidString)
        .dropDestination(for: String.self) { items, _ in drop(items, into: folderID(trace)) }
        .contextMenu {
            Button("Rename") { startRename(trace) }
            Button("Edit…") { editing = trace.info }
            Button("Show Only This") { model.visible = [trace.id] }
            Button("Export Impulse Response…") { model.exportRequest = ExportRequest(traces: [trace.id]) }
                .disabled(trace.impulseResponse == nil)
            Menu("Move to Folder") {
                Button("None (Top Level)") { model.move([trace.id], to: nil) }
                    .disabled(folderID(trace) == nil)
                if !model.folders.isEmpty { Divider() }
                ForEach(model.folders) { f in
                    Button(f.name) { model.move([trace.id], to: f.id) }
                        .disabled(folderID(trace) == f.id)
                }
                Divider()
                Button("New Folder…") {
                    let id = model.addFolder()
                    model.move([trace.id], to: id)
                    startRenameFolder(id)
                }
            }
            Menu("Colour") {
                ForEach(TracePalette.names.indices, id: \.self) { i in
                    Button(TracePalette.names[i]) { setColor(trace, index: i) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete([trace.id]) }
        }
    }

    // MARK: - Folders

    /// The trace's folder, if that folder still exists.
    private func folderID(_ trace: Trace) -> UUID? {
        guard let id = trace.info.folder, model.folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func expanded(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.folders.first { $0.id == id }?.expanded ?? true },
                set: { model.setExpanded(id, $0) })
    }

    /// Moves dragged traces (their ids as text) into a folder, or to the top level for nil.
    private func drop(_ items: [String], into folder: UUID?) -> Bool {
        let ids = Set(items.compactMap(UUID.init(uuidString:))).intersection(model.traces.map(\.id))
        guard !ids.isEmpty else { return false }
        model.move(ids, to: folder)
        return true
    }

    private func folderLabel(_ folder: TraceFolder) -> some View {
        let members = model.traces.filter { $0.info.folder == folder.id }.map(\.id)
        let shown = Binding(
            get: { !members.isEmpty && members.allSatisfy { model.visible.contains($0) } },
            set: { on in if on { model.visible.formUnion(members) } else { model.visible.subtract(members) } })
        return HStack(spacing: 8) {
            Toggle("", isOn: shown)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(members.isEmpty)
                .help("Show or hide every measurement in this folder")
            Image(systemName: "folder").foregroundStyle(.secondary)
            if renamingFolder == folder.id {
                TextField("Folder name", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .focused($folderFocused)
                    .onSubmit { commitFolderRename(folder.id) }
                    .onExitCommand { renamingFolder = nil }
                    .onChange(of: folderFocused) { _, focused in if !focused { commitFolderRename(folder.id) } }
            } else {
                Text(folder.name).fontWeight(.medium).lineLimit(1)
                    .onTapGesture(count: 2) { startRenameFolder(folder.id) }
            }
            Spacer(minLength: 0)
            Text("\(members.count)").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in drop(items, into: folder.id) }
        .contextMenu {
            Button("Rename") { startRenameFolder(folder.id) }
            Button("Show Only This Folder") { model.visible = Set(members) }
                .disabled(members.isEmpty)
            Divider()
            Button("Delete Folder") { model.deleteFolder(folder.id) }
                .help("Removes the folder; its measurements stay, at the top level")
        }
    }

    /// New Folder, and a place to drop measurements to take them out of their folders.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                startRenameFolder(model.addFolder())
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Add a folder to the list, then drag measurements onto it")
            Spacer(minLength: 0)
            if !model.folders.isEmpty {
                Text("Drop here for the top level").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in drop(items, into: nil) }
    }

    private func startRenameFolder(_ id: UUID) {
        folderName = model.folders.first { $0.id == id }?.name ?? ""
        renamingFolder = id
        DispatchQueue.main.async { folderFocused = true }
    }

    private func commitFolderRename(_ id: UUID) {
        guard renamingFolder == id else { return }
        renamingFolder = nil
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.renameFolder(id, to: name)
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
