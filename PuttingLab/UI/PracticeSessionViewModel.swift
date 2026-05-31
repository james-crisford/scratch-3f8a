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
        /// Page 1: Read what you're about to do. Tap READY to advance.
        case instructions
        /// Page 2: Stroke page. Big counter + stroke type. Press and hold to record.
        case ready
        case recording
        case showing
        case batchTransition
        case breakPoint
        case sessionComplete
    }

    var phase: Phase = .instructions
    var session: TestSessionState
    var lastImpactResult: ImpactResult?
    var justCompletedBatch: TestBatch?
    var lastError: String?
    var motionErrorText: String?
    var arkitErrorText: String?
    var latestSample: MotionSample?
    var samplesInCurrentRecording: Int = 0
    /// User's judgment for the current stroke's impact timing.
    /// Set via the result panel buttons; persisted to StrokeReplay on `tapDone`.
    var pendingImpactJudgment: String?

    /// Allowed impact judgments. Stored verbatim in StrokeReplay JSON.
    enum ImpactJudgment: String, Sendable {
        case justRight = "just_right"
        case early
        case late
    }

    private let motion: MotionStreaming
    private let arkit: ARTracking
    private let impactDetector: ImpactDetector
    private let replayStore: StrokeReplayStore?
    private let onHaptic: @MainActor (UIImpactFeedbackGenerator.FeedbackStyle) -> Void
    private let liveImpactDetector: LiveImpactDetector

    /// Count of live-haptic fires during the most recent stroke. Exposed so
    /// the result panel can confirm to the user how many "felt impacts" they
    /// got (typically 1 for fast strokes, 2 for backswing+forwardswing).
    private(set) var liveHapticFireCount: Int = 0

    private var streamTask: Task<Void, Never>?
    private var samplesDuringRecording: [MotionSample] = []
    private var posesDuringRecording: [ARPose] = []
    private var recordingLock: StillnessLock?
    private var recordingArkitBaseline: Double?
    /// The window for the stroke currently shown in the result panel.
    /// Held so `tapDone` can persist the replay with the user's impact judgment.
    private var pendingWindow: StrokeWindow?
    private var pendingResult: ImpactResult?

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
        liveImpactDetector: LiveImpactDetector = LiveImpactDetector(),
        onHaptic: @escaping @MainActor (UIImpactFeedbackGenerator.FeedbackStyle) -> Void = { style in
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    ) {
        self.session = session
        self.motion = motion
        self.arkit = arkit
        self.impactDetector = impactDetector
        self.replayStore = replayStore
        self.liveImpactDetector = liveImpactDetector
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
        } else if phase != .recording && phase != .showing && phase != .batchTransition && phase != .ready {
            // Cold-launch / batch start: show instructions page. Mid-batch
            // strokes stay on .ready (no need to re-read instructions every time).
            phase = .instructions
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
        // Safety belt: if we were in mid-stroke recording when the user
        // backgrounds the app (e.g., incoming call), discard the partial
        // buffer + return to .ready. Otherwise the user comes back to a
        // stuck red RECORDING screen with no thumb pressed and no exit.
        if phase == .recording {
            samplesDuringRecording.removeAll(keepingCapacity: false)
            posesDuringRecording.removeAll(keepingCapacity: false)
            samplesInCurrentRecording = 0
            recordingLock = nil
            recordingArkitBaseline = nil
            lastError = "Stroke discarded — phone was backgrounded mid-recording. Try again."
            phase = .ready
        }
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
            // Fire a real-time haptic at each estimated impact peak so the
            // user can judge timing in the result panel.
            //
            // Build 13 haptic-style distinction (from B12 first-session data):
            //   • The FIRST fire in a stroke is usually the backswing or
            //     transition peak — gets `.light` ("takeaway noted").
            //   • SECOND and subsequent fires are usually the forward-swing
            //     / impact peak — get `.heavy` ("THIS is the one to judge").
            // The .medium tap on touchDown still marks recording start, so the
            // user can disambiguate by feel: medium-tap → press registered;
            // light-tap → backswing top; heavy-thump → impact.
            if liveImpactDetector.consume(sample) {
                liveHapticFireCount += 1
                let style: UIImpactFeedbackGenerator.FeedbackStyle =
                    (liveHapticFireCount == 1) ? .light : .heavy
                onHaptic(style)
            }
        }
    }

    // MARK: - User actions

    /// Called when the user taps the "READY TO STROKE" button on the
    /// instructions page. Transitions to the stroke page (`.ready`) where
    /// they can press + hold to record.
    func tapReadyForStrokes() {
        guard phase == .instructions else { return }
        lastError = nil
        phase = .ready
    }

    /// Called when the user wants to go back to the instructions page from
    /// the stroke-ready page (e.g. they want to re-read the batch directions).
    func tapBackToInstructions() {
        guard phase == .ready else { return }
        phase = .instructions
    }

    /// Called when the user touches and holds the screen.
    /// Snapshots the address-pose baseline, then transitions to recording.
    func touchDown() {
        guard phase == .ready else { return }
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
        liveImpactDetector.reset()
        liveHapticFireCount = 0
        phase = .recording
        onHaptic(.medium)
    }

    /// Called when the user releases the touch.
    /// Builds a `StrokeWindow`, runs ImpactDetector, persists StrokeReplay,
    /// transitions to .showing.
    func touchUp() {
        guard phase == .recording else { return }
        guard let lock = recordingLock else {
            phase = .ready
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
            phase = .ready
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
            // Hold the window + result so tapDone can persist with the user's
            // impact judgment. Saving on touchUp + then again on tapDone
            // would have to overwrite — cleaner to wait the few seconds for
            // the user to tap a judgment + Done.
            pendingWindow = window
            pendingResult = result
            pendingImpactJudgment = nil
            phase = .showing
            onHaptic(.light)
        } catch {
            lastError = "Stroke not detected: \(error)"
            phase = .ready
        }
    }

    /// Called from the result panel when the user taps "Just right", "Felt early",
    /// or "Felt late". Stored locally; persisted to disk in `tapDone`.
    func setImpactJudgment(_ judgment: ImpactJudgment) {
        guard phase == .showing else { return }
        pendingImpactJudgment = judgment.rawValue
        onHaptic(.light)
    }

    /// User dismissed the result panel. Persists the stroke replay with any
    /// impact judgment, advances the session state, and routes to the next
    /// phase. Within a batch, returns to .ready (so the user can stroke again
    /// without re-reading instructions). New batches start on .instructions.
    func tapDone() {
        guard phase == .showing else { return }
        // Persist the stroke now (we held off saving in touchUp so we could
        // include the user's impact judgment).
        if let window = pendingWindow, let result = pendingResult, let store = replayStore {
            // strokesInCurrentBatch is the count of strokes *already* recorded
            // for this batch; this stroke is index (count + 1) — 1-indexed so
            // filenames read naturally (stroke-A-1-..., stroke-A-2-...).
            let currentBatch = session.currentBatch
            let replay = StrokeReplay(
                window: window,
                result: result,
                deviceModel: SessionCoordinator.deviceModelString(),
                appVersion: SessionCoordinator.appVersionString(),
                userImpactJudgment: pendingImpactJudgment,
                batchId: currentBatch.id,
                batchStrokeIndex: session.strokesInCurrentBatch + 1,
                batchStrokeType: currentBatch.strokeTypeLabel
            )
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
        pendingWindow = nil
        pendingResult = nil
        pendingImpactJudgment = nil

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
            // Same batch, next stroke — go straight to ready (no re-read).
            phase = .ready
        }
    }

    /// User tapped "CONTINUE TO BATCH X" on the batch-transition card.
    func tapContinueFromBatchTransition() {
        guard phase == .batchTransition else { return }
        justCompletedBatch = nil
        // New batch — show instructions page first.
        phase = .instructions
    }

    /// User tapped "I'M READY TO RESUME" after the break.
    func tapReadyAfterBreak() {
        guard phase == .breakPoint else { return }
        session.advanceBatch()
        session.save()
        // Block 2 starts — show instructions page.
        phase = .instructions
    }

    /// User tapped "Restart Session" on the complete screen.
    func restartSession() {
        session.reset()
        session.clearPersistence()
        justCompletedBatch = nil
        lastImpactResult = nil
        lastError = nil
        phase = .instructions
    }
}
