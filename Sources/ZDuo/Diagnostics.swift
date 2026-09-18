import AppKit
import CoreText
import CoreVideo
import FoldCore

enum Diagnostics {
    static func sensor() {
        print("ZDuo diagnostics")
        print("Screen recording permission:", CGPreflightScreenCaptureAccess() ? "granted" : "not granted")
        let reader = LidSensor()
        let semaphore = DispatchSemaphore(value: 0)
        reader.onReading = { angle, status in
            print("Sensor:", status, "angle:", angle.map { "\($0)°" } ?? "unavailable")
            semaphore.signal()
        }
        reader.start()
        if semaphore.wait(timeout: .now() + 3) == .timedOut { print("Sensor: timed out") }
        reader.stop()
    }

    static func render(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = try fixture()
        let renderer = try FoldRenderer()
        let angles = [110.0, 85, 60, 30, 15]
        var identityError = 0
        var closingAt60: [UInt8] = []
        for angle in angles {
            let effect = FoldEffect.calculate(angle: angle, settings: FoldSettings())!
            let url = directory.appendingPathComponent("angle-\(Int(angle)).png")
            let bytes = try renderer.renderDiagnostic(frame: frame, effect: effect, to: url)
            if angle == 60 { closingAt60 = bytes }
            if angle == 110 {
                CVPixelBufferLockBaseAddress(frame, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
                let source = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(frame)
                for y in 0..<CVPixelBufferGetHeight(frame) {
                    for x in 0..<(CVPixelBufferGetWidth(frame) * 4) {
                        identityError = max(identityError, abs(Int(source[y * stride + x]) - Int(bytes[y * CVPixelBufferGetWidth(frame) * 4 + x])))
                    }
                }
            }
            guard bytes.enumerated().filter({ $0.offset % 4 == 3 }).allSatisfy({ $0.element == 255 }) else {
                throw CaptureError.message("渲染出现透明空洞")
            }
            print("Rendered \(Int(angle))° → \(url.path)")
        }
        guard identityError <= 1 else { throw CaptureError.message("参考平面并非恒等变换，最大通道误差 \(identityError)") }
        // 反向回到同一角度应得到完全相同的画面，与此前开合方向无关。
        let same = FoldEffect.calculate(angle: 60, settings: FoldSettings())!
        let repeatURL = directory.appendingPathComponent("angle-60-reverse.png")
        let repeated = try renderer.renderDiagnostic(frame: frame, effect: same, to: repeatURL)
        guard repeated == closingAt60 else { throw CaptureError.message("反向回到相同角度时渲染不一致") }
        print("PASS: identity max channel error = \(identityError); all frames opaque; deterministic reverse rendering")
        print("GPU:", renderer.device.name)
    }

    private static func fixture() throws -> CVPixelBuffer {
        let width = 960, height = 600
        var frame: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &frame) == kCVReturnSuccess, let frame else {
            throw CaptureError.message("无法创建测试画面")
        }
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(frame), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(frame),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw CaptureError.message("无法绘制测试画面")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.045, green: 0.06, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 0.2, green: 0.28, blue: 0.4, alpha: 0.5))
        context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 40) {
            context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: 40) {
            context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()
        func text(_ value: String, x: Double, y: Double, size: Double, color: CGColor) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: CTFontCreateWithName("Helvetica" as CFString, size, nil),
                .foregroundColor: color
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        let white = CGColor(gray: 0.95, alpha: 1)
        text("ZDuo / Fixed plane", x: 48, y: 76, size: 32, color: white)
        text("TOP  /  The screen moves. The content stays.", x: 48, y: 110, size: 16, color: white)
        let colors: [CGColor] = [
            CGColor(red: 0.39, green: 0.56, blue: 0.91, alpha: 1),
            CGColor(red: 0.56, green: 0.40, blue: 0.83, alpha: 1),
            CGColor(red: 0.18, green: 0.66, blue: 0.61, alpha: 1)
        ]
        for index in 0..<3 {
            let x = 48 + index * 294
            context.setFillColor(colors[index])
            context.addPath(CGPath(roundedRect: CGRect(x: x, y: 160, width: 276, height: 280), cornerWidth: 20, cornerHeight: 20, transform: nil))
            context.fillPath()
            text(["01  Focus", "02  Distance", "03  Hinge"][index], x: Double(x + 20), y: 206, size: 21, color: white)
            // 重复细线用于肉眼比较顶部与底部的模糊差异。
            context.setStrokeColor(white)
            for y in stride(from: 240, through: 410, by: 14) {
                context.move(to: CGPoint(x: x + 20, y: y)); context.addLine(to: CGPoint(x: x + 252, y: y))
            }
            context.strokePath()
        }
        text("BOTTOM / HINGE ANCHOR", x: 48, y: 555, size: 20, color: white)
        context.setFillColor(CGColor(red: 0.65, green: 0.78, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 596, width: width, height: 4))
        return frame
    }
}
