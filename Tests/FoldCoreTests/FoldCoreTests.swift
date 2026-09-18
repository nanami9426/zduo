import Testing
@testable import FoldCore

@Suite("Fold effects and lifecycle")
struct FoldCoreTests {
    @Test func testReferenceAndOpenAnglesAreIdentity() throws {
        for angle in [110.0, 117, 150, 180] {
            let effect = try #require(FoldEffect.calculate(angle: angle, settings: FoldSettings()))
            #expect(effect == .identity)
            #expect(!(effect.isVisible))
            let source = effect.sourceCoordinate(x: 0.2, yFromHinge: 0.8)
            #expect(abs((source.x) - (0.2)) <= 0.000001)
            #expect(abs((source.y) - (0.8)) <= 0.000001)
        }
    }

    @Test func testClosingMonotonicallyIncreasesDepth() throws {
        var previous = FoldEffect.identity
        for angle in stride(from: 110.0, through: 0, by: -0.5) {
            let effect = try #require(FoldEffect.calculate(angle: angle, settings: FoldSettings()))
            #expect(effect.blur >= previous.blur)
            #expect(effect.closure >= previous.closure)
            #expect(effect.closure <= 1)
            #expect(effect.blur <= 1)
            previous = effect
        }
    }

    @Test func testDepthIncreasesAwayFromHinge() throws {
        let effect = try #require(FoldEffect.calculate(angle: 55, settings: FoldSettings()))
        #expect(effect.blurWeight(distanceFromHinge: 0) < effect.blurWeight(distanceFromHinge: 0.5))
        #expect(effect.blurWeight(distanceFromHinge: 0.5) < effect.blurWeight(distanceFromHinge: 1))
        #expect(effect.blurWeight(distanceFromHinge: 1) == effect.blur)
    }

    @Test func testHingeRemainsFixedAndProjectionNeverFlips() throws {
        for angle in stride(from: 110.0, through: 0, by: -1) {
            let effect = try #require(FoldEffect.calculate(angle: angle, settings: FoldSettings()))
            let bottom = effect.sourceCoordinate(x: 0.1, yFromHinge: 0)
            #expect(abs((bottom.x) - (0.1)) <= 0.000001)
            #expect(bottom.y == 0)
            let top = effect.sourceCoordinate(x: 0.1, yFromHinge: 1)
            #expect(top.x.isFinite && top.y.isFinite)
            #expect(top.y > 0.5 && top.y <= 1)
        }
    }

    @Test func testContentFillsHeightWithoutBackwardCardCollapse() throws {
        var previousTop = 1.0
        for angle in stride(from: 110.0, through: 15, by: -1) {
            let effect = try #require(FoldEffect.calculate(angle: angle, settings: FoldSettings()))
            let top = effect.sourceCoordinate(x: 0.5, yFromHinge: 1)
            // 顶部采样逐渐下移到原图内部；旧投影会采到图外并制造一大片顶部填充。
            #expect(top.y <= previousTop)
            previousTop = top.y
            var previousY = -1.0
            for row in 0...100 {
                let point = effect.sourceCoordinate(x: 0.5, yFromHinge: Double(row) / 100)
                #expect(point.y >= 0 && point.y <= 1)
                #expect(point.y > previousY)
                previousY = point.y
            }
            // 每侧最多约 11.54% 的收窄，不允许退化为很窄的卡片。
            let edge = effect.sourceCoordinate(x: 0.5 - 0.5 / (1 + 0.30 * effect.closure), yFromHinge: 1)
            #expect(abs(edge.x) < 0.000001)
        }
    }

    @Test func testSameAngleHasSameEffectInEitherDirection() {
        let closing = stride(from: 110.0, through: 15, by: -5).map { FoldEffect.calculate(angle: $0, settings: FoldSettings()) }
        let opening = stride(from: 15.0, through: 110, by: 5).map { FoldEffect.calculate(angle: $0, settings: FoldSettings()) }
        #expect(closing == opening.reversed())
    }

    @Test func testInvalidValuesAreRejectedAndZeroStrengthDisablesEffect() {
        for angle in [Double.nan, .infinity, -1, 181] {
            #expect(FoldEffect.calculate(angle: angle, settings: FoldSettings()) == nil)
        }
        #expect(FoldEffect.calculate(angle: 70, settings: FoldSettings(referenceAngle: .nan)) == nil)
        #expect(FoldEffect.calculate(angle: 70, settings: FoldSettings(strength: 2)) == nil)
        #expect(!(FoldEffect.calculate(angle: 15, settings: FoldSettings(strength: 0))!.isVisible))
    }

    @Test func testSmoothingSettlesWithoutOvershootAndReversesPromptly() throws {
        var smoother = AngleSmoother()
        #expect(smoother.update(target: 110, deltaTime: 1.0 / 60) == 110)
        var previous = 110.0
        for _ in 0..<60 {
            let updated = smoother.update(target: 50, deltaTime: 1.0 / 60)
            let value = try #require(updated)
            #expect(value <= previous)
            #expect(value >= 50)
            previous = value
        }
        #expect(abs((previous) - (50)) <= 0.02)
        #expect(smoother.update(target: 90, deltaTime: 1.0 / 60)! > previous)
        #expect(smoother.update(target: .nan, deltaTime: 0.1) == nil)
        smoother.reset()
        #expect(smoother.update(target: 90, deltaTime: 0) == 90)
    }

    @Test func testMovingLidTracksWithinTwoDegreesAndReversesPromptly() throws {
        // 用 90°/s 连续合盖检查实际跟随误差，避免只测最终能否收敛。
        for hz in [30.0, 60.0, 120.0] {
            var smoother = AngleSmoother()
            _ = smoother.update(target: 110, deltaTime: 0)
            var target = 110.0
            var value = 110.0
            for _ in 0..<Int(hz / 2) {
                target -= 90 / hz
                let updated = smoother.update(target: target, deltaTime: 1 / hz)
                value = try #require(updated)
                #expect(value >= target && value - target < 2)
            }
            let beforeReversal = value
            for _ in 0..<3 {
                target += 90 / hz
                let opening = smoother.update(target: target, deltaTime: 1 / hz)
                let reversed = try #require(opening)
                #expect(reversed >= min(value, target) && reversed <= max(value, target))
                value = reversed
            }
            #expect(value > beforeReversal)
            for _ in 0..<Int(hz / 4) {
                let updated = smoother.update(target: target, deltaTime: 1 / hz)
                value = try #require(updated)
            }
            #expect(abs(value - target) < 0.01)
        }
    }

    @Test func testQuantizedSlowMovementSpreadsStepsAcrossFrames() throws {
        var smoother = AngleSmoother()
        _ = smoother.update(target: 110, deltaTime: 0)
        var previous = 110.0
        // 模拟整数传感器缓慢开合，每六个显示帧才降低一度。
        for frame in 1...60 {
            let target = 110 - Double((frame + 5) / 6)
            let updated = smoother.update(target: target, deltaTime: 1.0 / 60)
            let value = try #require(updated)
            #expect(previous - value < 0.5)
            #expect(value >= target)
            previous = value
        }
    }

    @Test func testSensorReportDecoding() {
        #expect(LidReport.decode([1, 117, 0]) == 117)
        #expect(LidReport.decode([1, 0, 0]) == 0)
        #expect(LidReport.decode([2, 117, 0]) == nil)
        #expect(LidReport.decode([1, 117]) == nil)
        #expect(LidReport.decode([1, 255, 255]) == nil)
    }

    @Test func testFailuresAlwaysHideEffectAndRecoveryRequiresHealthyState() {
        var state = EffectAvailability()
        #expect(state.pauseReason == .disabled)
        state.enabled = true
        #expect(state.pauseReason == .permission)
        state.permission = true
        #expect(state.pauseReason == nil)
        state.captureFailed = true
        #expect(state.pauseReason == .captureFailed)
        state.sessionActive = false
        #expect(state.pauseReason == .sessionInactive)
        state.sessionActive = true
        #expect(state.pauseReason == .captureFailed)
        state.captureFailed = false
        #expect(state.pauseReason == nil)
    }

    @Test func testSimulationBypassesOnlySensorRequirement() {
        var state = EffectAvailability()
        state.enabled = true
        state.permission = true
        state.sensorAvailable = false
        #expect(state.pauseReason == .sensorUnavailable)
        state.simulated = true
        #expect(state.pauseReason == nil)
        state.lidClosed = true
        #expect(state.pauseReason == .lidClosed)
        state.lidClosed = false
        state.mirrored = true
        #expect(state.pauseReason == .mirrored)
        state.mirrored = false
        state.displayAvailable = false
        #expect(state.pauseReason == .noDisplay)
    }
}
