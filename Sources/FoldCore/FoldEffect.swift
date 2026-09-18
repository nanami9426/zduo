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
    public let closure: Double
    public let blur: Double
    public var isVisible: Bool { closure > 0.0001 || blur > 0.0001 }

    public static let identity = FoldEffect(progress: 0, closure: 0, blur: 0)

    public static func calculate(angle: Double, settings: FoldSettings) -> FoldEffect? {
        guard angle.isFinite, (0...180).contains(angle),
              settings.referenceAngle.isFinite, (30...150).contains(settings.referenceAngle),
              settings.strength.isFinite, (0...1).contains(settings.strength) else { return nil }

        let difference = max(0, settings.referenceAngle - angle)
        let progress = min(1, difference / (settings.referenceAngle - 15))
        let eased = progress * progress * (3 - 2 * progress)
        // closure 是带强度的合盖进度，不再把物理开合重复施加为虚拟卡片旋转。
        return FoldEffect(progress: progress,
                          closure: progress * settings.strength,
                          blur: eased * settings.strength)
    }

    /// 距离铰链越远，屏幕与参考平面的距离越大，因此顶部离焦更强。
    public func blurWeight(distanceFromHinge: Double) -> Double {
        blur * (0.12 + 0.88 * min(1, max(0, distanceFromHinge)))
    }

    /// 与 shader 相同的逆投影，用于检验参考角度处恒等、铰链固定和数值稳定。
    public func sourceCoordinate(x: Double, yFromHinge: Double) -> (x: Double, y: Double) {
        // 参考 Hinge 的满高度投影（MIT，见 THIRD_PARTY_NOTICES.md）。
        // 顶部轻微收窄；从铰链向上截取原图，避免整幅桌面被压低成向后倒的卡片。
        let v = 1 - yFromHinge
        let taper = 0.30 * closure
        let q = (1 + taper) / (1 + taper * v)
        let y = cos(closure * .pi / 2 * 0.65) * (1 - v * q)
        let x = 0.5 + (x - 0.5) * q
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
        // 一度量化的小台阶需要跨帧展开；快速开合时缩短平滑，减少拖后。
        // 依据当前跟随误差连续调整，不预测未来角度，停住和反向时不会过冲。
        let motion = min(1, abs(target - previous) / 3)
        let response = motion * motion * (3 - 2 * motion)
        let timeConstant = 0.035 + (0.012 - 0.035) * response
        let weight = 1 - exp(-min(deltaTime, 0.25) / timeConstant)
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
