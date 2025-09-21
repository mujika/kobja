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
        let lv = max(0.15, Double(audio.level))
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
        c.stroke(p, with: .color(color.opacity(0.9)), lineWidth: max(2, radius*0.18 * CGFloat(0.6 + 0.8*audio.level)))
    }
}

// MARK: - Engine
@MainActor final class TileMosaicEngine: ObservableObject {
    @Published fileprivate var tiles: [any Tile] = []
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

    fileprivate func reseed(size: CGSize) {
        palette = palettes.randomElement()!
        setup(size: size)
    }

    fileprivate func setup(size: CGSize) {
        m = min(size.width, size.height) * 0.75
        unit = m / CGFloat(n)
        origin = CGPoint(x: (size.width - m)/2 + unit/2, y: (size.height - m)/2 + unit/2)
        tiles = makeTiles(idealLength)
        lastChangeTime = CACurrentMediaTime()
    }

    fileprivate func makeTiles(_ count: Int) -> [any Tile] {
        var res: [any Tile] = []
        var occupied = Set<String>()
        var tries = 0
        func key(_ x: CGFloat, _ y: CGFloat) -> String { "\(x),\(y)" }
        while res.count < count && tries < 1000 {
            let spot = findSpot(addTiles: res, occupied: &occupied)
            if let s = spot, let tile = maybeMakeTile(x: s.x, y: s.y, sz: s.sz) {
                res.append(tile)
                occupied.insert(key(s.x, s.y))
                tries = 0
            } else { tries += 1 }
        }
        return res
    }

    fileprivate func findSpot(addTiles: [any Tile], occupied: inout Set<String>) -> (x: CGFloat, y: CGFloat, sz: Int)? {
        var tries = 0
        func key(_ x: CGFloat, _ y: CGFloat) -> String { "\(x),\(y)" }
        while tries < n*n {
            var x = CGFloat(Int.random(in: 0..<n))
            var y = CGFloat(Int.random(in: 0..<n))
            var sz = Int.random(in: 1...2)
            if sz == 2 && x > 0 && y > 0 { x -= 0.5; y -= 0.5 } else { sz = 1 }
            let exists = occupied.contains(key(x,y)) || addTiles.contains(where: { $0.x == x && $0.y == y })
            if !exists { return (x,y,sz) }
            tries += 1
        }
        return nil
    }

    fileprivate func maybeMakeTile(x: CGFloat, y: CGFloat, sz: Int) -> (any Tile)? {
        let nval = noise2(x*CGFloat(sz)*noiseFreq, y*CGFloat(sz)*noiseFreq)
        if nval < 1 - noiseChance { return nil }
        return makeTile(x: x, y: y, sz: sz)
    }

    fileprivate func makeTile(x: CGFloat, y: CGFloat, sz: Int) -> any Tile {
        let options: [any Tile] = [
            TileTris(x: x, y: y, sz: sz, rotate: 0, color: palette.colors.randomElement()!, dur: duration),
            TileTriSquare(x: x, y: y, sz: sz, rotate: 0, color: palette.colors.randomElement()!, dur: duration),
            TileLines(x: x, y: y, sz: sz, rotate: 0, color: palette.colors.randomElement()!, dur: duration),
            TileArc(x: x, y: y, sz: sz, rotate: 0, color: palette.colors.randomElement()!, dur: duration)
        ]
        let weights = [5.0, 2.0, 4.0, 0.8]
        var tile = weightedRandom(options, weights)
        var rotateOpts: [Int] = []
        if x + CGFloat(sz) <= CGFloat(n - 1) { rotateOpts.append(1) }
        if x - CGFloat(sz) >= 0 { rotateOpts.append(3) }
        if y + CGFloat(sz) <= CGFloat(n - 1) { rotateOpts.append(2) }
        if y - CGFloat(sz) >= 0 { rotateOpts.append(0) }
        if let r = rotateOpts.randomElement() { tile.rotate = r }
        return tile
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
        // Soft refresh: if too few tiles, add more
        if tiles.count < idealLength {
            var scratch = Set<String>()
            if let s = findSpot(addTiles: tiles, occupied: &scratch), let t = maybeMakeTile(x: s.x, y: s.y, sz: s.sz) {
                tiles.append(t)
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
    @StateObject private var engine = TileMosaicEngine()
    @StateObject private var audio = AudioAnalyzer.shared

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                if engine.tiles.isEmpty || engine.unit <= 0 { engine.setup(size: size) }
                // background
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(engine.palette.bg))
                // translate to grid origin
                let origin = engine.origin
                var c = ctx
                c.translateBy(x: origin.x, y: origin.y)
                // draw tiles
                for tile in engine.tiles {
                    var localCtx = ctx
                    var t = tile
                    t.draw(ctx: &localCtx, origin: engine.origin, unit: engine.unit, audio: audio)
                }
            }
            .onChange(of: timeline.date) { _, newNow in
                engine.step(now: newNow.timeIntervalSince1970, audio: audio)
                // Audio-reactive parameters
                engine.flipChance = max(0.005, 0.01 + 0.02 * Double(audio.flux))
                engine.noiseChance = max(0.3, min(0.9, 0.6 + 0.3 * audio.level))
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { engine.reseed(size: NSScreen.main?.visibleFrame.size ?? CGSize(width: 800, height: 600)) }
        .onAppear { if !isRunningInPreviewMosaic() { audio.start() } }
        .onDisappear { audio.stop() }
    }
}

// Local preview detection (avoid dependency on ContentView helper)
private func isRunningInPreviewMosaic() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" || env["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
}
