//
//  ContentView.swift
//  kobja
//
//  Created by 新村彰啓 on 9/21/25.
//

import SwiftUI
import AppKit
import AVFoundation
import Accelerate
import Combine
import simd

// SwiftUI Preview / Playgrounds 検出
private func isRunningInPreview() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" || env["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
}

struct ContentView: View {
    var body: some View {
        ReactiveBlueView()
            .onAppear {
                // Previewではフルスクリーン切替を行わない（クラッシュ回避）
                guard !isRunningInPreview() else { return }
                DispatchQueue.main.async {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
    }
}

// === Audio解析（RMSベース + 簡易スムージング） ===
@MainActor
final class AudioAnalyzer: ObservableObject {
    static let shared = AudioAnalyzer()

    @Published var level: CGFloat = 0  // 0...1 に正規化した音量
    @Published var low: CGFloat = 0    // FFT帯域エネルギー（低）
    @Published var mid: CGFloat = 0    // FFT帯域エネルギー（中）
    @Published var high: CGFloat = 0   // FFT帯域エネルギー（高）
    @Published var centroid: CGFloat = 0  // スペクトル重心（Hz）
    @Published var flux: CGFloat = 0      // スペクトルフラックス
    @Published var beat: Bool = false     // 簡易ビート検出

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var featureExtractor: AudioFeatureExtractor?
    private var smoothing: Float = 0
    // 自動ゲイン制御（環境音量に自動追従）
    private var agcPeak: Float = 0.02
    private let agcDecay: Float = 0.995   // 1.0に近いほどゆっくり下がる
    private let gate: Float = 0.0005      // これ未満は無視（ノイズゲート）
    private let emaAlpha: Float = 0.2

    func start() {
        if isRunning { return }
        if isRunningInPreview() { return }
        isRunning = true
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 1024

        // Remove any existing tap to avoid duplicate taps
        input.removeTap(onBus: 0)

        // FFT 初期化
        if self.featureExtractor == nil {
            self.featureExtractor = AudioFeatureExtractor(sampleRate: Double(format.sampleRate), fftSize: Int(bufferSize))
        }

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let ptr = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)

            // 入力強度（RMS）
            var rms: Float = 0
            vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))

            // ノイズゲート（極小値は切り捨て）
            let g = max(0, rms - gate)

            // 自動ゲイン制御：最近のピークを少しずつ減衰させながら保持
            agcPeak = max(g, agcPeak * agcDecay)
            let denom = max(agcPeak, 1e-6)
            var norm = g / denom   // 0...1 付近に自己正規化

            // 安定化（スムージング）
            norm = max(0, min(1, norm))
            self.smoothing = (1 - emaAlpha) * self.smoothing + emaAlpha * norm

            // FFT特徴量
            if let fx = self.featureExtractor {
                let feats = fx.process(buffer: ptr, frameCount: count)
                // 正規化（描画用に軽めのスケール）
                let norm: (Float) -> CGFloat = { CGFloat(min(1, max(0, $0 * 6))) }
                let lo = norm(feats.low)
                let mi = norm(feats.mid)
                let hi = norm(feats.high)
                let flux = CGFloat(min(1, feats.flux * 4))
                let centroid = CGFloat(feats.centroid)
                let beat = feats.beat
                Task { @MainActor in
                    self.low = lo
                    self.mid = mi
                    self.high = hi
                    self.flux = flux
                    self.centroid = centroid
                    self.beat = beat
                }
            }

            // UIへ反映（RMS）
            Task { @MainActor in self.level = CGFloat(self.smoothing) }
        }

        do {
            try engine.start()
        } catch {
            isRunning = false
            print("Audio engine start error: \(error)")
        }
    }

    func stop() {
        if !isRunning { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}

// === ランダム化されたエフェクトエンジン ===
fileprivate struct SeededRNG {
    private(set) var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next64() -> UInt64 {
        // SplitMix64
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next64()) / Double(UInt64.max) }
    mutating func nextCGFloat() -> CGFloat { CGFloat(nextDouble()) }
    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        let t = nextCGFloat()
        return range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
    mutating func nextInt(_ range: ClosedRange<Int>) -> Int {
        let w = range.upperBound - range.lowerBound + 1
        let r = Int(Double(w) * nextDouble())
        return range.lowerBound + max(0, min(w - 1, r))
    }
    mutating func chance(_ p: CGFloat) -> Bool { nextCGFloat() < max(0, min(1, p)) }
}

fileprivate struct Palette {
    let base: Color
    let accent: Color
    let bgOpacityRange: ClosedRange<Double>
    let baseRGB: SIMD3<Float>
    let accentRGB: SIMD3<Float>
    static func randomBlueish(rng: inout SeededRNG) -> Palette {
        let hueBase = rng.next(in: 0.55...0.70) // 青→シアン寄り
        let hueAccent = hueBase + rng.next(in: -0.05...0.08)
        let sat = rng.next(in: 0.65...0.95)
        let brightBase = rng.next(in: 0.7...1.0)
        let brightAccent = min(1.0, brightBase + rng.next(in: -0.1...0.15))
        let base = Color(hue: Double(hueBase), saturation: Double(sat), brightness: Double(brightBase))
        let accent = Color(hue: Double(hueAccent), saturation: Double(sat), brightness: Double(brightAccent))
        let baseRGB = hsbToRGB(Float(hueBase), Float(sat), Float(brightBase))
        let accentRGB = hsbToRGB(Float(hueAccent), Float(sat), Float(brightAccent))
        let bgOpacityRange: ClosedRange<Double> = 0.45...0.95
        return Palette(base: base, accent: accent, bgOpacityRange: bgOpacityRange, baseRGB: baseRGB, accentRGB: accentRGB)
    }
}

fileprivate func hsbToRGB(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
    let hh = (h - floor(h)) * 6.0
    let c = v * s
    let x = c * (1 - fabsf(fmodf(hh, 2) - 1))
    let m = v - c
    var r: Float = 0, g: Float = 0, b: Float = 0
    switch Int(hh) {
    case 0: (r,g,b) = (c, x, 0)
    case 1: (r,g,b) = (x, c, 0)
    case 2: (r,g,b) = (0, c, x)
    case 3: (r,g,b) = (0, x, c)
    case 4: (r,g,b) = (x, 0, c)
    default: (r,g,b) = (c, 0, x)
    }
    return SIMD3<Float>(r + m, g + m, b + m)
}

fileprivate struct AnyEffect {
    let name: String
    let draw: (_ ctx: inout GraphicsContext, _ size: CGSize, _ level: CGFloat, _ t: TimeInterval) -> Void
}

fileprivate struct EffectFactory {
    static func ringEffect(rng: inout SeededRNG, palette: Palette) -> AnyEffect {
        let ringCount = rng.nextInt(3...10)
        let baseOpacity = Double(rng.next(in: 0.4...0.8))
        let thicknessBase = rng.next(in: 0.8...6.0)
        let thicknessVar = rng.next(in: 0.5...6.0)
        let baseScale = rng.next(in: 0.30...0.70)
        let spread = rng.next(in: 0.20...0.55)
        let ellipticity = rng.next(in: 0.88...1.12) // yスケール
        let rotation = rng.next(in: -CGFloat.pi/12 ... CGFloat.pi/12)
        let noiseAmp = rng.next(in: 0.00...0.08)
        let color = palette.accent
        return AnyEffect(name: "Rings") { ctx, size, level, t in
            // 背景
            let bgRange = palette.bgOpacityRange
            let lvD = Double(level)
            let baseOp = bgRange.lowerBound + (bgRange.upperBound - bgRange.lowerBound) * (0.6 + 0.4 * lvD)
            let bgRect = CGRect(origin: .zero, size: size)
            let bgPath = Path(bgRect)
            let bgColor = Color.blue.opacity(baseOp)
            let bgShading: GraphicsContext.Shading = .color(bgColor)
            ctx.fill(bgPath, with: bgShading)

            let center = CGPoint(x: size.width/2, y: size.height/2)
            let maxDim = max(size.width, size.height)
            let baseR = maxDim * baseScale * (0.95 + 0.1 * level)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .radians(Double(rotation)))
            ctx.scaleBy(x: 1.0, y: ellipticity)
            // グロー
            let glowR = maxDim * (0.25 + 0.35 * level)
            let glowRect = CGRect(x: -glowR/2, y: -glowR/2, width: glowR, height: glowR)
            let glowPath = Path(ellipseIn: glowRect)
            let gradColors: [Color] = [
                color.opacity(0.10 + 0.25 * level),
                .clear
            ]
            let gradient = Gradient(colors: gradColors)
            let glowShading = GraphicsContext.Shading.radialGradient(gradient,
                                                                     center: .zero,
                                                                     startRadius: 0,
                                                                     endRadius: glowR/2)
            ctx.fill(glowPath, with: glowShading)
            // リング
            for i in 0..<max(1, ringCount) {
                let ti = CGFloat(i) / CGFloat(max(1, ringCount - 1))
                let phaseN = Double(i) * 1.7 + t * 0.8
                let noise = CGFloat(sin(phaseN))
                let radius = baseR * (1.0 + spread * ti + noiseAmp * noise)
                let rect = CGRect(x: -radius/2, y: -radius/2, width: radius, height: radius)
                let path = Path(ellipseIn: rect)
                let w = max(0.5, thicknessBase + thicknessVar * (0.8 * (1 - ti) + 0.2 * level))
                let a = baseOpacity * Double(0.15 + 0.85 * (1 - ti)) * Double(0.6 + 0.4 * level)
                ctx.stroke(path, with: .color(color.opacity(a)), lineWidth: w)
            }
        }
    }

    static func waveEffect(rng: inout SeededRNG, palette: Palette) -> AnyEffect {
        let lines = rng.nextInt(12...36)
        let freq = rng.next(in: 0.6...2.2)
        let amp = rng.next(in: 6...32)
        let speed = rng.next(in: 0.2...1.2)
        let thickness = rng.next(in: 0.8...3.0)
        let tilt = rng.next(in: -CGFloat.pi/6 ... CGFloat.pi/6)
        let color = palette.base
        return AnyEffect(name: "Waves") { ctx, size, level, t in
            // 背景
            let bgRangeW = palette.bgOpacityRange
            let lvDW = Double(level)
            let baseOpW = bgRangeW.lowerBound + (bgRangeW.upperBound - bgRangeW.lowerBound) * (0.55 + 0.45 * lvDW)
            let bgRectW = CGRect(origin: .zero, size: size)
            let bgPathW = Path(bgRectW)
            let bgColorW = Color.blue.opacity(baseOpW)
            let bgShadingW: GraphicsContext.Shading = .color(bgColorW)
            ctx.fill(bgPathW, with: bgShadingW)
            let center = CGPoint(x: size.width/2, y: size.height/2)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .radians(Double(tilt)))
            ctx.translateBy(x: -center.x, y: -center.y)
            // サイン波の束
            for i in 0..<lines {
                let y = CGFloat(i) / CGFloat(lines - 1) * size.height
                let phase = CGFloat(i) * 0.35
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                let steps = 120
                let A = amp * (0.3 + 1.2 * level)
                let w = thickness * (0.6 + 1.6 * level)
                for s in 1...steps {
                    let x = CGFloat(s) / CGFloat(steps) * size.width
                    let xd = Double(x)
                    let freqD = Double(freq)
                    let speedD = Double(speed)
                    let phaseD = Double(phase)
                    let phi = (xd / 80.0) * freqD + (t * speedD) + phaseD
                    let yoff = A * CGFloat(sin(phi))
                    path.addLine(to: CGPoint(x: x, y: y + yoff))
                }
                let cy: CGFloat = size.height / 2
                let denom: CGFloat = max(1.0, cy)
                let normCG: CGFloat = max(0, min(1, 1 - abs((y - cy) / denom)))
                let alpha = Double(0.05 + 0.25 * normCG)
                let shading: GraphicsContext.Shading = .color(color.opacity(alpha))
                ctx.stroke(path, with: shading, lineWidth: w)
            }
        }
    }

    static func particleEffect(rng: inout SeededRNG, palette: Palette) -> AnyEffect {
        let count = rng.nextInt(40...120)
        let baseR = rng.next(in: 40...CGFloat(240)) // 相対値想定
        let spread = rng.next(in: 0.4...1.8)
        let speed = rng.next(in: 0.2...1.8)
        let tail = rng.next(in: 0.0...0.4)
        let color = palette.accent
        // 個別パラメータを事前生成
        var seeds: [(angle: CGFloat, radius: CGFloat, omega: CGFloat, phase: CGFloat)] = []
        seeds.reserveCapacity(count)
        for _ in 0..<count {
            let ang = rng.next(in: 0...2 * .pi)
            let rad = baseR * (0.4 + spread * rng.nextCGFloat())
            let omg = (0.4 + 1.6 * rng.nextCGFloat()) * speed
            let ph = rng.next(in: 0...2 * .pi)
            seeds.append((ang, rad, omg, ph))
        }
        return AnyEffect(name: "Particles") { ctx, size, level, t in
            // 背景
            let bgRangeP = palette.bgOpacityRange
            let lvDP = Double(level)
            let baseOpP = bgRangeP.lowerBound + (bgRangeP.upperBound - bgRangeP.lowerBound) * (0.50 + 0.50 * lvDP)
            let bgRectP = CGRect(origin: .zero, size: size)
            let bgPathP = Path(bgRectP)
            let bgColorP = Color.blue.opacity(baseOpP)
            let bgShadingP: GraphicsContext.Shading = .color(bgColorP)
            ctx.fill(bgPathP, with: bgShadingP)
            let c = CGPoint(x: size.width/2, y: size.height/2)
            let dotBase = 2.0 + 6.0 * level
            let tailCount = Int(3 + floor(level * 12 * tail))
            for (i, p) in seeds.enumerated() {
                let r = p.radius * (0.9 + 0.2 * level)
                let ang = p.angle + p.omega * CGFloat(t) + p.phase
                let x = c.x + r * cos(ang)
                let y = c.y + r * sin(ang) * 0.9
                let alpha = Double(0.08 + 0.45 * level)
                let dot = Path(ellipseIn: CGRect(x: x - dotBase/2, y: y - dotBase/2, width: dotBase, height: dotBase))
                ctx.fill(dot, with: .color(color.opacity(alpha)))
                // 軽い尾
                if tailCount > 0 {
                    for k in 1...tailCount {
                        let decay = Double(k) / Double(tailCount + 1)
                        let ang2 = ang - p.omega * 0.05 * CGFloat(k)
                        let rr = r * (1.0 - 0.02 * CGFloat(k))
                        let xx = c.x + rr * cos(ang2)
                        let yy = c.y + rr * sin(ang2) * 0.9
                        let w = max(1.0, dotBase - CGFloat(k))
                        let a2 = alpha * (1.0 - decay)
                        let d2 = Path(ellipseIn: CGRect(x: xx - w/2, y: yy - w/2, width: w, height: w))
                        ctx.fill(d2, with: .color(color.opacity(a2)))
                    }
                }
                if i > 400 { break } // 安全措置
            }
        }
    }

    static func randomEffect(rng: inout SeededRNG, palette: Palette) -> AnyEffect {
        let pick = rng.nextCGFloat()
        if pick < 0.34 { return ringEffect(rng: &rng, palette: palette) }
        else if pick < 0.67 { return waveEffect(rng: &rng, palette: palette) }
        else { return particleEffect(rng: &rng, palette: palette) }
    }
}

// === 視覚側：ランダムエフェクト + 自動遷移 ===
struct ReactiveBlueView: View {
    @StateObject private var audio = AudioAnalyzer.shared
    // 乱数・効果
    @State private var sessionSeed: UInt64 = 0
    @State private var rng = SeededRNG(seed: 0)
    @State private var palette: Palette = Palette(base: .blue, accent: .white, bgOpacityRange: 0.5...0.95, baseRGB: SIMD3<Float>(0.2,0.4,0.9), accentRGB: SIMD3<Float>(0.95,0.98,1.0))
    @State private var current: AnyEffect? = nil
    @State private var next: AnyEffect? = nil
    @State private var startDate = Date()
    @State private var cycleStart = Date()
    // 設定
    private let cycleDuration: TimeInterval = 18
    private let crossfadeDuration: TimeInterval = 2.4

    var body: some View {
        Group {
            // Replace current effect with the Mosaic effect
            TileMosaicView()
        }
        .animation(.easeOut(duration: 0.06), value: audio.level)
        .ignoresSafeArea()
        .onAppear {
            startDate = Date(); cycleStart = Date()
            if !isRunningInPreview() { audio.start() }
            initSessionIfNeeded()
        }
        .onDisappear { audio.stop() }
    }

    private func initSessionIfNeeded() {
        if sessionSeed == 0 {
            let seed: UInt64 = isRunningInPreview() ? 42 : (UInt64.random(in: .min ... .max))
            sessionSeed = seed
            rng = SeededRNG(seed: seed)
            palette = .randomBlueish(rng: &rng)
            current = EffectFactory.randomEffect(rng: &rng, palette: palette)
            next = nil
            cycleStart = Date()
        }
    }

    private func scheduleNextEffect() {
        palette = .randomBlueish(rng: &rng)
        next = EffectFactory.randomEffect(rng: &rng, palette: palette)
        cycleStart = Date() // クロスフェード開始時刻
    }

    private func reseed(crossfade: Bool) {
        rng = SeededRNG(seed: UInt64.random(in: .min ... .max))
        palette = .randomBlueish(rng: &rng)
        if crossfade, current != nil {
            next = EffectFactory.randomEffect(rng: &rng, palette: palette)
            cycleStart = Date()
        } else {
            current = EffectFactory.randomEffect(rng: &rng, palette: palette)
            next = nil
            cycleStart = Date()
        }
    }

    // 時間経過に応じた状態更新（描画フェーズ外で呼ぶ）
    private func tick(now: Date) {
        // 初期化（初回のみ）
        if current == nil {
            initSessionIfNeeded()
            return
        }
        // 周期満了で次エフェクトを準備（クロスフェード開始）
        if next == nil && now.timeIntervalSince(cycleStart) > cycleDuration {
            scheduleNextEffect()
            return
        }
        // フェード完了でコミット
        if next != nil && now.timeIntervalSince(cycleStart) >= crossfadeDuration {
            current = next
            next = nil
            cycleStart = now
        }
    }
}

#Preview {
    ContentView()
}
