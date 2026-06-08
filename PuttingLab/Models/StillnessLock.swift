import Foundation
import simd

struct StillnessLock: Sendable, Equatable {
    /// DEPRECATED in B78. Pre-B78 the face-angle pipeline subtracted this
    /// from the compass yaw at impact to get the address-relative face
    /// angle. The new pipeline uses `attitudeAtPress` instead — every
    /// stroke self-calibrates from the IMU attitude quaternion captured
    /// the instant the user presses (declaring "square" by gesture). The
    /// field is kept so existing call sites + tests + serialized lock
    /// data round-trip, but FaceAngleComputer no longer reads it.
    let yawTargetCompass: Double
    /// B78 — IMU attitude quaternion captured at lock-creation.
    /// Two production paths converge on the same field:
    ///   * **AR mode (`ARPlacementView.handlePressBegan`)** — captured at
    ///     the *exact instant* the user presses the screen. The press is
    ///     the user's gestural declaration of "square = 0°".
    ///   * **Calibration mode (`StillnessDetector.consume`)** — captured
    ///     when the user has held the phone still for ~0.8 s
    ///     (`StillnessDetector.requiredDurationSeconds`). In this path the
    ///     user is not pressing; the app infers "ready" from continuous
    ///     stillness. The reference attitude is the sample whose
    ///     stillness streak reached the threshold, which can be up to
    ///     one sample stale relative to "now" (negligible at 100 Hz, ≤10
    ///     ms of additional IMU drift).
    ///
    /// `FaceAngleComputer` reads this and the impact attitude and reports
    /// the yaw delta as the face angle — no world-frame reference, no
    /// magnetometer drift, no cross-session bias. The legacy name was
    /// chosen for the AR path; do not rename without bumping the
    /// `StrokeReplay` schema version (the field is serialized).
    let attitudeAtPress: simd_quatd
    let gravity: SIMD3<Double>
    let lockedAt: TimeInterval
}
