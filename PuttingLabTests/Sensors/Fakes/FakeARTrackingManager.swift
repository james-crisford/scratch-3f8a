import Foundation
import simd
@testable import PuttingLab

final class FakeARTrackingManager: ARTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool = false
    private var pose: ARPose?
    private var state: ARTrackingState = .notAvailable

    var worldTrackingSupported: Bool = true

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var latestPose: ARPose? {
        lock.lock(); defer { lock.unlock() }
        return pose
    }

    var trackingState: ARTrackingState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            throw ARTrackingError.alreadyRunning
        }
        guard worldTrackingSupported else {
            lock.unlock()
            throw ARTrackingError.worldTrackingUnsupported
        }
        running = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func attitudeYaw() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let p = pose else { return nil }
        return ARTrackingManager.yaw(from: p.transform)
    }

    func inject(pose: ARPose) {
        lock.lock()
        self.pose = pose
        self.state = pose.trackingState
        lock.unlock()
    }

    func injectTrackingState(_ next: ARTrackingState) {
        lock.lock()
        self.state = next
        lock.unlock()
    }
}
