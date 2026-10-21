import Foundation
import MeasureDSP

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

    var options = RoomAcoustics.Options()
    if args.flags.contains("third") {
        options.resolution = .thirdOctave
        options.lowestBand = 50
        options.highestBand = 10_000
    }
    options.timeReversedFiltering = args.flags.contains("reverse-filter")
    options.noiseCompensation = !args.flags.contains("no-compensation")

    let result = RoomAcoustics.analyze(impulseResponse: ir, sampleRate: audio.sampleRate, options: options)
    let rows = result.bands + [result.broadband]

    let header = ["Band", "EDT s", "T20 s", "T30 s", "C50 dB", "C80 dB", "D50 %", "Ts ms", "PNR dB"]
    let table = rows.map { p in
        [p.band?.description ?? "Broadband", fmt(p.edt), fmt(p.t20), fmt(p.t30), fmt(p.c50, 1), fmt(p.c80, 1),
         fmt(p.d50 * 100, 1), fmt(p.ts * 1000, 0), fmt(p.peakToNoise, 0)]
    }

    print("\(url.lastPathComponent): \(Int(audio.sampleRate)) Hz, \(fmt(audio.duration, 2)) s, onset at sample \(result.onsetIndex)")
    let widths = header.indices.map { c in max(header[c].count, table.map { $0[c].count }.max() ?? 0) }
    func line(_ cells: [String]) -> String {
        cells.enumerated().map { c, s in
            c == 0 ? s.padding(toLength: widths[c], withPad: " ", startingAt: 0)
                   : String(repeating: " ", count: widths[c] - s.count) + s
        }.joined(separator: "  ")
    }
    print(line(header))
    table.forEach { print(line($0)) }

    if let csv = args.options["csv"] {
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
    case "-h", "--help", "help": print(usage)
    default:
        print("Unknown command '\(argv[1])'\n\n\(usage)")
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
