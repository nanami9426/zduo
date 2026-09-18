import Foundation

public struct FoldSettings: Equatable {
    public var referenceAngle: Double
    public var strength: Double

    public init(referenceAngle: Double = 110, strength: Double = 1) {
        self.referenceAngle = referenceAngle
        self.strength = strength
    }
}

public struct FoldEffect: Equatable {
    public let progress: Double
    public let rotation: Double
    public let blur: Double
    public var isVisible: Bool { rotation > 0.0001 || blur > 0.0001 }

    public static let identity = FoldEffect(progress: 0, rotation: 0, blur: 0)

    public static func calculate(angle: Double, settings: FoldSettings) -> FoldEffect? {
        guard angle.isFinite, (0...180).contains(angle),
              settings.referenceAngle.isFinite, (30...150).contains(settings.referenceAngle),
              settings.strength.isFinite, (0...1).contains(settings.strength) else { return nil }

        let difference = max(0, settings.referenceAngle - angle)
        let progress = min(1, difference / (settings.referenceAngle - 15))
        let eased = progress * progress * (3 - 2 * progress)
        // 限制补偿角度，防止接近合盖时投影奇点导致翻转。离焦继续随开合增强。
        return FoldEffect(progress: progress,
                          rotation: min(55, difference) * .pi / 180 * settings.strength,
                          blur: eased * settings.strength)
    }

    /// 距离铰链越远，屏幕与参考平面的距离越大，因此顶部离焦更强。
    public func blurWeight(distanceFromHinge: Double) -> Double {
        blur * (0.12 + 0.88 * min(1, max(0, distanceFromHinge)))
    }

    /// 与 shader 相同的逆投影，用于检验参考角度处恒等、铰链固定和数值稳定。
    public func sourceCoordinate(x: Double, yFromHinge: Double) -> (x: Double, y: Double) {
        let eyeDistance = 2.4
        let eyeHeight = 0.55
        let sine = sin(rotation)
        let denominator = max(0.2, eyeDistance * cos(rotation) + (eyeHeight - yFromHinge) * sine)
        let y = yFromHinge * eyeDistance / denominator
        let x = 0.5 + (x - 0.5) * (eyeDistance + y * sine) / eyeDistance
        return (x, y)
    }
}

public struct AngleSmoother {
    public private(set) var value: Double?
    public init() {}

    public mutating func reset() { value = nil }

    public mutating func update(target: Double, deltaTime: Double) -> Double? {
        guard target.isFinite, (0...180).contains(target), deltaTime.isFinite, deltaTime >= 0 else {
            return nil
        }
        guard let previous = value else { value = target; return target }
        // 按时间而不是帧数平滑，在 30 Hz 采样和 60 Hz 渲染之间消除一度量化的跳动。
        let weight = 1 - exp(-min(deltaTime, 0.25) / 0.055)
        let next = previous + (target - previous) * weight
        value = abs(next - target) < 0.01 ? target : next
        return value
    }
}

public enum PauseReason: String, Equatable {
    case disabled = "效果已关闭"
    case permission = "需要屏幕录制权限"
    case sessionInactive = "屏幕已锁定或正在睡眠"
    case noDisplay = "内置屏幕不可用"
    case mirrored = "镜像显示时暂停效果"
    case lidClosed = "屏幕已合拢"
    case sensorUnavailable = "角度传感器不可用，可切换模拟模式"
    case captureFailed = "桌面捕获中断，请重试"
}

public struct EffectAvailability {
    public var enabled = false
    public var permission = false
    public var sessionActive = true
    public var displayAvailable = true
    public var mirrored = false
    public var lidClosed = false
    public var sensorAvailable = true
    public var simulated = false
    public var captureFailed = false

    public init() {}

    public var pauseReason: PauseReason? {
        if !enabled { return .disabled }
        if !sessionActive { return .sessionInactive }
        if !displayAvailable { return .noDisplay }
        if mirrored { return .mirrored }
        if lidClosed { return .lidClosed }
        if !permission { return .permission }
        if !simulated && !sensorAvailable { return .sensorUnavailable }
        if captureFailed { return .captureFailed }
        return nil
    }
}

public enum LidReport {
    public static func decode(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3, bytes[0] == 1 else { return nil }
        let angle = Int(bytes[1]) | (Int(bytes[2]) << 8)
        return (0...180).contains(angle) ? Double(angle) : nil
    }
}
