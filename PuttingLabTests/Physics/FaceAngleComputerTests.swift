import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("FaceAngleComputer — compass fallback")
struct FaceAngleComputerCompassTests {

    @Test("zero on straight stroke with no ARKit")
    func zeroStraight() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let attitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: fixture.expectedImpactTime
        )
        #expect(abs(result.degrees) < 0.001)
        #expect(result.origin == .compass)
    }

    @Test("signed correctly: closed face → negative")
    func signedPull() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let attitude = simd_quatd(angle: -.pi / 36, axis: SIMD3(0, 0, 1))  // -5°
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: fixture.expectedImpactTime
        )
        #expect(result.degrees < 0)
        #expect(abs(result.degrees + 5.0) < 0.1)
    }

    @Test("signed correctly: open face → positive")
    func signedPush() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let attitude = simd_quatd(angle: .pi / 18, axis: SIMD3(0, 0, 1))  // +10°
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: fixture.expectedImpactTime
        )
        #expect(result.degrees > 0)
        #expect(abs(result.degrees - 10.0) < 0.1)
    }

    @Test("FaceAngleSource.degrees conversion")
    func degreesConversion() {
        let src = FaceAngleSource(radians: .pi / 4, origin: .compass)
        #expect(abs(src.degrees - 45.0) < 1e-9)
    }
}

@Suite("FaceAngleComputer — ARKit primary")
struct FaceAngleComputerARKitTests {

    @Test("ARKit clean throughout → uses ARKit source")
    func cleanArkitUsed() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let poses = arkitPoses(yaws: [0.0, 0.0, 0.0, 0.0], timestamps: [1.1, 1.2, 1.3, 1.4])
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            impactTime: 1.3,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        #expect(result.origin == .arkit)
        #expect(abs(result.degrees) < 0.001)
    }

    @Test("ARKit pose closest to impact time is selected")
    func closestPoseSelected() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        // Three poses: 1.1 (yaw=0), 1.3 (yaw=0.2), 1.5 (yaw=0.5)
        let poses = arkitPoses(yaws: [0.0, 0.2, 0.5], timestamps: [1.1, 1.3, 1.5])
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            impactTime: 1.31,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        #expect(result.origin == .arkit)
        #expect(abs(result.radians - 0.2) < 1e-5)
    }

    @Test("ARKit pose with non-zero baseline → delta computed against baseline")
    func nonZeroBaseline() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let poses = arkitPoses(yaws: [0.5], timestamps: [1.3])
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            impactTime: 1.3,
            arkitPoses: poses,
            arkitBaselineYaw: 0.3
        )
        #expect(result.origin == .arkit)
        #expect(abs(result.radians - 0.2) < 1e-5)
    }
}

@Suite("FaceAngleComputer — ARKit fallback")
struct FaceAngleComputerFallbackTests {

    @Test("ARKit lost >50% mid-stroke → falls back to compass with .fallbackArkitLost origin")
    func arkitLostFallsBack() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let poses: [ARPose] = [
            ARPose(timestamp: 1.1, transform: yawTransformF(radians: 0), trackingState: .limited(.initializing)),
            ARPose(timestamp: 1.2, transform: yawTransformF(radians: 0), trackingState: .limited(.excessiveMotion)),
            ARPose(timestamp: 1.3, transform: yawTransformF(radians: 0), trackingState: .normal),
        ]
        let attitude = simd_quatd(angle: .pi / 18, axis: SIMD3(0, 0, 1))
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: 1.3,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        #expect(result.origin == .fallbackArkitLost)
        #expect(abs(result.degrees - 10.0) < 0.1)
    }

    @Test("ARKit lost on single sample (≤50%) → still uses ARKit (spec >50% threshold)")
    func arkitSingleLostStaysClean() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let poses: [ARPose] = [
            ARPose(timestamp: 1.1, transform: yawTransformF(radians: 0), trackingState: .normal),
            ARPose(timestamp: 1.2, transform: yawTransformF(radians: 0), trackingState: .limited(.excessiveMotion)),
            ARPose(timestamp: 1.3, transform: yawTransformF(radians: 0), trackingState: .normal),
        ]
        let attitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: 1.3,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        // 2/3 normal = 66.7% > 50% → ARKit clean
        #expect(result.origin == .arkit)
    }

    @Test("ARKit available but no baseline → fallback with .fallbackNoBaseline origin")
    func noBaselineFallback() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let poses = arkitPoses(yaws: [0.0], timestamps: [1.3])
        let attitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: 1.3,
            arkitPoses: poses,
            arkitBaselineYaw: nil
        )
        #expect(result.origin == .fallbackNoBaseline)
    }

    @Test("empty arkitPoses → .compass origin")
    func emptyArkitCompass() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let attitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: 1.3,
            arkitPoses: [],
            arkitBaselineYaw: 0.0
        )
        #expect(result.origin == .compass)
    }

    @Test(".limited(.initializing) treated as lost")
    func limitedInitializingLost() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let poses: [ARPose] = [
            ARPose(timestamp: 1.3, transform: yawTransformF(radians: 0), trackingState: .limited(.initializing)),
        ]
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            impactTime: 1.3,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        #expect(result.origin == .fallbackArkitLost)
    }
}

@Suite("FaceAngleComputer — agreement & robustness")
struct FaceAngleComputerAgreementTests {

    @Test("ARKit and compass agree within 2° on synthetic stroke")
    func sourcesAgree() {
        let fixture = StrokeFixtures.pull(deg: 7)
        let computer = FaceAngleComputer()
        let attitude = simd_quatd(angle: -7.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let compassResult = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: fixture.expectedImpactTime
        )
        let poses = arkitPoses(yaws: [-7.0 * .pi / 180.0], timestamps: [fixture.expectedImpactTime])
        let arkitResult = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: fixture.expectedImpactTime,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        #expect(abs(arkitResult.degrees - compassResult.degrees) < 2.0)
    }

    @Test("determinism: same inputs → same output")
    func determinism() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let attitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let r1 = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: 1.3
        )
        let r2 = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: 1.3
        )
        #expect(r1 == r2)
    }

    @Test("ImpactDetector integration: clean stroke + clean ARKit → ARKit-sourced result")
    func detectorIntegration() throws {
        let fixture = StrokeFixtures.cleanStraight(durationMs: 600, peakVelocity: 1.0)
        let detector = ImpactDetector()
        var poses: [ARPose] = []
        for i in 0..<60 {
            let t = 1.0 + TimeInterval(i) * 0.01
            poses.append(ARPose(timestamp: t, transform: yawTransformF(radians: 0), trackingState: .normal))
        }
        let result = try detector.detect(
            in: fixture.window,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        #expect(abs(result.faceAngleDegrees) < 1.0)
    }

    @Test("ImpactDetector integration: ARKit-lost mid-stroke → compass result preserved")
    func detectorArkitLostIntegration() throws {
        let fixture = StrokeFixtures.pull(deg: 8)
        let detector = ImpactDetector()
        var poses: [ARPose] = []
        for i in 0..<60 {
            let t = 1.0 + TimeInterval(i) * 0.01
            let state: ARTrackingState = (i == 30) ? .limited(.excessiveMotion) : .normal
            poses.append(ARPose(timestamp: t, transform: yawTransformF(radians: -8.0 * .pi / 180.0), trackingState: state))
        }
        let result = try detector.detect(
            in: fixture.window,
            arkitPoses: poses,
            arkitBaselineYaw: 0.0
        )
        #expect(abs(result.faceAngleDegrees - (-8.0)) < 2.0)
    }

    @Test("ImpactDetector backwards-compat: no arkitPoses produces same result as before Day 6")
    func backwardsCompat() throws {
        let fixture = StrokeFixtures.pull(deg: 5)
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)
        #expect(abs(result.faceAngleDegrees - (-5.0)) < 2.0)
    }
}

// MARK: - Helpers

fileprivate func yawTransformF(radians: Double) -> simd_float4x4 {
    let r = Float(radians)
    let c = cos(r)
    let s = sin(r)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(c, 0, -s, 0)
    m.columns.1 = SIMD4<Float>(0, 1, 0, 0)
    m.columns.2 = SIMD4<Float>(s, 0, c, 0)
    m.columns.3 = SIMD4<Float>(0, 0, 0, 1)
    return m
}

fileprivate func arkitPoses(yaws: [Double], timestamps: [TimeInterval]) -> [ARPose] {
    precondition(yaws.count == timestamps.count)
    return zip(yaws, timestamps).map { (yaw, t) in
        ARPose(timestamp: t, transform: yawTransformF(radians: yaw), trackingState: .normal)
    }
}
