import AppKit
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import FoldCore

struct FoldUniforms {
    var closure: Float = 0
    var blur: Float = 0
    var width: Float = 0
    var height: Float = 0
}

final class FoldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let scale: MPSImageLanczosScale
    private var textureCache: CVMetalTextureCache!
    private var cvTexture: CVMetalTexture?
    private var pixelBuffer: CVPixelBuffer?
    private var pendingFrame: CVPixelBuffer?
    private var sharp: MTLTexture?
    private var reduced: MTLTexture?
    private var blurred: [MTLTexture] = []
    private var filters: [MPSImageGaussianBlur] = []
    private let inFlight = DispatchSemaphore(value: 3)
    private var lastUniforms: FoldUniforms?
    private var firstPresented = false
    private var presentedCount = 0
    private var fpsStart = Date()
    private var generation = 0

    var mailbox: FrameMailbox?
    var effect = FoldEffect.identity
    var pointSize = CGSize(width: 1280, height: 832)
    var onFirstPresentation: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onFPS: ((Double) -> Void)?

    init(makeDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device = makeDevice, let queue = device.makeCommandQueue() else {
            throw CaptureError.message("Metal GPU 不可用")
        }
        self.device = device
        self.commandQueue = queue
        // .app 从 Resources 读取；swift run / 测试命令从 SwiftPM 的资源 bundle 读取。
        guard let url = Bundle.main.url(forResource: "Fold", withExtension: "metal")
                ?? Bundle.module.url(forResource: "Fold", withExtension: "metal") else {
            throw CaptureError.message("找不到渲染资源 Fold.metal")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        scale = MPSImageLanczosScale(device: device)
        super.init()
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            throw CaptureError.message("无法创建画面纹理缓存")
        }
    }

    func reset() {
        generation += 1
        mailbox = nil
        pixelBuffer = nil
        pendingFrame = nil
        cvTexture = nil
        sharp = nil
        reduced = nil
        blurred = []
        filters = []
        lastUniforms = nil
        firstPresented = false
        presentedCount = 0
        fpsStart = Date()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        if let latest = mailbox?.takeLatest() { pendingFrame = latest }
        let frame = pendingFrame
        let uniforms = makeUniforms()
        if frame == nil, let previous = lastUniforms,
           previous.closure == uniforms.closure, previous.blur == uniforms.blur, firstPresented { return }
        guard frame != nil || sharp != nil else { return }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer() else { return }
        do {
            if let frame { try prepare(frame: frame, command: command); pendingFrame = nil }
            try encode(pass: pass, command: command, uniforms: uniforms)
        } catch {
            onFailure?(error.localizedDescription)
            return
        }
        lastUniforms = uniforms
        command.present(drawable)
        // CVMetalTexture 的拥有者也保留到 GPU 完成，避免 IOSurface 被下一帧提前复用。
        let retainedBuffer = pixelBuffer
        let retainedTexture = cvTexture
        let isFirst = !firstPresented
        let renderGeneration = generation
        firstPresented = true
        command.addCompletedHandler { [weak self, inFlight] buffer in
            withExtendedLifetime((retainedBuffer, retainedTexture)) {}
            inFlight.signal()
            DispatchQueue.main.async {
                guard let self, self.generation == renderGeneration else { return }
                if buffer.status == .error {
                    self.onFailure?(buffer.error?.localizedDescription ?? "GPU 渲染失败")
                } else {
                    if isFirst { self.onFirstPresentation?() }
                    self.presentedCount += 1
                    let elapsed = Date().timeIntervalSince(self.fpsStart)
                    if elapsed >= 1 {
                        self.onFPS?(Double(self.presentedCount) / elapsed)
                        self.fpsStart = Date()
                        self.presentedCount = 0
                    }
                }
            }
        }
        submitted = true
        command.commit()
    }

    private func makeUniforms() -> FoldUniforms {
        FoldUniforms(closure: Float(effect.closure), blur: Float(effect.blur),
                     width: Float(pointSize.width), height: Float(pointSize.height))
    }

    private func prepare(frame: CVPixelBuffer, command: MTLCommandBuffer) throws {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        var reference: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, frame, nil,
                                                              .bgra8Unorm, width, height, 0, &reference)
        guard result == kCVReturnSuccess, let reference, let texture = CVMetalTextureGetTexture(reference) else {
            throw CaptureError.message("无法读取桌面帧纹理")
        }
        pixelBuffer = frame
        cvTexture = reference
        sharp = texture

        let reducedWidth = min(1280, width)
        let reducedHeight = max(1, Int(Double(height) * Double(reducedWidth) / Double(width)))
        if reduced?.width != reducedWidth || reduced?.height != reducedHeight {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: reducedWidth, height: reducedHeight, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let reduced = device.makeTexture(descriptor: descriptor) else {
                throw CaptureError.message("无法分配模糊纹理")
            }
            self.reduced = reduced
            blurred = try (0..<3).map { _ in
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw CaptureError.message("GPU 内存不足")
                }
                return texture
            }
            let pixelScale = Float(reducedHeight) / Float(max(1, pointSize.height))
            filters = [Float(4), 12, 28].map {
                let filter = MPSImageGaussianBlur(device: device, sigma: max(0.1, $0 * pixelScale))
                filter.edgeMode = .clamp
                return filter
            }
        }
        guard let reduced else { return }
        // 每个捕获帧只做一次模糊；角度更新只重投影和混合，降低 60 Hz 渲染负担。
        scale.encode(commandBuffer: command, sourceTexture: texture, destinationTexture: reduced)
        for index in 0..<3 {
            filters[index].encode(commandBuffer: command, sourceTexture: reduced, destinationTexture: blurred[index])
        }
    }

    private func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, uniforms: FoldUniforms) throws {
        guard let sharp, blurred.count == 3, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw CaptureError.message("无法创建 GPU 渲染指令")
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.setFragmentTexture(sharp, index: 0)
        for index in 0..<3 { encoder.setFragmentTexture(blurred[index], index: index + 1) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// 使用自建测试图离屏渲染，可在未授权屏幕录制时检验真实 GPU shader。
    func renderDiagnostic(frame: CVPixelBuffer, effect: FoldEffect, to url: URL) throws -> [UInt8] {
        self.effect = effect
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        pointSize = CGSize(width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let output = device.makeTexture(descriptor: descriptor),
              let command = commandQueue.makeCommandBuffer() else { throw CaptureError.message("GPU 不可用") }
        try prepare(frame: frame, command: command)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try encode(pass: pass, command: command, uniforms: makeUniforms())
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? CaptureError.message("GPU 检查失败") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureError.message("无法导出检查图")
        }
        try png.write(to: url)
        return bytes
    }
}
