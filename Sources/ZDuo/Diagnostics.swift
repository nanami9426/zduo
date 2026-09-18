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
        let angles = [110.0, 109, 100, 85, 60, 30, 15, 8]
        var identityError = 0
        var identity: [UInt8] = []
        var closingAt60: [UInt8] = []
        for angle in angles {
            let effect = FoldEffect.calculate(angle: angle, settings: FoldSettings())!
            let url = directory.appendingPathComponent("angle-\(Int(angle)).png")
            let bytes = try renderer.renderDiagnostic(frame: frame, effect: effect, to: url)
            if angle == 60 { closingAt60 = bytes }
            if angle == 110 {
                identity = bytes
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
        let disabled = FoldEffect.calculate(angle: 15, settings: FoldSettings(strength: 0))!
        let disabledBytes = try renderer.renderDiagnostic(frame: frame, effect: disabled,
            to: directory.appendingPathComponent("zero-strength.png"))
        guard disabledBytes == identity else { throw CaptureError.message("零强度仍残留变形或材质") }
        try checkProjectionAndMaterial(renderer: renderer, directory: directory)
        try checkSideFill(renderer: renderer, directory: directory)
        print("PASS: identity max channel error = \(identityError); all frames opaque; deterministic reverse rendering; zero strength restores input")
        print("GPU:", renderer.device.name)
    }

    private static func makeFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        var frame: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &frame) == kCVReturnSuccess, let frame else {
            throw CaptureError.message("无法创建测试画面")
        }
        return frame
    }

    private static func checkProjectionAndMaterial(renderer: FoldRenderer, directory: URL) throws {
        let width = 960, height = 600
        let frame = try makeFrame(width: width, height: height)
        CVPixelBufferLockBaseAddress(frame, [])
        let pixels = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        // 红、绿分别编码参考平面的 x/y 坐标，验证 shader 的实际采样方向和 uniform 布局。
        for y in 0..<height {
            for x in 0..<width {
                let index = y * stride + x * 4
                pixels[index] = 40
                pixels[index + 1] = UInt8(((1 - (Double(y) + 0.5) / Double(height)) * 255).rounded())
                pixels[index + 2] = UInt8(((Double(x) + 0.5) / Double(width) * 255).rounded())
                pixels[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        var projectionError = 0
        for angle in [100.0, 85, 60, 30, 15, 8] {
            let effect = FoldEffect.calculate(angle: angle, settings: FoldSettings())!
            let bytes = try renderer.renderDiagnostic(frame: frame, effect: effect,
                to: directory.appendingPathComponent("coordinates-\(Int(angle)).png"), materialEnabled: false)
            for x in [width * 35 / 100, width / 2, width * 65 / 100] {
                for y in [height / 20, height / 4, height / 2, height * 3 / 4, height * 19 / 20] {
                    let source = effect.sourceCoordinate(x: (Double(x) + 0.5) / Double(width),
                        yFromHinge: 1 - (Double(y) + 0.5) / Double(height))
                    let index = (y * width + x) * 4
                    projectionError = max(projectionError, abs(Int(bytes[index + 2]) - Int((source.x * 255).rounded())),
                                          abs(Int(bytes[index + 1]) - Int((source.y * 255).rounded())))
                }
            }
        }
        guard projectionError <= 2 else { throw CaptureError.message("CPU/GPU 投影不一致，通道误差 \(projectionError)") }

        // 暗灰底图隔离材质本身，与 22:44 版本的冷灰渐变参考值比较。
        CVPixelBufferLockBaseAddress(frame, [])
        for y in 0..<height {
            for x in 0..<width {
                let index = y * stride + x * 4
                for channel in 0..<3 { pixels[index + channel] = 64 }
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let effect = FoldEffect.calculate(angle: 60, settings: FoldSettings())!
        let gray = try renderer.renderDiagnostic(frame: frame, effect: effect,
            to: directory.appendingPathComponent("frost-gray.png"))
        let row = (width * 2 / 5..<width * 3 / 5).map { Double(gray[(60 * width + $0) * 4 + 1]) }
        let mean = row.reduce(0, +) / Double(row.count)
        let variance = row.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(row.count)
        // 参考值来自旧 shader 在 64/255 灰底、60° 下的绿色通道，覆盖顶部到铰链。
        let expectedGradient: [(row: Int, mean: Double)] = [(60, 97.99), (180, 88.61), (300, 76.88), (480, 64.59), (599, 62.45)]
        var gradientError = 0.0
        for sample in expectedGradient {
            let values = (width * 2 / 5..<width * 3 / 5).map { Double(gray[(sample.row * width + $0) * 4 + 1]) }
            let rowMean = values.reduce(0, +) / Double(values.count)
            gradientError = max(gradientError, abs(rowMean - sample.mean))
        }
        guard gradientError < 1.2, variance > 0.01, variance < 2 else {
            throw CaptureError.message("旧版磨砂渐变不一致：mean error=\(gradientError), variance=\(variance)")
        }
        print("PASS: CPU/GPU projection max channel error = \(projectionError); classic frost gradient mean error = \(gradientError); top mean = \(mean), variance = \(variance)")
    }

    private static func checkSideFill(renderer: FoldRenderer, directory: URL) throws {
        let width = 960, height = 600
        let frame = try makeFrame(width: width, height: height)
        CVPixelBufferLockBaseAddress(frame, [])
        let pixels = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        // 两侧贴边细线模拟侧栏文字。旧 clamp_to_edge 会将每一条亮线横向复制到整个图外区域。
        for y in 0..<height {
            for x in 0..<width {
                let isLine = (x < 100 || x >= width - 100) && y % 20 < 3
                let index = y * stride + x * 4
                for channel in 0..<3 { pixels[index + channel] = isLine ? 235 : 32 }
                pixels[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        _ = try renderer.renderDiagnostic(frame: frame, effect: .identity,
            to: directory.appendingPathComponent("sidebar-input.png"))
        var maxSideStripe = 0.0
        // 覆盖用户截图的 118° → 108°，以及更大收窄角度；检查左右两侧，防止只修左侧。
        for angle in [108.0, 85, 60] {
            let effect = FoldEffect.calculate(angle: angle, settings: FoldSettings(referenceAngle: 118))!
            let bytes = try renderer.renderDiagnostic(frame: frame, effect: effect,
                to: directory.appendingPathComponent("sidebar-\(Int(angle)).png"))
            for x in [4, width - 5] {
                // 用邻近行估计平滑渐变，只检查高频条纹，避免把恢复的磨砂渐变误判成拖尾。
                for y in 80..<240 {
                    let value = Double(bytes[(y * width + x) * 4 + 1])
                    let above = Double(bytes[((y - 5) * width + x) * 4 + 1])
                    let below = Double(bytes[((y + 5) * width + x) * 4 + 1])
                    maxSideStripe = max(maxSideStripe, abs(value - (above + below) / 2))
                }
            }
        }
        guard maxSideStripe <= 12 else {
            throw CaptureError.message("侧边填充仍出现文字条纹，残差 \(maxSideStripe)/255")
        }
        print("PASS: side fill has no stretched text stripes; max stripe residual = \(maxSideStripe)/255")
    }

    private static func fixture() throws -> CVPixelBuffer {
        let width = 960, height = 600
        let frame = try makeFrame(width: width, height: height)
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
