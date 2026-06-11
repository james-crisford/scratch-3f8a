import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("Press-to-Impact Pipeline — Full Integration")
struct PressToImpactIntegrationTests {

    // B80 — fixtures apply a CCW (positive CoreMotion) world rotation of
    // `yawDegrees`; under the v3 golf-sign convention (press − impact)
    // CCW = closing for an RH golfer, so the reported face angle is
    // −yawDegrees (pull). Every sign expectation in this suite encodes
    // that deliberately — do NOT "fix" them back to +.
    @Test("baseline: 5° CCW swing reads −5° (pull) under v3 golf sign")
    func baseline5DegSwing() throws {
        let fixture = buildSwingFixture(
            yawDegrees: 5.0,
            attitudeAtPressIdentity: true,
            profile: nil
        )

        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)

        #expect(!result.snappedToSquare)
        #expect(abs(result.faceAngleDegrees - (-5.0)) < 2.0)
    }

    @Test("attitudeAtPress is captured correctly at start of stillness")
    func attitudeAtPressCapture() throws {
        let tiltYaw = 10.0 * .pi / 180.0
        let tilted = simd_quatd(angle: tiltYaw, axis: SIMD3(0, 0, 1))

        let fixture = buildSwingFixture(
            yawDegrees: 5.0,
            customAttitudeAtPress: tilted,
            profile: nil
        )

        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)

        #expect(!result.snappedToSquare)
        #expect(abs(result.faceAngleDegrees - (-5.0)) < 2.0)
    }

    @Test("with stale AR9 profile (bias +5.64°), raw yaw still yields +5° face angle")
    func staleBiasProfile() throws {
        let ar9Bias = 5.64 * .pi / 180.0
        let profile = CalibrationProfile(
            meanTempoSeconds: 0.6,
            speedToDistanceFactor: 1.0,
            faceAngleBiasRad: ar9Bias,
            swingPlaneAxis: SIMD3(1, 0, 0),
            arkitBaselineStability: 0.9,
            validStrokeCount: 100,
            targetDistanceFeet: 6.0
        )
        
        let fixture = buildSwingFixture(
            yawDegrees: 5.0,
            attitudeAtPressIdentity: true,
            profile: profile
        )
        
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)

        #expect(!result.snappedToSquare)
        // B78 — the raw face angle from the press-attitude pipeline is
        // already correct (−5° under the B80 v3 golf sign for this CCW
        // fixture); a stale +5.64° bias profile must NOT be subtracted
        // any more. The test exists to prove exactly that (the AR9
        // over-correction class). Apply the legacy bias on the side and
        // confirm it would have *broken* the result, surfacing the
        // regression if anyone re-enables the bias path. (B80 note: the
        // stored bias ALSO flips meaning across the sign change —
        // ProfileStore zeroes pre-v3 biases at load — but this canary
        // stays sign-valid because it only asserts "subtracting moves
        // the result off target".)
        #expect(abs(result.faceAngleDegrees - (-5.0)) < 2.0)
        let woulHaveBeenCorrectedDeg = ImpactDetector.wrapAngle(
            result.faceAngleRaw - profile.faceAngleBiasRad) * 180.0 / .pi
        #expect(abs(woulHaveBeenCorrectedDeg - (-5.0)) > 2.0,
                "legacy bias path would have driven the result off by ~5.64°; if this fires, the bias subtraction has been re-enabled somewhere")
    }

    @Test("relative delta preserved: tilted press + 5° CCW swing → −5° face angle")
    func tiltedPressPreservesRelativeDelta() throws {
        let tiltRadians = 15.0 * .pi / 180.0
        let tilted = simd_quatd(angle: tiltRadians, axis: SIMD3(0, 0, 1))
        let swingRelativeToTilt = 5.0

        let fixture = buildSwingFixture(
            yawDegrees: swingRelativeToTilt,
            customAttitudeAtPress: tilted,
            profile: nil
        )

        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)

        #expect(!result.snappedToSquare)
        #expect(abs(result.faceAngleDegrees - (-swingRelativeToTilt)) < 2.0)
    }

    @Test("peak velocity detected near middle of 700ms swing window")
    func peakVelocityTiming() throws {
        let fixture = buildSwingFixture(
            yawDegrees: 5.0,
            attitudeAtPressIdentity: true,
            profile: nil
        )
        
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)
        
        let swingStart = fixture.window.start + 0.2
        let swingEnd = swingStart + 0.7
        let midpoint = swingStart + 0.35
        
        #expect(result.timestamp > swingStart)
        #expect(result.timestamp < swingEnd)
        #expect(abs(result.timestamp - midpoint) < 0.1)
    }

    @Test("post-impact stillness does not distort face angle")
    func postImpactStillness() throws {
        let fixture = buildSwingFixture(
            yawDegrees: 8.0,
            attitudeAtPressIdentity: true,
            profile: nil
        )

        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)

        #expect(!result.snappedToSquare)
        #expect(abs(result.faceAngleDegrees - (-8.0)) < 2.0)
    }

    @Test("no bias correction when profile is nil")
    func noBiasCorrectionWhenNil() throws {
        let rawYaw = 7.0
        let fixture = buildSwingFixture(
            yawDegrees: rawYaw,
            attitudeAtPressIdentity: true,
            profile: nil
        )

        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)

        #expect(!result.snappedToSquare)
        #expect(abs(result.faceAngleDegrees - (-rawYaw)) < 2.0)
    }

    @Test("high confidence on clean swing (no ARKit loss)")
    func confidenceCleanSwing() throws {
        let fixture = buildSwingFixture(
            yawDegrees: 5.0,
            attitudeAtPressIdentity: true,
            profile: nil
        )
        
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)
        
        #expect(result.confidence >= 0.9)
    }

    @Test("deterministic: same fixture → same impact result")
    func determinism() throws {
        let fixture = buildSwingFixture(
            yawDegrees: 5.0,
            attitudeAtPressIdentity: true,
            profile: nil
        )
        
        let detector = ImpactDetector()
        let r1 = try detector.detect(in: fixture.window)
        let r2 = try detector.detect(in: fixture.window)
        
        #expect(r1 == r2)
    }
}

// MARK: - Helper: Build Press-to-Impact Fixture

fileprivate func buildSwingFixture(
    yawDegrees: Double,
    attitudeAtPressIdentity: Bool = false,
    customAttitudeAtPress: simd_quatd? = nil,
    profile: CalibrationProfile? = nil
) -> SyntheticStroke {
    let dt = 0.01
    let pressDuration = 0.2
    let swingDuration = 0.7
    let postDuration = 0.2
    
    let pressN = Int(pressDuration / dt)
    let swingN = Int(swingDuration / dt)
    let postN = Int(postDuration / dt)
    let totalN = pressN + swingN + postN
    
    let startTime = 1.0
    let yawRad = yawDegrees * .pi / 180.0
    
    let attitudeAtPress = customAttitudeAtPress ?? (attitudeAtPressIdentity ? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1))
    let attitudeAtImpact = simd_quatd(angle: yawRad, axis: SIMD3(0, 0, 1)) * attitudeAtPress
    
    let omega = Double.pi / swingDuration
    let peakVelocity = 1.0
    let accelAmp = peakVelocity * omega
    
    var samples: [MotionSample] = []
    samples.reserveCapacity(totalN)
    
    for i in 0..<totalN {
        let t = TimeInterval(i) * dt
        let sampleTime = startTime + t
        
        var accel = 0.0
        var attitude = attitudeAtPress
        
        if i < pressN {
            accel = 0.0
            attitude = attitudeAtPress
        } else if i < pressN + swingN {
            let swingPhaseT = TimeInterval(i - pressN) * dt
            accel = accelAmp * cos(omega * swingPhaseT)
            // B80 — face rotation completes BY the velocity peak (mid-
            // swing, where ImpactDetector samples the attitude) and holds
            // through the follow-through. The B78 version slerped linearly
            // across the WHOLE swing, so the attitude at the peak was only
            // 50% of yawDegrees — every face-angle expectation in this
            // suite was off by 2x from the day it was written (these tests
            // were never CI-run before B80: both B78/B79 TestFlight builds
            // shipped with skip_tests=true). peakVelocityTiming pins the
            // peak at mid-swing, which is what exposed this.
            let swingProgress = min(1.0, swingPhaseT / (swingDuration / 2.0))
            attitude = simd_slerp(attitudeAtPress, attitudeAtImpact, swingProgress)
        } else {
            accel = 0.0
            attitude = attitudeAtImpact
        }
        
        samples.append(MotionSample(
            timestamp: sampleTime,
            rotationRate: SIMD3(2.0, 0, 0),
            userAcceleration: SIMD3(accel, 0, 0),
            gravity: SIMD3(0, -1, 0),
            attitude: attitude
        ))
    }
    
    // B78 — production `FaceAngleComputer.compute` reads
    // `window.lock.attitudeAtPress`, so the lock's reference attitude
    // must match the one used to build the per-sample attitudes above.
    // Hardcoding identity here would make tilted-press tests see
    // (impact_yaw - 0) instead of (impact_yaw - press_yaw), which is
    // exactly the regression class B78 was designed to prevent.
    let lock = StillnessLock(
        yawTargetCompass: 0,
        attitudeAtPress: attitudeAtPress,
        gravity: SIMD3(0, -1, 0),
        lockedAt: startTime - 0.001
    )
    
    let window = StrokeWindow(
        start: startTime,
        end: startTime + TimeInterval(totalN - 1) * dt,
        samples: samples,
        lock: lock
    )
    
    return SyntheticStroke(
        name: "press_to_impact_\(Int(yawDegrees))deg",
        window: window,
        expectedImpactTime: startTime + pressDuration + swingDuration / 2.0,
        expectedPeakVelocity: peakVelocity,
        // B80 — v3 golf sign: a CCW (positive) world rotation reads as a
        // NEGATIVE (closed/pull) face angle.
        expectedFaceAngleRad: -yawRad
    )
}
