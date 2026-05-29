import Foundation
import simd

struct StillnessLock: Sendable, Equatable {
    let yawTargetCompass: Double
    let gravity: SIMD3<Double>
    let lockedAt: TimeInterval
}
