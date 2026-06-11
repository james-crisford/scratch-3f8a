import Testing
import Foundation
import simd
@testable import PuttingLab

/// B80 — rewritten against PRODUCTION `FaceAngleComputer.compute()`.
///
/// The B78 version of this suite exercised a test-local
/// `computeWithPress` extension that reimplemented the formula — so it
/// kept passing regardless of what production code did, and it pinned
/// the OLD (inverted) sign convention. These tests build a real
/// `StrokeWindow` whose lock carries the press attitude, exactly like
/// the production capture path.
///
/// Sign convention under test (v3, golf convention, B80):
///   raw = wrapAngle(yaw(press) − yaw(impact))
///   CCW rotation about world-up (positive CoreMotion yaw) = CLOSING the
///   face for a right-handed golfer ⇒ NEGATIVE faceAngle = pull/left.
///   CW rotation = opening ⇒ POSITIVE faceAngle = push/right.
@Suite("FaceAngleComputer — press-attitude pipeline (v3 golf sign)")
struct FaceAngleComputerPressAttitudeTests {

    /// Production-shaped window: the fixture's samples with the lock's
    /// press attitude replaced, mirroring handlePressBegan's capture.
    private func windowWithPress(_ press: simd_quatd) -> (window: StrokeWindow, impactTime: TimeInterval) {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let w = fixture.window
        let lock = StillnessLock(
            yawTargetCompass: w.lock.yawTargetCompass,
            attitudeAtPress: press,
            gravity: w.lock.gravity,
            lockedAt: w.lock.lockedAt
        )
        let window = StrokeWindow(start: w.start, end: w.end, samples: w.samples, lock: lock)
        return (window, fixture.expectedImpactTime)
    }

    private func compute(press: simd_quatd, impact: simd_quatd) -> FaceAngleSource {
        let (window, impactTime) = windowWithPress(press)
        return FaceAngleComputer().compute(
            window: window,
            attitudeAtImpact: impact,
            impactTime: impactTime
        )
    }

    private let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    // MARK: - Test 1: Identity case
    @Test("identity: attitudeAtPress == attitudeAtImpact → faceAngle == 0")
    func identityNoChange() {
        let result = compute(press: identity, impact: identity)
        #expect(abs(result.degrees) < 0.001)
        #expect(result.origin == .pressAttitude)
    }

    // MARK: - Test 2: CCW (+5°) physical rotation = closing → NEGATIVE (pull)
    @Test("+5° CCW yaw: closing rotation → faceAngle == -5° (PULL)")
    func ccwFiveDegreesIsPull() {
        let yaw5Deg = simd_quatd(angle: 5.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = compute(press: identity, impact: yaw5Deg)
        #expect(abs(result.degrees - (-5.0)) < 0.1)
        #expect(result.degrees < 0,
                "CCW rotation closes the face for an RH golfer → negative (PULL); got \(result.degrees)°")
    }

    // MARK: - Test 3: CW (-10°) physical rotation = opening → POSITIVE (push)
    @Test("-10° CW yaw: opening rotation → faceAngle == +10° (PUSH)")
    func cwTenDegreesIsPush() {
        let yaw10NegDeg = simd_quatd(angle: -10.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = compute(press: identity, impact: yaw10NegDeg)
        #expect(abs(result.degrees - 10.0) < 0.1)
        #expect(result.degrees > 0,
                "CW rotation opens the face for an RH golfer → positive (PUSH); got \(result.degrees)°")
    }

    // MARK: - Test 4: Wrap edge case (+175° to -175°)
    @Test("wrap edge: press at +175°, impact at -175° → wrapped to -10°")
    func wrapEdgeCrossing() {
        let yaw175Pos = simd_quatd(angle: 175.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let yaw175Neg = simd_quatd(angle: -175.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = compute(press: yaw175Pos, impact: yaw175Neg)
        // press − impact = 175° − (−175°) = +350° → wrapAngle → −10°.
        // Physically the phone rotated +10° CCW (closing) → pull. ✓
        #expect(abs(result.degrees - (-10.0)) < 0.2,
                "wrap-around: 175° − (−175°) = +350° → −10° after wrapAngle, got \(result.degrees)°")
    }

    // MARK: - Test 5: Pure pitch change (no yaw)
    @Test("pitch only: attitudeAtImpact has pitch but no yaw → faceAngle near zero")
    func purePitchThirtyDegrees() {
        let pitch30 = simd_quatd(angle: 30.0 * .pi / 180.0, axis: SIMD3(1, 0, 0))
        let result = compute(press: identity, impact: pitch30)
        #expect(abs(result.degrees) < 0.1,
                "pure pitch rotation should not affect yaw-based face angle, got \(result.degrees)°")
    }

    // MARK: - Test 6: Gimbal lock case (pitch ≈ 90°)
    @Test("gimbal lock: phone vertical (pitch ≈ 90°) → finite result, no crash")
    func gimbalLockPitch90() {
        let pitch90 = simd_quatd(angle: 90.0 * .pi / 180.0, axis: SIMD3(1, 0, 0))
        let result = compute(press: identity, impact: pitch90)
        #expect(result.radians.isFinite,
                "gimbal lock should produce finite result, not NaN or Inf; got \(result.radians)")
    }

    // MARK: - Test 7: b79 session stroke S1 regression (real device numbers)
    @Test("b79 S1 regression: press yaw 73.57°, impact yaw 55.67° → +17.90° (PUSH)")
    func b79SessionStrokeOneReadsPush() {
        // The 2026-06-10 device session: three intended-square strokes read
        // -17.9/-10.9/-12.3 under the v2 (inverted) convention and were
        // labelled "pull — ball goes left" while the screen recording showed
        // every roll missing RIGHT. Under v3 the same stroke must read
        // +17.90° = open/push, matching the video.
        let press = simd_quatd(angle: 73.57 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let impact = simd_quatd(angle: 55.67 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = compute(press: press, impact: impact)
        #expect(abs(result.degrees - 17.90) < 0.1,
                "b79 S1 must read +17.90° (open/push) under v3; got \(result.degrees)°")
    }

    // MARK: - Test 8: Roll-only rotation (90° about phone Y-axis)
    @Test("roll only: press and impact differ ONLY in 90° roll → faceAngle ≈ 0")
    func rollOnly90Degrees() {
        let roll90 = simd_quatd(angle: 90.0 * .pi / 180.0, axis: SIMD3(0, 1, 0))
        let result = compute(press: identity, impact: roll90)
        #expect(abs(result.degrees) < 0.1,
                "pure roll rotation should not affect yaw-based face angle, got \(result.degrees)°")
    }

    // MARK: - Test 9: Sign convention — CCW = closed = PULL
    @Test("sign convention: CCW physical rotation → NEGATIVE faceAngle (closed/PULL)")
    func signConventionCcwIsPull() {
        // For a right-handed golfer (target on his left), closing the
        // putter face rotates the face normal CCW viewed from above —
        // positive CoreMotion yaw. Golf convention says closed = pull =
        // negative, hence the producer emits press − impact.
        let ccw8 = simd_quatd(angle: 8.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = compute(press: identity, impact: ccw8)
        #expect(result.degrees < 0, "CCW (closing) rotation must read negative (PULL)")
        #expect(abs(result.degrees - (-8.0)) < 0.1)
    }

    // MARK: - Test 10: Multi-axis rotation (yaw + pitch + roll)
    @Test("complex rotation: yaw + pitch + roll combined → only yaw contributes")
    func multiAxisRotation() {
        // Canonical Z-Y-X (Rz * Ry * Rx) composition; yawFromQuaternion's
        // ZYX Tait-Bryan formula recovers the constructor yaw exactly
        // under that order (see B78 Test-10 composition-order note).
        let yaw = simd_quatd(angle: 7.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let pitch = simd_quatd(angle: 25.0 * .pi / 180.0, axis: SIMD3(1, 0, 0))
        let roll = simd_quatd(angle: 15.0 * .pi / 180.0, axis: SIMD3(0, 1, 0))
        let combined = yaw * roll * pitch
        let result = compute(press: identity, impact: combined)
        // Physical +7° CCW yaw component → v3 reads −7° (closed/pull).
        #expect(abs(result.degrees - (-7.0)) < 0.3,
                "multi-axis rotation should extract yaw ≈ 7° CCW → −7° under v3; got \(result.degrees)°")
    }

    // MARK: - Test 11: Both press and impact rotated (delta matters)
    @Test("both rotated: press at +12°, impact at +18° yaw → faceAngle == -6°")
    func bothRotated() {
        let yaw12 = simd_quatd(angle: 12.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let yaw18 = simd_quatd(angle: 18.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = compute(press: yaw12, impact: yaw18)
        // press − impact = 12° − 18° = −6° (closed 6° CCW from press).
        #expect(abs(result.degrees - (-6.0)) < 0.1,
                "12° (press) − 18° (impact) should be −6°; got \(result.degrees)°")
    }

    // MARK: - Test 12: Large delta with wrap
    @Test("large delta: press at -10°, impact at -165° → +155° (opened)")
    func largeDeltaWrap() {
        let yaw10Neg = simd_quatd(angle: -10.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let yaw165Neg = simd_quatd(angle: -165.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let result = compute(press: yaw10Neg, impact: yaw165Neg)
        // press − impact = −10° − (−165°) = +155° (CW sweep = opened).
        #expect(abs(result.degrees - 155.0) < 0.2,
                "−10° (press) − (−165°) (impact) = +155°; got \(result.degrees)°")
    }

    // MARK: - Test 13: Determinism with press-attitude pipeline
    @Test("determinism: same press/impact attitudes → same face angle")
    func pressAttitudeDeterminism() {
        let press = simd_quatd(angle: 3.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let impact = simd_quatd(angle: 11.0 * .pi / 180.0, axis: SIMD3(0, 0, 1))
        let r1 = compute(press: press, impact: impact)
        let r2 = compute(press: press, impact: impact)
        #expect(r1 == r2)
    }
}
