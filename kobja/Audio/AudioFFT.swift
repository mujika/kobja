import Foundation
import Accelerate

final class AudioFeatureExtractor {
    struct Features {
        var low: Float = 0
        var mid: Float = 0
        var high: Float = 0
        var level: Float = 0
        var centroid: Float = 0
        var flux: Float = 0
        var beat: Bool = false
    }

    private let fftSize: Int
    private var dft: vDSP.DFT<Float>?
    private var window: [Float]
    private var prevMag: [Float]
    private var fluxEMA: Float = 0
    private let fluxAlpha: Float = 0.15
    private let gate: Float = 1e-4
    private let sr: Float

    init?(sampleRate: Double, fftSize: Int = 1024) {
        guard fftSize.isPowerOfTwo else { return nil }
        self.fftSize = fftSize
        self.sr = Float(sampleRate)
        self.dft = vDSP.DFT<Float>(count: fftSize,
                                   direction: .forward,
                                   transformType: .complex,
                                   ofType: Float.self)
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        self.prevMag = [Float](repeating: 0, count: fftSize/2)
    }

    func process(buffer: UnsafePointer<Float>, frameCount: Int) -> Features {
        var f = Features()
        let n = min(frameCount, fftSize)
        if n < 8 { return f }

        // Copy input and apply window (zero-padded)
        var input = [Float](repeating: 0, count: fftSize)
        input.withUnsafeMutableBufferPointer { dst in
            if let base = dst.baseAddress {
                memcpy(base, buffer, n * MemoryLayout<Float>.size)
            }
        }
        input = vDSP.multiply(input, window)

        // Real DFT
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)
        let inImag = [Float](repeating: 0, count: fftSize)
        dft?.transform(inputReal: input, inputImag: inImag, resultReal: &outReal, resultImag: &outImag)

        // Magnitude^2
        let magR = vDSP.square(outReal)
        let magI = vDSP.square(outImag)
        var magFull = vDSP.add(magR, magI)
        var mag = Array(magFull.prefix(fftSize/2))

        // Energy bands
        let binHz = sr / Float(fftSize)
        func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, x)) }
        func bin(_ hz: Float) -> Int { Int(clampf(hz / binHz, 1, Float(fftSize/2 - 1))) }
        let mi: Float = 250.0, hi: Float = 2000.0, top: Float = min(sr*0.45, 8000)
        let b0 = 1, b1 = max(b0+1, bin(mi)), b2 = max(b1+1, bin(hi)), b3 = max(b2+1, bin(top))
        let eps: Float = 1e-6
        f.low = vDSP.sum(Array(mag[b0..<b1])) / Float(max(1, b1-b0))
        f.mid = vDSP.sum(Array(mag[b1..<b2])) / Float(max(1, b2-b1))
        f.high = vDSP.sum(Array(mag[b2..<b3])) / Float(max(1, b3-b2))
        let total = vDSP.sum(Array(mag[b0..<b3])) + eps

        // RMS-level approximation from spectrum total
        f.level = sqrtf(total / Float(max(1, b3-b0)))

        // Spectral centroid
        var idx = [Float](repeating: 0, count: b3-b0)
        vDSP.ramp(withInitialValue: Float(b0), increment: 1, count: b3-b0, result: &idx)
        let freqs = vDSP.multiply(binHz, idx)
        let mags = Array(mag[b0..<b3])
        let num: Float = vDSP.dot(freqs, mags)
        f.centroid = num / (vDSP.sum(mags) + eps)

        // Spectral flux and simple beat
        var fluxVal: Float = 0
        for i in 0..<mag.count { let d = mag[i] - prevMag[i]; fluxVal += max(0, d) }
        fluxVal /= Float(mag.count)
        fluxEMA = (1 - fluxAlpha) * fluxEMA + fluxAlpha * fluxVal
        f.flux = fluxVal
        let th = fluxEMA * 1.8 + gate
        f.beat = fluxVal > th

        // keep for next
        prevMag = mag
        return f
    }
}

private extension Int {
    var isPowerOfTwo: Bool { self > 0 && (self & (self - 1)) == 0 }
}
