#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MeasureApp: App {
    @State private var model = AppModel()

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
                Button("Import Files…") { importFiles(model) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Import Recordings…") { importRecordings(model) }
                Divider()
                Button("Open Project Folder…") { openProject(model) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Show Project in Finder") { NSWorkspace.shared.open(model.projectFolder) }
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
func openProject(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.message = "Choose or create a folder for this project's measurements"
    if panel.runModal() == .OK, let url = panel.url { model.openProject(url) }
}
#else
@main
enum MeasureApp {
    static func main() { print("The Measure app needs macOS. The analysis core and measure-cli run anywhere.") }
}
#endif
