import Foundation
import simd
@testable import PuttingLab

struct SyntheticStroke: Sendable {
    let name: String
    let window: StrokeWindow
    let expectedImpactTime: TimeInterval
    let expectedPeakVelocity: Double
    let expectedFaceAngleRad: Double
}

enum StrokeFixtures {

    static func synthesise(
        name: String = "synthetic",
        durationSeconds: TimeInterval = 0.6,
        peakVelocity: Double = 1.0,
        faceAngleDeg: Double = 0.0,
        rotationRateRadPerSec: Double = 2.0,
        rateHz: Double = 100.0,
        startTime: TimeInterval = 1.0,
        lockYawCompass: Double = 0.0,
        accelDirection: SIMD3<Double> = SIMD3(1, 0, 0)
    ) -> SyntheticStroke {
        let dt = 1.0 / rateHz
        let n = max(3, Int((durationSeconds / dt).rounded()))
        let faceRad = faceAngleDeg * .pi / 180.0
        let attitude = simd_quatd(angle: faceRad, axis: SIMD3(0, 0, 1))
        let omega = Double.pi / durationSeconds
        let accelAmp = peakVelocity * omega
        let forward = accelDirection / max(simd_length(accelDirection), 1e-12)

        var samples: [MotionSample] = []
        samples.reserveCapacity(n)
        for i in 0..<n {
            let t = TimeInterval(i) * dt
            let a = accelAmp * cos(omega * t)
            samples.append(MotionSample(
                timestamp: startTime + t,
                rotationRate: SIMD3(rotationRateRadPerSec, 0, 0),
                userAcceleration: forward * a,
                gravity: SIMD3(0, -1, 0),
                attitude: attitude
            ))
        }

        let lock = StillnessLock(
            yawTargetCompass: lockYawCompass,
            gravity: SIMD3(0, -1, 0),
            lockedAt: startTime - 0.001
        )
        let window = StrokeWindow(
            start: startTime,
            end: startTime + TimeInterval(n - 1) * dt,
            samples: samples,
            lock: lock
        )
        // Independent wrap math — DO NOT call production wrapAngle here, otherwise a sign
        // or bounds bug in wrapAngle would silently match the expected truth.
        var rawFace = faceRad - lockYawCompass
        while rawFace > .pi { rawFace -= 2.0 * .pi }
        while rawFace <= -.pi { rawFace += 2.0 * .pi }
        let expectedFace = rawFace
        return SyntheticStroke(
            name: name,
            window: window,
            expectedImpactTime: startTime + durationSeconds / 2.0,
            expectedPeakVelocity: peakVelocity,
            expectedFaceAngleRad: expectedFace
        )
    }

    static func cleanStraight8ft() -> SyntheticStroke {
        synthesise(name: "clean_straight_8ft", durationSeconds: 0.6, peakVelocity: 1.0, faceAngleDeg: 0)
    }

    static func cleanStraight(durationMs: Int, peakVelocity: Double = 1.0) -> SyntheticStroke {
        synthesise(
            name: "clean_straight_\(durationMs)ms",
            durationSeconds: TimeInterval(durationMs) / 1000.0,
            peakVelocity: peakVelocity,
            faceAngleDeg: 0
        )
    }

    static func pull(deg: Double) -> SyntheticStroke {
        synthesise(name: "pull_\(Int(deg))deg", faceAngleDeg: -deg)
    }

    static func push(deg: Double) -> SyntheticStroke {
        synthesise(name: "push_\(Int(deg))deg", faceAngleDeg: deg)
    }

    static func flickShort(ms: Int) -> SyntheticStroke {
        synthesise(name: "flick_short_\(ms)ms", durationSeconds: TimeInterval(ms) / 1000.0, peakVelocity: 0.5)
    }

    static func constantAccel(durationMs: Int = 600, accel: Double = 0.5) -> SyntheticStroke {
        let dt = 0.01
        let n = max(3, Int(TimeInterval(durationMs) / 1000.0 / dt))
        var samples: [MotionSample] = []
        let startTime = 1.0
        for i in 0..<n {
            let t = TimeInterval(i) * dt
            samples.append(MotionSample(
                timestamp: startTime + t,
                rotationRate: SIMD3(2.0, 0, 0),
                userAcceleration: SIMD3(accel, 0, 0),
                gravity: SIMD3(0, -1, 0),
                attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            ))
        }
        let lock = StillnessLock(yawTargetCompass: 0, gravity: SIMD3(0, -1, 0), lockedAt: startTime - 0.001)
        let window = StrokeWindow(
            start: startTime,
            end: startTime + TimeInterval(n - 1) * dt,
            samples: samples,
            lock: lock
        )
        return SyntheticStroke(
            name: "constant_accel_\(durationMs)ms",
            window: window,
            expectedImpactTime: startTime + TimeInterval(durationMs) / 2000.0,
            expectedPeakVelocity: 0,
            expectedFaceAngleRad: 0
        )
    }

    static func zeroAccel(durationMs: Int = 600) -> SyntheticStroke {
        constantAccel(durationMs: durationMs, accel: 0.0)
    }

    /// Marquardt 2007 SAM PuttLab empirical values (PGA Tour, n=99).
    /// Impact speed 1.51 m/s, downswing 317 ms, face open 0.3° at impact.
    /// See research_archive/puttinglab-putter-stroke-tempo-face-2026-05-29.md
    static func tourProDownswing(faceAngleDeg: Double = 0.3) -> SyntheticStroke {
        synthesise(
            name: "tour_pro_downswing",
            durationSeconds: 0.317,
            peakVelocity: 1.51,
            faceAngleDeg: faceAngleDeg
        )
    }

    /// Realistic full putting stroke (backswing + downswing + follow-through ≈ 1100 ms).
    static func tourProFullStroke(faceAngleDeg: Double = 0.3) -> SyntheticStroke {
        synthesise(
            name: "tour_pro_full",
            durationSeconds: 0.820,
            peakVelocity: 1.51,
            faceAngleDeg: faceAngleDeg
        )
    }

    /// Amateur recreational putt — slower, less consistent, wider face deviation.
    static func amateurStroke(durationMs: Int = 900, peakVelocity: Double = 1.0, faceAngleDeg: Double = 2.5) -> SyntheticStroke {
        synthesise(
            name: "amateur_\(durationMs)ms",
            durationSeconds: TimeInterval(durationMs) / 1000.0,
            peakVelocity: peakVelocity,
            faceAngleDeg: faceAngleDeg
        )
    }
}
