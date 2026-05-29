import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("ARTrackingManager — yaw math")
struct ARTrackingYawMathTests {

    @Test("identity transform → yaw 0")
    func identityYaw() {
        let t = matrix_identity_float4x4
        let yaw = ARTrackingManager.yaw(from: t)
        #expect(yaw != nil)
        #expect(abs(yaw!) < 1e-6)
    }

    @Test("yaw rotation +90° → +π/2")
    func ninetyYaw() {
        let t = yawTransform(radians: .pi / 2)
        let yaw = ARTrackingManager.yaw(from: t)!
        #expect(abs(yaw - .pi / 2) < 1e-5)
    }

    @Test("yaw rotation −90° → −π/2")
    func minusNinetyYaw() {
        let t = yawTransform(radians: -.pi / 2)
        let yaw = ARTrackingManager.yaw(from: t)!
        #expect(abs(yaw - (-.pi / 2)) < 1e-5)
    }

    @Test("yaw rotation 45° → π/4")
    func fortyFiveYaw() {
        let t = yawTransform(radians: .pi / 4)
        let yaw = ARTrackingManager.yaw(from: t)!
        #expect(abs(yaw - .pi / 4) < 1e-5)
    }

    @Test("yaw rotation 180° → ±π")
    func oneEightyYaw() {
        let t = yawTransform(radians: .pi)
        let yaw = ARTrackingManager.yaw(from: t)!
        #expect(abs(abs(yaw) - .pi) < 1e-5)
    }

    @Test("yaw output bounded to (-π, π]")
    func yawBounded() {
        for deg in stride(from: -179.0, through: 179.0, by: 17.0) {
            let t = yawTransform(radians: Float(deg * .pi / 180.0))
            let y = ARTrackingManager.yaw(from: t)!
            #expect(y > -.pi - 1e-5 && y <= .pi + 1e-5)
        }
    }

    @Test("yaw rejects NaN transform")
    func yawRejectsNaN() {
        var t = matrix_identity_float4x4
        t.columns.2 = SIMD4<Float>(Float.nan, 0, -1, 0)
        #expect(ARTrackingManager.yaw(from: t) == nil)
    }

    @Test("yaw rejects infinite transform")
    func yawRejectsInf() {
        var t = matrix_identity_float4x4
        t.columns.2 = SIMD4<Float>(Float.infinity, 0, 0, 0)
        #expect(ARTrackingManager.yaw(from: t) == nil)
    }

    @Test("yaw nil when forward vector is zero")
    func yawNilWhenZero() {
        var t = matrix_identity_float4x4
        t.columns.2 = SIMD4<Float>(0, 0, 0, 0)
        #expect(ARTrackingManager.yaw(from: t) == nil)
    }

    @Test("yaw is deterministic across repeated calls")
    func yawDeterministic() {
        let t = yawTransform(radians: 0.31415)
        var hash: UInt64 = 0
        for _ in 0..<1000 {
            let y = ARTrackingManager.yaw(from: t)!
            let bits = y.bitPattern
            hash ^= bits
        }
        let y0 = ARTrackingManager.yaw(from: t)!
        #expect(hash == 0 || hash == y0.bitPattern)
    }

    @Test("yaw performance — 10k calls < 50ms")
    func yawPerformance() {
        let t = yawTransform(radians: 0.5)
        let start = Date()
        for _ in 0..<10_000 {
            _ = ARTrackingManager.yaw(from: t)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.05)
    }

    @Test("yaw continuity — small step → small change")
    func yawContinuity() {
        let a = ARTrackingManager.yaw(from: yawTransform(radians: 0.1))!
        let b = ARTrackingManager.yaw(from: yawTransform(radians: 0.1001))!
        #expect(abs(a - b) < 0.001)
    }

    private func yawTransform(radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(c, 0, -s, 0)
        m.columns.1 = SIMD4<Float>(0, 1, 0, 0)
        m.columns.2 = SIMD4<Float>(s, 0, c, 0)
        m.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        return m
    }
}

@Suite("FakeARTrackingManager — lifecycle")
struct FakeARTrackingLifecycleTests {

    @Test("starts in stopped state")
    func startsStopped() {
        let fake = FakeARTrackingManager()
        #expect(!fake.isRunning)
        #expect(fake.latestPose == nil)
        #expect(fake.trackingState == .notAvailable)
    }

    @Test("start sets running true")
    func startSetsRunning() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        #expect(fake.isRunning)
    }

    @Test("stop returns to stopped state")
    func stopStops() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        fake.stop()
        #expect(!fake.isRunning)
    }

    @Test("stop is idempotent")
    func stopIdempotent() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        fake.stop()
        fake.stop()
        fake.stop()
        #expect(!fake.isRunning)
    }

    @Test("throws alreadyRunning on double-start")
    func doubleStartThrows() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        #expect(throws: ARTrackingError.alreadyRunning) {
            try fake.start()
        }
    }

    @Test("throws worldTrackingUnsupported when unsupported")
    func unsupportedThrows() {
        let fake = FakeARTrackingManager()
        fake.worldTrackingSupported = false
        #expect(throws: ARTrackingError.worldTrackingUnsupported) {
            try fake.start()
        }
        #expect(!fake.isRunning)
    }

    @Test("restart after stop works cleanly")
    func restartCleanly() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        fake.stop()
        try fake.start()
        #expect(fake.isRunning)
        fake.stop()
    }

    @Test("re-entrancy: 100 start/stop cycles")
    func reEntrancy() throws {
        let fake = FakeARTrackingManager()
        for _ in 0..<100 {
            try fake.start()
            fake.stop()
        }
        #expect(!fake.isRunning)
    }
}

@Suite("FakeARTrackingManager — pose stream")
struct FakeARTrackingPoseTests {

    @Test("attitudeYaw nil before any pose")
    func yawNilBeforePose() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        #expect(fake.attitudeYaw() == nil)
    }

    @Test("inject pose updates latestPose")
    func injectPose() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        let pose = ARPose(
            timestamp: 1.0,
            transform: matrix_identity_float4x4,
            trackingState: .normal
        )
        fake.inject(pose: pose)
        #expect(fake.latestPose == pose)
        #expect(fake.trackingState == .normal)
    }

    @Test("attitudeYaw returns yaw from injected pose")
    func yawFromInjected() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        var t = matrix_identity_float4x4
        let radians: Float = .pi / 4
        let c = cos(radians); let s = sin(radians)
        t.columns.0 = SIMD4<Float>(c, 0, -s, 0)
        t.columns.2 = SIMD4<Float>(s, 0, c, 0)
        fake.inject(pose: ARPose(timestamp: 0, transform: t, trackingState: .normal))
        let yaw = fake.attitudeYaw()!
        #expect(abs(yaw - .pi / 4) < 1e-5)
    }

    @Test("tracking state can be injected independently")
    func stateInjection() throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        fake.injectTrackingState(.limited(.excessiveMotion))
        #expect(fake.trackingState == .limited(.excessiveMotion))
        fake.injectTrackingState(.normal)
        #expect(fake.trackingState == .normal)
    }

    @Test("ARPose.yaw computed property matches static yaw")
    func poseYawProperty() {
        var t = matrix_identity_float4x4
        let radians: Float = 0.7
        let c = cos(radians); let s = sin(radians)
        t.columns.0 = SIMD4<Float>(c, 0, -s, 0)
        t.columns.2 = SIMD4<Float>(s, 0, c, 0)
        let pose = ARPose(timestamp: 0, transform: t, trackingState: .normal)
        #expect(pose.yaw == ARTrackingManager.yaw(from: t))
    }
}

@Suite("ARTrackingState — mapping & equality")
struct ARTrackingStateTests {

    @Test(".normal equals .normal")
    func normalEqual() {
        #expect(ARTrackingState.normal == .normal)
    }

    @Test(".notAvailable equals .notAvailable")
    func notAvailableEqual() {
        #expect(ARTrackingState.notAvailable == .notAvailable)
    }

    @Test(".limited equality respects reason")
    func limitedEquality() {
        #expect(ARTrackingState.limited(.excessiveMotion) == .limited(.excessiveMotion))
        #expect(ARTrackingState.limited(.excessiveMotion) != .limited(.insufficientFeatures))
    }

    @Test("isNormal true only for .normal")
    func isNormal() {
        #expect(ARTrackingState.normal.isNormal)
        #expect(!ARTrackingState.notAvailable.isNormal)
        #expect(!ARTrackingState.limited(.initializing).isNormal)
    }

    @Test("ARTrackingState is Sendable across actors")
    func sendableActorHop() async {
        let state = ARTrackingState.limited(.relocalizing)
        let received = await stateActor.echo(state)
        #expect(received == state)
    }

    @Test("ARPose Equatable round-trip")
    func poseEquatable() {
        let a = ARPose(timestamp: 1, transform: matrix_identity_float4x4, trackingState: .normal)
        let b = ARPose(timestamp: 1, transform: matrix_identity_float4x4, trackingState: .normal)
        let c = ARPose(timestamp: 2, transform: matrix_identity_float4x4, trackingState: .normal)
        #expect(a == b)
        #expect(a != c)
    }

    private let stateActor = StateEchoActor()
}

private actor StateEchoActor {
    func echo(_ s: ARTrackingState) -> ARTrackingState { s }
}

@Suite("ARTracking — concurrency & memory")
struct ARTrackingConcurrencyTests {

    @Test("concurrent reads of latestPose do not crash")
    func concurrentReads() async throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        let pose = ARPose(timestamp: 0, transform: matrix_identity_float4x4, trackingState: .normal)
        fake.inject(pose: pose)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { _ = fake.latestPose }
                group.addTask { _ = fake.attitudeYaw() }
                group.addTask { _ = fake.trackingState }
            }
        }
        #expect(fake.latestPose == pose)
    }

    @Test("stop from different task than start")
    func stopFromDifferentTask() async throws {
        let fake = FakeARTrackingManager()
        try fake.start()
        await Task.detached {
            fake.stop()
        }.value
        #expect(!fake.isRunning)
    }

    @Test("fake deallocates when out of scope (no retain cycle)")
    func noRetainCycle() throws {
        weak var weakRef: FakeARTrackingManager?
        try autoreleasepool {
            let fake = FakeARTrackingManager()
            try fake.start()
            weakRef = fake
            fake.stop()
        }
        #expect(weakRef == nil)
    }

    @Test("ARTrackingError values are equatable")
    func errorEquatable() {
        #expect(ARTrackingError.alreadyRunning == .alreadyRunning)
        #expect(ARTrackingError.notRunning != .alreadyRunning)
        #expect(ARTrackingError.worldTrackingUnsupported == .worldTrackingUnsupported)
    }
}
