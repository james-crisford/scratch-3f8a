import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif
import simd

struct MotionSample: Sendable, Equatable {
    let timestamp: TimeInterval
    let rotationRate: SIMD3<Double>
    let userAcceleration: SIMD3<Double>
    let gravity: SIMD3<Double>
    let attitude: simd_quatd

    init(
        timestamp: TimeInterval,
        rotationRate: SIMD3<Double>,
        userAcceleration: SIMD3<Double>,
        gravity: SIMD3<Double>,
        attitude: simd_quatd
    ) {
        self.timestamp = timestamp
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.attitude = attitude
    }

#if canImport(CoreMotion)
    init(from deviceMotion: CMDeviceMotion) {
        self.timestamp = deviceMotion.timestamp
        self.rotationRate = SIMD3(
            deviceMotion.rotationRate.x,
            deviceMotion.rotationRate.y,
            deviceMotion.rotationRate.z
        )
        self.userAcceleration = SIMD3(
            deviceMotion.userAcceleration.x,
            deviceMotion.userAcceleration.y,
            deviceMotion.userAcceleration.z
        )
        self.gravity = SIMD3(
            deviceMotion.gravity.x,
            deviceMotion.gravity.y,
            deviceMotion.gravity.z
        )
        let q = deviceMotion.attitude.quaternion
        self.attitude = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
    }
#endif

    var rotationMagnitude: Double {
        simd_length(rotationRate)
    }

    var accelerationMagnitude: Double {
        simd_length(userAcceleration)
    }

    /// Top-up phone orientation check. NOTE: in the documented putting
    /// grip (top of phone toward the floor) this reads FALSE by design —
    /// it exists for the reading-pose debug display (SensorDebugView row)
    /// only. No mechanics consumer; do not gate stroke logic on it.
    var isVertical: Bool {
        let downward = SIMD3<Double>(0, -1, 0)
        return simd_dot(simd_normalize(gravity), downward) > 0.96
    }

    var compassYaw: Double {
        let w = attitude.real
        let x = attitude.imag.x
        let y = attitude.imag.y
        let z = attitude.imag.z
        return atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))
    }
}
