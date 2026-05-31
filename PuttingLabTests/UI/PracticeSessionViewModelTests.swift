import Testing
import Foundation
import simd
import UIKit
@testable import PuttingLab

@Suite("PracticeSessionViewModel — touch flow + session integration")
@MainActor
struct PracticeSessionViewModelTests {

    private func makeViewModel(
        batches: [TestBatch]? = nil
    ) -> PracticeSessionViewModel {
        // Disable filesystem writes in tests by passing replayStore: nil.
        let session = TestSessionState(
            batches: batches ?? TestBatch.allBatches,
            userDefaults: UserDefaults(suiteName: "PracticeVM-\(UUID().uuidString)") ?? .standard
        )
        return PracticeSessionViewModel(
            session: session,
            motion: NoopMotion(),
            arkit: FakeARTrackingManager(),
            impactDetector: ImpactDetector(),
            replayStore: nil,
            onHaptic: { _ in }
        )
    }

    private func feed(_ vm: PracticeSessionViewModel, samples: [MotionSample]) {
        for s in samples { vm.handle(s) }
    }

    /// Synthesises a known-good stroke window's samples using the existing
    /// `StrokeFixtures.cleanStraight8ft()` fixture (the same fixture used
    /// by ImpactDetectorTests).
    private func fixtureStrokeSamples() -> [MotionSample] {
        StrokeFixtures.cleanStraight8ft().window.samples
    }

    @Test("starts in .instructions phase with no error")
    func startsInInstructions() {
        let vm = makeViewModel()
        #expect(vm.phase == .instructions)
        #expect(vm.lastError == nil)
    }

    @Test("tapReadyForStrokes transitions .instructions to .ready")
    func tapReadyTransitionsToReady() {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        #expect(vm.phase == .ready)
    }

    @Test("touchDown from .instructions is a no-op (user must tap Ready first)")
    func touchDownInInstructionsIsNoop() {
        let vm = makeViewModel()
        vm.handle(stillSample(t: 0))
        vm.touchDown()
        #expect(vm.phase == .instructions)
    }

    @Test("touchDown without any motion sample yet surfaces an error and stays in .ready")
    func touchDownWithoutSample() {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        vm.touchDown()
        #expect(vm.phase == .ready)
        #expect(vm.lastError != nil)
    }

    @Test("touchDown after sample arrives transitions to .recording")
    func touchDownTransitionsToRecording() {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        vm.handle(stillSample(t: 0))
        vm.touchDown()
        #expect(vm.phase == .recording)
        #expect(vm.lastError == nil)
    }

    @Test("samples accumulate only during .recording phase")
    func samplesAccumulateOnlyInRecording() {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        vm.handle(stillSample(t: 0))
        vm.handle(stillSample(t: 0.01))
        #expect(vm.samplesInCurrentRecording == 0)

        vm.touchDown()
        #expect(vm.samplesInCurrentRecording == 1)

        vm.handle(stillSample(t: 0.02))
        vm.handle(stillSample(t: 0.03))
        #expect(vm.samplesInCurrentRecording == 3)
    }

    @Test("touchUp with too few samples returns to .ready and sets error")
    func touchUpTooQuick() {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        vm.handle(stillSample(t: 0))
        vm.touchDown()
        vm.handle(stillSample(t: 0.01))
        vm.touchUp()
        #expect(vm.phase == .ready)
        #expect(vm.lastError != nil)
    }

    @Test("touchUp with valid stroke produces ImpactResult and transitions to .showing")
    func touchUpWithValidStroke() throws {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        let strokeSamples = fixtureStrokeSamples()
        try #require(strokeSamples.count >= 10, "stroke fixture must have enough samples")
        vm.handle(strokeSamples[0])
        vm.touchDown()
        for s in strokeSamples.dropFirst() {
            vm.handle(s)
        }
        vm.touchUp()
        #expect(vm.phase == .showing)
        #expect(vm.lastImpactResult != nil)
    }

    @Test("tapDone from .showing in mid-batch returns to .ready with incremented counter")
    func tapDoneMidBatch() throws {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        let strokeSamples = fixtureStrokeSamples()
        vm.handle(strokeSamples[0])
        vm.touchDown()
        for s in strokeSamples.dropFirst() { vm.handle(s) }
        vm.touchUp()
        try #require(vm.phase == .showing)
        vm.tapDone()
        #expect(vm.phase == .ready)
        #expect(vm.session.totalStrokesCompleted == 1)
        #expect(vm.session.currentBatchIndex == 0)
    }

    @Test("setImpactJudgment stores the user's choice on the view model")
    func setImpactJudgmentPersistsToVM() throws {
        let vm = makeViewModel()
        vm.tapReadyForStrokes()
        let strokeSamples = fixtureStrokeSamples()
        vm.handle(strokeSamples[0])
        vm.touchDown()
        for s in strokeSamples.dropFirst() { vm.handle(s) }
        vm.touchUp()
        try #require(vm.phase == .showing)
        vm.setImpactJudgment(.justRight)
        #expect(vm.pendingImpactJudgment == "just_right")
    }

    @Test("tapDone on last stroke of calibration transitions to .batchTransition")
    func tapDoneEndOfCalibration() throws {
        let vm = makeViewModel()
        // Pre-record 4 calibration strokes via the state so we only need to
        // simulate the 5th via the touch flow.
        for _ in 0..<4 { _ = vm.session.recordStroke() }
        try #require(vm.session.strokesInCurrentBatch == 4)

        vm.tapReadyForStrokes()
        let strokeSamples = fixtureStrokeSamples()
        vm.handle(strokeSamples[0])
        vm.touchDown()
        for s in strokeSamples.dropFirst() { vm.handle(s) }
        vm.touchUp()
        try #require(vm.phase == .showing)
        vm.tapDone()
        #expect(vm.phase == .batchTransition)
        #expect(vm.justCompletedBatch?.id == "cal")
        #expect(vm.session.currentBatch.id == "A")
    }

    // MARK: - Build 9: integration tests for live haptic + batch persistence

    /// Live impact detector helper that fires immediately on a high-mag
    /// rotation pulse — no warm-up, no cool-down, no 1 s fire-delay gate —
    /// so tests can synthesise a single peak deterministically.
    private func eagerDetector() -> LiveImpactDetector {
        LiveImpactDetector(
            armThreshold: 2.0,
            disarmThreshold: 1.0,
            coolDownSeconds: 0.0,
            warmUpSamplesBelowDisarm: 0,
            minFireDelayFromTouchDownSeconds: 0.0
        )
    }

    /// Single rising-falling rotation burst sample stream (5 samples).
    /// Magnitudes: 0.2, 3.0, 3.5, 3.0, 0.2 — guaranteed to arm and disarm.
    private func liveHapticBurst(startT: TimeInterval = 0.0) -> [MotionSample] {
        let mags: [Double] = [0.2, 3.0, 3.5, 3.0, 0.2]
        return mags.enumerated().map { idx, m in
            let comp = m / sqrt(3.0)
            return MotionSample(
                timestamp: startT + Double(idx) * 0.01,
                rotationRate: SIMD3(comp, comp, comp),
                userAcceleration: SIMD3(0, 0, 0),
                gravity: SIMD3(0, -1, 0),
                attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            )
        }
    }

    private func makeViewModelWithHapticSpy(
        liveImpactDetector: LiveImpactDetector? = nil
    ) -> (vm: PracticeSessionViewModel, hapticLog: HapticLog) {
        let log = HapticLog()
        let session = TestSessionState(
            batches: TestBatch.allBatches,
            userDefaults: UserDefaults(suiteName: "PracticeVM-haptic-\(UUID().uuidString)") ?? .standard
        )
        let vm = PracticeSessionViewModel(
            session: session,
            motion: NoopMotion(),
            arkit: FakeARTrackingManager(),
            impactDetector: ImpactDetector(),
            replayStore: nil,
            liveImpactDetector: liveImpactDetector ?? eagerDetector(),
            onHaptic: { style in log.append(style) },
            onImpactHaptic: { log.appendImpact() },
            onImpactSound: { log.appendSound() }
        )
        return (vm, log)
    }

    @Test("handle(_:) fires the impact haptic (notification.warning) when LiveImpactDetector returns true")
    func handleFiresImpactHapticOnLiveImpact() {
        let (vm, log) = makeViewModelWithHapticSpy()
        vm.tapReadyForStrokes()
        vm.handle(stillSample(t: 0))
        vm.touchDown()
        log.clearStyles()
        log.clearImpact()
        log.clearSound()
        for s in liveHapticBurst(startT: 0.02) {
            vm.handle(s)
        }
        // B14: there's no more light/heavy split — every impact fires the
        // strong notification-warning haptic via onImpactHaptic.
        #expect(log.impactCount() == 1, "expected 1 impact haptic during the burst")
        #expect(vm.liveHapticFireCount == 1)
    }

    @Test("handle(_:) fires the impact SOUND in lockstep with the impact haptic (B15)")
    func handleFiresImpactSoundAlongsideHaptic() {
        let (vm, log) = makeViewModelWithHapticSpy()
        vm.tapReadyForStrokes()
        vm.handle(stillSample(t: 0))
        vm.touchDown()
        log.clearSound()
        log.clearImpact()
        for s in liveHapticBurst(startT: 0.02) {
            vm.handle(s)
        }
        // The putter-click sound and the notification.warning haptic must
        // fire from the same code path so they're perceptually synchronous.
        #expect(log.soundCount() == 1, "expected 1 impact sound")
        #expect(log.impactCount() == 1, "expected 1 impact haptic")
        #expect(log.soundCount() == log.impactCount(), "sound and haptic must fire 1:1")
    }

    @Test("touchDown resets LiveImpactDetector — previous stroke's cool-down + counter do not leak")
    func touchDownResetsLiveImpactDetector() {
        // Detector with 10 s cool-down so any non-reset would suppress
        // the second stroke's haptic.
        let det = LiveImpactDetector(
            armThreshold: 2.0,
            disarmThreshold: 1.0,
            peakConfirmationSamples: 1,
            minPeakDropFraction: 0.02,
            coolDownSeconds: 10.0,
            warmUpSamplesBelowDisarm: 0,
            minFireDelayFromTouchDownSeconds: 0.0
        )
        let (vm, log) = makeViewModelWithHapticSpy(liveImpactDetector: det)
        vm.tapReadyForStrokes()

        // Stroke 1
        vm.handle(stillSample(t: 0))
        vm.touchDown()
        for s in liveHapticBurst(startT: 0.02) { vm.handle(s) }
        #expect(log.impactCount() == 1)
        vm.touchUp()
        if vm.phase == .showing { vm.tapDone() }
        log.clearImpact()

        // Stroke 2 — immediately after, well inside the 10 s cool-down.
        vm.handle(stillSample(t: 0.5))
        vm.touchDown()  // <- must reset the detector AND the fire counter
        for s in liveHapticBurst(startT: 0.55) { vm.handle(s) }
        #expect(log.impactCount() == 1, "stroke 2 should still fire impact haptic — cool-down must have been reset by touchDown")
    }

    @Test("tapDone writes a StrokeReplay with batchId, batchStrokeIndex, batchStrokeType set from session")
    func tapDoneWritesBatchFieldsToReplay() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        let session = TestSessionState(
            batches: TestBatch.allBatches,
            userDefaults: UserDefaults(suiteName: "PracticeVM-batch-\(UUID().uuidString)") ?? .standard
        )
        let vm = PracticeSessionViewModel(
            session: session,
            motion: NoopMotion(),
            arkit: FakeARTrackingManager(),
            impactDetector: ImpactDetector(),
            replayStore: store,
            onHaptic: { _ in }
        )

        vm.tapReadyForStrokes()
        let strokeSamples = fixtureStrokeSamples()
        vm.handle(strokeSamples[0])
        vm.touchDown()
        for s in strokeSamples.dropFirst() { vm.handle(s) }
        vm.touchUp()
        try #require(vm.phase == .showing)
        let expectedBatchId = vm.session.currentBatch.id
        let expectedStrokeType = vm.session.currentBatch.strokeTypeLabel
        vm.tapDone()

        // Save runs in a detached Task — give it a moment, then list.
        var urls: [URL] = []
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            urls = (try? store.list()) ?? []
            if !urls.isEmpty { break }
        }
        try #require(urls.count == 1, "expected one saved replay, got \(urls.count)")

        let loaded = try store.load(from: urls[0])
        #expect(loaded.batchId == expectedBatchId)
        #expect(loaded.batchStrokeIndex == 1)
        #expect(loaded.batchStrokeType == expectedStrokeType)
        // Filename should embed the batch info.
        #expect(urls[0].lastPathComponent.contains("-\(expectedBatchId)-1-"))
    }
}

/// Records every haptic/sound fired by the view-model under test.
/// `styles` covers the UIImpactFeedbackGenerator path (touchDown medium,
/// judgment-button light); `impactFires` counts the onImpactHaptic path
/// (UINotificationFeedbackGenerator.warning); `soundFires` counts the
/// onImpactSound path (bundled putter-click WAV).
@MainActor
fileprivate final class HapticLog {
    private(set) var styles: [UIImpactFeedbackGenerator.FeedbackStyle] = []
    private(set) var impactFires: Int = 0
    private(set) var soundFires: Int = 0
    func append(_ s: UIImpactFeedbackGenerator.FeedbackStyle) { styles.append(s) }
    func appendImpact() { impactFires += 1 }
    func appendSound() { soundFires += 1 }
    func clearStyles() { styles.removeAll(keepingCapacity: true) }
    func clearImpact() { impactFires = 0 }
    func clearSound() { soundFires = 0 }
    func heavyCount() -> Int { styles.filter { $0 == .heavy }.count }
    func lightCount() -> Int { styles.filter { $0 == .light }.count }
    func impactCount() -> Int { impactFires }
    func soundCount() -> Int { soundFires }
}

// MARK: - Test helpers (file-private, mirror SessionCoordinatorTests style)

@MainActor
fileprivate func stillSample(t: TimeInterval) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: SIMD3(0.001, 0.001, 0.001),
        userAcceleration: SIMD3(0.001, 0, 0),
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate final class NoopMotion: MotionStreaming, @unchecked Sendable {
    var isRunning: Bool = false
    var latestSample: MotionSample?
    func start() throws -> AsyncStream<MotionSample> {
        isRunning = true
        return AsyncStream<MotionSample> { continuation in
            continuation.finish()
        }
    }
    func stop() { isRunning = false }
}
