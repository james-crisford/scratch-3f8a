import Foundation
import simd

/// B80 — single owner of the green-frame ↔ ARKit-world handedness convention.
///
/// Green frame (BallPhysics): +x toward the cup, +y = LEFT of the target line
/// as seen from above (synthesis §1.1). ARKit world: right-handed, +Y up.
///
/// Why this exists: pre-B80, `BallRollAnimator` and `placeAddressMarkers`
/// each hand-rolled the lateral perpendicular as `(-aim.z, 0, aim.x)`.
/// In a right-handed +Y-up frame that vector is `aim × up` = the RIGHT of
/// the aim line (true left is `up × aim = (aim.z, 0, -aim.x)`; check
/// aim = +X → left = -Z). The renderer therefore mirrored every roll
/// across the target line — the b79 session video showed all three putts
/// rolling RIGHT while the buckets said "pull — ball goes left". Every
/// future consumer of green↔world lateral mapping MUST go through these
/// helpers so the handedness convention lives in exactly one place.
enum GreenFrame {

    /// Horizontal unit aim vector ball → hole, or nil when degenerate
    /// (co-located within 1 cm, or non-finite components — ARKit can emit
    /// non-finite transforms during tracking-limited transitions).
    static func aim(ball: SIMD3<Float>, hole: SIMD3<Float>) -> SIMD3<Float>? {
        let v = SIMD3<Float>(hole.x - ball.x, 0, hole.z - ball.z)
        guard v.x.isFinite, v.z.isFinite else { return nil }
        let len = simd_length(v)
        guard len > 0.01 else { return nil }
        return v / len
    }

    /// LEFT of the aim line viewed from above: `up × aim = (aim.z, 0, -aim.x)`.
    /// "Left" means the left hand of an observer standing at the ball,
    /// facing the hole.
    static func leftPerp(of aim: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(aim.z, 0, -aim.x)
    }

    /// Map a green-frame point (+x toward cup, +y left) to a horizontal
    /// world-frame offset from the ball. Y is left at 0 — callers own
    /// their own floor-relative lift.
    static func worldOffset(green: SIMD2<Double>, aim: SIMD3<Float>) -> SIMD3<Float> {
        aim * Float(green.x) + leftPerp(of: aim) * Float(green.y)
    }

    /// Signed lateral distance of a world offset, positive to the LEFT of
    /// the aim line. Test seam for end-to-end sign-chain assertions.
    static func signedLeft(of worldOffset: SIMD3<Float>, aim: SIMD3<Float>) -> Float {
        simd_dot(worldOffset, leftPerp(of: aim))
    }
}
