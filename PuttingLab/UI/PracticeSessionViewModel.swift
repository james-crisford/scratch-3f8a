import Foundation
import Observation
import UIKit
import simd

/// Drives the 100-stroke guided session UI.
///
/// Manages: motion + ARKit lifecycle, touch-controlled stroke recording,
/// ImpactDetector invocation, StrokeReplay persistence, and `TestSessionState`
/// progression.
///
/// Touch protocol (locked design decision):
///   - Press → start recording. Snapshot address-pose baseline (lock).
///   - Hold  → collect samples + ARKit poses.
///   - Release → build `StrokeWindow`, call `ImpactDetector.detect`, show result.
///
/// The existing `StrokeDetector` velocity-based path is NOT used in this mode.
/// This view model bypasses it to give the user explicit stroke boundaries via
/// touch, which gives cleaner test-session data for KI verification.
@MainActor
@Observable
final class PracticeSessionViewModel {
    /// High-level UI state.
    enum Phase: Equatable, Sendable {
        case setup
        case recording
        case showing
        case batchTransition
        case breakPoint
        case sessionComplete
    }

    var phase: Phase = .setup
    var session: TestSessionState
    var lastImpactResult: ImpactResult?
    var justCompletedBatch: TestBatch?
    var lastError: String?
    var motionErrorText: String?
    var arkitErrorText: String?
    var latestSample: MotionSample?
    var samplesInCurrentRecording: Int = 0

    private let motion: MotionStreaming
    private let arkit: ARTracking
    private let impactDetector: ImpactDetector
    private let replayStore: StrokeReplayStore?
    private let onHaptic: @MainActor (UIImpactFeedbackGenerator.FeedbackStyle) -> Void

    private var streamTask: Task<Void, Never>?
    private var samplesDuringRecording: [MotionSample] = []
    private var posesDuringRecording: [ARPose] = []
    private var recordingLock: StillnessLock?
    private var recordingArkitBaseline: Double?

    /// Minimum sample count to attempt impact detection. ImpactDetector
    /// already requires >= 3; we set 5 to give the integration step a small
    /// safety margin against the BUNDLE_LOADER short-stroke failure mode.
    static let minimumSamplesForStroke = 5

    /// Hard cap on samples captured during a single recording — prevents
    /// runaway memory growth if the user holds the screen too long.
    /// 1500 samples at 100Hz = 15 seconds, which is far longer than any
    /// reasonable putting stroke + follow-through.
    static let maximumSamplesPerRecording = 1500

    /// Counter of save failures during the session, exposed for end-of-session
    /// reporting. Incremented only when the detached save Task throws.
    var replaySaveFailureCount: Int = 0

    init(
        session: TestSessionState = TestSessionState(),
        motion: MotionStreaming = MotionManager(),
        arkit: ARTracking = ARTrackingManager(),
        impactDetector: ImpactDetector = ImpactDetector(),
        replayStore: StrokeReplayStore? = StrokeReplayStore.shared,
        onHaptic: @escaping @MainActor (UIImpactFeedbackGenerator.FeedbackStyle) -> Void = { style in
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    ) {
        self.session = session
        self.motion = motion
        self.arkit = arkit
        self.impactDetector = impactDetector
        self.replayStore = replayStore
        self.onHaptic = onHaptic
    }

    /// Starts motion + ARKit and spins the sample-consumer task. Also loads
    /// any persisted session progress so the user resumes mid-session.
    ///
    /// CRITICAL: this method is idempotent. Calling it twice in quick succession
    /// (which happens on first launch when both .onAppear AND scenePhase .active
    /// fire) used to cancel the consumer task on the second call and then fail
    /// to recreate it (because motion.start() throws alreadyRunning). Result:
    /// motion was streaming but nobody was listening, so strokes were silently
    /// empty (peakSpeedTooLow with 0.0 velocity). Now we guard on isRunning.
    func startSession() {
        session.loadIfAvailable()
        if session.isAtBreak {
            phase = .breakPoint
        } else if session.isSessionComplete {
            phase = .sessionComplete
        } else if phase != .recording && phase != .showing && phase != .batchTransition {
            phase = .setup
        }

        // Guard against double-start. If motion is already running, the
        // consumer task is alive — don't disturb it.
        if motion.isRunning && streamTask != nil {
            return
        }

        streamTask?.cancel()
        streamTask = nil
        do {
            let stream = try motion.start()
            motionErrorText = nil
            streamTask = Task { @MainActor [weak self] in
                for await sample in stream {
                    self?.handle(sample)
                }
            }
        } catch MotionManagerError.alreadyRunning {
            // Motion is running but our consumer was lost. We can't
            // recover the stream reference without restarting motion.
            // Stop + start to reattach.
            motion.stop()
            do {
                let stream = try motion.start()
                motionErrorText = nil
                streamTask = Task { @MainActor [weak self] in
                    for await sample in stream {
                        self?.handle(sample)
                    }
                }
            } catch {
                motionErrorText = "Motion restart failed: \(error)"
            }
        } catch {
            motionErrorText = String(describing: error)
        }
        do {
            try arkit.start()
            arkitErrorText = nil
        } catch ARTrackingError.alreadyRunning {
            // ARKit is already running — that's fine, leave it.
        } catch {
            arkitErrorText = String(describing: error)
        }
    }

    func stopSession() {
        motion.stop()
        arkit.stop()
        streamTask?.cancel()
        streamTask = nil
    }

    /// Consumer: every motion sample arrives here. Always update the latest
    /// reference; append to the recording buffer only when phase == .recording.
    /// Internal (not private) so tests can inject samples directly without
    /// constructing an AsyncStream.
    ///
    /// Silently caps the buffer at `maximumSamplesPerRecording` (15 s at 100Hz)
    /// to prevent runaway memory if the user holds the screen too long.
    func handle(_ sample: MotionSample) {
        latestSample = sample
        if phase == .recording {
            guard samplesDuringRecording.count < Self.maximumSamplesPerRecording else {
                return
            }
            samplesDuringRecording.append(sample)
            if let pose = arkit.latestPose {
                posesDuringRecording.append(pose)
            }
            samplesInCurrentRecording = samplesDuringRecording.count
        }
    }

    // MARK: - User actions

    /// Called when the user touches and holds the screen.
    /// Snapshots the address-pose baseline, then transitions to recording.
    func touchDown() {
        guard phase == .setup else { return }
        guard let latest = latestSample else {
            lastError = "Sensors warming up — wait a moment then try again."
            return
        }
        lastError = nil
        let lock = StillnessLock(
            yawTargetCompass: latest.compassYaw,
            gravity: latest.gravity,
            lockedAt: latest.timestamp
        )
        recordingLock = lock
        recordingArkitBaseline = arkit.attitudeYaw()
        samplesDuringRecording = [latest]
        posesDuringRecording = []
        if let pose = arkit.latestPose {
            posesDuringRecording.append(pose)
        }
        samplesInCurrentRecording = 1
        phase = .recording
        onHaptic(.medium)
    }

    /// Called when the user releases the touch.
    /// Builds a `StrokeWindow`, runs ImpactDetector, persists StrokeReplay,
    /// transitions to .showing.
    func touchUp() {
        guard phase == .recording else { return }
        guard let lock = recordingLock else {
            phase = .setup
            return
        }
        // Cleanly drain the per-recording buffers + counter regardless of
        // which path we exit on. samplesDuringRecording / posesDuringRecording
        // are re-seeded fresh on the next touchDown.
        defer {
            samplesInCurrentRecording = 0
            samplesDuringRecording.removeAll(keepingCapacity: false)
            posesDuringRecording.removeAll(keepingCapacity: false)
        }
        guard samplesDuringRecording.count >= Self.minimumSamplesForStroke else {
            lastError = "Too quick — please press, complete the stroke, then release."
            phase = .setup
            return
        }
        let window = StrokeWindow(
            start: samplesDuringRecording.first!.timestamp,
            end: samplesDuringRecording.last!.timestamp,
            samples: samplesDuringRecording,
            lock: lock
        )
        do {
            let result = try impactDetector.detect(
                in: window,
                arkitPoses: posesDuringRecording,
                arkitBaselineYaw: recordingArkitBaseline
            )
            lastImpactResult = result
            if let store = replayStore {
                let replay = StrokeReplay(
                    window: window,
                    result: result,
                    deviceModel: SessionCoordinator.deviceModelString(),
                    appVersion: SessionCoordinator.appVersionString()
                )
                // Detach to keep the UI smooth. Surface failures via a counter
                // (replaySaveFailureCount) so the end-of-session screen can
                // warn the user if any replays did not persist.
                Task.detached(priority: .utility) { [weak self] in
                    do {
                        _ = try store.save(replay)
                    } catch {
                        await MainActor.run {
                            self?.replaySaveFailureCount += 1
                        }
                    }
                }
            }
            phase = .showing
            onHaptic(.light)
        } catch {
            lastError = "Stroke not detected: \(error)"
            phase = .setup
        }
    }

    /// User dismissed the result panel. Advances the session state and
    /// routes to the next phase (Setup / BatchTransition / Break / Complete).
    func tapDone() {
        guard phase == .showing else { return }
        let batchComplete = session.recordStroke()
        session.save()
        if session.isSessionComplete {
            phase = .sessionComplete
            return
        }
        if batchComplete {
            // Remember the just-completed batch for the transition card.
            justCompletedBatch = session.currentBatch
            // Advance + check if NEXT batch is the break.
            session.advanceBatch()
            session.save()
            if session.isAtBreak {
                phase = .breakPoint
            } else if session.isSessionComplete {
                phase = .sessionComplete
            } else {
                phase = .batchTransition
            }
        } else {
            phase = .setup
        }
    }

    /// User tapped "CONTINUE TO BATCH X" on the batch-transition card.
    func tapContinueFromBatchTransition() {
        guard phase == .batchTransition else { return }
        justCompletedBatch = nil
        phase = .setup
    }

    /// User tapped "I'M READY TO RESUME" after the break.
    func tapReadyAfterBreak() {
        guard phase == .breakPoint else { return }
        session.advanceBatch()
        session.save()
        phase = .setup
    }

    /// User tapped "Restart Session" on the complete screen.
    func restartSession() {
        session.reset()
        session.clearPersistence()
        justCompletedBatch = nil
        lastImpactResult = nil
        lastError = nil
        phase = .setup
    }
}
