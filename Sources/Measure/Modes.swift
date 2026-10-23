#if os(macOS)
import SwiftUI

/// The ways of working. Tuning and acoustic analysis share the trace library, so an impulse response
/// measured while tuning can be analysed acoustically and the other way round. Live monitoring
/// listens to the mics continuously, for an RTA and sound levels.
enum AppMode: String, CaseIterable, Identifiable {
    case tuning = "System tuning"
    case acoustics = "Acoustic analysis"
    case monitoring = "Live monitoring"
    var id: String { rawValue }
}

/// How system tuning measures. Both end in an impulse response or transfer function.
enum TuningSource: String, CaseIterable, Identifiable {
    case sweep = "Sweep"
    case crossSpectrum = "Cross-spectrum (live)"
    var id: String { rawValue }
    /// For the toolbar, where space is short.
    var shortName: String { self == .sweep ? "Sweep" : "Live" }
}

enum TuningTab: String, CaseIterable, Identifiable {
    case impulse = "Impulse"
    case frequency = "Frequency"
    case phase = "Phase"
    case delay = "Delay"
    case alignment = "Alignment"
    case sti = "STI"
    var id: String { rawValue }
}

enum MonitoringTab: String, CaseIterable, Identifiable {
    case rta = "RTA"
    case spl = "SPL"
    var id: String { rawValue }
}

enum AcousticsTab: String, CaseIterable, Identifiable {
    case reverb = "Reverb"
    case clarity = "Clarity"
    case echo = "Echo"
    case sti = "STI"
    case levels = "Levels"
    case noise = "Noise"
    case spectrogram = "Spectrogram"
    var id: String { rawValue }
}

/// What an analysis is computed from. Impulse responses come from a sweep or an imported IR; levels
/// and noise ratings need a plain recording of the sound itself.
enum AnalysisInput: String {
    case impulseResponse = "an impulse response (a sweep measurement or an imported IR)"
    case impulseResponseAndNoise = "an impulse response, plus background noise levels per octave band"
    case recording = "a plain recording (background noise or programme)"
}

/// Placeholder for a part of the app that is planned but not built yet.
struct ComingSoonView: View {
    let title: String
    let detail: String
    let needs: AnalysisInput

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "hammer")
        } description: {
            Text("\(detail)\n\nComputed from \(needs.rawValue). Coming in a later step.")
        }
    }
}

#endif
