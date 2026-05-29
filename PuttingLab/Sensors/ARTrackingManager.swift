import Foundation
import ARKit
import simd

enum ARTrackingError: Error, Equatable {
    case worldTrackingUnsupported
    case alreadyRunning
    case notRunning
}

protocol ARTracking: AnyObject, Sendable {
    var isRunning: Bool { get }
    var latestPose: ARPose? { get }
    var trackingState: ARTrackingState { get }
    func start() throws
    func stop()
    func attitudeYaw() -> Double?
}

final class ARTrackingManager: NSObject, ARTracking, ARSessionDelegate, @unchecked Sendable {
    private let session: ARSession
    private let lock = NSLock()
    private var running: Bool = false
    private var pose: ARPose?
    private var state: ARTrackingState = .notAvailable

    init(session: ARSession = ARSession()) {
        self.session = session
        super.init()
    }

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
        guard ARWorldTrackingConfiguration.isSupported else {
            lock.unlock()
            throw ARTrackingError.worldTrackingUnsupported
        }
        running = true
        lock.unlock()

        session.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        config.frameSemantics = []
        config.environmentTexturing = .none
        config.isLightEstimationEnabled = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()

        if wasRunning {
            session.pause()
        }
    }

    func attitudeYaw() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let p = pose else { return nil }
        return Self.yaw(from: p.transform)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let nextState = ARTrackingState(frame.camera.trackingState)
        let nextPose = ARPose(
            timestamp: frame.timestamp,
            transform: frame.camera.transform,
            trackingState: nextState
        )
        lock.lock()
        pose = nextPose
        state = nextState
        lock.unlock()
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let next = ARTrackingState(camera.trackingState)
        lock.lock()
        state = next
        lock.unlock()
    }

    deinit {
        session.pause()
    }

    static func yaw(from transform: simd_float4x4) -> Double? {
        let z = transform.columns.2
        let fx = -z.x
        let fz = -z.z
        guard fx.isFinite, fz.isFinite else { return nil }
        if fx == 0 && fz == 0 { return nil }
        return Double(atan2(-fx, -fz))
    }
}
