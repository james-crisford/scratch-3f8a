import Testing
import Foundation
import simd
@testable import PuttingLab

/// B80 — pins the one-sided golf-address stance solver. The b79 markers
/// straddled the ball→hole line (one foot each side, spread ACROSS the
/// line, long axes ALONG it, absolute world y = 0.08). Every test here
/// encodes the corrected model: both feet on the golfer's side (RH = the
/// up×aim / LEFT side of the aim vector), set back from the line, spread
/// shoulder-width ALONG it, toes pointing AT it, floor-relative Y.
@Suite("StanceGeometry — address placement (B80 one-sided stance)")
struct StanceGeometryPlacementTests {

    private func place(
        ball: SIMD3<Float>,
        hole: SIMD3<Float>,
        heightCm: Double = 170,
        handedness: UserProfile.Handedness = .right
    ) -> StancePlacement? {
        let profile = UserProfile(heightCm: heightCm, handedness: handedness)
        return StanceGeometry.addressPlacement(
            ball: ball,
            hole: hole,
            stance: StanceGeometry.compute(profile: profile),
            handedness: handedness
        )
    }

    /// Local deterministic LCG for the property tests (no Date/random —
    /// fixed seeds keep the suite reproducible).
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
            lo + (hi - lo) * next()
        }
    }

    // MARK: - Golden regression: the b79 session geometry

    @Test("b79 session golden: RH 185 cm feet land left of the line, floor-relative")
    func goldenSessionRegression() throws {
        // Session 2026-06-10: ball (-0.8055, -0.8532, 0.4600), hole
        // (-0.4629, -0.8535, -0.5294); profile height 185 cm (the logged
        // foot_half_spread 0.2266 = 0.245 × 1.85 / 2), right-handed.
        let p = try #require(place(
            ball: SIMD3(-0.8055, -0.8532, 0.4600),
            hole: SIMD3(-0.4629, -0.8535, -0.5294),
            heightCm: 185
        ))
        #expect(simd_length(p.leadFootPosition - SIMD3(-1.0935, -0.8432, 0.1628)) < 1e-3)
        #expect(simd_length(p.trailFootPosition - SIMD3(-1.2418, -0.8432, 0.5911)) < 1e-3)
        #expect(abs(p.leadFootYaw * 180 / .pi - 77.90) < 0.05)
        #expect(abs(p.trailFootYaw * 180 / .pi - 63.90) < 0.05)
        #expect(p.sideSign == 1)
    }

    // MARK: - Cardinal cases

    @Test("cardinal RH: aim +X, 170 cm → both feet at z = -0.36335 (left of line)")
    func cardinalRightHanded() throws {
        let p = try #require(place(ball: .zero, hole: SIMD3(2, 0, 0)))
        #expect(simd_length(p.leadFootPosition - SIMD3(0.16825, 0.01, -0.36335)) < 1e-4)
        #expect(simd_length(p.trailFootPosition - SIMD3(-0.24825, 0.01, -0.36335)) < 1e-4)
        // Foot long axis (local +Z under yaw) must point AT the line
        // (toward +Z from the -Z side), flared ±7° toe-out.
        let leadDir = SIMD3<Float>(sin(p.leadFootYaw), 0, cos(p.leadFootYaw))
        let trailDir = SIMD3<Float>(sin(p.trailFootYaw), 0, cos(p.trailFootYaw))
        #expect(leadDir.z > 0.99, "lead foot must point at the line")
        #expect(trailDir.z > 0.99, "trail foot must point at the line")
        #expect(leadDir.x > 0.1, "lead toe flares toward the target")
        #expect(trailDir.x < -0.1, "trail toe flares away from the target")
    }

    @Test("cardinal LH mirror: same geometry reflected across the aim line")
    func cardinalLeftHanded() throws {
        let p = try #require(place(ball: .zero, hole: SIMD3(2, 0, 0), handedness: .left))
        #expect(simd_length(p.leadFootPosition - SIMD3(0.16825, 0.01, 0.36335)) < 1e-4)
        #expect(simd_length(p.trailFootPosition - SIMD3(-0.24825, 0.01, 0.36335)) < 1e-4)
        #expect(p.sideSign == -1)
        let leadDir = SIMD3<Float>(sin(p.leadFootYaw), 0, cos(p.leadFootYaw))
        #expect(leadDir.z < -0.99, "LH lead foot points at the line from +Z side")
    }

    // MARK: - Properties over random configurations

    @Test("anti-straddle invariant: both feet on the SAME side at setback distance")
    func sameSideInvariant() throws {
        var rng = LCG(state: 42)
        for _ in 0..<50 {
            let ball = SIMD3<Float>(Float(rng.uniform(-3, 3)), Float(rng.uniform(-2, 0)), Float(rng.uniform(-3, 3)))
            let theta = rng.uniform(0, 2 * .pi)
            let dist = Float(rng.uniform(0.5, 4))
            let hole = ball + SIMD3<Float>(Float(cos(theta)), 0, Float(sin(theta))) * dist
            let handed: UserProfile.Handedness = rng.next() < 0.5 ? .right : .left
            let heightCm = rng.uniform(150, 200)

            let p = try #require(place(ball: ball, hole: hole, heightCm: heightCm, handedness: handed))
            let aim = try #require(GreenFrame.aim(ball: ball, hole: hole))
            let left = GreenFrame.leftPerp(of: aim)

            let leadSide = simd_dot(p.leadFootPosition - ball, left)
            let trailSide = simd_dot(p.trailFootPosition - ball, left)
            let stance = StanceGeometry.compute(profile: UserProfile(heightCm: heightCm, handedness: handed))
            let expectedSide = Float(stance.setbackMetres) * p.sideSign

            #expect(abs(leadSide - expectedSide) < 1e-3,
                    "lead foot must sit exactly setback to the stance side (b79 bug: straddle)")
            #expect(abs(trailSide - expectedSide) < 1e-3,
                    "trail foot must sit exactly setback to the stance side (b79 bug: straddle)")
        }
    }

    @Test("lead foot is the one nearer the hole")
    func leadIsTowardHole() throws {
        var rng = LCG(state: 7)
        for _ in 0..<50 {
            let ball = SIMD3<Float>(Float(rng.uniform(-3, 3)), -0.8, Float(rng.uniform(-3, 3)))
            let theta = rng.uniform(0, 2 * .pi)
            let hole = ball + SIMD3<Float>(Float(cos(theta)), 0, Float(sin(theta))) * Float(rng.uniform(0.6, 4))
            let p = try #require(place(ball: ball, hole: hole))
            #expect(simd_distance(p.leadFootPosition, hole) < simd_distance(p.trailFootPosition, hole))
        }
    }

    @Test("toes point at the line for both handednesses")
    func toesPointAtLine() throws {
        var rng = LCG(state: 99)
        for _ in 0..<50 {
            let ball = SIMD3<Float>(Float(rng.uniform(-3, 3)), -1.0, Float(rng.uniform(-3, 3)))
            let theta = rng.uniform(0, 2 * .pi)
            let hole = ball + SIMD3<Float>(Float(cos(theta)), 0, Float(sin(theta))) * 2
            let handed: UserProfile.Handedness = rng.next() < 0.5 ? .right : .left
            let p = try #require(place(ball: ball, hole: hole, handedness: handed))
            let aim = try #require(GreenFrame.aim(ball: ball, hole: hole))
            let towardLine = -GreenFrame.leftPerp(of: aim) * p.sideSign
            for yaw in [p.leadFootYaw, p.trailFootYaw] {
                let dir = SIMD3<Float>(sin(yaw), 0, cos(yaw))
                #expect(simd_dot(dir, towardLine) > cos(Float(8.0 * .pi / 180.0)),
                        "foot long axis must point at the line within toe-out flare")
            }
        }
    }

    @Test("ball sits one ball-width ahead of stance centre (along-aim stations)")
    func ballForwardOfCenter() throws {
        let p = try #require(place(
            ball: SIMD3(-0.8055, -0.8532, 0.4600),
            hole: SIMD3(-0.4629, -0.8535, -0.5294),
            heightCm: 185
        ))
        let aim = try #require(GreenFrame.aim(
            ball: SIMD3(-0.8055, -0.8532, 0.4600),
            hole: SIMD3(-0.4629, -0.8535, -0.5294)))
        let ball = SIMD3<Float>(-0.8055, -0.8532, 0.4600)
        let leadStation = simd_dot(p.leadFootPosition - ball, aim)
        let trailStation = simd_dot(p.trailFootPosition - ball, aim)
        #expect(abs(leadStation - 0.18663) < 1e-3)
        #expect(abs(trailStation - (-0.26663)) < 1e-3)
    }

    @Test("floor-relative Y + translation invariance (kills the absolute-y bug class)")
    func floorRelativeAndTranslationInvariant() throws {
        let ball = SIMD3<Float>(-0.8055, -0.8532, 0.4600)
        let hole = SIMD3<Float>(-0.4629, -0.8535, -0.5294)
        let p1 = try #require(place(ball: ball, hole: hole, heightCm: 185))
        #expect(abs(p1.leadFootPosition.y - (ball.y + 0.010)) < 1e-6)
        #expect(abs(p1.trailFootPosition.y - (ball.y + 0.010)) < 1e-6)

        // Translate the whole scene; output must translate identically.
        // The b46-b79 code FAILS this: its y stayed at the absolute 0.08
        // regardless of where the floor actually was. Tolerances are
        // float-ulp aware: (hole+t)−(ball+t) is not bitwise hole−ball,
        // so the derived aim/yaw wobble by an ulp at translated scale.
        let t = SIMD3<Float>(3, 5, -2)
        let p2 = try #require(place(ball: ball + t, hole: hole + t, heightCm: 185))
        #expect(simd_length((p2.leadFootPosition - p1.leadFootPosition) - t) < 5e-4)
        #expect(simd_length((p2.trailFootPosition - p1.trailFootPosition) - t) < 5e-4)
        #expect(abs(p2.leadFootYaw - p1.leadFootYaw) < 1e-3)
    }

    // MARK: - Guards

    @Test("degenerate / non-finite inputs return nil (B79 keep-last-good contract)")
    func degenerateGuards() {
        let p = SIMD3<Float>(1, -0.8, 1)
        #expect(place(ball: p, hole: p) == nil)
        #expect(place(ball: p, hole: p + SIMD3(0.006, 0, 0.006)) == nil)
        #expect(place(ball: p, hole: SIMD3(.nan, -0.8, 1)) == nil)
        #expect(place(ball: SIMD3(.infinity, 0, 0), hole: p) == nil)
    }
}
