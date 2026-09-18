import AppKit
import Combine
import FoldCore

enum InputMode: String, CaseIterable, Identifiable {
    case real = "真实开合"
    case simulated = "滑杆模拟"
    var id: Self { self }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published var inputMode: InputMode = .real {
        didSet { smoother.reset(); captureError = nil }
    }
    @Published var simulatedAngle = 110.0
    @Published var referenceAngle: Double {
        didSet { UserDefaults.standard.set(referenceAngle, forKey: "referenceAngle") }
    }
    @Published var strength: Double {
        didSet { UserDefaults.standard.set(strength, forKey: "strength") }
    }
    @Published private(set) var rawAngle: Double?
    @Published private(set) var displayedAngle = 110.0
    @Published private(set) var sensorStatus = "正在查找传感器…"
    @Published private(set) var captureStatus = "效果已关闭"
    @Published private(set) var permissionGranted = false
    @Published private(set) var effect = FoldEffect.identity
    @Published private(set) var fps = 0.0
    @Published private(set) var overlayVisible = false
    @Published var shortcutAvailable = true
    var onStatusChange: (() -> Void)?

    private let sensor = LidSensor()
    private var lastSensorReading = Date.distantPast
    private var lastTick = Date()
    private var smoother = AngleSmoother()
    private var timer: Timer?
    private var screen: NSScreen?
    private var screenID: CGDirectDisplayID?
    private var screenSignature = ""
    private var lastDisplayCheck = Date.distantPast
    private var displayAvailable = false
    private var mirrored = false
    private var systemAwake = true
    private var displayAwake = true
    private var sessionActive = true
    private var screenLocked = false
    private var resumeAfter = Date.distantPast
    private var captureError: String?
    private var menuOpen = false
    private var renderer: FoldRenderer?
    private var overlay: OverlayWindow?
    private var capture: DesktopCapture?
    private var captureTask: Task<Void, Never>?
    private var captureStarted = Date.distantPast
    private var generation = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let savedReference = UserDefaults.standard.object(forKey: "referenceAngle") as? Double ?? 110
        let savedStrength = UserDefaults.standard.object(forKey: "strength") as? Double ?? 1
        referenceAngle = savedReference.isFinite ? min(150, max(30, savedReference)) : 110
        strength = savedStrength.isFinite ? min(1, max(0, savedStrength)) : 1
        permissionGranted = CGPreflightScreenCaptureAccess()
    }

    func start() {
        sensor.onReading = { [weak self] angle, message in
            DispatchQueue.main.async {
                guard let self else { return }
                if let angle {
                    if Date().timeIntervalSince(self.lastSensorReading) > 0.5 { self.smoother.reset() }
                    if self.rawAngle != angle { self.rawAngle = angle }
                    self.lastSensorReading = Date()
                }
                if self.sensorStatus != message { self.sensorStatus = message }
            }
        }
        sensor.start()
        installObservers()
        refreshDisplay()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        captureError = nil
        smoother.reset()
        if value {
            permissionGranted = CGPreflightScreenCaptureAccess()
            if !permissionGranted { permissionGranted = CGRequestScreenCaptureAccess() }
        } else {
            stopCapture()
        }
        tick()
        onStatusChange?()
    }

    func retry() {
        captureError = nil
        permissionGranted = CGPreflightScreenCaptureAccess()
        if !permissionGranted { permissionGranted = CGRequestScreenCaptureAccess() }
        resumeAfter = Date().addingTimeInterval(0.3)
        stopCapture()
        tick()
    }

    func anchorHere() {
        let angle = inputMode == .real ? rawAngle : simulatedAngle
        guard let angle else { return }
        referenceAngle = min(150, max(30, angle))
        smoother.reset()
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func setMenuOpen(_ value: Bool) {
        menuOpen = value
        // 原生菜单不参与变形，展开菜单时临时透出真实桌面，确保菜单可见且点击对齐。
        if value { overlay?.alphaValue = 0 }
        else if overlayVisible { overlay?.reveal() }
    }

    func shutdown() {
        enabled = false
        timer?.invalidate()
        timer = nil
        stopCapture()
        sensor.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func refreshDisplay() {
        lastDisplayCheck = Date()
        let builtIn = NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        let id = builtIn?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        let signature = "\(id ?? 0):\(builtIn?.frame ?? .zero):\(builtIn?.backingScaleFactor ?? 0)"
        if signature != screenSignature { stopCapture(); screenSignature = signature }
        screen = builtIn
        screenID = id
        displayAvailable = id.map { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 } ?? false
        mirrored = id.map { CGDisplayIsInMirrorSet($0) != 0 } ?? false
    }

    private func tick() {
        let now = Date()
        let dt = max(0, now.timeIntervalSince(lastTick))
        lastTick = now
        if now.timeIntervalSince(lastDisplayCheck) > 0.5 { refreshDisplay() }
        let sensorAvailable = now.timeIntervalSince(lastSensorReading) < 1
        let target = inputMode == .simulated ? simulatedAngle : (rawAngle ?? referenceAngle)
        let smoothed = smoother.update(target: target, deltaTime: dt) ?? referenceAngle
        if abs(displayedAngle - smoothed) > 0.005 { displayedAngle = smoothed }

        var availability = EffectAvailability()
        availability.enabled = enabled
        availability.permission = permissionGranted
        availability.sessionActive = systemAwake && displayAwake && sessionActive && !screenLocked && now >= resumeAfter
        availability.displayAvailable = displayAvailable
        availability.mirrored = mirrored
        availability.lidClosed = sensorAvailable && (rawAngle ?? 180) <= 5
        availability.sensorAvailable = sensorAvailable
        availability.simulated = inputMode == .simulated
        availability.captureFailed = captureError != nil
        if let reason = availability.pauseReason {
            stopCapture()
            setStatus(reason == .captureFailed ? captureError! : reason.rawValue)
            if effect != .identity { effect = .identity }
            return
        }
        let settings = FoldSettings(referenceAngle: referenceAngle, strength: strength)
        // 已回到参考平面时立即透出真实桌面，不让平滑尾部留下模糊覆盖。
        let next = target >= referenceAngle ? FoldEffect.identity : (FoldEffect.calculate(angle: smoothed, settings: settings) ?? .identity)
        if effect != next { effect = next }
        guard next.isVisible else {
            stopCapture()
            setStatus("已就绪 · 合至 \(Int(referenceAngle))° 以下开始")
            return
        }
        if capture == nil, captureTask == nil { beginCapture() }
        renderer?.effect = next
        guard let capture else { return }
        let health = capture.mailbox.health
        if health.frames == 0 && now.timeIntervalSince(captureStarted) > 5 {
            failCapture("等待桌面首帧超时，请检查屏幕录制权限后重试")
        } else if health.frames > 0 && now.timeIntervalSince(health.lastActivity) > 5 {
            failCapture("桌面捕获失去响应，已撤下效果，请重试")
        }
    }

    private func setStatus(_ status: String) {
        if captureStatus != status { captureStatus = status; onStatusChange?() }
    }

    private func beginCapture() {
        guard let screen, let screenID else { return }
        do {
            if renderer == nil { renderer = try FoldRenderer() }
            guard let renderer else { return }
            renderer.reset()
            let window = OverlayWindow(screen: screen, renderer: renderer)
            overlay = window
            let session = DesktopCapture()
            capture = session
            captureStarted = Date()
            generation += 1
            let token = generation
            renderer.mailbox = session.mailbox
            renderer.effect = effect
            renderer.onFirstPresentation = { [weak self, weak window] in
                guard let self, self.generation == token, self.enabled else { return }
                if !self.menuOpen { window?.reveal() }
                self.overlayVisible = true
                self.setStatus("实时景深 · 内置屏幕")
            }
            renderer.onFPS = { [weak self] fps in self?.fps = fps }
            renderer.onFailure = { [weak self] message in
                guard let self, self.generation == token else { return }
                self.failCapture(message)
            }
            session.onFailure = { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.failCapture(message)
                }
            }
            // alpha=0 的窗口先注册到 WindowServer；获得首帧并完成 GPU 渲染后才揭示。
            window.prepare()
            setStatus("正在准备实时桌面…")
            let scale = screen.backingScaleFactor
            let width = Int(screen.frame.width * scale)
            let height = Int(screen.frame.height * scale)
            captureTask = Task { [weak self] in
                do {
                    try await session.start(displayID: screenID, pixelWidth: width, pixelHeight: height)
                    guard let self, self.generation == token else { await session.stop(); return }
                    self.captureTask = nil
                } catch {
                    guard let self, self.generation == token else { return }
                    self.captureTask = nil
                    self.permissionGranted = CGPreflightScreenCaptureAccess()
                    self.failCapture(error.localizedDescription)
                }
            }
        } catch { failCapture(error.localizedDescription) }
    }

    private func failCapture(_ message: String) {
        captureError = message
        stopCapture()
        setStatus(message)
    }

    private func stopCapture() {
        guard capture != nil || captureTask != nil || overlay != nil else { return }
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        overlay?.dismiss()
        overlay = nil
        overlayVisible = false
        fps = 0
        let previous = capture
        capture = nil
        Task { await previous?.stop() }
    }

    private func installObservers() {
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (AppModel) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                    self.stopCapture()
                    self.smoother.reset()
                    self.tick()
                }
            }
            observers.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemAwake = false }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemAwake = true; $0.resume() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAwake = false }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAwake = true; $0.resume() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionActive = true; $0.resume() }
        // macOS 的锁屏通知补足 session 通知；唤醒仍需等待屏幕和新帧可用。
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false; $0.resume() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refreshDisplay(); $0.resume() }
    }

    private func resume() {
        captureError = nil
        resumeAfter = Date().addingTimeInterval(0.5)
        lastDisplayCheck = .distantPast
        permissionGranted = CGPreflightScreenCaptureAccess()
    }
}
