import Foundation
import simd

/// Stroke capture runner for Stage 3 Slice 3.3 (B48).
///
/// Wires together the existing `MotionManager` + `StrokeDetector`
/// + `ImpactDetector` to provide a one-shot or repeat stroke
/// pipeline at the AR placement layer. When `arm(with:)` is
/// called, the runner:
///
///   1. Starts the IMU stream (100 Hz `MotionSample`s)
///   2. Arms the `StrokeDetector` with a synthesized
///      `StillnessLock` built from the captured `AddressPose`
///   3. Fires `onStrokeStarted` when the detector's phase
///      transitions from `.armed` → `.starting` / `.recording`
///   4. Fires `onStrokeCompleted` with the computed `ImpactResult`
///      after the detector returns a `StrokeWindow`
///
/// This is distinct from `AddressPoseCapture` which captures a
/// single still-pose. `StrokeCapture` runs continuously across
/// multiple strokes — the caller can disarm after each one if
/// desired or just leave it armed for repeat-putt UX.
@MainActor
final class StrokeCapture {
    let motionManager: MotionManager
    private let stroke: StrokeDetector
    private let impact: ImpactDetector
    private var streamTask: Task<Void, Never>?

    /// Sentinel — fires once when the detector transitions out
    /// of `.armed`. Reset on each `arm`.
    private var strokeStartFired: Bool = false

    private var onStarted: (() -> Void)?
    private var onCompleted: ((ImpactResult, StrokeWindow) -> Void)?
    private var onFailure: ((String) -> Void)?

    init(motionManager: MotionManager = MotionManager(),
         stroke: StrokeDetector = StrokeDetector(),
         impact: ImpactDetector = ImpactDetector()) {
        self.motionManager = motionManager
        self.stroke = stroke
        self.impact = impact
    }

    /// Arm the capture for a stroke. Builds a `StillnessLock` from
    /// the `AddressPose` (the StrokeDetector needs a lock pose to
    /// arm — we use the address pose as the equivalent stationary
    /// reference). Starts the IMU stream.
    func arm(with pose: AddressPose,
              onStarted: @escaping () -> Void,
              onCompleted: @escaping (ImpactResult, StrokeWindow) -> Void,
              onFailure: @escaping (String) -> Void) {
        self.onStarted = onStarted
        self.onCompleted = onCompleted
        self.onFailure = onFailure
        strokeStartFired = false

        let lock = StillnessLock(
            yawTargetCompass: pose.compassYaw,
            gravity: pose.gravity,
            lockedAt: pose.lockedAt
        )
        do {
            try stroke.arm(with: lock)
        } catch {
            onFailure("Stroke arm failed: \(error)")
            return
        }

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
            }
        }
    }

    /// Stop the IMU stream + reset the detector. Safe to call
    /// even when not armed.
    func disarm() {
        streamTask?.cancel()
        streamTask = nil
        if motionManager.isRunning {
            motionManager.stop()
        }
        stroke.reset()
        onStarted = nil
        onCompleted = nil
        onFailure = nil
    }

    private func handle(sample: MotionSample) {
        // Detector phase transition firing — strokeStarted goes
        // out the FIRST time phase leaves `.armed`.
        if !strokeStartFired,
           stroke.phase != .armed && stroke.phase != .idle && stroke.phase != .ended {
            strokeStartFired = true
            onStarted?()
        }

        guard let window = stroke.consume(sample) else { return }

        // Window closed → compute impact.
        do {
            let result = try impact.detect(in: window)
            onCompleted?(result, window)
        } catch {
            onFailure?("Impact detect failed: \(error)")
        }
    }
}
