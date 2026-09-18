import AppKit
import MetalKit

final class OverlayWindow: NSWindow {
    let metalView: MTKView
    let renderer: FoldRenderer
    static let effectLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
    static let controlLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    init(screen: NSScreen, renderer: FoldRenderer) {
        self.renderer = renderer
        metalView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer.device)
        // 带 screen 的 ObjC 初始化器会回调另一个 init；Swift 子类应直接调用指定初始化器。
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = Self.effectLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.autoResizeDrawable = true
        metalView.delegate = renderer
        if let layer = metalView.layer as? CAMetalLayer { layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        contentView = metalView
        renderer.pointSize = screen.frame.size
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func prepare() {
        alphaValue = 0
        orderFrontRegardless()
        metalView.isPaused = false
    }

    func reveal() { alphaValue = 1 }

    func dismiss() {
        alphaValue = 0
        metalView.isPaused = true
        orderOut(nil)
        renderer.reset()
    }
}
