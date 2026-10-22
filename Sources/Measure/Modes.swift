#if os(macOS)
import SwiftUI

/// The two ways of working. Both share the trace library, so an impulse response measured while
/// tuning can be analysed acoustically and the other way round.
enum AppMode: String, CaseIterable, Identifiable {
    case tuning = "System tuning"
    case acoustics = "Acoustic analysis"
    var id: String { rawValue }
}

/// How system tuning measures. Both end in an impulse response or transfer function.
enum TuningSource: String, CaseIterable, Identifiable {
    case sweep = "Sweep"
    case crossSpectrum = "Cross-spectrum (live)"
    var id: String { rawValue }
}

enum TuningTab: String, CaseIterable, Identifiable {
    case impulse = "Impulse"
    case frequency = "Frequency"
    case phase = "Phase"
    case delay = "Delay"
    case sti = "STI"
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

struct StatisticalLevelsView: View {
    var body: some View {
        ComingSoonView(title: "Statistical levels",
                       detail: "Leq, Lmax, L10, L50 and L90 with A, C or Z frequency weighting and fast or slow time weighting, overall and per band.",
                       needs: .recording)
    }
}

struct NoiseRatingView: View {
    var body: some View {
        ComingSoonView(title: "Noise",
                       detail: "Octave-band background noise rated against the NR and NC curves. Needs a calibrated mic for absolute levels.",
                       needs: .recording)
    }
}

/// Side panel next to the frequency response for trying EQ on a measurement.
struct VirtualEQPanel: View {
    var body: some View {
        ContentUnavailableView {
            Label("Virtual EQ", systemImage: "slider.vertical.3")
        } description: {
            Text("Add parametric filters to a trace and see the predicted response over the measurement, with each filter's frequency, gain and Q listed. Prediction only: nothing is sent to a processor.\n\nComing in a later step.")
        }
        .frame(minWidth: 220)
    }
}
#endif
