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
    private let log2n: vDSP_Length
    private let fftSetup: vDSP.FFT
    private var window: [Float]
    private var tempReal: [Float]
    private var tempImag: [Float]
    private var prevMag: [Float]
    private var fluxEMA: Float = 0
    private let fluxAlpha: Float = 0.15
    private let gate: Float = 1e-4
    private let sr: Float

    init?(sampleRate: Double, fftSize: Int = 1024) {
        guard fftSize.isPowerOfTwo else { return nil }
        self.fftSize = fftSize
        self.log2n = vDSP_Length(Int(log2(Double(fftSize))))
        self.sr = Float(sampleRate)
        guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fftSetup = setup
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        self.tempReal = [Float](repeating: 0, count: fftSize/2)
        self.tempImag = [Float](repeating: 0, count: fftSize/2)
        self.prevMag = [Float](repeating: 0, count: fftSize/2)
    }

    func process(buffer: UnsafePointer<Float>, frameCount: Int) -> Features {
        var f = Features()
        let n = min(frameCount, fftSize)
        if n < 8 { return f }

        // Windowing + zero-pad
        var real = [Float](repeating: 0, count: fftSize)
        real.withUnsafeMutableBufferPointer { dst in
            let count = min(n, fftSize)
            vDSP.multiply(buffer, 1, window, 1, dst.baseAddress!, 1, vDSP_Length(count))
        }

        var split = DSPSplitComplex(realp: &tempReal, imagp: &tempImag)
        tempReal.withUnsafeMutableBufferPointer { rPtr in
            tempImag.withUnsafeMutableBufferPointer { iPtr in
                real.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize/2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize/2))
                    }
                }
                fftSetup.forward(input: split, output: &split)
            }
        }

        var mag = [Float](repeating: 0, count: fftSize/2)
        vDSP.squareMagnitudes(split, result: &mag)

        // Energy bands
        let binHz = sr / Float(fftSize)
        func bin(_ hz: Float) -> Int { Int((hz / binHz).clamped(to: 1...Float(fftSize/2 - 1))) }
        let lo = 20.0 as Float, mi = 250.0 as Float, hi = 2000.0 as Float, top = min(sr*0.45, 8000)
        let b0 = 1, b1 = max(b0+1, bin(mi)), b2 = max(b1+1, bin(hi)), b3 = max(b2+1, bin(top))
        let eps: Float = 1e-6
        f.low = vDSP.sum(mag[b0..<b1]) / Float(max(1, b1-b0))
        f.mid = vDSP.sum(mag[b1..<b2]) / Float(max(1, b2-b1))
        f.high = vDSP.sum(mag[b2..<b3]) / Float(max(1, b3-b2))
        let total = vDSP.sum(mag[b0..<b3]) + eps

        // RMS-level approximation from spectrum total
        f.level = sqrtf(total / Float(max(1, b3-b0)))

        // Spectral centroid
        var idx = [Float](repeating: 0, count: b3-b0)
        vDSP.convertElements(in: b0..<(b3), to: &idx)
        var freqs = [Float](repeating: 0, count: b3-b0)
        vDSP.multiply(idx, Float(binHz), result: &freqs)
        let mags = Array(mag[b0..<b3])
        var num: Float = 0
        vDSP.dot(freqs, mags, result: &num)
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

private extension Float {
    func clamped(to r: ClosedRange<Float>) -> Float { min(r.upperBound, max(r.lowerBound, self)) }
}

