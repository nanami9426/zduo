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
            #expect(effect.rotation >= previous.rotation)
            #expect(effect.rotation <= 55 * .pi / 180)
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
            #expect(top.y >= 1 - 0.000001)
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
