import Foundation
import simd
import UIKit

@MainActor
@Observable
final class SessionCoordinator {

    var phase: PhaseState = .arm
    var lastImpactResult: ImpactResult?
    var lastFaceOrigin: FaceAngleSource.Origin?
    var lastError: String?
    var motionErrorText: String?
    var arkitErrorText: String?
    var sampleCount: Int = 0

    let readyTimeoutSeconds: TimeInterval
    let rollTimeoutSeconds: TimeInterval

    private let motion: MotionStreaming
    private let arkit: ARTracking
    private let stillness: StillnessDetector
    private let stroke: StrokeDetector
    private let impactDetector: ImpactDetector
    private let onResult: @MainActor (ImpactResult) -> Void
    private let onLockHaptic: @MainActor () -> Void

    private var currentLock: StillnessLock?
    private var readyEnteredAt: TimeInterval?
    private var rollEnteredAt: TimeInterval?
    private var arkitBaselineYaw: Double?
    private var strokeArkitPoses: [ARPose] = []

    init(
        motion: MotionStreaming = MotionManager(),
        arkit: ARTracking = ARTrackingManager(),
        stillness: StillnessDetector = StillnessDetector(),
        stroke: StrokeDetector = StrokeDetector(),
        impactDetector: ImpactDetector = ImpactDetector(),
        readyTimeoutSeconds: TimeInterval = 15.0,
        rollTimeoutSeconds: TimeInterval = 3.0,
        onResult: @escaping @MainActor (ImpactResult) -> Void = { _ in },
        onLockHaptic: @escaping @MainActor () -> Void = SessionCoordinator.defaultHaptic
    ) {
        self.motion = motion
        self.arkit = arkit
        self.stillness = stillness
        self.stroke = stroke
        self.impactDetector = impactDetector
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.rollTimeoutSeconds = rollTimeoutSeconds
        self.onResult = onResult
        self.onLockHaptic = onLockHaptic
    }

    @MainActor
    static func defaultHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
    }

    func start() {
        reset()
        do {
            try motion.start { [weak self] sample in
                Task { @MainActor in
                    self?.handle(sample)
                }
            }
        } catch {
            motionErrorText = String(describing: error)
        }
        do {
            try arkit.start()
        } catch {
            arkitErrorText = String(describing: error)
        }
    }

    func stop() {
        motion.stop()
        arkit.stop()
    }

    func reset() {
        phase = .arm
        lastImpactResult = nil
        lastFaceOrigin = nil
        lastError = nil
        sampleCount = 0
        currentLock = nil
        readyEnteredAt = nil
        rollEnteredAt = nil
        arkitBaselineYaw = nil
        strokeArkitPoses = []
        stillness.reset()
        stroke.reset()
    }

    func handle(_ sample: MotionSample) {
        sampleCount += 1
        switch phase {
        case .arm:
            handleArm(sample)
        case .address:
            handleAddress(sample)
        case .ready:
            handleReady(sample)
        case .stroke:
            handleStroke(sample)
        case .impact:
            break
        case .roll:
            handleRoll(sample)
        }
    }

    private func handleArm(_ sample: MotionSample) {
        // Spec §2.5: ARKit baseline yaw must come from a .normal tracking frame.
        // If ARKit exists but is .limited or .initializing, suppress lock firing
        // (keep stillness reset so the 800ms clock starts from when ARKit goes .normal).
        // If ARKit is genuinely .notAvailable (e.g. device doesn't support world tracking),
        // proceed with compass-only baseline.
        if isArKitDegraded() {
            stillness.reset()
            return
        }

        if let lock = stillness.consume(sample) {
            currentLock = lock
            try? stroke.arm(with: lock)
            arkitBaselineYaw = arkit.attitudeYaw()
            phase = .address
            phase = .ready
            readyEnteredAt = sample.timestamp
            strokeArkitPoses = []
            captureArkitPose(at: sample.timestamp)
            onLockHaptic()
        }
    }

    private func isArKitDegraded() -> Bool {
        switch arkit.trackingState {
        case .normal, .notAvailable:
            return false
        case .limited:
            return true
        }
    }

    private func handleAddress(_ sample: MotionSample) {
        phase = .ready
        readyEnteredAt = sample.timestamp
    }

    private func handleReady(_ sample: MotionSample) {
        if let newLock = stillness.consume(sample) {
            currentLock = newLock
            try? stroke.arm(with: newLock)
            arkitBaselineYaw = arkit.attitudeYaw()
            readyEnteredAt = sample.timestamp
            strokeArkitPoses = []
            onLockHaptic()
        }
        captureArkitPose(at: sample.timestamp)

        let window = stroke.consume(sample)
        let currentStrokePhase = stroke.phase
        if currentStrokePhase == .starting || currentStrokePhase == .recording {
            phase = .stroke
            if let w = window {
                completeStroke(window: w)
            }
            return
        }

        if let entered = readyEnteredAt,
           sample.timestamp - entered + StrokeDetector.fpTolerance >= readyTimeoutSeconds {
            timeoutToArm()
        }
    }

    private func handleStroke(_ sample: MotionSample) {
        captureArkitPose(at: sample.timestamp)
        let window = stroke.consume(sample)
        if let w = window {
            completeStroke(window: w)
        }
    }

    private func handleRoll(_ sample: MotionSample) {
        if let entered = rollEnteredAt,
           sample.timestamp - entered + StrokeDetector.fpTolerance >= rollTimeoutSeconds {
            timeoutToArm()
        }
    }

    private func completeStroke(window: StrokeWindow) {
        phase = .impact
        do {
            let result = try impactDetector.detect(
                in: window,
                arkitPoses: strokeArkitPoses,
                arkitBaselineYaw: arkitBaselineYaw
            )
            lastImpactResult = result
            onResult(result)
            phase = .roll
            rollEnteredAt = window.end
            stillness.reset()
        } catch {
            lastError = String(describing: error)
            timeoutToArm()
        }
    }

    private func captureArkitPose(at time: TimeInterval) {
        if let pose = arkit.latestPose {
            strokeArkitPoses.append(pose)
        } else {
            let placeholder = ARPose(
                timestamp: time,
                transform: matrix_identity_float4x4,
                trackingState: .notAvailable
            )
            strokeArkitPoses.append(placeholder)
        }
    }

    private func timeoutToArm() {
        phase = .arm
        stillness.reset()
        stroke.reset()
        currentLock = nil
        readyEnteredAt = nil
        rollEnteredAt = nil
        arkitBaselineYaw = nil
        strokeArkitPoses = []
    }
}
