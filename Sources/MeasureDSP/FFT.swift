import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// A spectrum stored as separate real and imaginary arrays.
public struct SplitComplex: Equatable {
    public var real: [Double]
    public var imag: [Double]

    public init(real: [Double], imag: [Double]) {
        precondition(real.count == imag.count, "real and imag must have the same length")
        self.real = real
        self.imag = imag
    }

    public init(count: Int) {
        self.real = [Double](repeating: 0, count: count)
        self.imag = [Double](repeating: 0, count: count)
    }

    public var count: Int { real.count }

    /// |X|^2 for every bin.
    public var power: [Double] {
        (0..<count).map { real[$0] * real[$0] + imag[$0] * imag[$0] }
    }

    public var magnitude: [Double] { power.map { $0.squareRoot() } }

    /// Phase in radians, wrapped to (-pi, pi].
    public var phase: [Double] { (0..<count).map { atan2(imag[$0], real[$0]) } }
}

/// Power-of-two FFT. Uses vDSP on Apple platforms and a portable radix-2 FFT elsewhere,
/// so the same tests run on a Mac and on Linux CI.
///
/// Convention: forward is X[k] = sum x[n] e^(-2 pi i k n / N), unscaled.
/// Inverse is scaled by 1/N, so `inverse(forward(x)) == x`.
public final class FFT {
    public let size: Int

    #if canImport(Accelerate)
    private let forwardSetup: OpaquePointer
    private let inverseSetup: OpaquePointer
    #else
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let bitReversed: [Int]
    #endif

    public init(size: Int) {
        precondition(size >= 16 && size & (size - 1) == 0, "FFT size must be a power of two and at least 16")
        self.size = size

        #if canImport(Accelerate)
        guard let fwd = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(size), vDSP_DFT_Direction.FORWARD),
              let inv = vDSP_DFT_zop_CreateSetupD(fwd, vDSP_Length(size), vDSP_DFT_Direction.INVERSE) else {
            fatalError("vDSP could not create a DFT setup for size \(size)")
        }
        forwardSetup = fwd
        inverseSetup = inv
        #else
        let half = size / 2
        cosTable = (0..<half).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        sinTable = (0..<half).map { sin(2 * Double.pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        bitReversed = (0..<size).map { i in
            var r = 0
            var v = i
            for _ in 0..<bits {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            return r
        }
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_DFT_DestroySetupD(forwardSetup)
        vDSP_DFT_DestroySetupD(inverseSetup)
        #endif
    }

    /// Smallest power of two that is >= n (and at least 16).
    public static func size(atLeast n: Int) -> Int {
        var s = 16
        while s < n { s <<= 1 }
        return s
    }

    /// Complex-to-complex transform of `size` points.
    public func transform(_ input: SplitComplex, inverse: Bool = false) -> SplitComplex {
        precondition(input.count == size, "input length \(input.count) does not match FFT size \(size)")
        var output = SplitComplex(count: size)
        #if canImport(Accelerate)
        input.real.withUnsafeBufferPointer { ir in
            input.imag.withUnsafeBufferPointer { ii in
                output.real.withUnsafeMutableBufferPointer { or in
                    output.imag.withUnsafeMutableBufferPointer { oi in
                        vDSP_DFT_ExecuteD(inverse ? inverseSetup : forwardSetup,
                                          ir.baseAddress!, ii.baseAddress!,
                                          or.baseAddress!, oi.baseAddress!)
                    }
                }
            }
        }
        #else
        for i in 0..<size {
            let j = bitReversed[i]
            output.real[j] = input.real[i]
            output.imag[j] = input.imag[i]
        }
        let sign: Double = inverse ? 1 : -1
        var len = 2
        while len <= size {
            let halfLen = len / 2
            let step = size / len
            var start = 0
            while start < size {
                for k in 0..<halfLen {
                    let wr = cosTable[k * step]
                    let wi = sign * sinTable[k * step]
                    let a = start + k
                    let b = a + halfLen
                    let tr = output.real[b] * wr - output.imag[b] * wi
                    let ti = output.real[b] * wi + output.imag[b] * wr
                    output.real[b] = output.real[a] - tr
                    output.imag[b] = output.imag[a] - ti
                    output.real[a] += tr
                    output.imag[a] += ti
                }
                start += len
            }
            len <<= 1
        }
        #endif
        if inverse {
            let scale = 1 / Double(size)
            for i in 0..<size {
                output.real[i] *= scale
                output.imag[i] *= scale
            }
        }
        return output
    }

    /// Real-input forward transform. Input shorter than `size` is zero-padded.
    /// Returns bins 0...size/2 (DC to Nyquist).
    public func forward(_ x: [Double]) -> SplitComplex {
        precondition(x.count <= size, "input longer than FFT size")
        var input = SplitComplex(count: size)
        for i in 0..<x.count { input.real[i] = x[i] }
        let full = transform(input)
        let bins = size / 2 + 1
        return SplitComplex(real: Array(full.real[0..<bins]), imag: Array(full.imag[0..<bins]))
    }

    /// Inverse of `forward`: takes bins 0...size/2 of a Hermitian spectrum and returns `size` real samples.
    public func inverse(_ halfSpectrum: SplitComplex) -> [Double] {
        let bins = size / 2 + 1
        precondition(halfSpectrum.count == bins, "expected \(bins) bins")
        var full = SplitComplex(count: size)
        for k in 0..<bins {
            full.real[k] = halfSpectrum.real[k]
            full.imag[k] = halfSpectrum.imag[k]
        }
        // DC and Nyquist bins of a real signal have no imaginary part.
        full.imag[0] = 0
        full.imag[size / 2] = 0
        for k in 1..<(size / 2) {
            full.real[size - k] = halfSpectrum.real[k]
            full.imag[size - k] = -halfSpectrum.imag[k]
        }
        return transform(full, inverse: true).real
    }

    /// Frequency in Hz of each bin returned by `forward`.
    public func binFrequencies(sampleRate: Double) -> [Double] {
        (0...(size / 2)).map { Double($0) * sampleRate / Double(size) }
    }
}
