#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A measurement set: a .measure package of measurements, declared in Measure.app's Info.plist.
    /// Run with `swift run` the type is not declared, and this is a dynamic type for the extension.
    static let measureSet = UTType(filenameExtension: ProjectStore.setExtension, conformingTo: .package) ?? .package
}

/// Opens measurement sets double-clicked in the Finder or dropped on the app's icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        let sets = urls.filter { $0.pathExtension == ProjectStore.setExtension }
        guard let url = sets.first else { return }
        model.openProject(url)
        for other in sets.dropFirst() { model.addSet(from: other) }
    }
}

@main
struct MeasureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    init() {
        // Started with `swift run` the process is not a bundled app; make it a normal foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Measure") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandMenu("Measurement") {
                Button("Measure") { Task { await model.measure() } }
                    .keyboardShortcut("m", modifiers: .command)
                    .disabled(model.isMeasuring)
                Button(model.levelCheck.isRunning ? "Stop Level Check" : "Check Levels") {
                    if model.levelCheck.isRunning { model.levelCheck.stop(); model.status = nil } else { Task { await model.levelCheck.start(model) } }
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.isMeasuring)
                Toggle("Input Meters", isOn: Binding(get: { model.inputMeters.enabled }, set: { model.inputMeters.enabled = $0 }))
                Button("Clear Clip Marks") { model.inputMeters.resetClips() }
                    .disabled(!model.inputMeters.isRunning)
                Divider()
                Button("Import Files…") { importFiles(model) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Import Recordings…") { importRecordings(model) }
                Button("Import Sweep Recordings…") { importSweepRecordings(model) }
                Divider()
                Button("Open Set or Project Folder…") { openProject(model) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save Set As…") { saveSet(model, ticked: false) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Save Ticked as Set…") { saveSet(model, ticked: true) }
                    .disabled(model.visible.isEmpty)
                Button("Add Set to This Project…") { addSet(model) }
                Divider()
                Button("Export Impulse Responses…") { model.requestImpulseExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Copy Plot") { PlotCapture.copy() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Save Plot as PNG…") { PlotCapture.save() }
                Divider()
                Toggle("iPad Remote", isOn: Binding(get: { model.remote.enabled }, set: { model.remote.enabled = $0 }))
                Divider()
                Button("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.projectFolder]) }
            }
        }

        Window("Signal Generator", id: "generator") {
            GeneratorView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 420)
        }
        .defaultSize(width: 640, height: 520)
    }
}

@MainActor
func importFiles(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose WAV impulse responses or REW text exports"
    if panel.runModal() == .OK {
        let urls = panel.urls
        Task { await model.importFiles(urls) }
    }
}

@MainActor
func importRecordings(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.wav]
    panel.message = "Choose WAV recordings for levels and noise ratings. Only the first channel is used."
    if panel.runModal() == .OK {
        let urls = panel.urls
        Task { await model.importRecordings(urls) }
    }
}

@MainActor
func importSweepRecordings(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.wav]
    panel.message = "Choose WAV recordings of the sweep set in Measurement Setup. Each channel becomes a measurement, with its distortion."
    if panel.runModal() == .OK {
        let urls = panel.urls
        Task { await model.importSweepRecordings(urls) }
    }
}

/// A panel that chooses a measurement set or a project folder.
@MainActor
private func setPanel(_ message: String) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowedContentTypes = [.measureSet, .folder]
    panel.message = message
    return panel
}

@MainActor
func openProject(_ model: AppModel) {
    let panel = setPanel("Choose a measurement set, or choose or create a folder for this project's measurements")
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url { model.openProject(url) }
}

/// Saves all the measurements as a set and carries on in it, or saves only the ticked ones.
@MainActor
func saveSet(_ model: AppModel, ticked: Bool) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.measureSet]
    panel.canCreateDirectories = true
    let name = model.projectFolder.deletingPathExtension().lastPathComponent
    panel.nameFieldStringValue = ticked ? "\(name) selection" : name
    panel.message = ticked
        ? "Save the ticked measurements as a set. This project stays open."
        : "Save every measurement as a set. Measure carries on in the set, so new measurements are saved there."
    guard panel.runModal() == .OK, var url = panel.url else { return }
    if url.pathExtension != ProjectStore.setExtension { url.appendPathExtension(ProjectStore.setExtension) }
    model.saveSet(to: url, only: ticked ? model.visible : nil)
}

@MainActor
func addSet(_ model: AppModel) {
    let panel = setPanel("Choose a measurement set to copy into this project. Its measurements keep their folders.")
    if panel.runModal() == .OK, let url = panel.url { model.addSet(from: url) }
}
#else
@main
enum MeasureApp {
    static func main() { print("The Measure app needs macOS. The analysis core and measure-cli run anywhere.") }
}
#endif
