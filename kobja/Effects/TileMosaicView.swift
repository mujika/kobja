import SwiftUI
import Combine

// MARK: - Palettes
struct MosaicPalette {
    let colors: [Color]
    let bg: Color
}

private let palettes: [MosaicPalette] = [
    MosaicPalette(colors: [Color(hex: 0x4BA3C3), Color(hex: 0x0E6BA8), Color(hex: 0x5AD2F4), Color(hex: 0xD7F9FF)], bg: Color(hex: 0x071E26)),
    MosaicPalette(colors: [Color(hex: 0xF2545B), Color(hex: 0xF5DFBB), Color(hex: 0xA93F55), Color(hex: 0x19323C)], bg: Color(hex: 0x0B1A21)),
    MosaicPalette(colors: [Color(hex: 0x2E86AB), Color(hex: 0xF6F5AE), Color(hex: 0xF26419), Color(hex: 0x33658A)], bg: Color(hex: 0x10212A)),
    MosaicPalette(colors: [Color(hex: 0x80FFDB), Color(hex: 0x72EFDD), Color(hex: 0x64DFDF), Color(hex: 0x48BFE3)], bg: Color(hex: 0x0B2D3A))
]

// MARK: - Utils
fileprivate extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

private func weightedRandom<T>(_ array: [T], _ weights: [Double]) -> T {
    let total = weights.reduce(0, +)
    let r = Double.random(in: 0..<total)
    var sum = 0.0
    for i in 0..<array.count { sum += weights[i]; if r <= sum { return array[i] } }
    return array.last!
}

private func noise2(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
    // Cheap analytic noise via sin/cos combos (deterministic)
    let v = sin(x * 1.3) * cos(y * 1.7) + sin(x * 0.7 + y * 1.1)
    return 0.5 + 0.5 * CGFloat(tanh(Double(v)))
}

// MARK: - Tiles
fileprivate enum TileStage { case show, steady, hide }

fileprivate protocol Tile {
    var x: CGFloat { get set }
    var y: CGFloat { get set }
    var sz: Int { get set }
    var rotate: Int { get set }
    var color: Color { get set }
    var dur: Double { get set }
    var stage: TileStage { get set }
    var t: Double { get set } // 0..dur
    mutating func update(_ dt: Double)
    mutating func flip()
    func draw(ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, audio: AudioAnalyzer)
}

fileprivate extension Tile {
    mutating func update(_ dt: Double) {
        t = min(dur, t + dt)
        if stage == .show && t >= dur { stage = .steady; t = 0 }
        if stage == .hide && t >= dur { /* removal handled by engine */ }
    }
    mutating func flip() { rotate = (rotate + 2) % 4; stage = .show; t = 0 }
}

fileprivate struct TileLines: Tile {
    var x: CGFloat; var y: CGFloat; var sz: Int; var rotate: Int; var color: Color; var dur: Double; var stage: TileStage = .show; var t: Double = 0
    func draw(ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, audio: AudioAnalyzer) {
        let rect = CGRect(x: origin.x + x*unit, y: origin.y + y*unit, width: CGFloat(sz)*unit, height: CGFloat(sz)*unit)
        var c = ctx
        c.translateBy(x: rect.midX, y: rect.midY)
        c.rotate(by: .radians(Double(rotate) * .pi/2))
        c.translateBy(x: -rect.size.width/2, y: -rect.size.height/2)
        let lv = max(0.15, Double(audio.low))
        let step = max(4.0, Double(unit) * 0.18)
        let w = max(1.0, Double(unit) * 0.06 * lv * Double(sz))
        let progress = stage == .show ? min(1, t/dur) : 1
        let maxX = Double(rect.width) * progress
        var path = Path()
        var xx = 0.0
        while xx <= maxX {
            path.move(to: CGPoint(x: xx, y: 0))
            path.addLine(to: CGPoint(x: xx, y: Double(rect.height)))
            xx += step
        }
        c.stroke(path, with: .color(color.opacity(0.9)), lineWidth: w)
    }
}

fileprivate struct TileTris: Tile {
    var x: CGFloat; var y: CGFloat; var sz: Int; var rotate: Int; var color: Color; var dur: Double; var stage: TileStage = .show; var t: Double = 0
    func draw(ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, audio: AudioAnalyzer) {
        let rect = CGRect(x: origin.x + x*unit, y: origin.y + y*unit, width: CGFloat(sz)*unit, height: CGFloat(sz)*unit)
        var c = ctx
        c.translateBy(x: rect.midX, y: rect.midY)
        c.rotate(by: .radians(Double(rotate) * .pi/2))
        c.translateBy(x: -rect.size.width/2, y: -rect.size.height/2)
        let progress = stage == .show ? min(1, t/dur) : 1
        let p = Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width * progress, y: 0))
            p.addLine(to: CGPoint(x: 0, y: rect.height * progress))
            p.closeSubpath()
        }
        c.fill(p, with: .color(color))
        let p2 = Path { p in
            p.move(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: rect.width * (1-progress), y: rect.height))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height * (1-progress)))
            p.closeSubpath()
        }
        c.fill(p2, with: .color(color.opacity(0.8)))
    }
}

fileprivate struct TileTriSquare: Tile {
    var x: CGFloat; var y: CGFloat; var sz: Int; var rotate: Int; var color: Color; var dur: Double; var stage: TileStage = .show; var t: Double = 0
    func draw(ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, audio: AudioAnalyzer) {
        let rect = CGRect(x: origin.x + x*unit, y: origin.y + y*unit, width: CGFloat(sz)*unit, height: CGFloat(sz)*unit)
        var c = ctx
        c.translateBy(x: rect.midX, y: rect.midY)
        c.rotate(by: .radians(Double(rotate) * .pi/2))
        c.translateBy(x: -rect.size.width/2, y: -rect.size.height/2)
        let progress = stage == .show ? min(1, t/dur) : 1
        // Center square
        let s = rect.insetBy(dx: rect.width*0.25*(1-progress), dy: rect.height*0.25*(1-progress))
        c.fill(Path(s), with: .color(color.opacity(0.9)))
        // Corner triangles
        let tri = Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: rect.width*0.35*progress, y: 0)); p.addLine(to: CGPoint(x: 0, y: rect.height*0.35*progress)); p.closeSubpath()
        }
        c.fill(tri, with: .color(color.opacity(0.6)))
        c.translateBy(x: rect.width, y: 0); c.rotate(by: .radians(.pi/2)); c.fill(tri, with: .color(color.opacity(0.5)))
    }
}

fileprivate struct TileArc: Tile {
    var x: CGFloat; var y: CGFloat; var sz: Int; var rotate: Int; var color: Color; var dur: Double; var stage: TileStage = .show; var t: Double = 0
    func draw(ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, audio: AudioAnalyzer) {
        let rect = CGRect(x: origin.x + x*unit, y: origin.y + y*unit, width: CGFloat(sz)*unit, height: CGFloat(sz)*unit)
        var c = ctx
        c.translateBy(x: rect.midX, y: rect.midY)
        c.rotate(by: .radians(Double(rotate) * .pi/2))
        c.translateBy(x: -rect.size.width/2, y: -rect.size.height/2)
        let progress = stage == .show ? min(1, t/dur) : 1
        let radius = min(rect.width, rect.height) * 0.5
        let start: Angle = .radians(0)
        let end: Angle = .radians(Double.pi * 0.5 * progress)
        var p = Path()
        p.addArc(center: CGPoint(x: radius, y: radius), radius: radius*0.9, startAngle: start, endAngle: end, clockwise: false)
        c.stroke(p, with: .color(color.opacity(0.9)), lineWidth: max(2, radius*0.18 * CGFloat(0.6 + 0.8*audio.low)))
    }
}

// MARK: - Engine
@MainActor final class TileMosaicEngine: ObservableObject {
    @Published fileprivate var tiles: [any Tile] = []
    enum Kind: CaseIterable { case tris, triSquare, lines, arc }
    var n: Int = 10
    var changeInterval: Double = 0.03 // seconds per animation frame step
    var idealLength: Int = 50
    var noiseFreq: CGFloat = 0.4
    var noiseChance: CGFloat = 0.6
    var flipChance: CGFloat = 0.01
    var duration: Double = 1.5
    var unit: CGFloat = 40
    var m: CGFloat = 400
    var origin: CGPoint = .zero
    var lastChangeTime: CFTimeInterval = 0
    var lastBeatTime: CFTimeInterval = 0
    var palette: MosaicPalette = palettes.randomElement()!
    // Distribution controls
    var fillRatio: CGFloat = 0.6               // target density across grid (0..1)
    var noisePhaseX: CGFloat = 0               // random phase to avoid fixed noise bias
    var noisePhaseY: CGFloat = 0
    var candidateK: Int = 20                   // blue-noise: number of random candidates per pick
    var neighborRadius: CGFloat = 1.25         // blue-noise: how far to check occupancy
    // Surprise controls
    var repetitionPenalty: CGFloat = 0.4       // penalize recently頻出の種類
    var recentKinds: [Kind] = []               // 最近の種類（上限 recentCap）
    let recentCap: Int = 64
    var lastColorIndex: Int = -1
    // Rare-event scheduler（群発など）
    var hazard: CGFloat = 0
    var lastRareTS: CFTimeInterval = 0
    var rareCooldown: CFTimeInterval = 2.0
    var spawnBurstFramesRemaining: Int = 0

    fileprivate func reseed(size: CGSize) {
        palette = palettes.randomElement()!
        // randomize noise phase each reseed
        noisePhaseX = CGFloat.random(in: 0...1000)
        noisePhaseY = CGFloat.random(in: 0...1000)
        setup(size: size)
    }

    fileprivate func setup(size: CGSize) {
        m = min(size.width, size.height) * 0.75
        unit = m / CGFloat(n)
        origin = CGPoint(x: (size.width - m)/2 + unit/2, y: (size.height - m)/2 + unit/2)
        // auto target density based on grid size
        let gridCells = n * n
        idealLength = max(24, Int(CGFloat(gridCells) * fillRatio))
        tiles = makeTiles(idealLength)
        lastChangeTime = CACurrentMediaTime()
    }

    fileprivate func makeTiles(_ count: Int) -> [any Tile] {
        var res: [any Tile] = []
        var occupied = Set<String>()
        var tries = 0
        func key(_ x: CGFloat, _ y: CGFloat) -> String { "\(x),\(y)" }
        while res.count < count && tries < 1000 {
            let spot = findSpotBlueNoise(addTiles: res, occupied: &occupied)
            if let s = spot, let tile = maybeMakeTile(x: s.x, y: s.y, sz: s.sz, audio: nil) {
                res.append(tile)
                occupied.insert(key(s.x, s.y))
                tries = 0
            } else { tries += 1 }
        }
        return res
    }

    // Blue-noise candidate selection: sample K random candidates and pick the one
    // with the lowest neighbor occupancy score (uniform distribution).
    fileprivate func findSpotBlueNoise(addTiles: [any Tile], occupied: inout Set<String>) -> (x: CGFloat, y: CGFloat, sz: Int)? {
        func key(_ x: CGFloat, _ y: CGFloat) -> String { "\(x),\(y)" }
        // helper: count neighbors around a coordinate within neighborRadius
        func neighborScore(_ xx: CGFloat, _ yy: CGFloat) -> CGFloat {
            var score: CGFloat = 0
            for t in addTiles {
                let dx = abs(t.x - xx)
                let dy = abs(t.y - yy)
                if dx + dy <= neighborRadius { score += 1 }
            }
            // slight bias away from top-left corner (reduce clustering)
            let cx = CGFloat(n - 1) / 2
            let cy = CGFloat(n - 1) / 2
            let centerBias = (abs(xx - cx) + abs(yy - cy)) / CGFloat(n)
            return score + 0.05 * centerBias
        }

        var best: (x: CGFloat, y: CGFloat, sz: Int, score: CGFloat)? = nil
        let K = max(8, candidateK)
        for _ in 0..<K {
            var x = CGFloat(Int.random(in: 0..<n))
            var y = CGFloat(Int.random(in: 0..<n))
            var sz = Int.random(in: 1...2)
            if sz == 2 && x > 0 && y > 0 { x -= 0.5; y -= 0.5 } else { sz = 1 }
            if occupied.contains(key(x,y)) || addTiles.contains(where: { $0.x == x && $0.y == y }) { continue }
            let sc = neighborScore(x, y)
            if best == nil || sc < best!.score { best = (x, y, sz, sc) }
        }
        if let b = best { return (b.x, b.y, b.sz) }
        return nil
    }

    fileprivate func maybeMakeTile(x: CGFloat, y: CGFloat, sz: Int, audio: AudioAnalyzer?) -> (any Tile)? {
        // randomized noise phase to avoid fixed spatial bias
        let nval = noise2((x + noisePhaseX)*CGFloat(sz)*noiseFreq, (y + noisePhaseY)*CGFloat(sz)*noiseFreq)
        if nval < 1 - noiseChance { return nil }
        return makeTile(x: x, y: y, sz: sz, audio: audio)
    }

    fileprivate func makeTile(x: CGFloat, y: CGFloat, sz: Int, audio: AudioAnalyzer?) -> any Tile {
        let kind = pickKind(audio: audio)
        let clr = pickColor()
        var tile: any Tile
        switch kind {
        case .tris:
            tile = TileTris(x: x, y: y, sz: sz, rotate: 0, color: clr, dur: duration)
        case .triSquare:
            tile = TileTriSquare(x: x, y: y, sz: sz, rotate: 0, color: clr, dur: duration)
        case .lines:
            tile = TileLines(x: x, y: y, sz: sz, rotate: 0, color: clr, dur: duration)
        case .arc:
            tile = TileArc(x: x, y: y, sz: sz, rotate: 0, color: clr, dur: duration)
        }
        record(kind: kind)
        var rotateOpts: [Int] = []
        if x + CGFloat(sz) <= CGFloat(n - 1) { rotateOpts.append(1) }
        if x - CGFloat(sz) >= 0 { rotateOpts.append(3) }
        if y + CGFloat(sz) <= CGFloat(n - 1) { rotateOpts.append(2) }
        if y - CGFloat(sz) >= 0 { rotateOpts.append(0) }
        if let r = rotateOpts.randomElement() { tile.rotate = r }
        return tile
    }

    private func pickColor() -> Color {
        let colors = palette.colors
        guard !colors.isEmpty else { return .white }
        if colors.count == 1 { lastColorIndex = 0; return colors[0] }
        var idx = Int.random(in: 0..<colors.count)
        if idx == lastColorIndex && Double.random(in: 0...1) < 0.7 { idx = (idx + 1) % colors.count }
        lastColorIndex = idx
        return colors[idx]
    }

    private func pickKind(audio: AudioAnalyzer?) -> Kind {
        var w: [Kind: Double] = [.tris: 5.0, .triSquare: 2.0, .lines: 4.0, .arc: 0.8]
        if let a = audio {
            let mid = Double(max(0, min(1, a.mid)))
            let high = Double(max(0, min(1, a.high)))
            w[.lines]! *= 1.0 + 0.8 * mid
            w[.arc]!   *= 1.0 + 1.1 * high
        }
        // anti-repetition
        let freq = recentFrequency()
        for k in Kind.allCases {
            let p = Double(max(0, 1.0 - repetitionPenalty * freq[k, default: 0]))
            w[k]! *= max(0.1, p)
        }
        let kinds = Kind.allCases
        let weights = kinds.map { w[$0]! }
        return weightedRandom(kinds, weights)
    }

    private func record(kind: Kind) {
        recentKinds.append(kind)
        if recentKinds.count > recentCap { recentKinds.removeFirst(recentKinds.count - recentCap) }
    }

    private func recentFrequency() -> [Kind: CGFloat] {
        var counts: [Kind: Int] = [:]
        for k in recentKinds { counts[k, default: 0] += 1 }
        let total = max(1, recentKinds.count)
        var freq: [Kind: CGFloat] = [:]
        for k in Kind.allCases { freq[k] = CGFloat(counts[k, default: 0]) / CGFloat(total) }
        return freq
    }

    fileprivate func step(now: CFTimeInterval, audio: AudioAnalyzer) {
        let dt = max(0, now - lastChangeTime)
        lastChangeTime = now
        // Update tiles
        for i in tiles.indices { tiles[i].update(dt) }
        // Flip chance boosts with beat
        if audio.beat && now - lastBeatTime > 0.2 {
            lastBeatTime = now
            randomFlip(count: Int.random(in: 1...3))
        }
        // Rare-event scheduler (hazard grows with time and flux)
        hazard = min(1.0, hazard + CGFloat(dt) * 0.08 + 0.2 * audio.flux)
        if now - lastRareTS > rareCooldown {
            let triggerProb = min(0.9, Double(hazard))
            if Double.random(in: 0...1) < triggerProb {
                lastRareTS = now
                hazard = 0
                spawnBurstFramesRemaining = Int.random(in: 2...4)
                randomFlip(count: Int.random(in: 3...7))
            }
        }
        // Soft refresh: if too few tiles, add more (spawn budget per tick)
        if tiles.count < idealLength {
            let deficit = idealLength - tiles.count
            var budget = min(3, max(1, deficit / 5))
            if spawnBurstFramesRemaining > 0 { budget = min(3, budget + 2); spawnBurstFramesRemaining -= 1 }
            for _ in 0..<budget {
                var scratch = Set<String>()
                if let s = findSpotBlueNoise(addTiles: tiles, occupied: &scratch) {
                    // Choose size: small frequent; bass boosts chance for bigger tiles
                    let baseP2: Double = 0.18
                    let p2 = baseP2 + 0.25 * Double(max(0, min(1, audio.low)))
                    let chosenSz = (Double.random(in: 0...1) < p2) ? max(1, s.sz) : 1
                    if let t = maybeMakeTile(x: s.x, y: s.y, sz: chosenSz, audio: audio) {
                        tiles.append(t)
                    }
                }
            }
        }
        // Remove hidden
        tiles.removeAll { $0.stage == .hide && $0.t >= $0.dur }
    }

    fileprivate func randomFlip(count: Int) {
        guard !tiles.isEmpty else { return }
        for _ in 0..<count {
            let idx = Int.random(in: 0..<tiles.count)
            tiles[idx].flip()
        }
    }
}

// MARK: - SwiftUI View
struct TileMosaicView: View {
    // Double-buffered engines for crossfade
    @State private var current = TileMosaicEngine()
    @State private var next: TileMosaicEngine? = nil
    @StateObject private var audio = AudioAnalyzer.shared
    @State private var lastTick: Date = Date()
    @State private var bassPulse: CGFloat = 0
    @State private var blurDrop: CGFloat = 0
    @State private var cycleStart: Date = Date()
    @State private var lastSize: CGSize = .zero
    private let cycleDuration: TimeInterval = 10
    private let crossfadeDuration: TimeInterval = 1.2

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                lastSize = size
                // Initialize engines for this size
                if current.tiles.isEmpty || current.unit <= 0 { current.setup(size: size) }
                if let n = next, (n.tiles.isEmpty || n.unit <= 0) { n.setup(size: size) }

                // Compute fade
                let now = timeline.date
                let fading = next != nil
                let fade = fading ? CGFloat(min(1.0, max(0.0, now.timeIntervalSince(cycleStart) / crossfadeDuration))) : 0

                // Draw current layer
                var layer = ctx
                layer.opacity = Double(1 - fade)
                layer.fill(Path(CGRect(origin: .zero, size: size)), with: .color(current.palette.bg))
                var lc = layer
                lc.translateBy(x: current.origin.x, y: current.origin.y)
                for tile in current.tiles {
                    var drawCtx = layer
                    var t = tile
                    t.draw(ctx: &drawCtx, origin: current.origin, unit: current.unit, audio: audio)
                }

                // Draw next layer
                if let n = next {
                    var layerN = ctx
                    layerN.opacity = Double(fade)
                    layerN.fill(Path(CGRect(origin: .zero, size: size)), with: .color(n.palette.bg))
                    var ln = layerN
                    ln.translateBy(x: n.origin.x, y: n.origin.y)
                    for tile in n.tiles {
                        var drawCtx = layerN
                        var t = tile
                        t.draw(ctx: &drawCtx, origin: n.origin, unit: n.unit, audio: audio)
                    }
                }

                // Fullscreen bass-reactive pulse overlay
                let amp = max(0, min(1, audio.low))
                let pulse = max(amp, bassPulse)
                if pulse > 0.01 {
                    let maxDim = max(size.width, size.height)
                    let r = maxDim * (0.35 + 0.4 * pulse)
                    let rect = CGRect(x: size.width/2 - r/2, y: size.height/2 - r/2, width: r, height: r)
                    let g = Gradient(colors: [Color.white.opacity(0.18 * pulse), .clear])
                    ctx.fill(Path(ellipseIn: rect), with: .radialGradient(g, center: .init(x: size.width/2, y: size.height/2), startRadius: 0, endRadius: r/2))
                }
            }
            .onChange(of: timeline.date) { _, newNow in
                let dt = newNow.timeIntervalSince(lastTick)
                lastTick = newNow
                // Step both engines
                current.step(now: newNow.timeIntervalSince1970, audio: audio)
                next?.step(now: newNow.timeIntervalSince1970, audio: audio)
                // Audio-reactive parameters
                let amp = max(0, min(1, Double(audio.low)))
                current.flipChance = min(0.12, max(0.008, 0.006 + 0.025 * amp + (audio.lowBeat ? 0.03 : 0)))
                current.noiseChance = max(0.35, min(0.92, 0.55 + 0.35 * amp))
                if let n = next {
                    n.flipChance = current.flipChance
                    n.noiseChance = current.noiseChance
                }
                // Bass pulse envelope
                if audio.lowBeat { bassPulse = 1.0 } else { bassPulse = max(0, bassPulse - CGFloat(dt) * 2.0) }
                // Occasionally drop blur to zero on low beat, then recover quickly
                if audio.lowBeat && Double.random(in: 0...1) < 0.15 {
                    blurDrop = 1.0
                }
                let dropRecover: CGFloat = 0.35 // seconds to fully recover
                blurDrop = max(0, blurDrop - CGFloat(dt) / dropRecover)

                // Cycle management: start fade every cycleDuration
                if next == nil && newNow.timeIntervalSince(cycleStart) > cycleDuration {
                    var n = TileMosaicEngine()
                    n.reseed(size: lastSize == .zero ? CGSize(width: 800, height: 600) : lastSize)
                    next = n
                    cycleStart = newNow
                }
                // Commit fade
                if let n = next, newNow.timeIntervalSince(cycleStart) >= crossfadeDuration {
                    current = n
                    next = nil
                    cycleStart = newNow
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            // Start immediate crossfade to a fresh reseeded engine
            var n = TileMosaicEngine()
            let size = (NSScreen.main?.visibleFrame.size ?? CGSize(width: 800, height: 600))
            n.reseed(size: lastSize == .zero ? size : lastSize)
            next = n
            cycleStart = Date()
        }
        .onAppear { if !isRunningInPreviewMosaic() { audio.start() } }
        .onDisappear { audio.stop() }
        // Whole-view bass-driven scale/blur
        .scaleEffect(1 + 0.05 * max(0, min(1, audio.low)) + 0.04 * bassPulse)
        .blur(radius: max(0, (2 + 4 * max(0, min(1, audio.low)) + 4 * bassPulse) * (1 - blurDrop)))
    }
}

// Local preview detection (avoid dependency on ContentView helper)
private func isRunningInPreviewMosaic() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" || env["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
}
