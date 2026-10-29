#if os(macOS)
import AppKit
import MeasureAudio
import MeasureDSP
import SwiftUI

/// Devices, channels, mics and sweep settings.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The mic waiting for its calibrator to be fitted.
    @State private var calibrating: MicProfile?
    /// The mic being calibrated now.
    @State private var recordingCalibration: UUID?

    var body: some View {
        @Bindable var model = model
        let outputs = model.devices.filter { $0.outputChannels > 0 }
        let inputs = model.devices.filter { $0.inputChannels > 0 }
        let outChannels = model.outputDevice?.outputChannels ?? 0
        let inChannels = model.inputDevice?.inputChannels ?? 0

        Form {
            Section("Output") {
                Picker("Device", selection: $model.settings.outputUID) {
                    ForEach(outputs) { Text(deviceLabel($0)).tag(Optional($0.uid)) }
                }
                ChannelPicker(title: "Sweep channel", channel: $model.settings.outputChannel, count: outChannels)
                OptionalChannelPicker(title: "Also play on (loopback cable)", channel: $model.settings.loopbackOutput, count: outChannels)
            }

            Section {
                Picker("Device", selection: $model.settings.inputUID) {
                    Text("Same as output").tag(String?.none)
                    ForEach(inputs) { Text(deviceLabel($0)).tag(Optional($0.uid)) }
                }
                // Rows bind by id, not by index: removing a row while its controls still hold an index
                // binding into the array crashes SwiftUI.
                ForEach(model.settings.mics) { row in
                    let slot = micSlot(row)
                    HStack {
                        Toggle("", isOn: slot.active)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("Record this input in sweeps. Unticked inputs stay in live monitoring and the generator's meters.")
                        ChannelPicker(title: "Mic input", channel: slot.channel, count: inChannels)
                        Picker("Mic", selection: slot.micName) {
                            Text("Uncalibrated").tag(String?.none)
                            ForEach(model.micProfiles) { Text($0.name).tag(Optional($0.name)) }
                        }
                        .frame(width: 220)
                        Button { model.settings.mics.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(model.settings.mics.count <= 1)
                    }
                }
                if model.settings.mics.count < 4 {
                    Button("Add mic") {
                        let next = (model.settings.mics.map(\.channel).max() ?? 0) + 1
                        model.settings.mics.append(MicSlot(channel: min(next, max(1, inChannels))))
                    }
                }
                OptionalChannelPicker(title: "Loopback input", channel: $model.settings.loopbackInput, count: inChannels)
            } header: {
                Text("Input")
            } footer: {
                Text(timingNote).font(.caption).foregroundStyle(.secondary)
            }

            Section("Sweep") {
                Picker("Sample rate", selection: $model.settings.sampleRate) {
                    ForEach(rates, id: \.self) { Text("\(String(format: "%g", $0 / 1000)) kHz").tag($0) }
                }
                HStack {
                    TextField("From (Hz)", value: $model.settings.startFrequency, format: .number)
                    TextField("To (Hz)", value: $model.settings.endFrequency, format: .number)
                }
                Picker("Length", selection: $model.settings.sweepLength) {
                    ForEach([1.0, 2, 3, 5, 10, 20], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Picker("Silence after", selection: $model.settings.silence) {
                    ForEach([1.0, 2, 3, 5, 8], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                LabeledContent("Level") {
                    HStack {
                        Slider(value: $model.settings.level, in: -80...0, step: 1)
                        Text("\(Int(model.settings.level)) dBFS").monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                TextField("Position label", text: $model.settings.position, prompt: Text("e.g. Seat A12"))
            }

            Section {
                ForEach(model.micProfiles) { mic in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: micProfile(mic).name).frame(width: 180)
                            Text(mic.calibrationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No calibration file")
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let s = mic.sensitivity { Text(String(format: "%.2f dB", s)).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Choose…") { chooseCalibration(for: micProfile(mic)) }
                            Button { removeMicProfile(mic) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        HStack {
                            TextField("SPL offset (dB)", value: micProfile(mic).splOffset, format: .number.precision(.fractionLength(1)),
                                      prompt: Text("Not calibrated"))
                                .frame(width: 260)
                                .help("dB added to a level re full scale to give dB SPL. Set by the calibrator, or type it in.")
                            Spacer()
                            if recordingCalibration == mic.id { ProgressView().controlSize(.small) }
                            Button("Calibrate…") { calibrating = mic }
                                .disabled(model.isMeasuring)
                                .help("Record a sound level calibrator on this mic's input to set the offset")
                        }
                    }
                }
                Button("Add mic") { model.micProfiles.append(MicProfile(name: "Mic \(model.micProfiles.count + 1)")) }
            } header: {
                Text("Microphones")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = model.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    } else if let status = model.status, recordingCalibration == nil, status.hasPrefix("Calibrated") {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Calibration files (REW/UMIK format) belong to the mic, so they follow it to whichever input it is plugged into. The SPL offset holds only while the interface gain stays where it was when calibrated.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 720)
        .confirmationDialog("Calibrate \(calibrating?.name ?? "")",
                            isPresented: Binding(get: { calibrating != nil }, set: { if !$0 { calibrating = nil } }),
                            presenting: calibrating) { mic in
            if model.settings.mics.contains(where: { $0.micName == mic.name }) {
                ForEach([94.0, 114.0], id: \.self) { reference in
                    Button("Record \(Int(reference)) dB calibrator") {
                        recordingCalibration = mic.id
                        Task {
                            await model.calibrateSPL(mic: mic.id, reference: reference)
                            recordingCalibration = nil
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(calibrationMessage)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) { Button("Refresh devices") { model.refreshDevices() } }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func micSlot(_ slot: MicSlot) -> Binding<MicSlot> {
        Binding(get: { model.settings.mics.first { $0.id == slot.id } ?? slot },
                set: { new in
                    if let i = model.settings.mics.firstIndex(where: { $0.id == slot.id }) { model.settings.mics[i] = new }
                })
    }

    private func micProfile(_ mic: MicProfile) -> Binding<MicProfile> {
        Binding(get: { model.micProfiles.first { $0.id == mic.id } ?? mic },
                set: { new in
                    if let i = model.micProfiles.firstIndex(where: { $0.id == mic.id }) { model.micProfiles[i] = new }
                })
    }

    /// Removes a mic and unassigns it from any input that used it.
    private func removeMicProfile(_ mic: MicProfile) {
        for i in model.settings.mics.indices where model.settings.mics[i].micName == mic.name {
            model.settings.mics[i].micName = nil
        }
        model.micProfiles.removeAll { $0.id == mic.id }
    }

    private var calibrationMessage: String {
        guard let mic = calibrating else { return "" }
        guard let slot = model.settings.mics.first(where: { $0.micName == mic.name }) else {
            return "\(mic.name) is not assigned to a mic input. Assign it above first."
        }
        return "Fit the calibrator to \(mic.name) on input \(slot.channel) and switch it on, then choose its level. Measure records 5 seconds."
    }

    private var rates: [Double] {
        let available = model.outputDevice?.availableSampleRates ?? []
        return available.isEmpty ? [44_100, 48_000, 96_000] : available
    }

    private var timingNote: String {
        if model.settings.loopbackInput != nil {
            return "With a loopback input, delays are absolute: the interface latency cancels."
        }
        if let out = model.outputDevice, let input = model.inputDevice, out.id != input.id {
            return "Output and input are different devices. Their clock difference is measured and corrected. For exact timing, cable a spare output of \(out.name) to a spare input of \(input.name) and set both loopback channels."
        }
        return "Without a loopback input, delays include the interface latency."
    }

    private func deviceLabel(_ d: AudioDevice) -> String {
        "\(d.name) (\(d.transport), \(d.inputChannels) in / \(d.outputChannels) out)"
    }

    private func chooseCalibration(for mic: Binding<MicProfile>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "Choose the calibration file for \(mic.wrappedValue.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let parsed = try FrequencyResponseText.parse(contentsOf: url)
            mic.wrappedValue.calibrationPath = url.path
            mic.wrappedValue.sensitivity = parsed.sensitivity
        } catch {
            model.errorMessage = "\(url.lastPathComponent) is not a calibration file: \(error)"
        }
    }
}

struct ChannelPicker: View {
    let title: String
    @Binding var channel: Int
    let count: Int

    var body: some View {
        Picker(title, selection: $channel) {
            ForEach(1...max(1, max(count, channel)), id: \.self) { Text("\($0)").tag($0) }
        }
    }
}

struct OptionalChannelPicker: View {
    let title: String
    @Binding var channel: Int?
    let count: Int

    var body: some View {
        Picker(title, selection: $channel) {
            Text("None").tag(Int?.none)
            ForEach(1...max(1, max(count, channel ?? 1)), id: \.self) { Text("\($0)").tag(Optional($0)) }
        }
    }
}
#endif
