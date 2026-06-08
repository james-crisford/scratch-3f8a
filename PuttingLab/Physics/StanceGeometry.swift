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
///   * Putter lie angle at address: 70° from vertical (USGA standard for
///     conforming putters). Hand-to-ball horizontal distance therefore
///     equals `putterLength × cos(70°)` ≈ `putterLength × 0.342`.
///
/// The numbers come out very small in practice — a 170 cm user has a
/// bideltoid shoulder width of about 41.7 cm, so each foot marker sits
/// ~20.8 cm to the side of the ball. This is closer to a real golf stance
/// than the hard-coded 36 cm flanking spread we shipped in B77, and it
/// scales with the user instead of forcing a one-size-fits-all stance.
struct StanceGeometry: Sendable, Equatable {

    /// Outer-shoulder-to-outer-shoulder width in metres.
    let shoulderWidthMetres: Double

    /// Half-width — the lateral distance from the ball centreline to the
    /// centre of each foot marker. By convention each foot sits directly
    /// under the corresponding shoulder, so half the shoulder width.
    var footHalfSpreadMetres: Double { shoulderWidthMetres / 2.0 }

    /// Distance from the ball, along the -aim direction (away from the
    /// target), where the stance line crosses the aim line. Default
    /// putter geometry puts the user's hands ~29 cm from the ball; feet
    /// sit roughly under the hands at address.
    let handToBallMetres: Double

    /// Plausible adult-putter shaft range. 30 in is the shortest standard
    /// adult putter sold (e.g. junior-adult crossover); 40 in is at the
    /// upper end of long-mallet specifications. Anything outside this
    /// range is treated as a typo (e.g. "340") and clamped — same
    /// philosophy as `UserProfile.heightMetresClamped`.
    static let putterLengthMinInches: Double = 30.0
    static let putterLengthMaxInches: Double = 40.0

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
        // Lie angle 70° from vertical → horizontal hand-to-ball offset is
        // shaft length × cos(70°). cos(70°) ≈ 0.342.
        let putterInchesSafe = min(max(putterLengthInches,
                                       putterLengthMinInches),
                                   putterLengthMaxInches)
        let putterMetres = putterInchesSafe * 0.0254
        let handToBall = putterMetres * 0.342
        return StanceGeometry(
            shoulderWidthMetres: shoulderWidth,
            handToBallMetres: handToBall
        )
    }
}
