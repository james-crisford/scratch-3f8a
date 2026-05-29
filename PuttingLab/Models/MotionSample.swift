import Foundation
import CoreMotion
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

    var rotationMagnitude: Double {
        simd_length(rotationRate)
    }

    var accelerationMagnitude: Double {
        simd_length(userAcceleration)
    }

    var isVertical: Bool {
        let downward = SIMD3<Double>(0, -1, 0)
        return simd_dot(simd_normalize(gravity), downward) > 0.96
    }
}
