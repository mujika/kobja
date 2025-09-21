import Foundation
import AVFoundation
import Metal

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var textureCache: CVMetalTextureCache?
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "camera.capture.queue")

    var onTexture: ((MTLTexture) -> Void)?

    init?(device: MTLDevice) {
        self.device = device
        super.init()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else { return nil }
        configureSession()
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        guard let cam = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video) { conn.videoOrientation = .portrait }
        session.commitConfiguration()
    }

    func start() { if !session.isRunning { session.startRunning() } }
    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer), let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(pixel)
        let h = CVPixelBufferGetHeight(pixel)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, .bgra8Unorm, w, h, 0, &cvTex)
        if status != kCVReturnSuccess { return }
        if let tex = CVMetalTextureGetTexture(cvTex!) { onTexture?(tex) }
    }
}

