import Foundation
import CoreMotion

enum MotionManagerError: Error, Equatable {
    case deviceMotionUnavailable
    case alreadyRunning
    case notRunning
}

protocol MotionStreaming: AnyObject {
    var isRunning: Bool { get }
    var latestSample: MotionSample? { get }
    func start(handler: @escaping @Sendable (MotionSample) -> Void) throws
    func stop()
}

final class MotionManager: MotionStreaming, @unchecked Sendable {
    static let targetSampleHz: Double = 100.0

    private let manager: CMMotionManager
    private let queue: OperationQueue
    private let lock = NSLock()
    private var running: Bool = false
    private var latest: MotionSample?

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

    func start(handler: @escaping @Sendable (MotionSample) -> Void) throws {
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

        manager.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: queue
        ) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let sample = MotionSample(from: motion)
            self.lock.lock()
            self.latest = sample
            self.lock.unlock()
            handler(sample)
        }
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()

        if wasRunning {
            manager.stopDeviceMotionUpdates()
        }
    }

    deinit {
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
    }
}
