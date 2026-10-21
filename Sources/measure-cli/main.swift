import Foundation
import MeasureDSP
#if os(macOS)
import MeasureAudio
#endif

let usage = """
measure-cli: command-line front end for the Measure analysis core

USAGE
  measure-cli analyze <ir.wav> [--channel N] [--third] [--reverse-filter] [--no-compensation] [--csv out.csv]
      ISO 3382-1 parameters (EDT, T20, T30, C50, C80, D50, Ts) per octave or third-octave band.

  measure-cli sweep <out.wav> [--fs 48000] [--from 20] [--to 20000] [--length 3] [--silence 2] [--level -6]
      Write an exponential sine sweep (level in dBFS peak).

  measure-cli deconvolve <recording.wav> <reference.wav> <out.wav> [--rec-channel N] [--ref-channel N] [--from 20] [--to 20000]
      Impulse response from a recording and its excitation (the generated sweep or a loopback recording).

  measure-cli delay <signal.wav> <reference.wav> [--channel N] [--ref-channel N]
      Delay of a signal relative to a reference, in samples and milliseconds.

  measure-cli devices
      List audio devices with their channels and sample rates (macOS).

  measure-cli measure --out DEVICE [--out-ch 1] [--in DEVICE] [--mics 1,2] [--loopback N] [--loopback-out N]
                      [--fs 48000] [--from 20] [--to 20000] [--length 3] [--silence 2] [--level -12]
                      [--save PREFIX] [--third]
      Play a sweep and record up to 4 mics (macOS). DEVICE is a number from `devices`, its UID, or part
      of its name. --in defaults to the output device. With --loopback (an input wired to the sweep
      output) delays are absolute; --loopback-out also plays the sweep on a second output to cable to it.
      --save writes PREFIX-raw.wav and PREFIX-mic1.wav, ...

Channels are numbered from 1.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

/// Minimal option parsing: positional arguments plus `--name value` and `--flag` options.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, flags known: Set<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if known.contains(name) { flags.insert(name) } else { options[name] = it.next() ?? "" }
            } else {
                positional.append(a)
            }
        }
    }

    func double(_ name: String, default value: Double) throws -> Double {
        guard let s = options[name] else { return value }
        guard let v = Double(s) else { throw CLIError(description: "--\(name) needs a number, got '\(s)'") }
        return v
    }

    func channel(_ name: String) throws -> Int {
        Int(try double(name, default: 1)) - 1
    }

    func file(_ i: Int, _ what: String) throws -> URL {
        guard i < positional.count else { throw CLIError(description: "missing \(what)\n\n\(usage)") }
        return URL(fileURLWithPath: positional[i])
    }
}

func channel(_ audio: AudioData, _ index: Int, of path: URL) throws -> [Double] {
    guard audio.channels.indices.contains(index) else {
        throw CLIError(description: "\(path.lastPathComponent) has \(audio.channelCount) channel(s); channel \(index + 1) does not exist")
    }
    return audio.channels[index]
}

func fmt(_ v: Double?, _ digits: Int = 2) -> String {
    guard let v, v.isFinite else { return "-" }
    return String(format: "%.\(digits)f", v)
}

func analyze(_ args: Arguments) throws {
    let url = try args.file(0, "impulse response file")
    let audio = try WAV.read(contentsOf: url)
    let ir = try channel(audio, try args.channel("channel"), of: url)

    let options = roomOptions(args)
    let result = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: audio.sampleRate, options: options)
    print("\(url.lastPathComponent): \(Int(audio.sampleRate)) Hz, \(fmt(audio.duration, 2)) s, onset at sample \(result.onsetIndex)")
    try printResults(result, csv: args.options["csv"])
}

func roomOptions(_ args: Arguments) -> RoomAcoustics.Options {
    var options = RoomAcoustics.Options()
    if args.flags.contains("third") {
        options.resolution = .thirdOctave
        options.lowestBand = 50
        options.highestBand = 10_000
    }
    options.timeReversedFiltering = args.flags.contains("reverse-filter")
    options.noiseCompensation = !args.flags.contains("no-compensation")
    return options
}

/// Prints the ISO 3382 table, and writes it as CSV when a path is given.
func printResults(_ result: RoomAcousticsResult, csv: String? = nil) throws {
    let rows = result.bands + [result.broadband]
    let header = ["Band", "EDT s", "T20 s", "T30 s", "C50 dB", "C80 dB", "D50 %", "Ts ms", "PNR dB"]
    let table = rows.map { p in
        [p.band?.description ?? "Broadband", fmt(p.edt), fmt(p.t20), fmt(p.t30), fmt(p.c50, 1), fmt(p.c80, 1),
         fmt(p.d50 * 100, 1), fmt(p.ts * 1000, 0), fmt(p.peakToNoise, 0)]
    }
    let widths = header.indices.map { c in max(header[c].count, table.map { $0[c].count }.max() ?? 0) }
    func line(_ cells: [String]) -> String {
        cells.enumerated().map { c, s in
            c == 0 ? s.padding(toLength: widths[c], withPad: " ", startingAt: 0)
                   : String(repeating: " ", count: widths[c] - s.count) + s
        }.joined(separator: "  ")
    }
    print(line(header))
    table.forEach { print(line($0)) }

    if let csv {
        let text = ([header] + table).map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
        try text.write(toFile: csv, atomically: true, encoding: .utf8)
        print("Wrote \(csv)")
    }
}

func sweep(_ args: Arguments) throws {
    let url = try args.file(0, "output file")
    let fs = try args.double("fs", default: 48_000)
    let sweep = ExponentialSweep(startFrequency: try args.double("from", default: 20),
                                 endFrequency: try args.double("to", default: 20_000),
                                 duration: try args.double("length", default: 3),
                                 sampleRate: fs,
                                 amplitude: pow(10, try args.double("level", default: -6) / 20))
    let samples = sweep.samples(silence: try args.double("silence", default: 2))
    try WAV.write(AudioData(sampleRate: fs, mono: samples), to: url)
    print("Wrote \(url.path): \(samples.count) samples at \(Int(fs)) Hz")
}

func deconvolve(_ args: Arguments) throws {
    let recURL = try args.file(0, "recording file")
    let refURL = try args.file(1, "reference file")
    let outURL = try args.file(2, "output file")
    let rec = try WAV.read(contentsOf: recURL)
    let ref = try WAV.read(contentsOf: refURL)
    guard rec.sampleRate == ref.sampleRate else {
        throw CLIError(description: "sample rates differ: \(rec.sampleRate) and \(ref.sampleRate) Hz")
    }
    let ir = Deconvolution.impulseResponse(
        recording: try channel(rec, try args.channel("rec-channel"), of: recURL),
        reference: try channel(ref, try args.channel("ref-channel"), of: refURL),
        sampleRate: rec.sampleRate,
        band: try args.double("from", default: 20)...(try args.double("to", default: min(20_000, rec.sampleRate / 2))))
    try WAV.write(AudioData(sampleRate: rec.sampleRate, mono: ir), to: outURL)
    print("Wrote \(outURL.path): \(ir.count) samples, peak at sample \(fmt(Peak.index(of: ir), 1))")
}

func delay(_ args: Arguments) throws {
    let sigURL = try args.file(0, "signal file")
    let refURL = try args.file(1, "reference file")
    let sig = try WAV.read(contentsOf: sigURL)
    let ref = try WAV.read(contentsOf: refURL)
    let d = Delay.estimate(signal: try channel(sig, try args.channel("channel"), of: sigURL),
                           reference: try channel(ref, try args.channel("ref-channel"), of: refURL))
    print("Delay: \(fmt(d, 2)) samples = \(fmt(d / sig.sampleRate * 1000, 3)) ms")
}

#if os(macOS)
func devices() throws {
    let list = try AudioDevices.all()
    for (i, d) in list.enumerated() {
        let rates = d.availableSampleRates.map { String(format: "%g", $0 / 1000) }.joined(separator: "/")
        print("\(i + 1). \(d.name)  [\(d.transport)]")
        print("     in \(d.inputChannels), out \(d.outputChannels), now \(Int(d.sampleRate)) Hz, supports \(rates) kHz, latency in \(d.inputLatency) / out \(d.outputLatency) frames")
        print("     uid \(d.uid)")
    }
    if list.isEmpty { print("No audio devices found") }
}

func channelList(_ s: String?, default value: [Int]) throws -> [Int] {
    guard let s else { return value }
    let parts = s.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? 0) >= 1 }) else {
        throw CLIError(description: "--mics needs channel numbers from 1, like 1,2")
    }
    return parts.map { $0! - 1 }
}

func measure(_ args: Arguments) async throws {
    guard let outName = args.options["out"] else { throw CLIError(description: "measure needs --out DEVICE\n\n\(usage)") }
    let out = try AudioDevices.find(outName)
    let inDevice = try args.options["in"].map(AudioDevices.find) ?? out
    let mics = try channelList(args.options["mics"], default: [0])
    let loopback = try args.options["loopback"].map { _ in try args.channel("loopback") }
    let loopbackOut = try args.options["loopback-out"].map { _ in try args.channel("loopback-out") }
    let fs = try args.double("fs", default: 48_000)

    let sweep = ExponentialSweep(startFrequency: try args.double("from", default: 20),
                                 endFrequency: try args.double("to", default: min(20_000, fs / 2)),
                                 duration: try args.double("length", default: 3),
                                 sampleRate: fs,
                                 amplitude: pow(10, try args.double("level", default: -12) / 20))
    let played = sweep.samples(silence: try args.double("silence", default: 2))
    let routing = SweepRouting(outputDevice: out, outputChannel: try args.channel("out-ch"),
                               inputDevice: inDevice, micChannels: mics, loopbackChannel: loopback,
                               loopbackOutputChannel: loopbackOut)

    print("Playing a \(fmt(sweep.duration, 1)) s sweep on \(out.name) channel \(routing.outputChannel + 1); recording \(inDevice.name) channel(s) \(mics.map { String($0 + 1) }.joined(separator: ","))" + (loopback.map { ", loopback on \($0 + 1)" } ?? ""))
    let recording = try await SweepRecorder().record(played, sampleRate: fs, routing: routing)
    let result = SweepProcessing.process(mics: recording.mics, loopback: recording.loopback, sweep: sweep,
                                         played: recording.played, clockRatio: recording.clockRatio ?? 1)

    if let latency = result.loopbackLatency {
        print("Timing: loopback reference, round-trip latency \(fmt(latency, 1)) samples (\(fmt(latency / fs * 1000, 2)) ms)")
        if let gain = result.loopbackGain {
            print("Loopback level: \(fmt(20 * log10(gain), 1)) dB (levels below are relative to the sweep's full scale)")
        }
        if let peak = result.loopbackPeakLevel, peak > -1 {
            print("WARNING: the loopback input clipped (peak \(fmt(peak, 1)) dBFS), which distorts every impulse response. Lower --level or the loopback input gain.")
        }
    } else {
        print("Timing: generated sweep (no loopback), so delays include the interface latency")
    }
    if recording.separateDevices {
        if let ppm = recording.driftPPM, let i = recording.inputRate, let o = recording.outputRate {
            print("Separate devices: input clock \(fmt(i, 2)) Hz, output clock \(fmt(o, 2)) Hz, difference \(fmt(ppm, 1)) ppm (corrected)")
        } else {
            print("Separate devices: could not measure the clock difference, so it was not corrected")
        }
        if recording.loopback == nil {
            print("Note: without a loopback, arrival times between separate devices are approximate (device latencies are not known).")
            print("      Cable an output of \(out.name) to an input of \(inDevice.name) and use --loopback-out/--loopback for exact timing.")
        }
    }

    if let prefix = args.options["save"] {
        let raw = AudioData(sampleRate: fs, channels: recording.mics + [recording.loopback].compactMap { $0 })
        try WAV.write(raw, to: URL(fileURLWithPath: "\(prefix)-raw.wav"))
        print("Wrote \(prefix)-raw.wav")
    }

    for (i, ir) in result.impulseResponses.enumerated() {
        let peak = result.micPeakLevels[i]
        let warning = peak > -1 ? "  CLIPPING: lower --level" : peak < -50 ? "  low level: raise --level or the gain" : ""
        let arrival = Peak.index(of: ir)
        print("\nMic \(i + 1) (input \(mics[i] + 1)): peak \(fmt(peak, 1)) dBFS\(warning), direct sound at \(fmt(arrival / fs * 1000, 2)) ms")
        if let prefix = args.options["save"] {
            try WAV.write(AudioData(sampleRate: fs, mono: ir), to: URL(fileURLWithPath: "\(prefix)-mic\(i + 1).wav"))
            print("Wrote \(prefix)-mic\(i + 1).wav")
        }
        try printResults(RoomAcoustics.analyze(impulseResponse: ir, sampleRate: fs, options: roomOptions(args)))
    }
}
#endif

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    print(usage)
    exit(1)
}
let args = Arguments(argv.dropFirst(2), flags: ["third", "reverse-filter", "no-compensation"])
do {
    switch argv[1] {
    case "analyze": try analyze(args)
    case "sweep": try sweep(args)
    case "deconvolve": try deconvolve(args)
    case "delay": try delay(args)
    #if os(macOS)
    case "devices": try devices()
    case "measure": try await measure(args)
    #else
    case "devices", "measure": throw CLIError(description: "\(argv[1]) needs macOS")
    #endif
    case "-h", "--help", "help": print(usage)
    default:
        print("Unknown command '\(argv[1])'\n\n\(usage)")
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
