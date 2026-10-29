#if os(macOS)
import AppKit
import MeasureDSP
import SwiftUI

/// The Calibration window (Calibration > Calibrate Inputs…): every mic input of Measurement Setup with
/// its mic, its SPL offset and a live level, and a Calibrate button for each that opens its own sheet.
struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    /// The input being calibrated, by index into the mics of Measurement Setup.
    @State private var calibrating: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fit the calibrator to each mic in turn and press Calibrate. The offset is kept with the mic, so Levels, Noise, STI, the SPL meters and the RTA all read dB SPL from it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.settings.mics.isEmpty {
                EmptyState(text: "No mic inputs in Measurement Setup")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Input").foregroundStyle(.secondary)
                        Text("Mic").foregroundStyle(.secondary)
                        Text("Level").foregroundStyle(.secondary)
                        Text("Offset").foregroundStyle(.secondary)
                        Text("")
                    }
                    .font(.caption)
                    ForEach(Array(model.settings.mics.enumerated()), id: \.element.id) { i, slot in
                        row(i, slot)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Erase All Calibration…") { confirmEraseAllCalibration(model) }
            }
        }
        .padding()
        .sheet(item: Binding(get: { calibrating.map(CalibrationTarget.init) }, set: { calibrating = $0?.index })) { target in
            CalibrateInputSheet(index: target.index)
        }
    }

    private func row(_ i: Int, _ slot: MicSlot) -> some View {
        let offset = model.micProfiles.first { $0.name == slot.micName }?.splOffset
        let meter = model.inputMeters.mic(i)
        return GridRow {
            Text("\(slot.channel)").monospacedDigit()
            Text(slot.micName ?? "No mic").lineLimit(1)
                .foregroundStyle(slot.micName == nil ? .secondary : .primary)
            HStack(spacing: 6) {
                if let meter { VerticalInputMeter(channel: meter).frame(height: 22) }
                Text(levelText(meter, offset: offset)).monospacedDigit()
                    .foregroundStyle(meter?.noSignal == true ? Color.orange : Color.primary)
            }
            Text(offset.map { String(format: "%.1f dB", $0) } ?? "Not calibrated").monospacedDigit()
                .foregroundStyle(offset == nil ? .secondary : .primary)
            Button("Calibrate…") { calibrating = i }
                .disabled(model.isMeasuring)
        }
    }

    private func levelText(_ meter: InputMeters.Channel?, offset: Double?) -> String {
        guard let meter, meter.reading.rms > -150 else { return "–" }
        if meter.noSignal { return "No signal" }
        if let offset { return String(format: "%.1f dB SPL", meter.reading.rms + offset) }
        return String(format: "%.1f dBFS", meter.reading.rms)
    }
}

/// Identifies the sheet's input, for `sheet(item:)`.
private struct CalibrationTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Calibrates one input: the calibrator's level (94 dB unless changed), its live reading, and Record,
/// which records 5 s and sets the mic's offset.
struct CalibrateInputSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @AppStorage("calibration.reference") private var reference = 94.0
    @State private var recordingSince: Date?
    @State private var result: AppModel.CalibrationResult?
    @State private var failed: String?

    static let seconds = 5.0

    var body: some View {
        let slot = index < model.settings.mics.count ? model.settings.mics[index] : nil
        let meter = model.inputMeters.mic(index)
        VStack(alignment: .leading, spacing: 14) {
            Text("Calibrate input \(slot?.channel ?? index + 1)" + (slot?.micName.map { " (\($0))" } ?? ""))
                .font(.headline)
            Text("Fit the calibrator to the mic and switch it on. When the level below is steady, press Record: Measure records \(Int(Self.seconds)) seconds and sets this mic's offset.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Calibrator level")
                TextField("Level", value: $reference, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .disabled(recordingSince != nil)
                Text("dB SPL").foregroundStyle(.secondary)
                Spacer()
            }
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                if let meter { VerticalInputMeter(channel: meter).frame(height: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(meter.map { $0.reading.rms > -150 ? String(format: "%.1f dBFS", $0.reading.rms) : "–" } ?? "–")
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(liveNote(meter)).font(.caption)
                        .foregroundStyle(meter?.noSignal == true || meter?.clipped == true ? Color.orange : Color.secondary)
                }
            }
            if let since = recordingSince {
                TimelineView(.periodic(from: since, by: 0.25)) { context in
                    let elapsed = min(Self.seconds, context.date.timeIntervalSince(since))
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: elapsed, total: Self.seconds)
                        Text(String(format: "Recording… %.0f s left", (Self.seconds - elapsed).rounded(.up)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let result {
                Label(String(format: "%.1f dBFS reads %.1f dB SPL: offset %.1f dB, saved with %@.",
                             result.level, reference, result.offset, result.mic), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let failed {
                Label(failed, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(recordingSince != nil)
                Button(result == nil ? "Record \(Int(Self.seconds)) s" : "Record Again") { record() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recordingSince != nil || model.isMeasuring || !(reference > 0))
            }
        }
        .padding()
        .frame(width: 440)
        .interactiveDismissDisabled(recordingSince != nil)
    }

    private func liveNote(_ meter: InputMeters.Channel?) -> String {
        guard let meter else { return "Input meters are off (Measurement menu)" }
        if meter.noSignal { return "No signal: check the cable and the mic's phantom power" }
        if meter.clipped { return "This input has clipped: turn its gain down (click the meter to clear)" }
        return "Live RMS level of this input"
    }

    private func record() {
        result = nil
        failed = nil
        recordingSince = Date()
        Task {
            let found = await model.calibrateInput(index, reference: reference, seconds: Self.seconds)
            recordingSince = nil
            if let found {
                result = found
            } else {
                failed = model.errorMessage ?? "The calibration did not complete."
                model.errorMessage = nil
            }
        }
    }
}

/// Asks before erasing every calibration, then erases it.
@MainActor
func confirmEraseAllCalibration(_ model: AppModel) {
    let alert = NSAlert()
    alert.messageText = "Erase all calibration?"
    alert.informativeText = "Every mic's SPL offset, the offsets typed on recordings and the SPL view's mic offsets are cleared. Levels show dB re full scale until the mics are calibrated again. Calibration files stay."
    alert.addButton(withTitle: "Erase All")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if alert.runModal() == .alertFirstButtonReturn { model.eraseAllCalibration() }
}
#endif
