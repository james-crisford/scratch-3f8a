import Foundation
import CoreMotion

enum MotionManagerError: Error, Equatable {
    case deviceMotionUnavailable
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
    static let streamBufferSize: Int = 16

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
        running = true
        lock.unlock()

        manager.deviceMotionUpdateInterval = 1.0 / Self.targetSampleHz

        let (stream, cont) = AsyncStream<MotionSample>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.streamBufferSize)
        )
        lock.lock()
        self.continuation = cont
        lock.unlock()

        manager.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
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
