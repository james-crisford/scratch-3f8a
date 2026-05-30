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

    let batches: [TestBatch]
    let userDefaults: UserDefaults

    private static let keyCurrentBatchIndex = "TestSessionState_v1.currentBatchIndex"
    private static let keyStrokesInCurrentBatch = "TestSessionState_v1.strokesInCurrentBatch"
    private static let keyTotalStrokesCompleted = "TestSessionState_v1.totalStrokesCompleted"

    init(
        batches: [TestBatch] = TestBatch.allBatches,
        userDefaults: UserDefaults = .standard
    ) {
        self.batches = batches
        self.userDefaults = userDefaults
    }

    var currentBatch: TestBatch { batches[currentBatchIndex] }
    var isAtBreak: Bool { currentBatch.phase == .breakPoint }

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
    }

    /// Saves current state to UserDefaults. Call after every recordStroke()
    /// + advanceBatch() so resume after backgrounding is byte-accurate.
    func save() {
        userDefaults.set(currentBatchIndex, forKey: Self.keyCurrentBatchIndex)
        userDefaults.set(strokesInCurrentBatch, forKey: Self.keyStrokesInCurrentBatch)
        userDefaults.set(totalStrokesCompleted, forKey: Self.keyTotalStrokesCompleted)
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
    }

    func clearPersistence() {
        userDefaults.removeObject(forKey: Self.keyCurrentBatchIndex)
        userDefaults.removeObject(forKey: Self.keyStrokesInCurrentBatch)
        userDefaults.removeObject(forKey: Self.keyTotalStrokesCompleted)
    }
}
