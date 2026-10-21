#if os(macOS)
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case response = "Frequency response"
    case impulse = "Impulse"
    case decay = "Decay"
    case acoustics = "Acoustics"
    case spectrogram = "Spectrogram"
    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: DetailTab = .response
    @State private var showSetup = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            TraceList()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)

                Group {
                    switch tab {
                    case .response: FrequencyResponseView()
                    case .impulse: ImpulseView()
                    case .decay: DecayView()
                    case .acoustics: AcousticsView()
                    case .spectrogram: SpectrogramView()
                    }
                }
                .padding([.horizontal, .bottom], 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBar()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showSetup = true } label: { Label("Setup", systemImage: "slider.horizontal.3") }
                    .help("Devices, channels, mics and sweep settings")
                Button { importFiles(model) } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import WAV impulse responses or REW text exports (⌘I)")
                Button { Task { await model.measure() } } label: {
                    Label(model.isMeasuring ? "Measuring" : "Measure", systemImage: model.isMeasuring ? "waveform" : "record.circle")
                }
                .disabled(model.isMeasuring)
                .help("Play the sweep and record (⌘M)")
            }
        }
        .sheet(isPresented: $showSetup) { SetupView() }
        .navigationTitle(model.projectFolder.lastPathComponent)
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
            ToolbarItem(placement: .confirmationAction) { Button("Save") { model.update(info); dismiss() } }
        }
    }
}
#endif
