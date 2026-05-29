import Foundation
import simd

final class StillnessDetector: @unchecked Sendable {
    static let maxRotationRateRadPerSec: Double = 5.0 * .pi / 180.0
    static let maxAccelMagnitude: Double = 0.2
    /// Spec §3 phase 2 was "±15° of vertical" but research (puttinglab-putter-stroke-tempo-face)
    /// shows real putter lie angles are ~70° → phone-Y-along-shaft sits ~20° from world vertical.
    /// 15° tolerance would prevent any natural address pose from locking. Relaxed to ~25° for
    /// natural grip. Future work (KI): per-user gravity reference captured at calibration.
    /// cos(25°) ≈ 0.906; use 0.9 with a small safety margin for hand tremor.
    static let minGravityDot: Double = 0.9
    static let requiredDurationSeconds: TimeInterval = 0.8

    private let lock = NSLock()
    private var stillSinceTimestamp: TimeInterval?
    private var emitted: Bool = false

    var isAccumulating: Bool {
        lock.lock(); defer { lock.unlock() }
        return stillSinceTimestamp != nil
    }

    var hasEmittedLock: Bool {
        lock.lock(); defer { lock.unlock() }
        return emitted
    }

    func consume(_ sample: MotionSample) -> StillnessLock? {
        lock.lock(); defer { lock.unlock() }

        guard Self.isStill(sample) else {
            stillSinceTimestamp = nil
            emitted = false
            return nil
        }

        if stillSinceTimestamp == nil {
            stillSinceTimestamp = sample.timestamp
            return nil
        }

        let elapsed = sample.timestamp - (stillSinceTimestamp ?? sample.timestamp)
        guard elapsed + 1e-6 >= Self.requiredDurationSeconds, !emitted else {
            return nil
        }

        emitted = true
        return StillnessLock(
            yawTargetCompass: sample.compassYaw,
            gravity: sample.gravity,
            lockedAt: sample.timestamp
        )
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        stillSinceTimestamp = nil
        emitted = false
    }

    static func isStill(_ s: MotionSample) -> Bool {
        guard
            s.rotationMagnitude.isFinite,
            s.accelerationMagnitude.isFinite,
            s.gravity.x.isFinite, s.gravity.y.isFinite, s.gravity.z.isFinite
        else {
            return false
        }
        let gravityMag = simd_length(s.gravity)
        guard gravityMag > 0 else { return false }
        let g = s.gravity / gravityMag
        let downward = SIMD3<Double>(0, -1, 0)
        return s.rotationMagnitude < maxRotationRateRadPerSec
            && s.accelerationMagnitude < maxAccelMagnitude
            && simd_dot(g, downward) > minGravityDot
    }
}
