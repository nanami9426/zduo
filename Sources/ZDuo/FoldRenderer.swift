import AppKit
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import FoldCore

struct FoldUniforms {
    var closure: Float = 0
    var blur: Float = 0
    var projectionDepth: Float = 0
    var sourceHeight: Float = 1
    var width: Float = 0
    var height: Float = 0
}

final class FoldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let projectionPipeline: MTLRenderPipelineState
    private let scale: MPSImageLanczosScale
    private var textureCache: CVMetalTextureCache!
    private var cvTexture: CVMetalTexture?
    private var pixelBuffer: CVPixelBuffer?
    private var pendingFrame: CVPixelBuffer?
    private var sharp: MTLTexture?
    private var projected: MTLTexture?
    private var reduced: MTLTexture?
    private var backdrop: MTLTexture?
    private var backdropFilter: MPSImageGaussianBlur?
    private var backdropNeedsUpdate = true
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
        descriptor.fragmentFunction = library.makeFunction(name: "foldProjectionFragment")
        projectionPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
        projected = nil
        reduced = nil
        backdrop = nil
        backdropFilter = nil
        backdropNeedsUpdate = true
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
           previous.closure == uniforms.closure, previous.blur == uniforms.blur,
           previous.width == uniforms.width, previous.height == uniforms.height, firstPresented { return }
        guard frame != nil || sharp != nil else { return }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer() else { return }
        do {
            if let frame { try prepare(frame: frame); pendingFrame = nil }
            try prepareProjection(command: command, uniforms: uniforms)
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
        backdropNeedsUpdate = false
    }

    private func makeUniforms() -> FoldUniforms {
        FoldUniforms(closure: Float(effect.closure), blur: Float(effect.blur),
                     projectionDepth: Float(effect.projectionDepth), sourceHeight: Float(effect.sourceHeight),
                     width: Float(pointSize.width), height: Float(pointSize.height))
    }

    private func prepare(frame: CVPixelBuffer) throws {
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
        backdropNeedsUpdate = true
    }

    private func prepareProjection(command: MTLCommandBuffer, uniforms: FoldUniforms) throws {
        guard let sharp else { throw CaptureError.message("缺少桌面帧") }
        let width = sharp.width, height = sharp.height
        if projected?.width != width || projected?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw CaptureError.message("无法分配透视纹理")
            }
            projected = texture
        }

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
            guard let backdrop = device.makeTexture(descriptor: descriptor) else {
                throw CaptureError.message("无法分配侧边背景纹理")
            }
            self.backdrop = backdrop
            backdropNeedsUpdate = true
            blurred = try (0..<3).map { _ in
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw CaptureError.message("GPU 内存不足")
                }
                return texture
            }
        }
        // 恢复 22:44 版本的 4 / 12 / 28 pt 档位，保留屏幕空间散射和缩放一致性。
        let pixelScale = Float(reducedHeight) / Float(max(1, pointSize.height))
        let sigmas = [Float(4), 12, 28].map { max(0.1, $0 * pixelScale) }
        if filters.map(\.sigma) != sigmas {
            filters = sigmas.map {
                let filter = MPSImageGaussianBlur(device: device, sigma: $0)
                filter.edgeMode = .clamp
                return filter
            }
        }
        let backdropSigma = max(0.1, 36 * pixelScale)
        if backdropFilter?.sigma != backdropSigma {
            let filter = MPSImageGaussianBlur(device: device, sigma: backdropSigma)
            filter.edgeMode = .clamp
            backdropFilter = filter
            backdropNeedsUpdate = true
        }
        guard let projected, let reduced, let backdrop, let backdropFilter else {
            throw CaptureError.message("缺少磨砂纹理")
        }
        // 图外背景先独立做宽模糊，不再把桌面边缘的一列文字拉满空白区域。
        // 只在新捕获帧或尺寸变化时更新；下方继续复用 reduced 作为屏幕空间散射的临时纹理。
        if backdropNeedsUpdate {
            scale.encode(commandBuffer: command, sourceTexture: sharp, destinationTexture: reduced)
            backdropFilter.encode(commandBuffer: command, sourceTexture: reduced, destinationTexture: backdrop)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = projected
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw CaptureError.message("无法创建透视渲染指令")
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(projectionPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.setFragmentTexture(sharp, index: 0)
        encoder.setFragmentTexture(backdrop, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // 先透视后散射，模糊半径才属于物理屏幕，合盖时不会被拉成长条。
        // 有新帧或角度变化才重算；纹理和 MPS kernel 复用，模糊仍限制在 1280 px 内。
        scale.encode(commandBuffer: command, sourceTexture: projected, destinationTexture: reduced)
        for index in 0..<3 {
            filters[index].encode(commandBuffer: command, sourceTexture: reduced, destinationTexture: blurred[index])
        }
    }

    private func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, uniforms: FoldUniforms) throws {
        guard let projected, blurred.count == 3, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw CaptureError.message("无法创建 GPU 渲染指令")
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.setFragmentTexture(projected, index: 0)
        for index in 0..<3 { encoder.setFragmentTexture(blurred[index], index: index + 1) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// 使用自建测试图离屏渲染，可在未授权屏幕录制时检验真实 GPU shader。
    func renderDiagnostic(frame: CVPixelBuffer, effect: FoldEffect, to url: URL,
                          materialEnabled: Bool = true) throws -> [UInt8] {
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
        try prepare(frame: frame)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        var uniforms = makeUniforms()
        // 几何检查关闭材质后与坐标色卡对照，避免模糊、反射掩盖逆投影错误。
        if !materialEnabled { uniforms.blur = 0 }
        try prepareProjection(command: command, uniforms: uniforms)
        try encode(pass: pass, command: command, uniforms: uniforms)
        command.commit()
        backdropNeedsUpdate = false
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
