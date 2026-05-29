import Testing
import CoreMotion
import simd
@testable import PuttingLab

@Suite("MotionManager")
struct MotionManagerTests {

    @Test("starts in stopped state")
    func startsStopped() {
        let mock = FakeCMMotionManager(deviceMotionAvailable: true)
        let manager = MotionManager(manager: mock)
        #expect(!manager.isRunning)
        #expect(manager.latestSample == nil)
    }

    @Test("throws when device motion unavailable")
    func throwsWhenUnavailable() {
        let mock = FakeCMMotionManager(deviceMotionAvailable: false)
        let manager = MotionManager(manager: mock)
        #expect(throws: MotionManagerError.deviceMotionUnavailable) {
            _ = try manager.start() as AsyncStream<MotionSample>
        }
        #expect(!manager.isRunning)
    }

    @Test("throws when started twice")
    func throwsOnDoubleStart() throws {
        let mock = FakeCMMotionManager(deviceMotionAvailable: true)
        let manager = MotionManager(manager: mock)
        _ = try manager.start()
        #expect(throws: MotionManagerError.alreadyRunning) {
            _ = try manager.start() as AsyncStream<MotionSample>
        }
        manager.stop()
    }

    @Test("configures interval for 100Hz")
    func configuresHundredHz() throws {
        let mock = FakeCMMotionManager(deviceMotionAvailable: true)
        let manager = MotionManager(manager: mock)
        _ = try manager.start()
        #expect(abs(mock.deviceMotionUpdateInterval - 0.01) < 1e-9)
        manager.stop()
    }

    @Test("picks a supported attitude reference frame from the fallback chain")
    func usesValidAttitudeFrame() throws {
        // Post-2026-05-30 hardening: MotionManager no longer hardcodes .xMagneticNorthZVertical.
        // It walks CMMotionManager.availableAttitudeReferenceFrames() and picks the best
        // available, falling back to .xArbitraryCorrectedZVertical → .xArbitraryZVertical
        // when the magnetometer isn't trustworthy (steel rebar, AirPods, MagSafe at the
        // tester's venue). On the simulator the picked frame depends on the host runtime;
        // we just assert SOME valid frame was selected.
        let mock = FakeCMMotionManager(deviceMotionAvailable: true)
        let manager = MotionManager(manager: mock)
        _ = try manager.start()
        let frame = mock.lastReferenceFrame
        #expect(frame != nil)
        if let f = frame {
            let valid: [CMAttitudeReferenceFrame] = [
                .xMagneticNorthZVertical,
                .xArbitraryCorrectedZVertical,
                .xArbitraryZVertical
            ]
            #expect(valid.contains(f))
        }
        manager.stop()
    }

    @Test("selectAttitudeFrame picks magnetic-north when available")
    func selectsMagneticWhenAvailable() {
        let all: CMAttitudeReferenceFrame = [
            .xMagneticNorthZVertical,
            .xArbitraryCorrectedZVertical,
            .xArbitraryZVertical
        ]
        #expect(MotionManager.selectAttitudeFrame(from: all) == .xMagneticNorthZVertical)
    }

    @Test("selectAttitudeFrame falls back to xArbitraryCorrected when no magnetic-north")
    func fallsBackToCorrected() {
        let some: CMAttitudeReferenceFrame = [
            .xArbitraryCorrectedZVertical,
            .xArbitraryZVertical
        ]
        #expect(MotionManager.selectAttitudeFrame(from: some) == .xArbitraryCorrectedZVertical)
    }

    @Test("selectAttitudeFrame final fallback is xArbitrary")
    func finalFallback() {
        let only: CMAttitudeReferenceFrame = [.xArbitraryZVertical]
        #expect(MotionManager.selectAttitudeFrame(from: only) == .xArbitraryZVertical)
    }

    @Test("stop is idempotent and returns to stopped state")
    func stopIsIdempotent() throws {
        let mock = FakeCMMotionManager(deviceMotionAvailable: true)
        let manager = MotionManager(manager: mock)
        _ = try manager.start()
        manager.stop()
        manager.stop()
        #expect(!manager.isRunning)
    }

    @Test("can restart cleanly after stop")
    func restartAfterStop() throws {
        let mock = FakeCMMotionManager(deviceMotionAvailable: true)
        let manager = MotionManager(manager: mock)
        _ = try manager.start()
        manager.stop()
        _ = try manager.start()
        #expect(manager.isRunning)
        manager.stop()
    }

    @Test("target sample rate is 100Hz")
    func targetRateIsHundred() {
        #expect(MotionManager.targetSampleHz == 100.0)
    }
}

@Suite("MotionSample")
struct MotionSampleTests {

    @Test("rotation magnitude")
    func rotationMagnitude() {
        let sample = MotionSample(
            timestamp: 0,
            rotationRate: SIMD3(3, 4, 0),
            userAcceleration: .zero,
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
        )
        #expect(abs(sample.rotationMagnitude - 5.0) < 1e-9)
    }

    @Test("acceleration magnitude")
    func accelMagnitude() {
        let sample = MotionSample(
            timestamp: 0,
            rotationRate: .zero,
            userAcceleration: SIMD3(0, 3, 4),
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
        )
        #expect(abs(sample.accelerationMagnitude - 5.0) < 1e-9)
    }

    @Test("vertical when gravity is mostly downward")
    func verticalTrue() {
        let sample = MotionSample(
            timestamp: 0,
            rotationRate: .zero,
            userAcceleration: .zero,
            gravity: SIMD3(0, -0.99, 0.05),
            attitude: simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
        )
        #expect(sample.isVertical)
    }

    @Test("not vertical when phone is flat")
    func verticalFalse() {
        let sample = MotionSample(
            timestamp: 0,
            rotationRate: .zero,
            userAcceleration: .zero,
            gravity: SIMD3(0, 0, -1),
            attitude: simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
        )
        #expect(!sample.isVertical)
    }
}

private final class FakeCMMotionManager: CMMotionManager, @unchecked Sendable {
    private let _deviceMotionAvailable: Bool
    var lastReferenceFrame: CMAttitudeReferenceFrame?

    init(deviceMotionAvailable: Bool) {
        self._deviceMotionAvailable = deviceMotionAvailable
        super.init()
    }

    override var isDeviceMotionAvailable: Bool {
        _deviceMotionAvailable
    }

    override func startDeviceMotionUpdates(
        using referenceFrame: CMAttitudeReferenceFrame,
        to queue: OperationQueue,
        withHandler handler: @escaping CMDeviceMotionHandler
    ) {
        lastReferenceFrame = referenceFrame
    }

    override func stopDeviceMotionUpdates() {}

    override var isDeviceMotionActive: Bool { false }
}
