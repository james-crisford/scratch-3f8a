import Foundation
import simd

/// Address-stance dimensions derived from the user's height + putter length.
///
/// Sources:
///   * Bideltoid (outer-shoulder-to-outer-shoulder) ≈ 0.245 × stature, with
///     ANSUR II reporting ~0.26 for the adult male median and ~0.23 for the
///     adult female median. 0.245 is the centred working value used here.
///   * Standard adult putter shaft length: 33-35 inches. We default to 34 in
///     until the user can override it. Source: PGA TOUR equipment standards.
///   * Putter lie angle: conventionally ~70° measured from the GROUND plane
///     (the pre-B80 comment said "from vertical", which mislabels the
///     convention, but cos(70°) IS the correct horizontal projection for a
///     70°-from-ground lie, so the ~0.295 m value stands). Hand-to-ball
///     horizontal distance = `putterLength × cos(70°)` ≈ `putterLength ×
///     0.342`.
struct StanceGeometry: Sendable, Equatable {

    /// Outer-shoulder-to-outer-shoulder width in metres.
    let shoulderWidthMetres: Double

    /// Half-width — half the lead-to-trail foot spread. By convention each
    /// foot sits directly under the corresponding shoulder, so half the
    /// shoulder width. B80: the spread runs ALONG the target line (lead
    /// foot toward the hole), not across it.
    var footHalfSpreadMetres: Double { shoulderWidthMetres / 2.0 }

    /// Horizontal distance from the ball to the user's hands at address,
    /// PERPENDICULAR to the target line (putter-lie trig — see header).
    /// B80: this is the base of the stance-line setback; pre-B80 it was
    /// computed and never read, and its doc comment pointed it down the
    /// wrong axis ("along the -aim direction").
    let handToBallMetres: Double

    /// User's clamped standing height — scales the toe-line setback.
    let heightMetres: Double

    /// Plausible adult-putter shaft range. 30 in is the shortest standard
    /// adult putter sold (e.g. junior-adult crossover); 40 in is at the
    /// upper end of long-mallet specifications. Anything outside this
    /// range is treated as a typo (e.g. "340") and clamped — same
    /// philosophy as `UserProfile.heightMetresClamped`.
    static let putterLengthMinInches: Double = 30.0
    static let putterLengthMaxInches: Double = 40.0

    /// Perpendicular distance from the target line to the STANCE LINE
    /// (the line through both foot-marker centres). The putter pins the
    /// hands ~0.295 m from the ball; eyes-over-ball posture puts the toes
    /// a further height-scaled step back. 1.78 m user → ≈ 0.37 m, inside
    /// the 0.35-0.45 m empirical toe-line band for putting.
    var setbackMetres: Double { handToBallMetres + 0.04 * heightMetres }

    /// Construct from the user's declared height and a putter length in
    /// inches (default 34 in). `putterLengthInches` is clamped to
    /// `[putterLengthMinInches, putterLengthMaxInches]` so a typo (e.g.
    /// the user enters 340 instead of 34) cannot push the address marker
    /// metres off screen.
    static func compute(profile: UserProfile,
                        putterLengthInches: Double = 34.0) -> StanceGeometry {
        let heightM = profile.heightMetresClamped
        // 0.245 = centred bideltoid-to-stature ratio (ANSUR II adult median
        // averaged across sexes). Scales with the user's actual height
        // instead of assuming the 170 cm median.
        let shoulderWidth = heightM * 0.245
        // Lie ~70° from the ground → horizontal hand-to-ball offset is
        // shaft length × cos(70°). cos(70°) ≈ 0.342.
        let putterInchesSafe = min(max(putterLengthInches,
                                       putterLengthMinInches),
                                   putterLengthMaxInches)
        let putterMetres = putterInchesSafe * 0.0254
        let handToBall = putterMetres * 0.342
        return StanceGeometry(
            shoulderWidthMetres: shoulderWidth,
            handToBallMetres: handToBall,
            heightMetres: heightM
        )
    }
}

/// B80 — fully-resolved foot-marker placement in ARKit world coordinates.
/// Output of the pure `StanceGeometry.addressPlacement` function so the
/// geometry is unit-testable without RealityKit.
struct StancePlacement: Sendable, Equatable {
    /// Lead foot (nearer the hole) marker centre, world coords, floor-
    /// relative Y already applied.
    let leadFootPosition: SIMD3<Float>
    /// Trail foot (away from the hole) marker centre.
    let trailFootPosition: SIMD3<Float>
    /// Yaw (radians, about world +Y) for each foot rectangle. The mesh's
    /// long axis is local +Z; these yaws point it from the golfer's toes
    /// AT the target line, with a slight toe-out flare.
    let leadFootYaw: Float
    let trailFootYaw: Float
    /// Stance-line centre (between the feet), for telemetry.
    let stanceCenter: SIMD3<Float>
    /// +1 = right-handed (golfer LEFT of the aim vector), -1 = left-handed.
    let sideSign: Float
}

extension StanceGeometry {

    /// Vertical lift of the foot decals above the raycast floor. 10 mm:
    /// enough to clear z-fighting and small detected-plane tilt across the
    /// ~0.4 m lateral offset, small enough to read as "on the carpet".
    /// (The B57 "LiDAR occlusion sits 3-5 cm above floor" rationale for a
    /// big lift is inoperative — RealityKit scene-understanding occlusion
    /// is never enabled in this app; the pre-B77 invisibility was frustum
    /// culling. If occlusion is ever enabled, revisit — don't just raise
    /// this.)
    static let markerLiftMetres: Double = 0.010

    /// Ball sits about one ball-width (42.7 mm) ahead of stance centre —
    /// standard putting doctrine (contact fractionally on the upstroke).
    /// Implemented by shifting the FEET back along −aim; the ball anchor
    /// never moves.
    static let ballForwardMetres: Double = 0.040

    /// Slight toe-out flare per foot. Real stances aren't rail-parallel.
    static let toeOutRadians: Double = 7.0 * .pi / 180.0

    /// Pure stance solver: where do a golfer's feet go for this putt?
    ///
    /// A RIGHT-handed golfer stands on the LEFT of the aim vector
    /// (up × aim side): facing the line with the target on his left means
    /// his facing direction f satisfies up × f = aim ⇒ f = aim × up, and
    /// he stands offset from the ball OPPOSITE his facing — the up × aim
    /// side. Cross-checked against down-the-line camera footage and the
    /// b79 session video (James's real feet were left of the line).
    /// Left-handed mirrors everything via `sideSign`.
    ///
    /// Returns nil for degenerate/non-finite aim (ball ≈ hole) — callers
    /// must keep last-good markers in that case (B79 guard ordering).
    static func addressPlacement(
        ball: SIMD3<Float>,
        hole: SIMD3<Float>,
        stance: StanceGeometry,
        handedness: UserProfile.Handedness
    ) -> StancePlacement? {
        guard ball.x.isFinite, ball.y.isFinite, ball.z.isFinite,
              let aim = GreenFrame.aim(ball: ball, hole: hole) else { return nil }

        let side: Float = handedness == .right ? 1.0 : -1.0
        let sideVec = GreenFrame.leftPerp(of: aim) * side

        let setback = Float(stance.setbackMetres)
        let halfSpread = Float(stance.footHalfSpreadMetres)
        let lift = Float(Self.markerLiftMetres)
        let ballForward = Float(Self.ballForwardMetres)

        var center = ball + sideVec * setback - aim * ballForward
        center.y = ball.y + lift

        let lead = center + aim * halfSpread
        let trail = center - aim * halfSpread

        // Foot long axis (mesh local +Z) points from the toes AT the line:
        // baseYaw = aimYaw − side·90° maps local +Z onto −sideVec.
        // Toe-out flares the toes apart, lead foot toward the target.
        let aimYaw = atan2(aim.x, aim.z)
        let baseYaw = aimYaw - side * (.pi / 2)
        let toeOut = Float(Self.toeOutRadians)

        return StancePlacement(
            leadFootPosition: lead,
            trailFootPosition: trail,
            leadFootYaw: baseYaw + side * toeOut,
            trailFootYaw: baseYaw - side * toeOut,
            stanceCenter: center,
            sideSign: side
        )
    }
}
