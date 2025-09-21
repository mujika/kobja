import Foundation
import SwiftUI
import MetalKit
import simd

// MARK: - Uniforms
struct VisualUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var seed: Float
    var level: Float
    var low: Float
    var mid: Float
    var high: Float
    var centroid: Float
    var flux: Float
    var beat: Float
    var baseColor: SIMD3<Float>
    var accentColor: SIMD3<Float>
}

struct MirrorUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var seed: Float
    var level: Float
    var low: Float
    var mid: Float
    var high: Float
    var flux: Float
    var beat: Float
    var cols: Float
    var rows: Float
    var seamWidth: Float
    var seamBright: Float
    var curveAmt: Float
    var noiseAmp: Float
    var noiseSpeed: Float
}

// MARK: - Renderer
final class MetalRenderer: NSObject, MTKViewDelegate {
    enum Mode { case kaleido, mirror }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelineKaleido: MTLRenderPipelineState
    private var pipelineMirror: MTLRenderPipelineState
    private var start = CFAbsoluteTimeGetCurrent()
    var mode: Mode = .mirror

    private var uniforms = VisualUniforms(
        resolution: .zero, time: 0, seed: 1,
        level: 0, low: 0, mid: 0, high: 0, centroid: 0, flux: 0, beat: 0,
        baseColor: SIMD3<Float>(0.1, 0.3, 0.9),
        accentColor: SIMD3<Float>(0.8, 0.9, 1.0)
    )

    private var mirror = MirrorUniforms(
        resolution: .zero, time: 0, seed: 1,
        level: 0, low: 0, mid: 0, high: 0, flux: 0, beat: 0,
        cols: 4, rows: 2, seamWidth: 0.003, seamBright: 0.8,
        curveAmt: 0.05, noiseAmp: 0.008, noiseSpeed: 0.35
    )

    private var audio: AudioAnalyzer = .shared
    var cameraTexture: MTLTexture?

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        // Pipeline
        guard
            let lib = try? device.makeDefaultLibrary(bundle: .main),
            let vtx = lib.makeFunction(name: "fullScreenVertex"),
            let fragK = lib.makeFunction(name: "kaleidoFragment"),
            let fragM = lib.makeFunction(name: "mirrorFragment")
        else { return nil }

        let descK = MTLRenderPipelineDescriptor()
        descK.vertexFunction = vtx
        descK.fragmentFunction = fragK
        descK.colorAttachments[0].pixelFormat = .bgra8Unorm
        let descM = MTLRenderPipelineDescriptor()
        descM.vertexFunction = vtx
        descM.fragmentFunction = fragM
        descM.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipelineKaleido = try device.makeRenderPipelineState(descriptor: descK)
            pipelineMirror = try device.makeRenderPipelineState(descriptor: descM)
        } catch {
            return nil
        }
        super.init()
    }

    func updatePalette(seed: UInt64, baseRGB: SIMD3<Float>, accentRGB: SIMD3<Float>) {
        uniforms.seed = Float(bitPattern: UInt32(truncatingIfNeeded: seed))
        uniforms.baseColor = baseRGB
        uniforms.accentColor = accentRGB
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.resolution = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let t = Float(now - start)

        // Pull audio features (cheap reads)
        switch mode {
        case .kaleido:
            uniforms.time = t
            uniforms.level = Float(audio.level)
            uniforms.low = Float(audio.low)
            uniforms.mid = Float(audio.mid)
            uniforms.high = Float(audio.high)
            uniforms.centroid = Float(audio.centroid)
            uniforms.flux = Float(audio.flux)
            uniforms.beat = audio.beat ? 1 : 0
        case .mirror:
            mirror.time = t
            mirror.level = Float(audio.level)
            mirror.low = Float(audio.low)
            mirror.mid = Float(audio.mid)
            mirror.high = Float(audio.high)
            mirror.flux = Float(audio.flux)
            mirror.beat = audio.beat ? 1 : 0
            // Subtle audio-driven boost
            let boost = max(1.0, 1.0 + 0.6*mirror.level + 0.4*mirror.flux)
            mirror.noiseAmp = 0.008 * Float(boost)
            mirror.noiseSpeed = 0.35 * Float(boost)
        }

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        switch mode {
        case .kaleido:
            enc.setRenderPipelineState(pipelineKaleido)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<VisualUniforms>.stride, index: 0)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<VisualUniforms>.stride, index: 0)
        case .mirror:
            enc.setRenderPipelineState(pipelineMirror)
            mirror.resolution = uniforms.resolution
            mirror.seed = uniforms.seed
            enc.setVertexBytes(&mirror, length: MemoryLayout<MirrorUniforms>.stride, index: 0)
            enc.setFragmentBytes(&mirror, length: MemoryLayout<MirrorUniforms>.stride, index: 0)
            if let tex = cameraTexture { enc.setFragmentTexture(tex, index: 0) }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - SwiftUI bridge (macOS)
struct MetalVisualView: NSViewRepresentable {
    let seed: UInt64
    let baseRGB: SIMD3<Float>
    let accentRGB: SIMD3<Float>
    var mode: MetalRenderer.Mode = .mirror

    final class Coordinator {
        var renderer: MetalRenderer?
        var camera: CameraCapture?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = MetalRenderer(device: device) else {
            return view
        }
        view.device = device
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = renderer
        renderer.mode = mode
        renderer.updatePalette(seed: seed, baseRGB: baseRGB, accentRGB: accentRGB)
        // Start camera for mirror mode
        if mode == .mirror, let cam = CameraCapture(device: device) {
            cam.onTexture = { [weak renderer] tex in renderer?.cameraTexture = tex }
            cam.start()
            context.coordinator.camera = cam
        }
        context.coordinator.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.mode = mode
        context.coordinator.renderer?.updatePalette(seed: seed, baseRGB: baseRGB, accentRGB: accentRGB)
    }
}
