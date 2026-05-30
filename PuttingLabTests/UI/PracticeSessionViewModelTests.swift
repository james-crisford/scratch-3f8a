import Testing
import Foundation
import simd
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
