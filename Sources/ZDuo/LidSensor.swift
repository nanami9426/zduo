import Foundation
import IOKit.hid
import FoldCore

final class LidSensor {
    private let queue = DispatchQueue(label: "app.zduo.lid", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var lastDiscovery = Date.distantPast
    var onReading: ((Double?, String) -> Void)?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            disconnect()
        }
    }

    private func disconnect() {
        if let device { IOHIDDeviceClose(device, 0) }
        if let manager { IOHIDManagerClose(manager, 0) }
        device = nil
        manager = nil
    }

    private func discover() -> String? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        // 只匹配铰链传感器，避免打开键盘、鼠标或请求输入监控权限。
        let match: [String: Int] = [
            kIOHIDVendorIDKey: 0x05ac,
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8a
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let result = IOHIDManagerOpen(manager, 0)
        guard result == kIOReturnSuccess else {
            IOHIDManagerClose(manager, 0)
            return "传感器打开失败（\(String(format: "0x%08x", result))）"
        }
        self.manager = manager
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            disconnect()
            return "未找到铰链传感器"
        }
        for candidate in devices {
            if IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess {
                self.device = candidate
                return nil
            }
        }
        disconnect()
        return "这台 Mac 没有可读取的铰链传感器"
    }

    private func poll() {
        if device == nil {
            guard Date().timeIntervalSince(lastDiscovery) >= 1 else { return }
            lastDiscovery = Date()
            if let message = discover() { onReading?(nil, message); return }
        }
        guard let device else { return }
        var bytes = [UInt8](repeating: 0, count: 8)
        var count = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &count)
        if result == kIOReturnSuccess, let angle = LidReport.decode(Array(bytes.prefix(max(0, min(count, 8))))) {
            onReading?(angle, "已连接 · 30 Hz 轮询")
        } else {
            onReading?(nil, "传感器读取失败，正在重连")
            disconnect()
        }
    }
}
