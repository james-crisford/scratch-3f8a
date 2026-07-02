import Testing
import Foundation
import simd
@testable import PuttingLab

// Expected values are derived from the v1 minimal physics model documented
// in docs/ar-replay/research-synthesis.md:
//
//   μ_r(S)        = 0.611 / S_feet                          (Penner 2002 / Lee 2025)
//   a_friction    = μ_r · g                                 (5/7 absorbed in μ_r)
//   v_0_magnitude = peakVelocity · speedCal · 0.90 · √0.95
//   distance_to_stop = v_0² / (2 · a_friction)
//
// Per-test tolerances are ±5 % unless otherwise noted (matches the
// "v1 minimal model gets ~80 % realism" caveat from synthesis §5.2).

@Suite("BallPhysics — flat-green roll distance")
struct BallPhysicsRollDistanceTests {

    /// Reference values for the headline 3-m putt scenario on a Stimp-10 green.
    ///
    /// Derivation:
    ///   μ_r = 0.611 / 10 = 0.0611
    ///   a   = 0.0611 · 9.81 = 0.5994 m/s²
    ///   v_0 = 2.0 · 1.0 · 0.90 · √0.95 ≈ 1.7544 m/s
    ///   d   = v_0² / (2a) = 3.0779 / 1.1988 ≈ 2.568 m
    @Test("Stimp 10, peakVelocity 2.0 m/s, speedCal 1.0 → roll ≈ 2.57 m ±5 %")
    func headlineStimp10RollDistance() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 2.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(50.0, 0.0) // far away — no capture
        )
        let endDistance = simd_length(result.endPosition)
        let expected = 2.568
        let tolerance = expected * 0.05
        #expect(abs(endDistance - expected) < tolerance,
                "endDistance = \(endDistance), expected ≈ \(expected)")
        #expect(result.outcome == .stopped)
    }

    /// Penner 2002 / Lee 2025 derivation says distance scales linearly with
    /// Stimp: d ∝ 1/μ_r ∝ S. A Stimp-14 green should roll the same launch
    /// 14/6 ≈ 2.33× as far as a Stimp-6 green.
    @Test("Stimp 14 vs Stimp 6, same launch → distance ratio ≈ 2.33 ±5 %")
    func stimpRatioScalesLinearly() {
        let slow = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 6.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        let fast = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 14.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        let slowDistance = simd_length(slow.endPosition)
        let fastDistance = simd_length(fast.endPosition)
        let ratio = fastDistance / slowDistance
        let expected = 14.0 / 6.0
        let tolerance = expected * 0.05
        #expect(abs(ratio - expected) < tolerance,
                "ratio = \(ratio), expected ≈ \(expected)")
    }
}

@Suite("BallPhysics — sign convention")
struct BallPhysicsSignTests {

    /// Synthesis §3.3: negative faceAngleRaw = closed face = pull left for
    /// a RH user → endPosition.y > 0 in the +y=left green frame.
    @Test("negative faceAngleRaw (closed face) → ball ends LEFT (+y) of target")
    func closedFaceGoesLeft() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: -0.1, // closed face, ~5.7°
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        #expect(result.endPosition.y > 0,
                "endPosition.y = \(result.endPosition.y), expected > 0")
        #expect(result.endPosition.x > 0)
    }

    @Test("positive faceAngleRaw (open face) → ball ends RIGHT (-y) of target")
    func openFaceGoesRight() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: 0.1, // open face, ~5.7°
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        #expect(result.endPosition.y < 0,
                "endPosition.y = \(result.endPosition.y), expected < 0")
        #expect(result.endPosition.x > 0)
    }

    @Test("zero face angle → straight roll along +x with negligible y drift")
    func zeroFaceGoesStraight() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        #expect(abs(result.endPosition.y) < 1e-9)
        #expect(result.endPosition.x > 0)
    }
}

@Suite("BallPhysics — boundary conditions")
struct BallPhysicsBoundaryTests {

    @Test("zero peak velocity → no roll, single stationary sample")
    func zeroVelocityNoRoll() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 0.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            cupPosition: SIMD2<Double>(3.0, 0.0)
        )
        #expect(result.outcome == .stopped)
        #expect(result.path.count == 1)
        #expect(result.endPosition == .zero)
        #expect(result.endVelocity == .zero)
        #expect(result.totalDuration == 0)
    }

    @Test("negative peak velocity → rejected, empty trajectory")
    func negativeVelocityRejected() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: -1.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            cupPosition: SIMD2<Double>(3.0, 0.0)
        )
        #expect(result.outcome == .rejected)
        #expect(result.path.isEmpty)
        #expect(result.endPosition == .zero)
    }

    @Test("NaN peakVelocity → rejected, empty trajectory")
    func nanVelocityRejected() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: .nan,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            cupPosition: SIMD2<Double>(3.0, 0.0)
        )
        #expect(result.outcome == .rejected)
        #expect(result.path.isEmpty)
    }

    @Test("Inf faceAngleRaw → rejected")
    func infFaceAngleRejected() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.0,
            faceAngleRaw: .infinity,
            speedCalibration: 1.0,
            cupPosition: SIMD2<Double>(3.0, 0.0)
        )
        #expect(result.outcome == .rejected)
        #expect(result.path.isEmpty)
    }

    @Test("NaN cup position → rejected")
    func nanCupRejected() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            cupPosition: SIMD2<Double>(.nan, 0.0)
        )
        #expect(result.outcome == .rejected)
        #expect(result.path.isEmpty)
    }

    @Test("non-positive integration step → rejected")
    func zeroDtRejected() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            cupPosition: SIMD2<Double>(3.0, 0.0),
            integrationStep: 0.0
        )
        #expect(result.outcome == .rejected)
        #expect(result.path.isEmpty)
    }

    @Test("Stimp clamp: ridiculous Stimp values do not crash")
    func stimpClampDoesNotCrash() {
        let tooSlow = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 0.0001, // would otherwise blow up μ_r
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        let tooFast = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 1000.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        #expect(tooSlow.outcome == .stopped)
        #expect(tooFast.outcome == .stopped)
        #expect(!tooSlow.path.isEmpty)
        #expect(!tooFast.path.isEmpty)
    }
}

@Suite("BallPhysics — stop condition")
struct BallPhysicsStopConditionTests {

    @Test("ball comes to rest: end velocity magnitude ≈ 0")
    func endsAtRest() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 2.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        let endSpeed = simd_length(result.endVelocity)
        // The semi-implicit Euler step snaps to zero when the friction step
        // would overshoot — so the final velocity is exactly zero or below
        // the 5 cm/s stop threshold.
        #expect(endSpeed <= BallPhysics.stopVelocity)
        #expect(result.outcome == .stopped)
    }

    @Test("ball comes to rest within a finite time")
    func stopsWithinFiniteTime() {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 2.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        // A 2.0 m/s peak putt on Stimp 10 should stop within ~5 s.
        #expect(result.totalDuration > 0)
        #expect(result.totalDuration < 10.0)
    }

    @Test("last path sample matches endPosition and endVelocity")
    func lastSampleMatchesEndState() throws {
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.5,
            faceAngleRaw: 0.05,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(50.0, 0.0)
        )
        let last = try #require(result.path.last)
        #expect(last.position == result.endPosition)
        #expect(last.velocity == result.endVelocity)
    }
}

@Suite("BallPhysics — determinism")
struct BallPhysicsDeterminismTests {

    @Test("same inputs → identical paths")
    func sameInputsIdenticalPaths() {
        let a = BallPhysics.simulatePutt(
            peakVelocity: 1.7,
            faceAngleRaw: 0.05,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(3.0, 0.0)
        )
        let b = BallPhysics.simulatePutt(
            peakVelocity: 1.7,
            faceAngleRaw: 0.05,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(3.0, 0.0)
        )
        #expect(a.path == b.path)
        #expect(a.endPosition == b.endPosition)
        #expect(a.endVelocity == b.endVelocity)
        #expect(a.totalDuration == b.totalDuration)
        #expect(a.outcome == b.outcome)
        #expect(a == b)
    }

    @Test("same inputs across 5 calls → all results identical")
    func fiveCallsIdentical() {
        var results: [BallPhysics.Result] = []
        for _ in 0..<5 {
            let r = BallPhysics.simulatePutt(
                peakVelocity: 2.0,
                faceAngleRaw: -0.02,
                speedCalibration: 1.0,
                stimpFeet: 11.0,
                cupPosition: SIMD2<Double>(2.5, 0.0)
            )
            results.append(r)
        }
        let first = results[0]
        for r in results.dropFirst() {
            #expect(r == first)
        }
    }
}

@Suite("BallPhysics — cup capture")
struct BallPhysicsCupCaptureTests {

    /// A slow putt aimed at a cup 2 m away should drop — entry speed well
    /// below the 1.626 m/s capture limit.
    @Test("slow putt directly into cup → captured")
    func slowPuttCaptured() {
        // Aim short: peakVelocity 1.5, speedCal 1, factor 0.877 → v_0 ≈ 1.32 m/s
        // Distance to stop ≈ 1.32² / (2 · 0.5994) ≈ 1.45 m — but the cup is
        // at 2 m. So we need a slightly harder putt.
        // Try peakVel 1.85 → v_0 ≈ 1.62 m/s, distance ≈ 2.20 m, passing through
        // cup at 2 m with entry speed sqrt(1.62² - 2 · 0.5994 · 2) ≈ 0.27 m/s.
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.85,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(2.0, 0.0)
        )
        #expect(result.outcome == .captured)
        #expect(result.endPosition.x == 2.0)
        #expect(result.endPosition.y == 0.0)
        #expect(result.endVelocity == .zero)
    }

    /// A hard putt straight at the cup should lip out — entry speed above
    /// the 1.626 m/s capture limit.
    @Test("fast putt straight at cup → lip out")
    func fastPuttLipsOut() {
        // peakVel 4.0, speedCal 1, factor 0.877 → v_0 ≈ 3.51 m/s
        // At 1 m cup: entry speed ≈ √(3.51² - 2·0.5994·1) ≈ 3.34 m/s → lip out.
        let result = BallPhysics.simulatePutt(
            peakVelocity: 4.0,
            faceAngleRaw: 0.0,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(1.0, 0.0)
        )
        #expect(result.outcome == .lipOut)
    }

    @Test("putt aimed wide of cup → not captured (no false positives)")
    func wideOfCupNotCaptured() {
        // Aim 50 cm offline — well outside 5.4 cm cup radius.
        let result = BallPhysics.simulatePutt(
            peakVelocity: 1.85,
            faceAngleRaw: -0.25, // ~14° — sends ball well left
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(2.0, 0.0)
        )
        #expect(result.outcome != .captured)
    }

    @Test("IMU spike above maxPlausiblePeakVelocity is rejected, not rolled")
    func sensorSpikeRejected() {
        // The Build-6 DistanceModel spike guard, now enforced at the
        // physics boundary: a double-integration glitch must never render
        // a confidently-displayed multi-kilometre putt.
        let spike = BallPhysics.simulatePutt(
            peakVelocity: BallPhysics.maxPlausiblePeakVelocity + 1.0,
            faceAngleRaw: 0,
            speedCalibration: 14.4,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(2.0, 0.0)
        )
        #expect(spike.outcome == .rejected)
        #expect(spike.path.isEmpty)

        let fast = BallPhysics.simulatePutt(
            peakVelocity: BallPhysics.maxPlausiblePeakVelocity - 0.1,
            faceAngleRaw: 0,
            speedCalibration: 1.0,
            stimpFeet: 10.0,
            cupPosition: SIMD2<Double>(2.0, 0.0)
        )
        #expect(fast.outcome != .rejected)
    }
}
