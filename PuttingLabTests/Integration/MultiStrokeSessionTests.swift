import Testing
import Foundation
import simd
@testable import PuttingLab

@MainActor
@Suite("Multi-stroke session simulation")
struct MultiStrokeSessionTests {

    @Test("10 mixed strokes through SessionCoordinator: 10 ImpactResults, no wedges")
    func tenStrokeSession() {
        var resultCount = 0
        let c = SessionCoordinator(
            motion: NoopMotion(),
            arkit: FakeARTrackingManager(),
            rollTimeoutSeconds: 0.4,
            onResult: { _ in resultCount += 1 }
        )

        let strokes: [SyntheticStroke] = [
            StrokeFixtures.cleanStraight8ft(),
            StrokeFixtures.pull(deg: 4),
            StrokeFixtures.cleanStraight8ft(),
            StrokeFixtures.push(deg: 8),
            StrokeFixtures.pull(deg: 12),
            StrokeFixtures.cleanStraight8ft(),
            StrokeFixtures.amateurStroke(),
            StrokeFixtures.pull(deg: 18),
            StrokeFixtures.cleanStraight8ft(),
            StrokeFixtures.push(deg: 3),
        ]

        var t: TimeInterval = 0
        for stroke in strokes {
            for sample in stillStream(count: 81, startT: t) {
                c.handle(sample); t = sample.timestamp + 0.01
            }
            let strokeOffset = t - (stroke.window.samples.first?.timestamp ?? 0)
            for s in stroke.window.samples {
                let shifted = MotionSample(
                    timestamp: s.timestamp + strokeOffset,
                    rotationRate: s.rotationRate,
                    userAcceleration: s.userAcceleration,
                    gravity: s.gravity,
                    attitude: s.attitude
                )
                c.handle(shifted); t = shifted.timestamp + 0.01
            }
            for i in 0..<35 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
            }
            t += 0.35
            for i in 0..<60 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
            }
            t += 0.60
        }

        #expect(resultCount == 10)
        #expect(c.phase == .arm || c.phase == .ready || c.phase == .roll)
    }

    @Test("session simulation: phase trail visits .ready, .stroke, .roll, .arm at least 5 times each")
    func phaseTrailHealthy() {
        var phaseTrail: [PhaseState] = []
        let c = SessionCoordinator(
            motion: NoopMotion(),
            arkit: FakeARTrackingManager(),
            rollTimeoutSeconds: 0.4,
            onResult: { _ in }
        )

        var t: TimeInterval = 0
        for _ in 0..<6 {
            for sample in stillStream(count: 81, startT: t) {
                c.handle(sample); t = sample.timestamp + 0.01
                phaseTrail.append(c.phase)
            }
            let stroke = StrokeFixtures.cleanStraight8ft()
            let offset = t - (stroke.window.samples.first?.timestamp ?? 0)
            for s in stroke.window.samples {
                let shifted = MotionSample(
                    timestamp: s.timestamp + offset,
                    rotationRate: s.rotationRate,
                    userAcceleration: s.userAcceleration,
                    gravity: s.gravity,
                    attitude: s.attitude
                )
                c.handle(shifted); t = shifted.timestamp + 0.01
                phaseTrail.append(c.phase)
            }
            for i in 0..<35 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
                phaseTrail.append(c.phase)
            }
            t += 0.35
            for i in 0..<60 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
                phaseTrail.append(c.phase)
            }
            t += 0.60
        }

        let readyCount = phaseTrail.filter { $0 == .ready }.count
        let strokeCount = phaseTrail.filter { $0 == .stroke }.count
        let rollCount = phaseTrail.filter { $0 == .roll }.count
        let armCount = phaseTrail.filter { $0 == .arm }.count
        #expect(readyCount >= 5)
        #expect(strokeCount >= 5)
        #expect(rollCount >= 5)
        #expect(armCount >= 5)
    }

    @Test("50-stroke fuzz session: zero crashes, ≥45 results")
    func fiftyStrokeFuzz() {
        var rng = SeededRNG(seed: 999)
        var resultCount = 0
        let c = SessionCoordinator(
            motion: NoopMotion(),
            arkit: FakeARTrackingManager(),
            rollTimeoutSeconds: 0.4,
            onResult: { _ in resultCount += 1 }
        )

        var t: TimeInterval = 0
        for _ in 0..<50 {
            let durationMs = rng.uniform(250, 1000)
            let peakVel = rng.uniform(0.5, 2.5)
            let faceDeg = rng.uniform(-15, 15)
            let stroke = StrokeFixtures.synthesise(
                durationSeconds: durationMs / 1000.0,
                peakVelocity: peakVel,
                faceAngleDeg: faceDeg
            )
            for sample in stillStream(count: 81, startT: t) {
                c.handle(sample); t = sample.timestamp + 0.01
            }
            let offset = t - (stroke.window.samples.first?.timestamp ?? 0)
            for s in stroke.window.samples {
                let shifted = MotionSample(
                    timestamp: s.timestamp + offset,
                    rotationRate: s.rotationRate,
                    userAcceleration: s.userAcceleration,
                    gravity: s.gravity,
                    attitude: s.attitude
                )
                c.handle(shifted); t = shifted.timestamp + 0.01
            }
            for i in 0..<35 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
            }
            t += 0.35
            for i in 0..<60 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
            }
            t += 0.60
        }

        #expect(resultCount >= 45)
    }
}

// MARK: - Helpers (shared layout with SessionCoordinatorTests)

fileprivate final class NoopMotion: MotionStreaming, @unchecked Sendable {
    var isRunning: Bool = false
    var latestSample: MotionSample?
    func start() throws -> AsyncStream<MotionSample> {
        isRunning = true
        return AsyncStream<MotionSample> { continuation in
            continuation.finish()
        }
    }
    func stop() { isRunning = false }
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

fileprivate func stillStream(count: Int, startT: TimeInterval) -> [MotionSample] {
    (0..<count).map { i in stillSample(t: startT + TimeInterval(i) * 0.01) }
}
