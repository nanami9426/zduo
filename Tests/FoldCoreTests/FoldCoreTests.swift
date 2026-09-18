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
        #expect(effect.blurWeight(distanceFromHinge: 0) == effect.blur * 0.12)
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
            // 对齐 Hinge：最窄保留约 76.9% 的宽度，避免强收窄产生画面一起移动的感觉。
            let width = 1 - effect.projectionDepth
            #expect(width > 0.76)
            let edge = effect.sourceCoordinate(x: 0.5 - 0.5 * width, yFromHinge: 1)
            #expect(abs(edge.x) < 0.000001)
        }
    }

    @Test func testProjectionMatchesHingeReferenceSamples() throws {
        // 独立记录 Hinge shader 在 25% / 50% / 75% / 100% 进度的采样值，防止再改成强透视。
        let samples: [(progress: Double, width: Double, top: Double, x: Double, y: Double)] = [
            (0.25, 0.930232558140, 0.967599092360, 0.240963855422, 0.466312815595),
            (0.50, 0.869565217391, 0.872496007073, 0.232558139535, 0.405812096313),
            (0.75, 0.816326530612, 0.720853596703, 0.224719101124, 0.323979144586),
            (1.00, 0.769230769231, 0.522498564716, 0.217391304348, 0.227173289007)
        ]
        for sample in samples {
            let effect = try #require(FoldEffect.calculate(angle: 110 - 102 * sample.progress, settings: FoldSettings()))
            let point = effect.sourceCoordinate(x: 0.25, yFromHinge: 0.5)
            #expect(abs(1 - effect.projectionDepth - sample.width) < 1e-9)
            #expect(abs(effect.sourceHeight - sample.top) < 1e-9)
            #expect(abs(point.x - sample.x) < 1e-9 && abs(point.y - sample.y) < 1e-9)
        }
    }

    @Test func testClassicFrostKeepsItsOriginalAngleCurve() throws {
        let middle = try #require(FoldEffect.calculate(angle: 62.5, settings: FoldSettings()))
        #expect(middle.blur == 0.5)
        let nearlyClosed = try #require(FoldEffect.calculate(angle: 15, settings: FoldSettings()))
        #expect(nearlyClosed.blur == 1)
        #expect(nearlyClosed.closure < 1)
        let closed = try #require(FoldEffect.calculate(angle: 8, settings: FoldSettings()))
        #expect(closed.closure == 1)
    }

    @Test func testProjectionIsStableAcrossReferenceAnglesAndStrengths() throws {
        for reference in [30.0, 60, 110, 150] {
            for strength in [0.0, 0.25, 0.5, 1] {
                var previous = 1.0
                for angle in stride(from: reference, through: 0, by: -1) {
                    let effect = try #require(FoldEffect.calculate(
                        angle: angle, settings: FoldSettings(referenceAngle: reference, strength: strength)))
                    let top = effect.sourceCoordinate(x: 0.2, yFromHinge: 1)
                    let bottom = effect.sourceCoordinate(x: 0.2, yFromHinge: 0)
                    #expect(top.x.isFinite && top.y > 0 && top.y <= previous + 1e-12)
                    #expect(abs(bottom.x - 0.2) < 1e-12 && bottom.y == 0)
                    if strength == 0 {
                        #expect(abs(top.x - 0.2) < 1e-12 && top.y == 1)
                        #expect(effect.blur == 0)
                    }
                    previous = top.y
                }
            }
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
