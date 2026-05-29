import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("Noise robustness — ImpactDetector with synthetic IMU noise")
struct NoiseRobustnessTests {

    @Test("clean stroke + light Gaussian accel noise (σ=0.05 m/s²) → face angle within ±3°")
    func lightNoise() throws {
        let baseline = StrokeFixtures.cleanStraight8ft()
        let noisy = addAccelerationNoise(to: baseline.window, stddev: 0.05, seed: 1)
        let r = try ImpactDetector().detect(in: noisy)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg) < 3.0)
    }

    @Test("clean stroke + moderate noise (σ=0.20 m/s²) → face angle within ±5°")
    func moderateNoise() throws {
        let baseline = StrokeFixtures.cleanStraight8ft()
        let noisy = addAccelerationNoise(to: baseline.window, stddev: 0.20, seed: 2)
        let r = try ImpactDetector().detect(in: noisy)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg) < 5.0)
    }

    @Test("clean stroke + heavy noise (σ=0.50 m/s²) → still produces a result")
    func heavyNoise() throws {
        let baseline = StrokeFixtures.cleanStraight8ft()
        let noisy = addAccelerationNoise(to: baseline.window, stddev: 0.50, seed: 3)
        _ = try ImpactDetector().detect(in: noisy)
    }

    @Test("pull_8deg + moderate noise → still identifies as pull, deg within ±4° of -8°")
    func pullWithNoise() throws {
        let baseline = StrokeFixtures.pull(deg: 8)
        let noisy = addAccelerationNoise(to: baseline.window, stddev: 0.15, seed: 4)
        let r = try ImpactDetector().detect(in: noisy)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(deg < 0)
        #expect(abs(deg - (-8.0)) < 4.0)
    }

    @Test("rotation rate noise (σ=0.1 rad/s) → impact time still within ±15ms")
    func rotationNoiseImpactTime() throws {
        let baseline = StrokeFixtures.cleanStraight8ft()
        let noisy = addRotationNoise(to: baseline.window, stddev: 0.1, seed: 5)
        let r = try ImpactDetector().detect(in: noisy)
        #expect(abs(r.timestamp - baseline.expectedImpactTime) < 0.015)
    }

    @Test("attitude jitter (σ=0.5°) → face angle stays within ±2.5° of true")
    func attitudeJitter() throws {
        let baseline = StrokeFixtures.pull(deg: 10)
        let noisy = addAttitudeNoise(to: baseline.window, stddevDeg: 0.5, seed: 6)
        let r = try ImpactDetector().detect(in: noisy)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg - (-10.0)) < 2.5)
    }

    @Test("combined noise (accel + rotation + attitude) → still produces sensible result")
    func combinedNoise() throws {
        let baseline = StrokeFixtures.cleanStraight8ft()
        var noisy = addAccelerationNoise(to: baseline.window, stddev: 0.10, seed: 7)
        noisy = addRotationNoise(to: noisy, stddev: 0.05, seed: 8)
        noisy = addAttitudeNoise(to: noisy, stddevDeg: 0.3, seed: 9)
        let r = try ImpactDetector().detect(in: noisy)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg) < 5.0)
        #expect(r.confidence > 0.4)
    }

    @Test("100 different noise seeds → no crashes, ≥95% produce face within ±5°")
    func manyNoiseSeeds() {
        var passedFaceCheck = 0
        var crashed = 0
        let baseline = StrokeFixtures.cleanStraight8ft()
        for seed in 1...100 {
            let noisy = addAccelerationNoise(to: baseline.window, stddev: 0.15, seed: UInt64(seed))
            do {
                let r = try ImpactDetector().detect(in: noisy)
                let deg = r.faceAngleRaw * 180.0 / .pi
                if abs(deg) < 5.0 { passedFaceCheck += 1 }
            } catch {
                crashed += 1
            }
        }
        #expect(crashed == 0)
        #expect(passedFaceCheck >= 95)
    }
}

// MARK: - Noise helpers

fileprivate func addAccelerationNoise(to window: StrokeWindow, stddev: Double, seed: UInt64) -> StrokeWindow {
    var rng = SeededRNG(seed: seed)
    let noisy = window.samples.map { s in
        MotionSample(
            timestamp: s.timestamp,
            rotationRate: s.rotationRate,
            userAcceleration: SIMD3(
                s.userAcceleration.x + rng.gaussian(stddev: stddev),
                s.userAcceleration.y + rng.gaussian(stddev: stddev),
                s.userAcceleration.z + rng.gaussian(stddev: stddev)
            ),
            gravity: s.gravity,
            attitude: s.attitude
        )
    }
    return StrokeWindow(start: window.start, end: window.end, samples: noisy, lock: window.lock)
}

fileprivate func addRotationNoise(to window: StrokeWindow, stddev: Double, seed: UInt64) -> StrokeWindow {
    var rng = SeededRNG(seed: seed)
    let noisy = window.samples.map { s in
        MotionSample(
            timestamp: s.timestamp,
            rotationRate: SIMD3(
                s.rotationRate.x + rng.gaussian(stddev: stddev),
                s.rotationRate.y + rng.gaussian(stddev: stddev),
                s.rotationRate.z + rng.gaussian(stddev: stddev)
            ),
            userAcceleration: s.userAcceleration,
            gravity: s.gravity,
            attitude: s.attitude
        )
    }
    return StrokeWindow(start: window.start, end: window.end, samples: noisy, lock: window.lock)
}

fileprivate func addAttitudeNoise(to window: StrokeWindow, stddevDeg: Double, seed: UInt64) -> StrokeWindow {
    var rng = SeededRNG(seed: seed)
    let stddevRad = stddevDeg * .pi / 180.0
    let noisy = window.samples.map { s in
        let jitter = rng.gaussian(stddev: stddevRad)
        let jitterQuat = simd_quatd(angle: jitter, axis: SIMD3(0, 0, 1))
        return MotionSample(
            timestamp: s.timestamp,
            rotationRate: s.rotationRate,
            userAcceleration: s.userAcceleration,
            gravity: s.gravity,
            attitude: s.attitude * jitterQuat
        )
    }
    return StrokeWindow(start: window.start, end: window.end, samples: noisy, lock: window.lock)
}
