import Foundation
import ARKit
import simd

/// One-shot address-pose capture for Stage 3 Slice 3.2 (B47).
///
/// Holds a private `MotionManager` + `StillnessDetector`. When
/// `start` is called, begins streaming IMU samples; the moment
/// the existing `StillnessDetector` emits a lock (phone still
/// for ~0.8 s), it pulls the AR camera transform from the
/// caller-provided ARSession, builds an `AddressPose`, and
/// invokes the completion handler exactly once.
///
/// This is distinct from `CalibrationCoordinator` (which collects
/// MULTIPLE strokes for distance-model calibration). Address
/// capture is single-shot — one stillness lock, one pose.
@MainActor
final class AddressPoseCapture {

    private let motionManager: MotionManager
    private let stillness: StillnessDetector
    private var streamTask: Task<Void, Never>?
    private weak var session: ARSession?
    private var ballWorld: SIMD3<Float>?

    /// Closure fired exactly once when a lock is captured. The
    /// caller is responsible for calling `stop()` afterwards to
    /// stop the motion stream.
    private var onCapture: ((AddressPose) -> Void)?
    private var onFailure: ((String) -> Void)?

    /// True after a lock has been captured for the current
    /// `start` invocation. Prevents the late stream samples from
    /// firing the callback a second time.
    private var captured: Bool = false

    init(motionManager: MotionManager = MotionManager(),
         stillness: StillnessDetector = StillnessDetector()) {
        self.motionManager = motionManager
        self.stillness = stillness
    }

    /// Begin capturing. Streams IMU samples through the existing
    /// `StillnessDetector`. The first lock triggers `onCapture`.
    /// Pass the ARSession so we can pull the camera transform at
    /// the lock moment, and the ball world position so we can
    /// compute phone-to-ball distance for sanity logging.
    func start(session: ARSession,
                ballWorld: SIMD3<Float>,
                onCapture: @escaping (AddressPose) -> Void,
                onFailure: @escaping (String) -> Void) {
        self.session = session
        self.ballWorld = ballWorld
        self.onCapture = onCapture
        self.onFailure = onFailure
        captured = false
        stillness.reset()

        let stream: AsyncStream<MotionSample>
        do {
            stream = try motionManager.start()
        } catch {
            onFailure("Motion start failed: \(error)")
            return
        }

        streamTask = Task { [weak self] in
            for await sample in stream {
                guard let self else { return }
                await self.handle(sample: sample)
                if await self.captured { break }
            }
        }
    }

    /// Stop the motion stream + tear down the task. Safe to call
    /// even when capture has already completed.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        if motionManager.isRunning {
            motionManager.stop()
        }
        onCapture = nil
        onFailure = nil
    }

    private func handle(sample: MotionSample) {
        guard !captured else { return }
        guard let lock = stillness.consume(sample) else { return }
        guard let session, let ballWorld else {
            onFailure?("Address capture: session or ball missing at lock")
            captured = true
            return
        }
        guard let frame = session.currentFrame else {
            // No ARFrame yet — extremely rare race; let the
            // stream continue and hope the next still-pause hits
            // a frame.
            return
        }
        let phoneTransform = frame.camera.transform
        let phonePos = SIMD3<Float>(phoneTransform.columns.3.x,
                                     phoneTransform.columns.3.y,
                                     phoneTransform.columns.3.z)
        let distance = simd_distance(phonePos, ballWorld)

        let pose = AddressPose(
            phoneWorldTransform: phoneTransform,
            phoneToBallM: distance,
            compassYaw: lock.yawTargetCompass,
            gravity: lock.gravity,
            lockedAt: lock.lockedAt
        )
        captured = true
        onCapture?(pose)
    }
}
