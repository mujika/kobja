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

// MARK: - Renderer
final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    private var start = CFAbsoluteTimeGetCurrent()

    private var uniforms = VisualUniforms(
        resolution: .zero, time: 0, seed: 1,
        level: 0, low: 0, mid: 0, high: 0, centroid: 0, flux: 0, beat: 0,
        baseColor: SIMD3<Float>(0.1, 0.3, 0.9),
        accentColor: SIMD3<Float>(0.8, 0.9, 1.0)
    )

    private var audio: AudioAnalyzer = .shared

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        // Pipeline
        guard
            let lib = try? device.makeDefaultLibrary(bundle: .main),
            let vtx = lib.makeFunction(name: "fullScreenVertex"),
            let frag = lib.makeFunction(name: "kaleidoFragment")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vtx
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
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
        uniforms.time = t
        uniforms.level = Float(audio.level)
        uniforms.low = Float(audio.low)
        uniforms.mid = Float(audio.mid)
        uniforms.high = Float(audio.high)
        uniforms.centroid = Float(audio.centroid)
        uniforms.flux = Float(audio.flux)
        uniforms.beat = audio.beat ? 1 : 0

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<VisualUniforms>.stride, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<VisualUniforms>.stride, index: 0)
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

    final class Coordinator {
        var renderer: MetalRenderer?
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
        renderer.updatePalette(seed: seed, baseRGB: baseRGB, accentRGB: accentRGB)
        context.coordinator.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.updatePalette(seed: seed, baseRGB: baseRGB, accentRGB: accentRGB)
    }
}
