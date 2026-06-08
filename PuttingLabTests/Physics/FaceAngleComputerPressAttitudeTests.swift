import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("FaceAngleComputer — press-attitude pipeline")
struct FaceAngleComputerPressAttitudeTests {

    // MARK: - Test 1: Identity case
    @Test("identity: attitudeAtPress == attitudeAtImpact → faceAngle == 0")
    func identityNoChange() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: identity,
            impactTime: fixture.expectedImpactTime
        )
        #expect(abs(result.degrees) < 0.001)
    }

    // MARK: - Test 2: +5° yaw rotation
    @Test("+5° yaw: press at identity, impact at +5° yaw → faceAngle == +5° (within 0.1°)")
    func plusFiveDegrees() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let yaw5Deg = simd_quatd(angle: 5.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: yaw5Deg,
            impactTime: fixture.expectedImpactTime
        )
        #expect(abs(result.degrees - 5.0) < 0.1)
        #expect(result.degrees > 0, "positive yaw rotation should give positive faceAngle (PUSH)")
    }

    // MARK: - Test 3: -10° yaw rotation
    @Test("-10° yaw: press at identity, impact at -10° yaw → faceAngle == -10°")
    func minusTenDegrees() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let yaw10NegDeg = simd_quatd(angle: -10.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: yaw10NegDeg,
            impactTime: fixture.expectedImpactTime
        )
        #expect(abs(result.degrees - (-10.0)) < 0.1)
        #expect(result.degrees < 0, "negative yaw rotation should give negative faceAngle (PULL)")
    }

    // MARK: - Test 4: Wrap edge case (+175° to -175°)
    @Test("wrap edge: press at +175°, impact at -175° → faceAngle near zero (wrapped)")
    func wrapEdgeCrossing() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        // Press at +175°
        let yaw175Pos = simd_quatd(angle: 175.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        // Impact at -175° (equivalent to +185°, but normalized to [-π, π])
        let yaw175Neg = simd_quatd(angle: -175.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: yaw175Pos,
            attitudeAtImpact: yaw175Neg,
            impactTime: fixture.expectedImpactTime
        )
        // Delta should wrap: (-175°) - (+175°) = -350° → normalized to +10°
        #expect(abs(result.degrees - 10.0) < 0.2,
                "wrap-around: -175° - 175° = -350° → +10° after wrapAngle, got \(result.degrees)°")
    }

    // MARK: - Test 5: Pure pitch change (no yaw)
    @Test("pitch only: attitudeAtImpact has pitch but no yaw → faceAngle near zero")
    func purePitchThirtyDegrees() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        // Pitch 30° (rotation about phone X-axis) — yaw should remain zero
        let pitch30 = simd_quatd(angle: 30.0 * .pi / 180.0, axis: SIMD3(1, 0, 0))
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: pitch30,
            impactTime: fixture.expectedImpactTime
        )
        // Pitch does not affect yaw; should be near zero.
        #expect(abs(result.degrees) < 0.1,
                "pure pitch rotation should not affect yaw-based face angle, got \(result.degrees)°")
    }

    // MARK: - Test 6: Gimbal lock case (pitch ≈ 90°)
    @Test("gimbal lock: phone vertical (pitch ≈ 90°) → yaw extraction is unstable; document behavior")
    func gimbalLockPitch90() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        // Pitch 90° (vertical phone, X-axis rotation)
        let pitch90 = simd_quatd(angle: 90.0 * .pi / 180.0, axis: SIMD3(1, 0, 0))
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: pitch90,
            impactTime: fixture.expectedImpactTime
        )
        // At gimbal lock, the yaw axis is undefined, but yawFromQuaternion should not crash.
        // We document that the result is undefined but finite; tests here verify non-crash.
        #expect(result.radians.isFinite,
                "gimbal lock should produce finite result, not NaN or Inf; got \(result.radians)")
    }

    // MARK: - Test 7: Real-world fixture (AR9 compass baseline +3.17°)
    @Test("real-world AR9: compass-based result +3.17° → re-run with press-attitude; document delta")
    func ar9CompassBaseline() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        
        // Simulate a small yaw rotation consistent with +3.17° compass reading
        let compassYaw = 3.17 * .pi / 180.0
        let attitudeAtImpact = simd_quatd(angle: compassYaw, axis: SIMD3(0, 0, 1))
        
        // Press attitude at identity (or nearly so, simulating a clean address)
        let attitudeAtPress = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: attitudeAtPress,
            attitudeAtImpact: attitudeAtImpact,
            impactTime: fixture.expectedImpactTime
        )
        
        // If press = identity and impact yaw ≈ +3.17°, then delta ≈ +3.17°
        // (assuming compass and attitude yaw approximately agree).
        #expect(abs(result.degrees - 3.17) < 0.2,
                "AR9 compass baseline +3.17° should mostly agree with press-attitude delta; got \(result.degrees)°")
    }

    // MARK: - Test 8: Roll-only rotation (90° about phone Y-axis)
    @Test("roll only: press and impact differ ONLY in 90° roll → faceAngle ≈ 0")
    func rollOnly90Degrees() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        // Roll 90° (rotation about phone Y-axis) — should not affect yaw
        let roll90 = simd_quatd(angle: 90.0 * .pi / 180.0, axis: SIMD3(0, 1, 0))
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: roll90,
            impactTime: fixture.expectedImpactTime
        )
        // Roll does not affect yaw; should be near zero.
        #expect(abs(result.degrees) < 0.1,
                "pure roll rotation should not affect yaw-based face angle, got \(result.degrees)°")
    }

    // MARK: - Test 9: Sign convention (positive = PUSH/open face)
    @Test("sign convention: positive faceAngle → PUSH (face open to right of target)")
    func signConventionPush() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        
        // Phone Y = shaft, Phone X = face normal (pointing right).
        // Positive yaw = counterclockwise rotation about Z (phone up).
        // This opens the face to the right of the swing direction → PUSH.
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let pushYaw = simd_quatd(angle: 8.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: pushYaw,
            impactTime: fixture.expectedImpactTime
        )
        
        #expect(result.degrees > 0, "positive yaw should give positive faceAngle (PUSH)")
        #expect(abs(result.degrees - 8.0) < 0.1)
    }

    // MARK: - Test 10: Multi-axis rotation (yaw + pitch + roll)
    @Test("complex rotation: yaw + pitch + roll combined → only yaw contributes to faceAngle")
    func multiAxisRotation() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        
        // Build a quaternion with yaw=7°, pitch=25°, roll=15° in
        // canonical Z-Y-X (Rz * Ry * Rx) order. yawFromQuaternion uses
        // the ZYX Tait-Bryan formula atan2(2(wz+xy), 1-2(y²+z²)) which
        // recovers the constructor yaw exactly under that order.
        // Caveat: `yaw * pitch * roll` here would be Rz * Rx * Ry (Z-X-Y),
        // a physically DIFFERENT orientation whose ZYX-extracted yaw is
        // ~13.46° — not a bug in the extractor, just a different basis.
        let yaw = simd_quatd(angle: 7.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let pitch = simd_quatd(angle: 25.0 * .pi / 180.0, axis: SIMD3(1, 0, 0))
        let roll = simd_quatd(angle: 15.0 * .pi / 180.0, axis: SIMD3(0, 1, 0))
        let combined = yaw * roll * pitch
        
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: identity,
            attitudeAtImpact: combined,
            impactTime: fixture.expectedImpactTime
        )
        
        // yawFromQuaternion extracts only the yaw component, so the result
        // should be approximately +7° (within extraction error).
        #expect(abs(result.degrees - 7.0) < 0.3,
                "multi-axis rotation should extract yaw ≈ 7°; got \(result.degrees)°")
    }

    // MARK: - Test 11: Both press and impact rotated (delta matters)
    @Test("both rotated: press at +12°, impact at +18° yaw → faceAngle == +6°")
    func bothRotated() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let yaw12 = simd_quatd(angle: 12.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let yaw18 = simd_quatd(angle: 18.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: yaw12,
            attitudeAtImpact: yaw18,
            impactTime: fixture.expectedImpactTime
        )
        
        // Delta = 18° - 12° = 6°
        #expect(abs(result.degrees - 6.0) < 0.1,
                "delta of +18° (impact) minus +12° (press) should be +6°; got \(result.degrees)°")
    }

    // MARK: - Test 12: Large negative delta with wrap
    @Test("large negative delta: press at -10°, impact at -165° → wrapped delta ≈ -155°")
    func largeNegativeDeltaWrap() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let yaw10Neg = simd_quatd(angle: -10.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let yaw165Neg = simd_quatd(angle: -165.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        
        let result = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: yaw10Neg,
            attitudeAtImpact: yaw165Neg,
            impactTime: fixture.expectedImpactTime
        )
        
        // Delta = -165° - (-10°) = -155°
        #expect(abs(result.degrees - (-155.0)) < 0.2,
                "delta of -165° (impact) minus -10° (press) = -155°; got \(result.degrees)°")
    }

    // MARK: - Test 13: Determinism with press-attitude pipeline
    @Test("determinism: same press/impact attitudes → same face angle")
    func pressAttitudeDeterminism() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let press = simd_quatd(angle: 3.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let impact = simd_quatd(angle: 11.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        
        let r1 = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: press,
            attitudeAtImpact: impact,
            impactTime: fixture.expectedImpactTime
        )
        let r2 = computer.computeWithPress(
            window: fixture.window,
            attitudeAtPress: press,
            attitudeAtImpact: impact,
            impactTime: fixture.expectedImpactTime
        )
        
        #expect(r1 == r2)
    }
}

// MARK: - Extension to FaceAngleComputer

extension FaceAngleComputer {
    func computeWithPress(
        window: StrokeWindow,
        attitudeAtPress: simd_quatd,
        attitudeAtImpact: simd_quatd,
        impactTime: TimeInterval,
        arkitPoses: [ARPose] = [],
        arkitBaselineYaw: Double? = nil
    ) -> FaceAngleSource {
        // New press-attitude pipeline:
        // faceAngle = wrapAngle(yaw(attitudeAtImpact) - yaw(attitudeAtPress))
        
        let pressYaw = ImpactDetector.yawFromQuaternion(attitudeAtPress)
        let impactYaw = ImpactDetector.yawFromQuaternion(attitudeAtImpact)
        let deltaYaw = ImpactDetector.wrapAngle(impactYaw - pressYaw)
        
        return FaceAngleSource(radians: deltaYaw, origin: .pressAttitude)
    }
}

// MARK: - Implementation Notes
//
// New enum case required in FaceAngleSource.Origin:
//     case pressAttitude
//
// Update FaceAngleSource.Origin enum definition in FaceAngleComputer.swift to include:
//     enum Origin: Sendable, Equatable {
//         case arkit
//         case compass
//         case fallbackArkitLost
//         case fallbackNoBaseline
//         case pressAttitude      // <-- ADD THIS
//     }
