import Foundation
import simd

/// Captured phone pose at the moment the user holds the address
/// position still. Built by `AddressPoseCapture` (Slice 3.2 / B47)
/// when the existing `StillnessDetector` emits a lock and the
/// AR session reports a valid camera transform.
///
/// All fields are value-type Sendable so the struct flows freely
/// through the SwiftUI `PlacementState` enum (Equatable + Sendable
/// auto-derived).
struct AddressPose: Sendable, Equatable {
    /// Full 4×4 world transform of the phone (= the AR camera) at
    /// the lock instant. Used by `BallRollAnimator` in Slice 3.4
    /// to place the ball's roll origin at the addressed putter
    /// position and by stroke detection in Slice 3.3 to anchor
    /// the swing reference frame.
    let phoneWorldTransform: simd_float4x4

    /// Phone-to-ball distance in metres at lock time. Useful for
    /// sanity-checking the address geometry — typically 30-90 cm
    /// for a real putting setup.
    let phoneToBallM: Float

    /// Compass yaw at the lock instant (radians). From the IMU,
    /// not the AR camera transform. Used as the address-frame
    /// heading reference.
    let compassYaw: Double

    /// Gravity vector as the IMU saw it at lock. Used by the
    /// stroke detector to define "up" in the phone's local frame.
    let gravity: SIMD3<Double>

    /// Wall-clock timestamp the lock fired.
    let lockedAt: TimeInterval

    /// Convenience accessor for the phone's world position (just
    /// the translation column of `phoneWorldTransform`).
    var phoneWorldPosition: SIMD3<Float> {
        SIMD3<Float>(phoneWorldTransform.columns.3.x,
                     phoneWorldTransform.columns.3.y,
                     phoneWorldTransform.columns.3.z)
    }

    /// Euler-decomposed pose (yaw / pitch / roll in radians) for
    /// JSON logging. Computed from `phoneWorldTransform`'s
    /// rotation submatrix. Order: ZYX (Tait-Bryan), the
    /// convention RealityKit uses internally.
    var eulerYPR: (yaw: Float, pitch: Float, roll: Float) {
        let m = phoneWorldTransform
        let pitch = asin(-m.columns.2.y)
        let yaw   = atan2(m.columns.2.x, m.columns.2.z)
        let roll  = atan2(m.columns.0.y, m.columns.1.y)
        return (yaw, pitch, roll)
    }
}
