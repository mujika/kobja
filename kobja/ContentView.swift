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
    // 帯域用プレースホルダ（将来拡張: FFT等）
    @Published var low: CGFloat = 0
    @Published var mid: CGFloat = 0
    @Published var high: CGFloat = 0

    private let engine = AVAudioEngine()
    private var isRunning = false
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

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let ptr = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)

            // 入力強度（RMS）
            var rms: Float = 0
            vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))

            // ノイズゲート（極小値は切り捨て）
            var g = max(0, rms - gate)

            // 自動ゲイン制御：最近のピークを少しずつ減衰させながら保持
            agcPeak = max(g, agcPeak * agcDecay)
            let denom = max(agcPeak, 1e-6)
            var norm = g / denom   // 0...1 付近に自己正規化

            // 安定化（スムージング）
            norm = max(0, min(1, norm))
            self.smoothing = (1 - emaAlpha) * self.smoothing + emaAlpha * norm

            // UIへ反映
            Task { @MainActor in
                self.level = CGFloat(self.smoothing)
            }
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
    static func randomBlueish(rng: inout SeededRNG) -> Palette {
        let hueBase = rng.next(in: 0.55...0.70) // 青→シアン寄り
        let hueAccent = hueBase + rng.next(in: -0.05...0.08)
        let sat = rng.next(in: 0.65...0.95)
        let brightBase = rng.next(in: 0.7...1.0)
        let brightAccent = min(1.0, brightBase + rng.next(in: -0.1...0.15))
        let base = Color(hue: Double(hueBase), saturation: Double(sat), brightness: Double(brightBase))
        let accent = Color(hue: Double(hueAccent), saturation: Double(sat), brightness: Double(brightAccent))
        let bgOpacityRange: ClosedRange<Double> = 0.45...0.95
        return Palette(base: base, accent: accent, bgOpacityRange: bgOpacityRange)
    }
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
            let baseOp = palette.bgOpacityRange.lowerBound + (palette.bgOpacityRange.upperBound - palette.bgOpacityRange.lowerBound) * Double(0.6 + 0.4 * level)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.blue.opacity(baseOp)))

            let center = CGPoint(x: size.width/2, y: size.height/2)
            let maxDim = max(size.width, size.height)
            let baseR = maxDim * baseScale * (0.95 + 0.1 * level)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: rotation)
            ctx.scaleBy(x: 1.0, y: ellipticity)
            // グロー
            let glowR = maxDim * (0.25 + 0.35 * level)
            let glowRect = CGRect(x: -glowR/2, y: -glowR/2, width: glowR, height: glowR)
            ctx.fill(Path(ellipseIn: glowRect), with: .radialGradient(
                .init(colors: [
                    color.opacity(0.10 + 0.25 * level),
                    .clear
                ]),
                center: .zero, startRadius: 0, endRadius: glowR/2
            ))
            // リング
            for i in 0..<max(1, ringCount) {
                let ti = CGFloat(i) / CGFloat(max(1, ringCount - 1))
                let radius = baseR * (1.0 + spread * ti + noiseAmp * CGFloat(sin((Double(i) * 1.7 + t * 0.8))))
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
            let baseOp = palette.bgOpacityRange.lowerBound + (palette.bgOpacityRange.upperBound - palette.bgOpacityRange.lowerBound) * Double(0.55 + 0.45 * level)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.blue.opacity(baseOp)))
            let center = CGPoint(x: size.width/2, y: size.height/2)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: tilt)
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
                    let yoff = A * sin((x / 80.0) * freq + (t * speed) + phase)
                    path.addLine(to: CGPoint(x: x, y: y + yoff))
                }
                let alpha = Double(0.05 + 0.25 * (1 - abs((y - size.height/2) / (size.height/2))))
                ctx.stroke(path, with: .color(color.opacity(alpha)), lineWidth: w)
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
            let baseOp = palette.bgOpacityRange.lowerBound + (palette.bgOpacityRange.upperBound - palette.bgOpacityRange.lowerBound) * Double(0.50 + 0.50 * level)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.blue.opacity(baseOp)))
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
    @State private var palette: Palette = Palette(base: .blue, accent: .white, bgOpacityRange: 0.5...0.95)
    @State private var current: AnyEffect? = nil
    @State private var next: AnyEffect? = nil
    @State private var startDate = Date()
    @State private var cycleStart = Date()
    // 設定
    private let cycleDuration: TimeInterval = 18
    private let crossfadeDuration: TimeInterval = 2.4

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let time = now.timeIntervalSince(startDate)
            Canvas { ctx, size in
                let lv = audio.level
                // 初期化
                if current == nil {
                    initSessionIfNeeded()
                }
                // 自動遷移管理
                var fade: CGFloat = 0
                if let _ = next {
                    let p = CGFloat(min(1.0, max(0.0, now.timeIntervalSince(cycleStart) / crossfadeDuration)))
                    fade = p
                } else if now.timeIntervalSince(cycleStart) > cycleDuration {
                    scheduleNextEffect()
                }

                // 描画（クロスフェード）
                if let e = current {
                    ctx.opacity = Double(1.0 - fade)
                    e.draw(&ctx, size, lv, time)
                }
                if let n = next {
                    ctx.opacity = Double(fade)
                    n.draw(&ctx, size, lv, time)
                    if fade >= 1.0 {
                        current = n
                        next = nil
                        cycleStart = now
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { reseed(crossfade: true) }
        .blur(radius: 4 + 18 * audio.level)
        .scaleEffect(1 + 0.06 * audio.level, anchor: .center)
        .animation(.easeOut(duration: 0.06), value: audio.level)
        .ignoresSafeArea()
        .onAppear {
            startDate = Date()
            cycleStart = Date()
            if !isRunningInPreview() {
                audio.start()
            }
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
}

#Preview {
    ContentView()
}
