import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("Invariants — properties that should hold for any valid input")
struct InvariantTests {

    // ──────────────────────────────────────────────────────────────────
    // P1. Clean strokes within the putting envelope MUST NOT snap.
    // ──────────────────────────────────────────────────────────────────

    @Test(
        "P1: clean strokes with peakVel∈[0.5,2.5] m/s, dur∈[300,1100]ms NEVER snap",
        arguments: [
            (durationMs: 300, peakVel: 0.5),
            (durationMs: 400, peakVel: 1.0),
            (durationMs: 500, peakVel: 1.5),
            (durationMs: 600, peakVel: 1.0),
            (durationMs: 700, peakVel: 1.8),
            (durationMs: 800, peakVel: 1.2),
            (durationMs: 900, peakVel: 0.8),
            (durationMs: 1000, peakVel: 1.5),
            (durationMs: 1100, peakVel: 2.0),
            (durationMs: 600, peakVel: 2.5),
        ]
    )
    func cleanStrokesNeverSnap(durationMs: Int, peakVel: Double) throws {
        let fixture = StrokeFixtures.cleanStraight(durationMs: durationMs, peakVelocity: peakVel)
        let r = try ImpactDetector().detect(in: fixture.window)
        #expect(!r.snappedToSquare, "duration=\(durationMs)ms, peakVel=\(peakVel) m/s should NOT snap")
        #expect(r.snapReason == nil)
        #expect(r.peakVelocity > 0)
        #expect(r.confidence > 0)
    }

    // ──────────────────────────────────────────────────────────────────
    // P2. ANY snapped result has confidence=0, faceAngleRaw=0,
    //     peakVelocity=0, attitude=identity, and a non-nil snapReason.
    // ──────────────────────────────────────────────────────────────────

    @Test(
        "P2: snapped results have all zero-fields + non-nil reason",
        arguments: SnapReason.allTestable
    )
    func snappedResultInvariants(reason: SnapReason) throws {
        let fixture: SyntheticStroke
        switch reason {
        case .strokeTooShort:
            fixture = StrokeFixtures.flickShort(ms: 150)
        case .noClearPeak:
            fixture = StrokeFixtures.zeroAccel()
        case .peakSpeedTooLow:
            fixture = StrokeFixtures.cleanStraight(durationMs: 600, peakVelocity: 0.1)
        case .arkitLost:
            // Cannot synthesize this from a single-window detect call; it's set externally.
            return
        }
        let r = try ImpactDetector().detect(in: fixture.window)
        #expect(r.snappedToSquare)
        #expect(r.snapReason == reason)
        #expect(r.confidence == 0)
        #expect(r.faceAngleRaw == 0)
        #expect(r.peakVelocity == 0)
        #expect(r.attitudeAtImpact.real == 1.0)
        #expect(r.attitudeAtImpact.imag == SIMD3<Double>.zero)
    }

    // ──────────────────────────────────────────────────────────────────
    // P3. ANY stillness lock follows from 800ms+ of contiguous samples
    //     that satisfy all three stillness conditions.
    // ──────────────────────────────────────────────────────────────────

    @Test(
        "P3: stillness lock requires 800ms of [|ω|<5°/s ∧ |a|<0.2 m/s² ∧ gravity·down>0.9]",
        arguments: [
            // (rotation rad/s, accel m/s², gravity dot, expect_lock)
            (0.0, 0.0, 1.0, true),         // perfect still
            (0.05, 0.1, 0.99, true),       // within all thresholds
            (5.0 * .pi / 180.0, 0.0, 1.0, false),  // 5°/s exactly = rejected (strict <)
            (0.0, 0.2, 1.0, false),        // 0.2 m/s² = rejected
            (0.0, 0.0, 0.89, false),       // below gravity threshold
            (0.0, 0.0, 0.91, true),        // just above gravity threshold
        ]
    )
    func stillnessConditionsAreNecessary(
        rotation: Double, accel: Double, gravityDot: Double, expectLock: Bool
    ) {
        let gravityY = -gravityDot
        let gravityX = sqrt(max(0, 1 - gravityDot * gravityDot))
        let gravity = SIMD3<Double>(gravityX, gravityY, 0)
        let s = MotionSample(
            timestamp: 0,
            rotationRate: SIMD3(rotation, 0, 0),
            userAcceleration: SIMD3(accel, 0, 0),
            gravity: gravity,
            attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        )
        #expect(StillnessDetector.isStill(s) == expectLock,
                "rot=\(rotation), accel=\(accel), grav·down=\(gravityDot): expected isStill=\(expectLock)")
    }

    @Test("P3b: 800ms of still samples fires lock; 799ms doesn't")
    func stillnessTimingInvariant() {
        let d = StillnessDetector()
        var lock: StillnessLock?
        for i in 0...79 {
            let t = TimeInterval(i) * 0.01
            lock = d.consume(stillSample(t: t))
        }
        #expect(lock == nil, "lock should NOT fire at 790ms (i=79, t=0.79)")

        // Sample 80 = elapsed 0.80s = exactly threshold (with 1µs FP tolerance)
        lock = d.consume(stillSample(t: 0.80))
        #expect(lock != nil, "lock should fire at 800ms (i=80, t=0.80)")
    }
}

// Helper: enumerate snap reasons that can be triggered from a single ImpactDetector.detect call.
fileprivate extension SnapReason {
    static var allTestable: [SnapReason] {
        [.strokeTooShort, .noClearPeak, .peakSpeedTooLow]
    }
}

fileprivate func stillSample(t: TimeInterval) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: SIMD3(0.001, 0.001, 0.001),
        userAcceleration: SIMD3(0.001, 0, 0),
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}
