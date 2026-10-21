import Foundation

/// Multichannel audio held as Double samples, nominally in the range -1...1.
public struct AudioData: Equatable {
    public var sampleRate: Double
    /// One array per channel, all the same length.
    public var channels: [[Double]]

    public init(sampleRate: Double, channels: [[Double]]) {
        precondition(Set(channels.map(\.count)).count <= 1, "all channels must have the same length")
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public init(sampleRate: Double, mono: [Double]) {
        self.init(sampleRate: sampleRate, channels: [mono])
    }

    public var channelCount: Int { channels.count }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: Double { Double(frameCount) / sampleRate }
}

public enum WAVError: Error, CustomStringConvertible {
    case notRIFFWave
    case missingChunk(String)
    case unsupportedFormat(tag: Int, bits: Int)
    case truncated

    public var description: String {
        switch self {
        case .notRIFFWave: return "Not a RIFF/WAVE file"
        case .missingChunk(let id): return "WAV file has no '\(id)' chunk"
        case .unsupportedFormat(let tag, let bits): return "Unsupported WAV format (tag \(tag), \(bits) bits)"
        case .truncated: return "WAV file is truncated"
        }
    }
}

/// Reads and writes WAV files: PCM 8, 16, 24 and 32 bit, and 32 and 64 bit float,
/// including WAVE_FORMAT_EXTENSIBLE headers.
public enum WAV {
    public enum SampleFormat {
        case pcm16, pcm24, float32
    }

    public static func read(contentsOf url: URL) throws -> AudioData {
        try read(data: try Data(contentsOf: url))
    }

    public static func read(data: Data) throws -> AudioData {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, ascii(bytes, 0, 4) == "RIFF", ascii(bytes, 8, 4) == "WAVE" else {
            throw WAVError.notRIFFWave
        }

        var formatTag = 0, channelCount = 0, sampleRate = 0, bits = 0
        var dataRange: Range<Int>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset, 4)
            let size = Int(le32(bytes, offset + 4))
            let body = offset + 8
            switch id {
            case "fmt ":
                guard body + 16 <= bytes.count else { throw WAVError.truncated }
                formatTag = Int(le16(bytes, body))
                channelCount = Int(le16(bytes, body + 2))
                sampleRate = Int(le32(bytes, body + 4))
                bits = Int(le16(bytes, body + 14))
                // WAVE_FORMAT_EXTENSIBLE: the real format is the first two bytes of the sub-format GUID.
                if formatTag == 0xFFFE, size >= 40, body + 26 <= bytes.count {
                    formatTag = Int(le16(bytes, body + 24))
                }
            case "data":
                // Some writers leave the size as 0 or 0xFFFFFFFF when streaming; read to the end in that case.
                let streaming = size == 0 || body + size > bytes.count
                dataRange = body..<(streaming ? bytes.count : body + size)
                if streaming { offset = bytes.count; continue }
            default:
                break
            }
            offset = body + size + (size & 1)
        }

        guard channelCount > 0 else { throw WAVError.missingChunk("fmt ") }
        guard let range = dataRange else { throw WAVError.missingChunk("data") }

        let bytesPerSample = bits / 8
        let frameBytes = bytesPerSample * channelCount
        let frames = range.count / frameBytes
        var channels = [[Double]](repeating: [Double](repeating: 0, count: frames), count: channelCount)

        let decode: (Int) -> Double
        switch (formatTag, bits) {
        case (1, 8): decode = { (Double(bytes[$0]) - 128) / 128 }
        case (1, 16): decode = { Double(Int16(bitPattern: le16(bytes, $0))) / 32768 }
        case (1, 24): decode = { i in
            let raw = Int32(bytes[i]) | Int32(bytes[i + 1]) << 8 | Int32(bytes[i + 2]) << 16
            return Double((raw << 8) >> 8) / 8_388_608
        }
        case (1, 32): decode = { Double(Int32(bitPattern: le32(bytes, $0))) / 2_147_483_648 }
        case (3, 32): decode = { Double(Float(bitPattern: le32(bytes, $0))) }
        case (3, 64): decode = { Double(bitPattern: le64(bytes, $0)) }
        default: throw WAVError.unsupportedFormat(tag: formatTag, bits: bits)
        }

        for f in 0..<frames {
            let base = range.lowerBound + f * frameBytes
            for c in 0..<channelCount {
                channels[c][f] = decode(base + c * bytesPerSample)
            }
        }
        return AudioData(sampleRate: Double(sampleRate), channels: channels)
    }

    public static func write(_ audio: AudioData, to url: URL, format: SampleFormat = .float32) throws {
        try data(for: audio, format: format).write(to: url)
    }

    public static func data(for audio: AudioData, format: SampleFormat = .float32) -> Data {
        let bits: Int, tag: UInt16
        switch format {
        case .pcm16: bits = 16; tag = 1
        case .pcm24: bits = 24; tag = 1
        case .float32: bits = 32; tag = 3
        }
        let channels = audio.channelCount
        let blockAlign = channels * bits / 8
        let dataSize = audio.frameCount * blockAlign

        var out = [UInt8]()
        out.reserveCapacity(44 + dataSize)
        out += Array("RIFF".utf8); put32(&out, UInt32(36 + dataSize)); out += Array("WAVE".utf8)
        out += Array("fmt ".utf8); put32(&out, 16)
        put16(&out, tag); put16(&out, UInt16(channels))
        put32(&out, UInt32(audio.sampleRate)); put32(&out, UInt32(Int(audio.sampleRate) * blockAlign))
        put16(&out, UInt16(blockAlign)); put16(&out, UInt16(bits))
        out += Array("data".utf8); put32(&out, UInt32(dataSize))

        for f in 0..<audio.frameCount {
            for c in 0..<channels {
                let x = audio.channels[c][f]
                switch format {
                case .pcm16:
                    put16(&out, UInt16(bitPattern: Int16(clamp(x * 32768, -32768, 32767).rounded())))
                case .pcm24:
                    let v = Int32(clamp(x * 8_388_608, -8_388_608, 8_388_607).rounded())
                    out += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)]
                case .float32:
                    put32(&out, Float(x).bitPattern)
                }
            }
        }
        return Data(out)
    }

    // MARK: - Byte helpers

    private static func ascii(_ b: [UInt8], _ at: Int, _ n: Int) -> String {
        String(decoding: b[at..<(at + n)], as: UTF8.self)
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
    }

    private static func put16(_ out: inout [UInt8], _ v: UInt16) {
        out += [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    private static func put32(_ out: inout [UInt8], _ v: UInt32) {
        out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}
