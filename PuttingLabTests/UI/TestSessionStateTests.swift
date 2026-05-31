import Testing
import Foundation
@testable import PuttingLab

@Suite("TestSessionState — 100-stroke session state machine")
@MainActor
struct TestSessionStateTests {

    /// Fresh per-test UserDefaults so tests can run in parallel without
    /// touching the real plist. Using a UUID suite gives byte-isolation
    /// between test cases.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "TestSessionStateTests-\(UUID().uuidString)") ?? .standard
    }

    @Test("starts at calibration batch")
    func startsAtCalibrationBatch() {
        let s = TestSessionState(userDefaults: makeDefaults())
        #expect(s.currentBatchIndex == 0)
        #expect(s.currentBatch.id == "cal")
        #expect(s.strokesInCurrentBatch == 0)
        #expect(s.totalStrokesCompleted == 0)
    }

    @Test("recordStroke increments both counters")
    func recordStrokeIncrementsCounters() {
        let s = TestSessionState(userDefaults: makeDefaults())
        _ = s.recordStroke()
        #expect(s.strokesInCurrentBatch == 1)
        #expect(s.totalStrokesCompleted == 1)
        _ = s.recordStroke()
        #expect(s.strokesInCurrentBatch == 2)
        #expect(s.totalStrokesCompleted == 2)
    }

    @Test("recordStroke returns true when batch target reached")
    func recordStrokeReturnsTrueAtBatchTarget() {
        let s = TestSessionState(userDefaults: makeDefaults())
        // Calibration target is 5.
        for i in 1...4 {
            #expect(s.recordStroke() == false, "stroke \(i) of calibration should not complete batch")
        }
        #expect(s.recordStroke() == true, "5th calibration stroke should complete batch")
    }

    @Test("recordStroke returns false mid-batch")
    func recordStrokeReturnsFalseMidBatch() {
        let s = TestSessionState(userDefaults: makeDefaults())
        let result = s.recordStroke()
        #expect(result == false)
    }

    @Test("advanceBatch advances index and resets in-batch counter")
    func advanceBatchAdvancesAndResets() {
        let s = TestSessionState(userDefaults: makeDefaults())
        _ = s.recordStroke()
        _ = s.recordStroke()
        s.advanceBatch()
        #expect(s.currentBatchIndex == 1)
        #expect(s.currentBatch.id == "A")
        #expect(s.strokesInCurrentBatch == 0)
        // totalStrokesCompleted is preserved across batch advances.
        #expect(s.totalStrokesCompleted == 2)
    }

    @Test("recordStroke on break phase is a no-op")
    func recordStrokeOnBreakIsNoop() {
        let s = TestSessionState(userDefaults: makeDefaults())
        // Fast-forward to the break batch (index after D).
        while s.currentBatch.id != "break" {
            s.advanceBatch()
            if s.currentBatchIndex >= s.batches.count - 1 { break }
        }
        #expect(s.isAtBreak == true)
        let totalBefore = s.totalStrokesCompleted
        let result = s.recordStroke()
        #expect(result == false)
        #expect(s.totalStrokesCompleted == totalBefore)
    }

    @Test("recordStroke after session complete is a no-op")
    func recordStrokeAfterCompleteIsNoop() {
        let s = TestSessionState(userDefaults: makeDefaults())
        // Walk the whole session.
        walkEntireSession(s)
        #expect(s.isSessionComplete == true)
        let totalBefore = s.totalStrokesCompleted
        let result = s.recordStroke()
        #expect(result == false)
        #expect(s.totalStrokesCompleted == totalBefore)
    }

    @Test("total target strokes equals 100")
    func totalTargetStrokesIs100() {
        let s = TestSessionState(userDefaults: makeDefaults())
        #expect(s.totalTargetStrokes == 100)
    }

    @Test("persistence saves and loads round-trip")
    func persistenceSaveAndLoad() {
        let defaults = makeDefaults()
        let a = TestSessionState(userDefaults: defaults)
        _ = a.recordStroke()
        _ = a.recordStroke()
        _ = a.recordStroke()
        a.advanceBatch()
        a.save()

        let b = TestSessionState(userDefaults: defaults)
        b.loadIfAvailable()
        #expect(b.currentBatchIndex == a.currentBatchIndex)
        #expect(b.strokesInCurrentBatch == a.strokesInCurrentBatch)
        #expect(b.totalStrokesCompleted == a.totalStrokesCompleted)
    }

    @Test("clearPersistence resets stored values")
    func clearPersistence() {
        let defaults = makeDefaults()
        let a = TestSessionState(userDefaults: defaults)
        _ = a.recordStroke()
        a.save()
        a.clearPersistence()

        let b = TestSessionState(userDefaults: defaults)
        b.loadIfAvailable()
        #expect(b.currentBatchIndex == 0)
        #expect(b.strokesInCurrentBatch == 0)
        #expect(b.totalStrokesCompleted == 0)
    }

    @Test("walking the entire session reaches 100 strokes")
    func walkThroughEntireSessionReaches100() {
        let s = TestSessionState(userDefaults: makeDefaults())
        walkEntireSession(s)
        #expect(s.totalStrokesCompleted == 100)
        #expect(s.isSessionComplete == true)
    }

    // MARK: - Helpers

    /// Walks the state machine through every batch as if the user had
    /// completed all 100 strokes (advancing through the break appropriately).
    private func walkEntireSession(_ s: TestSessionState) {
        var safety = 0
        while !s.isSessionComplete {
            safety += 1
            if safety > 200 {
                Issue.record("Session walk failed to terminate after 200 steps")
                return
            }
            if s.currentBatch.phase == .breakPoint {
                s.advanceBatch()
                continue
            }
            let target = s.currentBatch.targetCount
            for _ in 0..<target {
                if s.recordStroke() {
                    break
                }
            }
            if s.currentBatchIsComplete && !s.isLastBatch {
                s.advanceBatch()
            } else if s.isLastBatch && s.currentBatchIsComplete {
                break
            }
        }
    }

    // MARK: - B14: calibration face-angle baseline

    @Test("calibrationFaceBaselineRad is nil until at least 3 cal strokes recorded")
    func calBaselineNilBeforeThreeStrokes() {
        let s = TestSessionState(userDefaults: makeDefaults())
        #expect(s.calibrationFaceBaselineRad == nil)
        s.recordCalibrationFaceAngle(-0.10)
        s.recordCalibrationFaceAngle(-0.12)
        #expect(s.calibrationFaceBaselineRad == nil, "<3 samples should not yield a baseline")
        s.recordCalibrationFaceAngle(-0.11)
        #expect(s.calibrationFaceBaselineRad != nil, "3+ samples should yield a baseline")
        let mean = s.calibrationFaceBaselineRad ?? .nan
        #expect(abs(mean - (-0.11)) < 1e-9)
    }

    @Test("recordCalibrationFaceAngle silently rejects non-finite values")
    func calBaselineRejectsNonFinite() {
        let s = TestSessionState(userDefaults: makeDefaults())
        s.recordCalibrationFaceAngle(.nan)
        s.recordCalibrationFaceAngle(.infinity)
        s.recordCalibrationFaceAngle(-.infinity)
        #expect(s.calibrationFaceAnglesRad.isEmpty)
    }

    @Test("calibration face-angle buffer is capped at the cal batch target")
    func calBaselineCapsAtBatchTarget() {
        let s = TestSessionState(userDefaults: makeDefaults())
        let target = TestBatch.allBatches.first(where: { $0.id == "cal" })!.targetCount
        for i in 0..<(target + 10) {
            s.recordCalibrationFaceAngle(0.01 * Double(i))
        }
        #expect(s.calibrationFaceAnglesRad.count == target)
    }

    @Test("calibration face-angle buffer persists across save/load")
    func calBaselinePersistsAcrossLoad() {
        let defaults = makeDefaults()
        let s = TestSessionState(userDefaults: defaults)
        s.recordCalibrationFaceAngle(-0.115)
        s.recordCalibrationFaceAngle(-0.105)
        s.recordCalibrationFaceAngle(-0.110)
        s.save()

        let reloaded = TestSessionState(userDefaults: defaults)
        reloaded.loadIfAvailable()
        #expect(reloaded.calibrationFaceAnglesRad.count == 3)
        #expect(abs((reloaded.calibrationFaceBaselineRad ?? .nan) - (-0.110)) < 1e-9)
    }

    @Test("reset clears the calibration baseline")
    func resetClearsCalBaseline() {
        let s = TestSessionState(userDefaults: makeDefaults())
        s.recordCalibrationFaceAngle(-0.10)
        s.recordCalibrationFaceAngle(-0.12)
        s.recordCalibrationFaceAngle(-0.11)
        #expect(s.calibrationFaceBaselineRad != nil)
        s.reset()
        #expect(s.calibrationFaceAnglesRad.isEmpty)
        #expect(s.calibrationFaceBaselineRad == nil)
    }
}
