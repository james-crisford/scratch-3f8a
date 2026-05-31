import Foundation
import Observation

/// Observable state machine for the 100-stroke verification session.
///
/// Walks the user through 10 phases (9 stroke batches + 1 break) defined in
/// `TestBatch.allBatches`. Persists progress to UserDefaults so the user can
/// resume mid-session after backgrounding or quitting.
///
/// Used by `PracticeSessionViewModel`; tested directly in
/// `TestSessionStateTests`.
@MainActor
@Observable
final class TestSessionState {
    private(set) var currentBatchIndex: Int = 0
    private(set) var strokesInCurrentBatch: Int = 0
    private(set) var totalStrokesCompleted: Int = 0
    /// Raw face angles (radians) captured during the cal batch — used to
    /// derive `calibrationFaceBaselineRad` once at least 3 cal strokes
    /// have been recorded. Persisted to UserDefaults so a mid-session
    /// kill/relaunch doesn't lose the baseline.
    private(set) var calibrationFaceAnglesRad: [Double] = []

    let batches: [TestBatch]
    let userDefaults: UserDefaults

    private static let keyCurrentBatchIndex = "TestSessionState_v1.currentBatchIndex"
    private static let keyStrokesInCurrentBatch = "TestSessionState_v1.strokesInCurrentBatch"
    private static let keyTotalStrokesCompleted = "TestSessionState_v1.totalStrokesCompleted"
    private static let keyCalibrationFaceAngles = "TestSessionState_v1.calibrationFaceAnglesRad"

    init(
        batches: [TestBatch] = TestBatch.allBatches,
        userDefaults: UserDefaults = .standard
    ) {
        self.batches = batches
        self.userDefaults = userDefaults
    }

    var currentBatch: TestBatch { batches[currentBatchIndex] }
    var isAtBreak: Bool { currentBatch.phase == .breakPoint }

    /// Mean of the captured cal-batch face angles (radians), once we've
    /// got at least 3 samples. Nil before then so the UI shows the raw
    /// angle for the first few cal strokes (calibration hasn't stabilised).
    var calibrationFaceBaselineRad: Double? {
        guard calibrationFaceAnglesRad.count >= 3 else { return nil }
        let sum = calibrationFaceAnglesRad.reduce(0, +)
        return sum / Double(calibrationFaceAnglesRad.count)
    }

    /// Records a face angle into the cal-batch baseline accumulator.
    /// Caller should only invoke this for strokes saved during the cal
    /// batch (`currentBatch.id == "cal"`); silently caps the buffer at
    /// the cal batch's targetCount so a buggy caller can't over-fill it.
    func recordCalibrationFaceAngle(_ rad: Double) {
        guard rad.isFinite else { return }
        let calBatch = batches.first(where: { $0.id == "cal" })
        let cap = calBatch?.targetCount ?? 5
        guard calibrationFaceAnglesRad.count < cap else { return }
        calibrationFaceAnglesRad.append(rad)
    }

    var currentBatchIsComplete: Bool {
        if currentBatch.phase == .breakPoint { return false }
        return strokesInCurrentBatch >= currentBatch.targetCount
    }

    /// True when all stroke-bearing batches are done.
    var isSessionComplete: Bool {
        currentBatchIndex >= batches.count - 1 && currentBatchIsComplete
    }

    var isLastBatch: Bool {
        currentBatchIndex >= batches.count - 1
    }

    var totalTargetStrokes: Int {
        batches
            .filter { $0.phase != .breakPoint }
            .reduce(0) { $0 + $1.targetCount }
    }

    /// 0…100 percent through the session, computed from completed strokes.
    var sessionProgressPercent: Double {
        guard totalTargetStrokes > 0 else { return 0 }
        return Double(totalStrokesCompleted) / Double(totalTargetStrokes) * 100.0
    }

    /// Records a completed stroke. No-op when at a break or after session
    /// complete. Returns `true` when the current batch's target count is hit
    /// (caller should advance + show batch-transition card).
    @discardableResult
    func recordStroke() -> Bool {
        if currentBatch.phase == .breakPoint { return false }
        if isSessionComplete { return false }
        strokesInCurrentBatch += 1
        totalStrokesCompleted += 1
        return strokesInCurrentBatch >= currentBatch.targetCount
    }

    /// Advances to the next batch. No-op when already on the last batch.
    func advanceBatch() {
        guard currentBatchIndex < batches.count - 1 else { return }
        currentBatchIndex += 1
        strokesInCurrentBatch = 0
    }

    /// Wipes the session back to the calibration batch.
    func reset() {
        currentBatchIndex = 0
        strokesInCurrentBatch = 0
        totalStrokesCompleted = 0
        calibrationFaceAnglesRad = []
    }

    /// Saves current state to UserDefaults. Call after every recordStroke()
    /// + advanceBatch() so resume after backgrounding is byte-accurate.
    func save() {
        userDefaults.set(currentBatchIndex, forKey: Self.keyCurrentBatchIndex)
        userDefaults.set(strokesInCurrentBatch, forKey: Self.keyStrokesInCurrentBatch)
        userDefaults.set(totalStrokesCompleted, forKey: Self.keyTotalStrokesCompleted)
        userDefaults.set(calibrationFaceAnglesRad, forKey: Self.keyCalibrationFaceAngles)
    }

    /// Loads previous state from UserDefaults if present + still valid for
    /// the current batch list. Silently ignores invalid persisted values.
    func loadIfAvailable() {
        let idx = userDefaults.integer(forKey: Self.keyCurrentBatchIndex)
        let inBatch = userDefaults.integer(forKey: Self.keyStrokesInCurrentBatch)
        let total = userDefaults.integer(forKey: Self.keyTotalStrokesCompleted)
        guard idx >= 0, idx < batches.count else { return }
        let batchTarget = batches[idx].targetCount
        // Defensive: if persisted strokesInBatch exceeds target, clamp.
        let cappedInBatch = max(0, min(inBatch, batchTarget))
        let cappedTotal = max(0, min(total, totalTargetStrokes))
        currentBatchIndex = idx
        strokesInCurrentBatch = cappedInBatch
        totalStrokesCompleted = cappedTotal
        if let raw = userDefaults.array(forKey: Self.keyCalibrationFaceAngles) as? [Double] {
            // Defensive: drop non-finite entries that might have snuck in.
            calibrationFaceAnglesRad = raw.filter { $0.isFinite }
        }
    }

    func clearPersistence() {
        userDefaults.removeObject(forKey: Self.keyCurrentBatchIndex)
        userDefaults.removeObject(forKey: Self.keyStrokesInCurrentBatch)
        userDefaults.removeObject(forKey: Self.keyTotalStrokesCompleted)
        userDefaults.removeObject(forKey: Self.keyCalibrationFaceAngles)
    }
}
