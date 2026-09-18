import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// 采集线程只保存最新一帧，渲染线程按需取走，防止主线程忙时堆积画面。
final class FrameMailbox {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var activity = Date()
    private var frames = 0

    func receive(_ buffer: CVPixelBuffer?) {
        lock.lock()
        activity = Date()
        if let buffer { self.buffer = buffer; frames += 1 }
        lock.unlock()
    }

    func takeLatest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let value = buffer
        buffer = nil
        return value
    }

    var health: (lastActivity: Date, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (activity, frames)
    }

    func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }
}

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let mailbox = FrameMailbox()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.zduo.capture", qos: .userInteractive)
    var onFailure: ((String) -> Void)?

    @MainActor
    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.message("找不到内置屏幕")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // 必须确认自身被排除，否则覆盖层会被再次捕获，形成无限递归。
        guard !ownApps.isEmpty else { throw CaptureError.message("暂时无法排除 ZDuo 窗口，请重试") }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false // 继续使用系统光标，避免屏幕上出现两个指针。
        config.capturesAudio = false
        config.scalesToFit = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            try? await stream.stopCapture()
            self.stream = nil
            throw error
        }
    }

    @MainActor
    func stop() async {
        let previous = stream
        stream = nil
        try? await previous?.stopCapture()
        mailbox.clear()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?("桌面捕获已停止：\(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete:
            mailbox.receive(sampleBuffer.imageBuffer)
        case .idle, .started:
            // 桌面静止时没有新图像，idle 仍是健康心跳，不能误判成捕获失败。
            mailbox.receive(nil)
        case .blank, .suspended, .stopped:
            onFailure?("屏幕暂不可捕获，已撤下效果")
        @unknown default:
            onFailure?("收到未知的屏幕捕获状态")
        }
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
