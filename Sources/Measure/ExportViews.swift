#if os(macOS)
import AppKit
import MeasureDSP
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Impulse responses

/// The sample formats offered for exported impulse responses.
enum ExportFormat: String, CaseIterable, Identifiable {
    case float32 = "32-bit float"
    case pcm24 = "24-bit"
    case pcm16 = "16-bit"
    var id: String { rawValue }

    var wav: WAV.SampleFormat {
        switch self {
        case .float32: return .float32
        case .pcm24: return .pcm24
        case .pcm16: return .pcm16
        }
    }
}

/// Options for exporting impulse responses as WAV files, then a save panel.
struct ImpulseExportSheet: View {
    let ids: [UUID]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("irExport.format") private var format: ExportFormat = .float32
    @AppStorage("irExport.start") private var start: ImpulseExport.Start = .asMeasured
    @AppStorage("irExport.limitLength") private var limitLength = false
    @AppStorage("irExport.length") private var length = 1.0
    @AppStorage("irExport.normalize") private var normalize = false
    @AppStorage("irExport.peak") private var peak = -1.0
    @AppStorage("irExport.combine") private var combine = false

    var body: some View {
        let names = ids.compactMap { id in model.traces.first { $0.id == id }?.info.name }
        Form {
            Text(names.count == 1 ? names[0] : "\(names.count) impulse responses: \(names.joined(separator: ", "))")
                .lineLimit(3)
            Picker("Format", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Start", selection: $start) { ForEach(ImpulseExport.Start.allCases) { Text($0.rawValue).tag($0) } }
                .help("As measured keeps the time before the direct sound (the system's latency and the distance). At the direct sound starts 5 ms before it, for convolution.")
            HStack {
                Toggle("Length", isOn: $limitLength)
                TextField("Length", value: $length, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 70)
                    .disabled(!limitLength)
                Text("s, faded out at the end").foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Normalise peak to", isOn: $normalize)
                TextField("Peak", value: $peak, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 60)
                    .disabled(!normalize)
                Text("dBFS").foregroundStyle(.secondary)
            }
            if names.count > 1 {
                Toggle("One multichannel file, in this order", isOn: $combine)
                    .help("All the responses as the channels of one WAV, scaled together so their levels stay relative: for a stereo or multichannel convolution")
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Export…") { export(names) } }
        }
    }

    private var note: String {
        if format == .float32 { return "32-bit float keeps the measured level, even above full scale." }
        return "\(format.rawValue) cannot hold peaks above full scale, so a louder response is scaled down to fit and the status bar says by how much."
    }

    private var options: ImpulseExport {
        ImpulseExport(format: format.wav, start: start,
                      length: limitLength ? min(max(length, 0.001), 600) : nil,
                      normalizeTo: normalize ? min(peak, 0) : nil)
    }

    private func export(_ names: [String]) {
        let oneFile = names.count == 1 || combine
        let url: URL
        if oneFile {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = ImpulseExport.fileName(names.count == 1 ? names[0] : "Impulse responses")
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose a folder for the \(names.count) WAV files, named after the measurements"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        model.exportImpulseResponses(ids, options: options, combine: combine && names.count > 1, to: url)
        dismiss()
    }
}

// MARK: - Plots as images

/// Where a plot is on screen, so it can be captured.
final class PlotAnchor {
    weak var view: NSView?
    let name: String
    init(name: String) { self.name = name }
}

private struct PlotAnchorView: NSViewRepresentable {
    let anchor: PlotAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Copies plots to the clipboard or saves them as PNG.
@MainActor
enum PlotCapture {
    /// The plot the pointer was last over, for the menu commands.
    nonisolated(unsafe) static var current: PlotAnchor?

    /// The plot as drawn in its window, at the screen's resolution, on the window's background.
    static func image(_ anchor: PlotAnchor) -> NSImage? {
        guard let view = anchor.view, let window = view.window, let content = window.contentView else { return nil }
        let rect = view.convert(view.bounds, to: content)
        guard rect.width > 1, rect.height > 1, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: rect.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: rect.size))
        image.unlockFocus()
        return image
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Copies `anchor`'s plot, or the one the pointer was last over.
    static func copy(_ anchor: PlotAnchor? = nil) {
        guard let anchor = anchor ?? current, let image = image(anchor) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func save(_ anchor: PlotAnchor? = nil) {
        guard let anchor = anchor ?? current, let image = image(anchor), let data = png(image) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImpulseExport.fileName(anchor.name).replacingOccurrences(of: ".wav", with: ".png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

private struct ExportablePlot: ViewModifier {
    @State private var anchor: PlotAnchor

    init(name: String) { _anchor = State(initialValue: PlotAnchor(name: name)) }

    func body(content: Content) -> some View {
        content
            .background(PlotAnchorView(anchor: anchor))
            .onHover { inside in if inside { PlotCapture.current = anchor } }
            .contextMenu {
                Button("Copy Plot") { PlotCapture.copy(anchor) }
                Button("Save Plot as PNG…") { PlotCapture.save(anchor) }
            }
    }
}

extension View {
    /// Lets the plot be copied as an image or saved as PNG, from its context menu or the Measurement
    /// menu while the pointer is over it.
    func exportablePlot(_ name: String) -> some View { modifier(ExportablePlot(name: name)) }
}
#endif
