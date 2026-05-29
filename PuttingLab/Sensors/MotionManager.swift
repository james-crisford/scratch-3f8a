import Foundation
import CoreMotion

enum MotionManagerError: Error, Equatable {
    case deviceMotionUnavailable
    case motionPermissionDenied
    case alreadyRunning
    case notRunning
}

protocol MotionStreaming: AnyObject, Sendable {
    var isRunning: Bool { get }
    var latestSample: MotionSample? { get }
    /// Returns an ordered AsyncStream of motion samples. Caller consumes via `for await`.
    /// Replaces the per-sample `Task { @MainActor in handle(_:) }` dispatch which did NOT
    /// preserve order at 100Hz (see docs/audit-cycles.md Cycle 4).
    func start() throws -> AsyncStream<MotionSample>
    func stop()
}

final class MotionManager: MotionStreaming, @unchecked Sendable {
    static let targetSampleHz: Double = 100.0

    private let manager: CMMotionManager
    private let queue: OperationQueue
    private let lock = NSLock()
    private var running: Bool = false
    private var latest: MotionSample?
    private var continuation: AsyncStream<MotionSample>.Continuation?

    init(manager: CMMotionManager = CMMotionManager()) {
        self.manager = manager
        let q = OperationQueue()
        q.name = "com.puttinglab.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        self.queue = q
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var latestSample: MotionSample? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Pick the best available attitude reference frame. Real-device TestFlight is
    /// likely to hit magnetometer interference (steel rebar, AirPods, MagSafe, fluorescents).
    /// `.xMagneticNorthZVertical` requires a calibrated magnetometer; if unavailable we
    /// fall back to `.xArbitraryCorrectedZVertical` (gyro-corrected, no compass), then
    /// `.xArbitraryZVertical` (pure inertial). Yaw absolute reference is lost on fallback,
    /// but the stroke window's relative yaw is still usable.
    static func selectAttitudeFrame(
        from available: CMAttitudeReferenceFrame
    ) -> CMAttitudeReferenceFrame {
        if available.contains(.xMagneticNorthZVertical) {
            return .xMagneticNorthZVertical
        }
        if available.contains(.xArbitraryCorrectedZVertical) {
            return .xArbitraryCorrectedZVertical
        }
        return .xArbitraryZVertical
    }

    /// True if the user has granted CoreMotion permission (or the prompt hasn't fired yet).
    /// Apple's CMMotionManager `isDeviceMotionAvailable` reports HARDWARE availability,
    /// NOT permission — a denied user gets `motion=nil` callbacks forever with no error.
    /// `CMMotionActivityManager.authorizationStatus()` is the source of truth for the
    /// motion-and-fitness permission that CoreMotion uses.
    static func isMotionPermissionGranted() -> Bool {
        let status = CMMotionActivityManager.authorizationStatus()
        // .notDetermined = first launch, prompt will appear when sensors start. Allow.
        // .authorized = granted. Allow.
        // .denied / .restricted = block.
        return status == .authorized || status == .notDetermined
    }

    func start() throws -> AsyncStream<MotionSample> {
        lock.lock()
        if running {
            lock.unlock()
            throw MotionManagerError.alreadyRunning
        }
        guard manager.isDeviceMotionAvailable else {
            lock.unlock()
            throw MotionManagerError.deviceMotionUnavailable
        }
        guard Self.isMotionPermissionGranted() else {
            lock.unlock()
            throw MotionManagerError.motionPermissionDenied
        }
        running = true
        lock.unlock()

        manager.deviceMotionUpdateInterval = 1.0 / Self.targetSampleHz

        // .unbounded is correct here: the StillnessDetector's 800ms window must contain
        // CONTIGUOUS samples — `.bufferingNewest(N)` would drop OLDEST samples on stall,
        // breaking the window. At 100Hz × 80 bytes/sample, 1s of stall = 8KB. Trivial.
        let (stream, cont) = AsyncStream<MotionSample>.makeStream(
            bufferingPolicy: .unbounded
        )
        lock.lock()
        self.continuation = cont
        lock.unlock()

        let frame = Self.selectAttitudeFrame(
            from: CMMotionManager.availableAttitudeReferenceFrames()
        )

        manager.startDeviceMotionUpdates(
            using: frame,
            to: queue
        ) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.lock.lock()
            guard self.running else {
                self.lock.unlock()
                return
            }
            let sample = MotionSample(from: motion)
            self.latest = sample
            let cont = self.continuation
            self.lock.unlock()
            cont?.yield(sample)
        }

        return stream
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let cont = continuation
        continuation = nil
        lock.unlock()

        if wasRunning {
            manager.stopDeviceMotionUpdates()
        }
        cont?.finish()
    }

    deinit {
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
        continuation?.finish()
    }
}
