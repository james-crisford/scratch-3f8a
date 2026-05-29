import Testing
import Foundation
import simd
@testable import PuttingLab

@MainActor
@Suite("SessionCoordinator — basic transitions")
struct SessionCoordinatorBasicTests {

    @Test("starts in .arm")
    func startsInArm() {
        let c = SessionCoordinator(motion: NoopMotion(), arkit: FakeARTrackingManager())
        #expect(c.phase == .arm)
    }

    @Test("80 still samples (800ms) transitions .arm → .ready")
    func stillnessLockGoesToReady() {
        let c = makeCoordinator()
        for sample in stillStream(count: 81, startT: 0) {
            c.handle(sample)
        }
        #expect(c.phase == .ready)
    }

    @Test("79 still samples (790ms) keeps phase = .arm")
    func notQuiteEnoughStillness() {
        let c = makeCoordinator()
        for sample in stillStream(count: 79, startT: 0) {
            c.handle(sample)
        }
        #expect(c.phase == .arm)
    }

    @Test("reset() returns coordinator to .arm")
    func resetReturnsToArm() {
        let c = makeCoordinator()
        for sample in stillStream(count: 81, startT: 0) { c.handle(sample) }
        #expect(c.phase == .ready)
        c.reset()
        #expect(c.phase == .arm)
        #expect(c.lastImpactResult == nil)
    }

    @Test("consume in .arm with stroke-rate sample stays in .arm")
    func strokeSampleInArmStaysArm() {
        let c = makeCoordinator()
        c.handle(strokeSample(t: 0, rotationRate: 1.0))
        #expect(c.phase == .arm)
    }
}

@MainActor
@Suite("SessionCoordinator — stroke flow")
struct SessionCoordinatorStrokeFlowTests {

    @Test("READY → STROKE when stroke detector enters .starting")
    func readyToStroke() {
        let c = makeCoordinator()
        var t = 0.0
        for sample in stillStream(count: 81, startT: t) { c.handle(sample); t = sample.timestamp + 0.01 }
        #expect(c.phase == .ready)
        c.handle(strokeSample(t: t, rotationRate: 1.0))
        #expect(c.phase == .stroke)
    }

    @Test("STROKE → ROLL after full stroke completes (via .impact)")
    func strokeToRoll() {
        let c = makeCoordinator()
        let samples = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in samples { c.handle(s) }
        #expect(c.phase == .roll)
        #expect(c.lastImpactResult != nil)
    }

    @Test("lastImpactResult populated with sane face angle for clean stroke")
    func lastResultPopulated() {
        let c = makeCoordinator()
        let samples = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in samples { c.handle(s) }
        let r = c.lastImpactResult
        #expect(r != nil)
        #expect(abs(r!.faceAngleDegrees) < 2.0)
    }

    @Test("onResult callback fires exactly once per stroke")
    func onResultFiresOnce() {
        var count = 0
        let c = makeCoordinator(onResult: { _ in count += 1 })
        let samples = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in samples { c.handle(s) }
        #expect(count == 1)
    }

    @Test("pull_8deg fixture: result face angle negative within ±2°")
    func pullDetected() {
        let c = makeCoordinator()
        let samples = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.pull(deg: 8),
            quietCount: 35,
            startTime: 0
        )
        for s in samples { c.handle(s) }
        let deg = c.lastImpactResult?.faceAngleDegrees ?? 0
        #expect(deg < 0)
        #expect(abs(deg - (-8.0)) < 2.0)
    }
}

@MainActor
@Suite("SessionCoordinator — timeouts & re-arm")
struct SessionCoordinatorTimeoutTests {

    @Test("3s after .roll → returns to .arm")
    func rollTimeoutReturnsToArm() {
        let c = makeCoordinator(rollTimeoutSeconds: 1.0)
        let samples = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in samples { c.handle(s) }
        #expect(c.phase == .roll)
        let baseTime = samples.last!.timestamp
        for i in 0..<120 {
            let t = baseTime + 0.01 + TimeInterval(i) * 0.01
            c.handle(stillSample(t: t))
        }
        #expect(c.phase == .arm)
    }

    @Test("15s in .ready without stroke → returns to .arm")
    func readyTimeoutReturnsToArm() {
        let c = makeCoordinator(readyTimeoutSeconds: 2.0)
        var t = 0.0
        for s in stillStream(count: 81, startT: t) { c.handle(s); t = s.timestamp + 0.01 }
        #expect(c.phase == .ready)
        for i in 0..<250 {
            let st = t + TimeInterval(i) * 0.01
            c.handle(stillSample(t: st))
        }
        #expect(c.phase == .arm)
    }

    @Test("re-arms cleanly after a full stroke completes")
    func reArmsAfterStroke() {
        let c = makeCoordinator(rollTimeoutSeconds: 0.5)
        let samples = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in samples { c.handle(s) }
        let baseTime = samples.last!.timestamp
        for i in 0..<80 {
            let t = baseTime + 0.01 + TimeInterval(i) * 0.01
            c.handle(stillSample(t: t))
        }
        #expect(c.phase == .arm)

        var t2 = baseTime + 1.0
        for s in stillStream(count: 81, startT: t2) { c.handle(s); t2 = s.timestamp + 0.01 }
        #expect(c.phase == .ready)
    }
}

@MainActor
@Suite("SessionCoordinator — error & ARKit paths")
struct SessionCoordinatorErrorTests {

    @Test("haptic fires exactly once per stillness lock")
    func hapticFiresOnLock() {
        var hapticCount = 0
        let c = makeCoordinator(onLockHaptic: { hapticCount += 1 })
        for s in stillStream(count: 81, startT: 0) { c.handle(s) }
        #expect(hapticCount == 1)
    }

    @Test("haptic fires again on re-address after stroke")
    func hapticFiresOnReLock() {
        var hapticCount = 0
        let c = makeCoordinator(rollTimeoutSeconds: 0.5, onLockHaptic: { hapticCount += 1 })
        let stream = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in stream { c.handle(s) }
        let countAfterFirst = hapticCount
        let baseTime = stream.last!.timestamp
        // Wait out the roll timeout
        for i in 0..<80 {
            c.handle(stillSample(t: baseTime + 0.01 + TimeInterval(i) * 0.01))
        }
        // Then another 81 still samples → second lock
        var t = baseTime + 1.0
        for s in stillStream(count: 81, startT: t) { c.handle(s); t = s.timestamp + 0.01 }
        #expect(hapticCount == countAfterFirst + 1)
    }

    @Test("ARKit baseline is NOT captured while tracking state is .limited")
    func arkitBaselineGatedOnNormal() {
        let fake = FakeARTrackingManager()
        try? fake.start()
        // Inject a pose with .limited tracking state — should NOT be used as baseline.
        fake.inject(pose: ARPose(
            timestamp: 0,
            transform: matrix_identity_float4x4,
            trackingState: .limited(.initializing)
        ))
        let c = makeCoordinator(arkit: fake)
        for s in stillStream(count: 90, startT: 0) { c.handle(s) }
        // Lock should NOT have fired yet because ARKit is not .normal.
        #expect(c.phase == .arm)
    }

    @Test("After ARKit reaches .normal, stillness lock proceeds")
    func arkitNormalAllowsLock() {
        let fake = FakeARTrackingManager()
        try? fake.start()
        fake.inject(pose: ARPose(
            timestamp: 0,
            transform: matrix_identity_float4x4,
            trackingState: .limited(.initializing)
        ))
        let c = makeCoordinator(arkit: fake)
        for s in stillStream(count: 50, startT: 0) { c.handle(s) }
        #expect(c.phase == .arm)
        // ARKit transitions to .normal
        fake.inject(pose: ARPose(
            timestamp: 0.5,
            transform: matrix_identity_float4x4,
            trackingState: .normal
        ))
        for s in stillStream(count: 90, startT: 0.5) { c.handle(s) }
        #expect(c.phase == .ready)
    }

    @Test("snapped stroke (zero accel = no clear peak) propagates through coordinator: phase=.roll + lastSnapReason set (C3 fix)")
    func snapPropagatesToCoordinator() {
        let c = makeCoordinator()
        // Build a session stream where the "stroke" has zero acceleration — detector
        // sees rotation crossing the stroke threshold but no clear velocity peak →
        // snaps to square with .noClearPeak.
        let stream = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.zeroAccel(),
            quietCount: 35,
            startTime: 0
        )
        for s in stream { c.handle(s) }
        #expect(c.phase == .roll)
        let r = c.lastImpactResult
        #expect(r != nil)
        #expect(r?.snappedToSquare == true)
        #expect(c.lastSnapReason == .noClearPeak)
    }

    @Test("clean stroke does NOT populate lastSnapReason (positive regression)")
    func cleanStrokeNoSnapReason() {
        let c = makeCoordinator()
        let stream = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in stream { c.handle(s) }
        #expect(c.phase == .roll)
        #expect(c.lastImpactResult?.snappedToSquare == false)
        #expect(c.lastSnapReason == nil)
    }

    @Test("ARKit pose stream consumed → impact uses ARKit origin (face angle still correct)")
    func arkitPath() {
        let fake = FakeARTrackingManager()
        try? fake.start()
        fake.inject(pose: ARPose(
            timestamp: 0,
            transform: matrix_identity_float4x4,
            trackingState: .normal
        ))
        let c = makeCoordinator(arkit: fake)
        let samples = fullSessionStream(
            stillCount: 81,
            strokeFixture: StrokeFixtures.cleanStraight8ft(),
            quietCount: 35,
            startTime: 0
        )
        for s in samples { c.handle(s) }
        #expect(c.phase == .roll)
        let r = c.lastImpactResult
        #expect(r != nil)
        #expect(abs(r!.faceAngleDegrees) < 2.0)
    }

    @Test("re-address: moderate movement breaks lock, then re-stilling re-locks (stays in .ready domain)")
    func reAddressMidReady() {
        let c = makeCoordinator()
        var t = 0.0
        for s in stillStream(count: 81, startT: t) { c.handle(s); t = s.timestamp + 0.01 }
        #expect(c.phase == .ready)

        for i in 0..<20 {
            let st = t + TimeInterval(i) * 0.01
            c.handle(reAddressMovement(t: st))
        }
        t += 0.20

        for s in stillStream(count: 90, startT: t) { c.handle(s); t = s.timestamp + 0.01 }
        #expect(c.phase == .ready)
    }

    @Test("rapid burst of strokes: phase progresses correctly through each")
    func rapidBurst() {
        let c = makeCoordinator(rollTimeoutSeconds: 0.5)
        var phaseTrail: [PhaseState] = []
        var t = 0.0
        for _ in 0..<2 {
            for s in stillStream(count: 81, startT: t) { c.handle(s); t = s.timestamp + 0.01 }
            phaseTrail.append(c.phase)
            let fix = StrokeFixtures.cleanStraight8ft()
            for sample in fix.window.samples {
                let shifted = MotionSample(
                    timestamp: t,
                    rotationRate: sample.rotationRate,
                    userAcceleration: sample.userAcceleration,
                    gravity: sample.gravity,
                    attitude: sample.attitude
                )
                c.handle(shifted)
                t += 0.01
            }
            for i in 0..<35 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
            }
            t += 0.35
            phaseTrail.append(c.phase)
            for i in 0..<80 {
                c.handle(stillSample(t: t + TimeInterval(i) * 0.01))
            }
            t += 0.80
            phaseTrail.append(c.phase)
        }
        #expect(phaseTrail.contains(.ready))
        #expect(phaseTrail.contains(.roll))
        #expect(phaseTrail.contains(.arm))
    }
}

// MARK: - Helpers

@MainActor
fileprivate func makeCoordinator(
    motion: MotionStreaming = NoopMotion(),
    arkit: ARTracking = FakeARTrackingManager(),
    readyTimeoutSeconds: TimeInterval = 15.0,
    rollTimeoutSeconds: TimeInterval = 3.0,
    onResult: @escaping @MainActor (ImpactResult) -> Void = { _ in },
    onLockHaptic: @escaping @MainActor () -> Void = { }
) -> SessionCoordinator {
    SessionCoordinator(
        motion: motion,
        arkit: arkit,
        readyTimeoutSeconds: readyTimeoutSeconds,
        rollTimeoutSeconds: rollTimeoutSeconds,
        onResult: onResult,
        onLockHaptic: onLockHaptic,
        replayStore: nil  // disable filesystem writes in tests
    )
}

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

fileprivate func strokeSample(t: TimeInterval, rotationRate: Double, accel: Double = 5.0) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: SIMD3(rotationRate, 0, 0),
        userAcceleration: SIMD3(accel, 0, 0),
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate func reAddressMovement(t: TimeInterval) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: SIMD3(0.3, 0, 0),
        userAcceleration: SIMD3(0.5, 0, 0),
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate func stillStream(count: Int, startT: TimeInterval) -> [MotionSample] {
    (0..<count).map { i in stillSample(t: startT + TimeInterval(i) * 0.01) }
}

fileprivate func fullSessionStream(
    stillCount: Int,
    strokeFixture: SyntheticStroke,
    quietCount: Int,
    startTime: TimeInterval
) -> [MotionSample] {
    var out: [MotionSample] = []
    let dt = 0.01
    for i in 0..<stillCount {
        out.append(stillSample(t: startTime + TimeInterval(i) * dt))
    }
    let strokeStart = startTime + TimeInterval(stillCount) * dt
    let originalStart = strokeFixture.window.samples.first?.timestamp ?? 0
    for s in strokeFixture.window.samples {
        let shifted = MotionSample(
            timestamp: s.timestamp - originalStart + strokeStart,
            rotationRate: s.rotationRate,
            userAcceleration: s.userAcceleration,
            gravity: s.gravity,
            attitude: s.attitude
        )
        out.append(shifted)
    }
    let quietStart = out.last!.timestamp + dt
    let lastAttitude = strokeFixture.window.samples.last?.attitude ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for i in 0..<quietCount {
        out.append(MotionSample(
            timestamp: quietStart + TimeInterval(i) * dt,
            rotationRate: SIMD3(0.001, 0, 0),
            userAcceleration: SIMD3(0, 0, 0),
            gravity: SIMD3(0, -1, 0),
            attitude: lastAttitude
        ))
    }
    return out
}
