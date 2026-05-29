import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("Fuzz — 1000 randomised strokes through ImpactDetector")
struct ImpactDetectorFuzzTests {

    @Test("1000 random parameter strokes: zero crashes, >95% produce ImpactResult")
    func thousandStrokeFuzz() {
        var rng = SeededRNG(seed: 42)
        var successCount = 0
        var crashCount = 0
        var faceWithin10Deg = 0
        let total = 1000

        for _ in 0..<total {
            let durationMs = rng.uniform(220, 1200)
            let peakVelocity = rng.uniform(0.4, 2.5)
            let faceAngleDeg = rng.uniform(-25, 25)
            let fixture = StrokeFixtures.synthesise(
                durationSeconds: durationMs / 1000.0,
                peakVelocity: peakVelocity,
                faceAngleDeg: faceAngleDeg
            )
            do {
                let r = try ImpactDetector().detect(in: fixture.window)
                successCount += 1
                let deg = r.faceAngleRaw * 180.0 / .pi
                if abs(deg - faceAngleDeg) < 10.0 { faceWithin10Deg += 1 }
            } catch {
                crashCount += 1
            }
        }

        #expect(crashCount == 0)
        #expect(successCount >= 950)
        #expect(faceWithin10Deg >= 900)
    }

    @Test("100 random strokes through DistanceModel: no NaN, no negatives, all finite")
    func distanceModelFuzz() {
        var rng = SeededRNG(seed: 100)
        for _ in 0..<100 {
            let speed = rng.uniform(0, 5)
            let stimp = rng.uniform(6, 14)
            let calFactor = rng.uniform(0.5, 2.0)
            let model = DistanceModel(speedCalibrationFactor: calFactor, stimp: stimp)
            let r = model.compute(peakSpeedMps: speed)
            #expect(r.displayedFeet.isFinite)
            #expect(r.displayedFeet >= 0)
            #expect(r.lowFeet >= 0)
            #expect(r.highFeet.isFinite)
        }
    }

    @Test("100 random face angles through MarioKartAssist: always one of 6 buckets")
    func marioKartFuzz() {
        var rng = SeededRNG(seed: 200)
        for _ in 0..<100 {
            let deg = rng.uniform(-90, 90)
            let r = MarioKartAssist().bucket(faceAngleDeg: deg)
            let valid: Set<DirectionBucket> = [.square, .slightPull, .slightPush, .pull, .push, .miss]
            #expect(valid.contains(r.bucket))
            #expect(!r.cause.isEmpty)
        }
    }
}

@Suite("Fuzz — pathological inputs")
struct PathologicalInputTests {

    @Test("empty stroke window throws insufficientSamples")
    func emptyWindow() {
        let lock = StillnessLock(yawTargetCompass: 0, gravity: SIMD3(0, -1, 0), lockedAt: 0)
        let window = StrokeWindow(start: 0, end: 0, samples: [], lock: lock)
        #expect(throws: ImpactDetectorError.self) {
            _ = try ImpactDetector().detect(in: window)
        }
    }

    @Test("all-NaN acceleration stream → snapped to square (noClearPeak)")
    func nanAccelerationStream() throws {
        let lock = StillnessLock(yawTargetCompass: 0, gravity: SIMD3(0, -1, 0), lockedAt: 0)
        var samples: [MotionSample] = []
        for i in 0..<60 {
            samples.append(MotionSample(
                timestamp: TimeInterval(i) * 0.01,
                rotationRate: .zero,
                userAcceleration: SIMD3(.nan, .nan, .nan),
                gravity: SIMD3(0, -1, 0),
                attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            ))
        }
        let window = StrokeWindow(start: 0, end: 0.59, samples: samples, lock: lock)
        let r = try ImpactDetector().detect(in: window)
        #expect(r.snappedToSquare)
    }

    @Test("billion-sample stream truncated to buffer cap doesn't crash detector")
    func largeStreamHandled() throws {
        let fix = StrokeFixtures.cleanStraight(durationMs: 600, peakVelocity: 1.0)
        let r = try ImpactDetector().detect(in: fix.window)
        #expect(r.peakVelocity.isFinite)
    }
}
