import Testing
import Foundation
import simd
@testable import PuttingLab

/// B80 — pins the green-frame ↔ ARKit-world handedness convention and the
/// FULL sign chain: faceAngleRaw → BallPhysics ψ₀ → green +y → world
/// lateral side → MarioKart bucket text. The b79 bug pair (producer sign
/// inversion + renderer right-perp) cancelled on screen while making every
/// label wrong; these tests fail if EITHER half ever regresses alone.
@Suite("GreenFrame — handedness convention")
struct GreenFrameTests {

    // MARK: - leftPerp cardinal checks

    @Test("leftPerp of +X aim is -Z (east → left is north)")
    func leftPerpEast() {
        let left = GreenFrame.leftPerp(of: SIMD3<Float>(1, 0, 0))
        #expect(simd_length(left - SIMD3<Float>(0, 0, -1)) < 1e-6)
    }

    @Test("leftPerp of -Z aim is -X (north → left is west)")
    func leftPerpNorth() {
        let left = GreenFrame.leftPerp(of: SIMD3<Float>(0, 0, -1))
        #expect(simd_length(left - SIMD3<Float>(-1, 0, 0)) < 1e-6)
    }

    @Test("leftPerp is up × aim for arbitrary horizontal aims")
    func leftPerpIsUpCrossAim() {
        let aims: [SIMD3<Float>] = [
            SIMD3(1, 0, 0),
            SIMD3(0, 0, -1),
            simd_normalize(SIMD3(0.3272, 0, -0.9450)),
            simd_normalize(SIMD3(-1, 0, 1)),
        ]
        let up = SIMD3<Float>(0, 1, 0)
        for aim in aims {
            let expected = simd_cross(up, aim)
            #expect(simd_length(GreenFrame.leftPerp(of: aim) - expected) < 1e-6)
        }
    }

    // MARK: - aim guards

    @Test("aim: degenerate and non-finite inputs return nil")
    func aimGuards() {
        let p = SIMD3<Float>(1, -0.8, 1)
        #expect(GreenFrame.aim(ball: p, hole: p) == nil)
        #expect(GreenFrame.aim(ball: p, hole: p + SIMD3(0.005, 0, 0.005)) == nil)
        #expect(GreenFrame.aim(ball: p, hole: SIMD3(.nan, 0, 0)) == nil)
    }

    @Test("aim: session ball/hole reproduce the logged 160.90° aim yaw")
    func aimMatchesSessionLog() throws {
        let ball = SIMD3<Float>(-0.8055, -0.8532, 0.4600)
        let hole = SIMD3<Float>(-0.4629, -0.8535, -0.5294)
        let aim = try #require(GreenFrame.aim(ball: ball, hole: hole))
        let yawDeg = atan2(aim.x, aim.z) * 180.0 / .pi
        #expect(abs(yawDeg - 160.90) < 0.05)
    }

    // MARK: - worldOffset maps green +y to the world LEFT of every aim

    @Test("worldOffset: green +y lands on the LEFT of the aim line for all aims")
    func greenPlusYIsWorldLeft() {
        let aims: [SIMD3<Float>] = [
            SIMD3(1, 0, 0),
            SIMD3(0, 0, -1),
            simd_normalize(SIMD3(0.3272, 0, -0.9450)),
            simd_normalize(SIMD3(-1, 0, 1)),
        ]
        for aim in aims {
            let world = GreenFrame.worldOffset(green: SIMD2(1.0, 0.4), aim: aim)
            #expect(GreenFrame.signedLeft(of: world, aim: aim) > 0.39,
                    "green +y must render LEFT of aim \(aim)")
            #expect(abs(simd_dot(world, aim) - 1.0) < 1e-5)
        }
    }

    // MARK: - End-to-end sign chain (T1/T2)

    @Test("PULL end-to-end: raw −15° → green +y, world LEFT, bucket pull, cause says left")
    func pullRendersLeft() {
        let aim = SIMD3<Float>(1, 0, 0)
        let rawDeg = -15.0
        let sim = BallPhysics.simulatePutt(
            peakVelocity: 0.15,
            faceAngleRaw: rawDeg * .pi / 180.0,
            speedCalibration: 14.18,
            cupPosition: SIMD2(2.0, 0)
        )
        #expect(sim.outcome == .stopped)
        #expect(sim.endPosition.y > 0.5, "pull must end LEFT (+y) in the green frame")

        let world = GreenFrame.worldOffset(green: sim.endPosition, aim: aim)
        #expect(GreenFrame.signedLeft(of: world, aim: aim) > 0.5,
                "pull must render LEFT of the aim line in world space")

        let bucket = MarioKartAssist().bucket(faceAngleDeg: rawDeg)
        #expect(bucket.bucket == .pull)
        #expect(bucket.cause.lowercased().contains("left"))
    }

    @Test("PUSH end-to-end: raw +15° → green −y, world RIGHT, bucket push, cause says right")
    func pushRendersRight() {
        let aim = SIMD3<Float>(1, 0, 0)
        let rawDeg = 15.0
        let sim = BallPhysics.simulatePutt(
            peakVelocity: 0.15,
            faceAngleRaw: rawDeg * .pi / 180.0,
            speedCalibration: 14.18,
            cupPosition: SIMD2(2.0, 0)
        )
        #expect(sim.outcome == .stopped)
        #expect(sim.endPosition.y < -0.5, "push must end RIGHT (−y) in the green frame")

        let world = GreenFrame.worldOffset(green: sim.endPosition, aim: aim)
        #expect(GreenFrame.signedLeft(of: world, aim: aim) < -0.5,
                "push must render RIGHT of the aim line in world space")

        let bucket = MarioKartAssist().bucket(faceAngleDeg: rawDeg)
        #expect(bucket.bucket == .push)
        #expect(bucket.cause.lowercased().contains("right"))
    }

    // MARK: - b79 session stroke S1, full-chain regression

    @Test("b79 S1 regression: +17.90° (v3) renders RIGHT of the real session aim, bucket push")
    func b79StrokeOneFullChain() throws {
        // Session 2026-06-10: ball (-0.8055, -0.8532, 0.4600), hole
        // (-0.4629, -0.8535, -0.5294), peakVelocity 0.138 m/s, speed
        // factor 14.18. Under v2 this stroke read −17.90° and was labelled
        // "pull — ball goes left" while the screen recording showed the
        // roll missing RIGHT. Under v3 the same physical stroke reads
        // +17.90° (open/push) and must render right — matching the video.
        let ball = SIMD3<Float>(-0.8055, -0.8532, 0.4600)
        let hole = SIMD3<Float>(-0.4629, -0.8535, -0.5294)
        let aim = try #require(GreenFrame.aim(ball: ball, hole: hole))

        let sim = BallPhysics.simulatePutt(
            peakVelocity: 0.138,
            faceAngleRaw: 17.90 * .pi / 180.0,
            speedCalibration: 14.18,
            cupPosition: SIMD2(1.047, 0)
        )
        // Rolls well past the 1.047 m hole (the b79 speed-calibration
        // mis-scale, a separate known issue) — total ≈ 2.46 m.
        #expect(abs(simd_length(sim.endPosition) - 2.46) < 0.15)
        #expect(sim.endPosition.y < -0.5, "S1 must end RIGHT of the line in the green frame")

        let world = GreenFrame.worldOffset(green: sim.endPosition, aim: aim)
        #expect(GreenFrame.signedLeft(of: world, aim: aim) < -0.5,
                "S1 must render RIGHT of the ball→hole line, as the b79 video showed")

        let bucket = MarioKartAssist().bucket(faceAngleDeg: 17.90)
        #expect(bucket.bucket == .push)
        #expect(bucket.cause.lowercased().contains("right"))
    }
}
