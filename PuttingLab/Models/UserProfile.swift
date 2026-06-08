import Foundation

/// Per-user setup information that drives stance geometry (foot-marker
/// placement) and any future ergonomic calculations. Separate from
/// `CalibrationProfile` (which holds learned per-stroke biases) because this
/// is user-declared data, not learned data — different lifecycle, different
/// store.
///
/// B78 — added so the address foot markers can be placed at a science-backed
/// shoulder-width derived from the user's height, instead of the hard-coded
/// 26 cm half-width that used to ignore the user entirely. See
/// `StanceGeometry` for the math.
struct UserProfile: Codable, Sendable, Equatable {

    /// Self-reported standing height in centimetres. Default 170 cm = the
    /// UK adult median (ONS, Health Survey for England 2021). The user can
    /// override in Settings.
    var heightCm: Double

    /// Which side of the ball the user stands on / which hand leads. Drives
    /// foot ordering and (later) the putter-grip hand model.
    var handedness: Handedness

    enum Handedness: String, Codable, Sendable, CaseIterable, Equatable {
        case right
        case left
    }

    static let `default` = UserProfile(heightCm: 170, handedness: .right)

    /// Convenience accessor. Clamped to a plausible adult range so a typo
    /// (e.g. "1700") can't blow up downstream stance geometry.
    var heightMetresClamped: Double {
        let m = heightCm / 100.0
        return min(max(m, 1.20), 2.20)
    }
}
