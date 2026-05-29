import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("StillnessDetector — lock behaviour")
struct StillnessDetectorLockTests {

    @Test("starts in unlocked, non-accumulating state")
    func startsUnlocked() {
        let d = StillnessDetector()
        #expect(!d.isAccumulating)
        #expect(!d.hasEmittedLock)
    }

    @Test("locks after exactly 800ms of still stream")
    func locksAfter800ms() {
        let d = StillnessDetector()
        var lock: StillnessLock?
        var firedAt: Int = -1
        for i in 0...80 {
            let t = TimeInterval(i) * 0.01
            lock = d.consume(stillSample(t: t))
            if lock != nil {
                firedAt = i
                break
            }
        }
        #expect(lock != nil)
        #expect(firedAt == 80)
        #expect(abs((lock?.lockedAt ?? 0) - 0.80) < 1e-9)
    }

    @Test("does NOT lock at 799ms")
    func noLockAt799ms() {
        let d = StillnessDetector()
        var lock: StillnessLock?
        for i in 0...79 {
            let t = TimeInterval(i) * 0.01
            lock = d.consume(stillSample(t: t))
        }
        #expect(lock == nil)
        #expect(d.isAccumulating)
        #expect(!d.hasEmittedLock)
    }

    @Test("does not emit a second lock while still continues")
    func singleEmitWhileStill() {
        let d = StillnessDetector()
        var locks: [StillnessLock] = []
        for i in 0...200 {
            let t = TimeInterval(i) * 0.01
            if let l = d.consume(stillSample(t: t)) {
                locks.append(l)
            }
        }
        #expect(locks.count == 1)
    }

    @Test("rotation rate spike mid-window resets accumulator")
    func rotationSpikeResets() {
        let d = StillnessDetector()
        for i in 0...40 {
            _ = d.consume(stillSample(t: TimeInterval(i) * 0.01))
        }
        _ = d.consume(spinSample(t: 0.41))
        #expect(!d.isAccumulating)
        #expect(!d.hasEmittedLock)
    }

    @Test("acceleration spike mid-window resets accumulator")
    func accelSpikeResets() {
        let d = StillnessDetector()
        for i in 0...40 {
            _ = d.consume(stillSample(t: TimeInterval(i) * 0.01))
        }
        _ = d.consume(accelSpikeSample(t: 0.41))
        #expect(!d.isAccumulating)
    }

    @Test("tilt past 15° from vertical resets accumulator")
    func tiltResets() {
        let d = StillnessDetector()
        for i in 0...40 {
            _ = d.consume(stillSample(t: TimeInterval(i) * 0.01))
        }
        _ = d.consume(tiltedSample(t: 0.41))
        #expect(!d.isAccumulating)
    }

    @Test("back-to-back lock after reset cycle")
    func backToBackLock() {
        let d = StillnessDetector()
        var first: StillnessLock?
        for i in 0...80 {
            first = d.consume(stillSample(t: TimeInterval(i) * 0.01))
            if first != nil { break }
        }
        #expect(first != nil)
        _ = d.consume(spinSample(t: 0.81))
        var second: StillnessLock?
        for i in 0...80 {
            let t = 1.0 + TimeInterval(i) * 0.01
            second = d.consume(stillSample(t: t))
            if second != nil { break }
        }
        #expect(second != nil)
        #expect(abs((second?.lockedAt ?? 0) - 1.80) < 1e-9)
    }

    @Test("reset() clears state")
    func resetClears() {
        let d = StillnessDetector()
        for i in 0...80 {
            _ = d.consume(stillSample(t: TimeInterval(i) * 0.01))
        }
        d.reset()
        #expect(!d.isAccumulating)
        #expect(!d.hasEmittedLock)
    }
}

@Suite("StillnessDetector — boundary conditions")
struct StillnessDetectorBoundaryTests {

    @Test("rotation rate exactly at 5°/s threshold → not still")
    func rotationAtThresholdRejected() {
        let s = sample(
            t: 0,
            rotation: SIMD3(StillnessDetector.maxRotationRateRadPerSec, 0, 0),
            accel: .zero,
            gravity: SIMD3(0, -1, 0)
        )
        #expect(!StillnessDetector.isStill(s))
    }

    @Test("rotation rate just under 5°/s → still")
    func rotationUnderThresholdAccepted() {
        let s = sample(
            t: 0,
            rotation: SIMD3(StillnessDetector.maxRotationRateRadPerSec - 1e-6, 0, 0),
            accel: .zero,
            gravity: SIMD3(0, -1, 0)
        )
        #expect(StillnessDetector.isStill(s))
    }

    @Test("acceleration exactly at 0.2 m/s² → not still")
    func accelAtThresholdRejected() {
        let s = sample(
            t: 0,
            rotation: .zero,
            accel: SIMD3(0.2, 0, 0),
            gravity: SIMD3(0, -1, 0)
        )
        #expect(!StillnessDetector.isStill(s))
    }

    @Test("acceleration just under 0.2 m/s² → still")
    func accelUnderThresholdAccepted() {
        let s = sample(
            t: 0,
            rotation: .zero,
            accel: SIMD3(0.2 - 1e-6, 0, 0),
            gravity: SIMD3(0, -1, 0)
        )
        #expect(StillnessDetector.isStill(s))
    }

    @Test("gravity dot well below 0.966 → not still")
    func gravityWellBelowThresholdRejected() {
        let g = SIMD3<Double>(sqrt(1 - 0.95 * 0.95), -0.95, 0)
        let s = sample(t: 0, rotation: .zero, accel: .zero, gravity: g)
        #expect(!StillnessDetector.isStill(s))
    }

    @Test("gravity dot 0.96 (just below spec 0.966 threshold) → not still")
    func gravityAt0_96NotStill() {
        let g = SIMD3<Double>(sqrt(1 - 0.96 * 0.96), -0.96, 0)
        let s = sample(t: 0, rotation: .zero, accel: .zero, gravity: g)
        #expect(!StillnessDetector.isStill(s))
    }

    @Test("gravity dot 0.97 (just above spec 0.966 threshold) → still")
    func gravityAt0_97Still() {
        let g = SIMD3<Double>(sqrt(1 - 0.97 * 0.97), -0.97, 0)
        let s = sample(t: 0, rotation: .zero, accel: .zero, gravity: g)
        #expect(StillnessDetector.isStill(s))
    }

    @Test("gravity dot just above 0.96 → still")
    func gravityAboveThresholdAccepted() {
        let g = SIMD3<Double>(0, -0.99, 0)
        let s = sample(t: 0, rotation: .zero, accel: .zero, gravity: g)
        #expect(StillnessDetector.isStill(s))
    }

    @Test("zero gravity vector rejected")
    func zeroGravityRejected() {
        let s = sample(t: 0, rotation: .zero, accel: .zero, gravity: .zero)
        #expect(!StillnessDetector.isStill(s))
    }

    @Test("NaN in any field rejects sample as not still")
    func nanRejected() {
        let nanG = SIMD3<Double>(.nan, -1, 0)
        let s = sample(t: 0, rotation: .zero, accel: .zero, gravity: nanG)
        #expect(!StillnessDetector.isStill(s))
    }
}

@Suite("StillnessDetector — snapshot integrity")
struct StillnessDetectorSnapshotTests {

    @Test("lock preserves exact compass yaw at lock moment")
    func preservesYaw() {
        let d = StillnessDetector()
        var lock: StillnessLock?
        let yaw: Double = 1.234
        let q = simd_quatd(angle: yaw, axis: SIMD3(0, 0, 1))
        for i in 0...80 {
            let t = TimeInterval(i) * 0.01
            let s = MotionSample(
                timestamp: t,
                rotationRate: .zero,
                userAcceleration: .zero,
                gravity: SIMD3(0, -1, 0),
                attitude: q
            )
            lock = d.consume(s)
            if lock != nil { break }
        }
        #expect(lock != nil)
        #expect(abs(lock!.yawTargetCompass - yaw) < 1e-9)
    }

    @Test("lock preserves gravity snapshot")
    func preservesGravity() {
        let d = StillnessDetector()
        let g = SIMD3<Double>(0.05, -0.98, 0.01)
        var lock: StillnessLock?
        for i in 0...80 {
            let t = TimeInterval(i) * 0.01
            let s = MotionSample(
                timestamp: t,
                rotationRate: .zero,
                userAcceleration: .zero,
                gravity: g,
                attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            )
            lock = d.consume(s)
            if lock != nil { break }
        }
        #expect(lock?.gravity == g)
    }

    @Test("lockedAt matches sample.timestamp at lock fire")
    func lockedAtMatches() {
        let d = StillnessDetector()
        var lock: StillnessLock?
        for i in 0...80 {
            let t = TimeInterval(i) * 0.01 + 100.0
            lock = d.consume(stillSample(t: t))
            if lock != nil { break }
        }
        #expect(lock != nil)
        #expect(abs((lock?.lockedAt ?? 0) - 100.80) < 1e-9)
    }
}

@Suite("StillnessDetector — concurrency, perf, memory")
struct StillnessDetectorConcurrencyTests {

    @Test("performance: 10k samples consumed in < 100ms")
    func performance() {
        let d = StillnessDetector()
        let start = Date()
        for i in 0..<10_000 {
            _ = d.consume(stillSample(t: TimeInterval(i) * 0.01))
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.1)
    }

    @Test("determinism: identical streams produce identical lock")
    func determinism() {
        var l1: StillnessLock?
        var l2: StillnessLock?
        let d1 = StillnessDetector()
        let d2 = StillnessDetector()
        for i in 0...80 {
            let t = TimeInterval(i) * 0.01
            let s = stillSample(t: t)
            if l1 == nil { l1 = d1.consume(s) }
            if l2 == nil { l2 = d2.consume(s) }
        }
        #expect(l1 == l2)
    }

    @Test("no retain cycle")
    func noRetainCycle() {
        weak var weakRef: StillnessDetector?
        autoreleasepool {
            let d = StillnessDetector()
            _ = d.consume(stillSample(t: 0))
            weakRef = d
        }
        #expect(weakRef == nil)
    }

    @Test("concurrent reads of state do not crash")
    func concurrentReads() async {
        let d = StillnessDetector()
        _ = d.consume(stillSample(t: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = d.isAccumulating }
                group.addTask { _ = d.hasEmittedLock }
            }
        }
    }

    @Test("100 reset cycles leave detector clean")
    func resetCycles() {
        let d = StillnessDetector()
        for _ in 0..<100 {
            _ = d.consume(stillSample(t: 0))
            d.reset()
        }
        #expect(!d.isAccumulating)
        #expect(!d.hasEmittedLock)
    }
}

@Suite("MotionSample.compassYaw")
struct MotionSampleCompassYawTests {

    @Test("identity quaternion → yaw 0")
    func identityYaw() {
        let s = MotionSample(
            timestamp: 0,
            rotationRate: .zero,
            userAcceleration: .zero,
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        )
        #expect(abs(s.compassYaw) < 1e-9)
    }

    @Test("Z-axis rotation π/4 → yaw π/4")
    func quarterRotationZ() {
        let q = simd_quatd(angle: .pi / 4, axis: SIMD3(0, 0, 1))
        let s = MotionSample(
            timestamp: 0,
            rotationRate: .zero,
            userAcceleration: .zero,
            gravity: SIMD3(0, -1, 0),
            attitude: q
        )
        #expect(abs(s.compassYaw - .pi / 4) < 1e-9)
    }

    @Test("Z-axis rotation -π/2 → yaw -π/2")
    func minusHalfRotationZ() {
        let q = simd_quatd(angle: -.pi / 2, axis: SIMD3(0, 0, 1))
        let s = MotionSample(
            timestamp: 0,
            rotationRate: .zero,
            userAcceleration: .zero,
            gravity: SIMD3(0, -1, 0),
            attitude: q
        )
        #expect(abs(s.compassYaw - (-.pi / 2)) < 1e-9)
    }

    @Test("compassYaw bounded to (-π, π]")
    func bounded() {
        for deg in stride(from: -179.0, through: 179.0, by: 23.0) {
            let rad = deg * .pi / 180.0
            let q = simd_quatd(angle: rad, axis: SIMD3(0, 0, 1))
            let s = MotionSample(
                timestamp: 0,
                rotationRate: .zero,
                userAcceleration: .zero,
                gravity: SIMD3(0, -1, 0),
                attitude: q
            )
            #expect(s.compassYaw > -.pi - 1e-6 && s.compassYaw <= .pi + 1e-6)
        }
    }
}

// MARK: - Fixture helpers (file-private to file, not type-private)

fileprivate func stillSample(t: TimeInterval) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: SIMD3(0.001, 0.001, 0.001),
        userAcceleration: SIMD3(0.001, 0.001, 0.001),
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate func spinSample(t: TimeInterval) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: SIMD3(5.0, 0, 0),
        userAcceleration: .zero,
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate func accelSpikeSample(t: TimeInterval) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: .zero,
        userAcceleration: SIMD3(2.0, 0, 0),
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate func tiltedSample(t: TimeInterval) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: .zero,
        userAcceleration: .zero,
        gravity: SIMD3(0.7, -0.7, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate func sample(
    t: TimeInterval,
    rotation: SIMD3<Double>,
    accel: SIMD3<Double>,
    gravity: SIMD3<Double>
) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: rotation,
        userAcceleration: accel,
        gravity: gravity,
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}
