import Foundation
import Observation
import UIKit
import simd
import AVFoundation

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
    /// Distinct from `onHaptic` — fires the strong "impact thwack"
    /// haptic when the LiveImpactDetector decides we just hit the ball.
    /// Default implementation uses UINotificationFeedbackGenerator(.warning)
    /// which is a sharp double-tap pattern, noticeably stronger than
    /// UIImpactFeedbackGenerator(.heavy).
    private let onImpactHaptic: @MainActor () -> Void
    /// Fires a short percussive "putter-on-ball" click in sync with the
    /// impact haptic. Bundled WAV at PuttingLab/Resources/Sounds/
    /// putter_click.wav — replace with a real recording to taste; the
    /// loader just reads it from the main bundle.
    private let onImpactSound: @MainActor () -> Void
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

    /// B58 — accumulator for cal-batch strokes used to compute + persist a
    /// CalibrationProfile to ProfileStore when the cal batch completes.
    /// Workflow audit confirmed that pre-B58, CalibrationModel.compute()
    /// was wired only to in-memory TestSessionState.calibrationFaceBaselineRad
    /// (display-time only) and the resulting CalibrationProfile was never
    /// persisted. Result: every session ran with a no-op bias correction.
    private var pendingCalibrationInputs: [CalibrationInput] = []

    /// B58 — shared ProfileStore. Injected for tests; default is the
    /// standard-UserDefaults store every other consumer also reads from.
    private let profileStore: ProfileStore

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
        profileStore: ProfileStore = ProfileStore(),
        onHaptic: @escaping @MainActor (UIImpactFeedbackGenerator.FeedbackStyle) -> Void = { style in
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        },
        onImpactHaptic: @escaping @MainActor () -> Void = {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        },
        onImpactSound: @escaping @MainActor () -> Void = {
            // Switched from AudioServicesPlaySystemSound (B15) to a
            // preloaded AVAudioPlayer (B16) to cut sound latency from
            // ~50 ms to ~5–10 ms. The haptic fires near-instantly; if
            // the sound lags 50 ms the brain anchors on the (later) sound
            // as "impact" and everything feels late. B15 testing showed
            // exactly this: 50 % of strokes felt late despite the
            // detector firing on time.
            if let player = ImpactSoundLoader.player {
                player.currentTime = 0
                player.play()
            }
        }
    ) {
        self.session = session
        self.motion = motion
        self.arkit = arkit
        self.impactDetector = impactDetector
        self.replayStore = replayStore
        self.liveImpactDetector = liveImpactDetector
        self.profileStore = profileStore
        self.onHaptic = onHaptic
        self.onImpactHaptic = onImpactHaptic
        self.onImpactSound = onImpactSound
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

    /// Pause ARTrackingManager before presenting a Slice 1 / Slice 2
    /// fullScreenCover. The cover spins up its own ARSession; iOS only
    /// supports one active session at a time. Without an explicit pause
    /// here, ARTrackingManager's session stays "running" by its flag
    /// but stops receiving frames, then sits zombied after cover
    /// dismiss until the next background+foreground cycle (H4 in the
    /// 2026-05-31 audit). Pair with `resumeARFromCover()` on dismiss.
    func pauseARForCover() {
        arkit.stop()
    }

    /// Restart ARTrackingManager after a Slice 1 / Slice 2 cover
    /// dismissal. `pauseARForCover` called `arkit.stop()` so the running
    /// flag is false — start() will not throw .alreadyRunning. Errors
    /// surface via `arkitErrorText` exactly like `startSession`.
    func resumeARFromCover() {
        do {
            try arkit.start()
            arkitErrorText = nil
        } catch ARTrackingError.alreadyRunning {
            // Defensive: if a previous cover dismissal left the flag set,
            // we already paused; this branch shouldn't fire. Treat as ok.
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
            // Fire the strong "impact thwack" haptic. Build 14: the
            // light/heavy backswing-vs-impact distinction from B13 is
            // dropped — the 1.0 s fire gate inside LiveImpactDetector
            // already suppresses backswing-peak fires structurally, so any
            // fire that DOES come through is the impact one. Using
            // UINotificationFeedbackGenerator(.warning) (the sharp
            // double-tap pattern) instead of UIImpactFeedbackGenerator
            // because the testers reported the .heavy style wasn't
            // perceptibly distinct from the .medium touchDown tap.
            if liveImpactDetector.consume(sample) {
                liveHapticFireCount += 1
                onImpactHaptic()
                onImpactSound()
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
            let rawResult = try impactDetector.detect(
                in: window,
                arkitPoses: posesDuringRecording,
                arkitBaselineYaw: recordingArkitBaseline
            )
            // B57.1 — apply calibration bias at source. CalibrationModel.applyBias()
            // existed since the early builds but was never called in production
            // (workflow audit confirmed: zero callers outside the unit test).
            // Result: every persisted StrokeReplay JSON + downstream consumer
            // carried James's raw measured -9° bias. The display-time arithmetic
            // in ResultPhaseView was a band-aid; correction at source fixes every
            // path (JSON export, batch stats, history charts) at once.
            let result: ImpactResult = {
                guard let profile = try? ProfileStore().load() else { return rawResult }
                let corrected = CalibrationModel.applyBias(
                    rawResult.faceAngleRaw, profile: profile)
                return ImpactResult(
                    timestamp: rawResult.timestamp,
                    peakVelocity: rawResult.peakVelocity,
                    faceAngleRaw: corrected,
                    attitudeAtImpact: rawResult.attitudeAtImpact,
                    confidence: rawResult.confidence,
                    snappedToSquare: rawResult.snappedToSquare,
                    snapReason: rawResult.snapReason
                )
            }()
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
            // B14: if we're saving a cal-batch stroke and it produced a
            // real (non-snapped) face angle, contribute it to the session
            // calibration baseline.
            if currentBatch.id == "cal" && !result.snappedToSquare {
                session.recordCalibrationFaceAngle(result.faceAngleRaw)
                // B58 — also accumulate the full CalibrationInput (window +
                // impact) so we can compute + persist a CalibrationProfile
                // when the cal batch completes. Pre-B58 the cal data lived
                // only in TestSessionState.calibrationFaceAnglesRad (face
                // angle floats only), which is enough for display-time
                // arithmetic but NOT for the full CalibrationProfile that
                // ProfileStore expects (face bias + speed factor + swing
                // axis + stability).
                pendingCalibrationInputs.append(CalibrationInput(
                    window: window, impact: result))
            }
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
            // B58 — when the cal batch finishes, compute + persist the
            // CalibrationProfile so downstream consumers (AR mode bias
            // correction, AR mode speedCalibration) have it on the next
            // session. This is the wiring that was missing pre-B58: the
            // CalibrationModel.compute() function existed since the early
            // builds but ProfileStore.save() was never called for the
            // computed profile, so the profile only lived in memory
            // for the duration of the session.
            if session.currentBatch.id == "cal" {
                persistCalibrationIfReady()
            }
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

    /// B58 — compute the CalibrationProfile from the in-memory cal-batch
    /// buffer + save to ProfileStore. Called once at cal-batch completion.
    /// Requires ≥3 valid cal strokes (matching TestSessionState's bias
    /// computation threshold). targetDistanceFeet is sourced from the cal
    /// batch's published target (defaults to 10 ft if absent).
    private func persistCalibrationIfReady() {
        guard pendingCalibrationInputs.count >= 3 else {
            lastError = "Calibration needs at least 3 valid cal strokes — got \(pendingCalibrationInputs.count)."
            pendingCalibrationInputs.removeAll(keepingCapacity: false)
            return
        }
        // TestBatch doesn't carry a per-batch target distance; the cal
        // batch instructions reference an imaginary target. Use the
        // standard 10ft / Stimp-10 target — matches what
        // BallPhysics.defaultStimp expects and the historical
        // calibration the 200+ strokes were taken against.
        let targetFeet: Double = 10.0
        let profile = CalibrationModel.compute(
            from: pendingCalibrationInputs,
            targetDistanceFeet: targetFeet)
        do {
            try profileStore.save(profile)
            lastError = nil
            // B63 — log calibration save event so the JSON pipeline can
            // show "yes, the profile was actually persisted" when
            // diagnosing why bias correction does or doesn't apply
            // downstream. Workflow audit flagged absence of this event.
            print("[B58/cal] CalibrationProfile saved: bias=\(profile.faceAngleBiasRad)rad, factor=\(profile.speedToDistanceFactor), n=\(pendingCalibrationInputs.count)")
        } catch {
            lastError = "Couldn't save calibration profile: \(error.localizedDescription)"
        }
        pendingCalibrationInputs.removeAll(keepingCapacity: false)
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

/// Lazily-loaded, preloaded AVAudioPlayer for the bundled putter-click
/// sound effect. Loading + `prepareToPlay()` happens once per process,
/// the first time the impact path fires, so subsequent `play()` calls
/// have ~5–10 ms of latency instead of AudioServicesPlaySystemSound's
/// ~50 ms (B15 testers reported every stroke felt "late" because the
/// sound — louder than the haptic — anchored their perception of
/// impact at +50 ms past the actual fire moment).
///
/// If the bundle is missing the file (e.g. SwiftUI Preview in isolated
/// module mode) or AVFoundation init fails, `player` is nil and
/// callers skip the play call — no crash, no audio.
/// B66 — promoted to internal scope so ARPlacementView can also play
/// the putter-click on impact. Workflow Round 5 flagged that AR mode
/// had ZERO audio feedback while PracticeSessionView had the 5-10ms
/// AVAudioPlayer setup.
enum ImpactSoundLoader {
    // Swift 6 strict concurrency: AVAudioPlayer is not Sendable. The only
    // callers are inside @MainActor closures (the default onImpactSound),
    // so this static is effectively MainActor-bound — but the compiler
    // can't prove that from the type. `nonisolated(unsafe)` is the right
    // escape hatch: we promise we won't touch it off-main.
    nonisolated(unsafe) static let player: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "putter_click", withExtension: "wav") else {
            return nil
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.volume = 1.0
            return p
        } catch {
            return nil
        }
    }()
}
