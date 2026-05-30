# Goal: 100-stroke guided test session mode (STRICT spec)

**Author:** Claude + James (clarified live 2026-05-30 ~12:00 GMT+1)
**Status:** READY FOR AUTONOMOUS EXECUTION while James is at lunch
**Budget cap:** $1.50 of remaining ~$3.00 GitHub Actions credits — hard ceiling

---

## Why this exists

The current `SensorDebugView` shows raw sensor numbers. Testers can't tell what
stroke they should be doing, when the app is recording, or which batch they're on.
This builds a guided **PracticeSessionView** that walks the user through the
100-stroke verification session with **touch-controlled stroke recording** and
explicit batch/stroke-type guidance.

## Locked design decisions (do not deviate)

1. **Touch protocol** — user presses + holds screen anywhere → recording starts;
   release → recording ends + ImpactDetector runs on the buffered window.
   Stroke window is bounded by the touch event, NOT by velocity thresholds.
   This is for the test session ONLY; the v1 production auto-detect path
   (StrokeDetector) is untouched.

2. **Aim target** — user picks ONE consistent target (doorway, wall mark,
   imaginary hole) before starting. Per spec ("back camera facing direction
   of swing"): the **back of the phone** (Z axis, perpendicular to screen)
   faces the target — NOT the top of the phone. Face angle is yaw delta
   from locked address yaw, so the absolute aim direction doesn't matter;
   what matters is CONSISTENCY of stance + orientation across all 100
   strokes. App calibration instructions say:
   - "Hold the phone vertical, screen TOWARD YOU, back of phone TOWARD TARGET"
   - "Don't change your stance between strokes — consistency > exact aim"

3. **Phone orientation** — vertical at aim/result phases (screen toward user
   for reading). During the actual stroke the phone tilts down naturally;
   that's expected. App tells user this explicitly.

4. **Result panel** — persists until user taps "DONE — NEXT STROKE". No
   auto-advance. User sets the pace.

5. **100 strokes split** — locked:
   - 5 calibration + 20 A + 15 B + 15 C + 5 D (Block 1 = 60)
   - 10-min break
   - 10 E + 10 F + 10 G + 10 H (Block 2 = 40)

6. **StrokeReplay JSON schema stays v1** — no schema changes. Touch metadata
   (touch_start_ts, touch_end_ts) NOT added in this commit; will go in v1.1.
   Reason: changing the schema requires backward-compat decoders + retesting
   the 315 existing tests, too much scope for one commit.

7. **Algorithm code UNCHANGED** — `ImpactDetector`, `StrokeDetector`,
   `StillnessDetector`, `MotionManager`, `ARTrackingManager`, `SessionCoordinator`
   are NOT modified. PracticeSessionViewModel builds its own touch-driven
   recording loop on top of the motion stream + ImpactDetector. The existing
   v1 pipeline remains testable separately.

---

## File plan

### NEW files

| File | Purpose |
|---|---|
| `PuttingLab/Models/TestBatch.swift` | Batch metadata (✅ already created) |
| `PuttingLab/Models/TestSessionState.swift` | @Observable session state machine + UserDefaults persistence |
| `PuttingLab/UI/PracticeSessionViewModel.swift` | Touch + motion handling, ImpactDetector integration |
| `PuttingLab/UI/PracticeSessionView.swift` | Root view with phase switching |
| `PuttingLab/UI/PhoneHoldVisual.swift` | Vertical iPhone illustration (SF Symbol-based, no asset needed) |
| `PuttingLabTests/UI/TestSessionStateTests.swift` | State machine unit tests |
| `PuttingLabTests/UI/PracticeSessionViewModelTests.swift` | Touch→stroke flow tests with NoopMotion / FakeAR |

### MODIFY files

| File | Change |
|---|---|
| `PuttingLab/App/PuttingLabApp.swift` | Root view becomes `PracticeSessionView`. Keep SensorDebugView reachable via a small "🔧 Debug" button in PracticeSessionView's corner. |
| `PuttingLab/UI/SensorDebugView.swift` | NO CHANGES — accessed via Debug button only. |
| `docs/testing-tomorrow-plan.md` | Bump 75 → 100. Update batch counts. Add touch protocol section. |
| `project.yml` | NO CHANGES (Swift files auto-included from PuttingLab/ folder). |

---

## Detailed phase-by-phase spec

### Phase 1 — Setup (waiting for stroke)

**Top bar:**
- Progress: "STROKE 23 of 100"  + filled bar `▰▰▰▰▱▱▱▱▱▱`
- Batch label: BIG TEXT "BATCH B · PULL · 3 of 15"

**Centre card:**
- Title: e.g. "Deliberate PULL stroke"
- Subtitle: intent summary
- Bullet list of batch instructions

**Phone-hold visual:**
- Shown for first 2 strokes of each new batch, auto-hides after
- SF Symbols `iphone` (vertical) + arrows + labels:
  - "Screen toward you"
  - "Top of phone → target"
  - "Phone tilts down during stroke — that's fine"

**Bottom area:**
- Pulsing prompt: **"TAP AND HOLD ANYWHERE TO STROKE"**
- Down arrow indicator

**Touch detection:** entire screen area is a `DragGesture(minimumDistance: 0)`
that fires `viewModel.touchDown()` on first move and `viewModel.touchUp()` on end.

### Phase 2 — Recording (touch held)

**Full screen RED background** (high contrast — peripherally visible)

**Centre:**
- Large white text: "RECORDING"
- Sub: "Release at end of follow-through"
- Pulsing circle animation

**On touchDown:**
- Medium haptic
- Snapshot latest `MotionSample` as the address-pose lock baseline
- Snapshot `arkit.attitudeYaw()` as baseline yaw
- Start collecting all subsequent samples into a buffer
- Start collecting `arkit.latestPose` snapshots too

**On touchUp:**
- Build `StrokeWindow` from buffered samples
- Reject if < 5 samples ("too quick — please try again" toast, return to Setup)
- Otherwise run `ImpactDetector.detect(in: window, arkitPoses: [...], arkitBaselineYaw: ...)`
- Save StrokeReplay via existing `StrokeReplayStore.shared.save(replay)` in a
  detached Task (same pattern as `SessionCoordinator.completeStroke`)
- Success haptic
- Transition to Phase 3

### Phase 3 — Result (waiting for user to dismiss)

**Background:** white / system bg
**Centre panel:**
- Big "STROKE 23 RECORDED" header
- Face row: "Face: +4.2° pull" (with bucket label from MarioKartAssist)
- Velocity row: "Peak: 1.24 m/s"
- Confidence row: "Confidence: 0.78"
- Snap row (only if snapped): "Square (peakSpeedTooLow)"

**Bottom:**
- Big green button: **"DONE — NEXT STROKE"**
- Tapping it: increments `TestSessionState.recordStroke()`, persists, advances
  to next phase (Setup with new stroke count, OR BatchComplete, OR Break, OR
  SessionComplete).

### Phase 4 — Batch transition (between batches)

**Centre:**
- Large "BATCH B COMPLETE" header
- "15 of 15 strokes recorded"
- "Next: Batch C — Push strokes"
- Intent summary of next batch

**Bottom:**
- Button: "CONTINUE TO BATCH C"
- Tapping: advances batch, returns to Setup

### Phase 5 — Break (between Block 1 and Block 2)

**Full screen:**
- Big "BREAK TIME" header
- "10 minutes recommended"
- "60 of 100 strokes done"
- Bullets: put phone down, drink water, stretch, etc.

**Bottom:**
- Button: "I'M READY TO RESUME"
- Tapping: advances to Batch E in Setup phase

### Phase 6 — Session complete

**Centre:**
- "🎉 SESSION COMPLETE"
- "100 of 100 strokes recorded"

**Instructions for export (NO emojis on action buttons):**
- "1. Open Files app on this iPhone"
- "2. Go to On My iPhone → PuttingLab → StrokeReplays"
- "3. Long-press → Select All → Share → Save to Drive"

**Bottom buttons:**
- "VIEW HISTORY" (opens existing ReplayHistoryView)
- "Restart Session" (with confirmation alert — wipes TestSessionState)

---

## TestSessionState spec

```swift
@MainActor @Observable
final class TestSessionState {
    private(set) var currentBatchIndex: Int = 0
    private(set) var strokesInCurrentBatch: Int = 0
    private(set) var totalStrokesCompleted: Int = 0
    let batches: [TestBatch]

    var currentBatch: TestBatch { batches[currentBatchIndex] }
    var isAtBreak: Bool { currentBatch.phase == .breakPoint }
    var isSessionComplete: Bool { /* last batch AND batch complete */ }
    var currentBatchIsComplete: Bool { /* depends on phase */ }
    var totalTargetStrokes: Int { 100 }

    @discardableResult
    func recordStroke() -> Bool /* returns true if batch now complete */
    func advanceBatch()
    func reset()
    func save()    // UserDefaults
    func loadIfAvailable()
    func clearPersistence()
}
```

**Persistence keys (UserDefaults):**
- `TestSessionState_v1.currentBatchIndex` (Int)
- `TestSessionState_v1.strokesInCurrentBatch` (Int)
- `TestSessionState_v1.totalStrokesCompleted` (Int)
- Saved on every `recordStroke()` and `advanceBatch()`
- Loaded on app launch (if present, resume mid-session)

---

## PracticeSessionViewModel spec

```swift
@MainActor @Observable
final class PracticeSessionViewModel {
    enum Phase: Equatable {
        case setup
        case recording
        case showing(ImpactResult?)
        case batchTransition  // batch just completed, waiting for "continue"
        case breakPoint
        case sessionComplete
    }

    var phase: Phase = .setup
    var session: TestSessionState
    var latestSample: MotionSample?
    var errorText: String?

    init(motion: MotionStreaming = MotionManager(),
         arkit: ARTracking = ARTrackingManager(),
         impactDetector: ImpactDetector = ImpactDetector(),
         replayStore: StrokeReplayStore? = StrokeReplayStore.shared)

    func startSession()  // calls motion.start() + arkit.start() + spins consumer task
    func stopSession()
    func touchDown()
    func touchUp()
    func tapDone()        // advance after Result panel
    func tapContinue()    // advance after batchTransition
    func tapReadyAfterBreak()
}
```

**On touchUp the stroke pipeline:**
1. Require `samplesDuringRecording.count >= 5`, else show "too quick" + return to setup
2. Build `StrokeWindow(start:, end:, samples:, lock:)`
3. Try `impactDetector.detect(in: window, arkitPoses: poses, arkitBaselineYaw: baseline)`
4. Save replay via `Task.detached { try? store.save(replay) }`
5. `phase = .showing(result)`

**On tapDone:**
- `let batchJustCompleted = session.recordStroke()`
- `session.save()`
- If session complete: `phase = .sessionComplete`
- Else if batch complete:
  - If NEXT batch is `.breakPoint`: advance batch + `phase = .breakPoint`
  - Else: `phase = .batchTransition`
- Else: `phase = .setup`

---

## Tests to ADD (must pass with existing 315)

### TestSessionStateTests.swift

- `startsAtCalibrationBatch`
- `recordStrokeIncrementsCounters`
- `recordStrokeReturnsTrueWhenBatchTargetReached`
- `recordStrokeReturnsFalseMidBatch`
- `advanceBatchAdvancesIndexAndResetsCounter`
- `recordStrokeOnBreakPhaseIsNoop`
- `recordStrokeOnCompleteSessionIsNoop`
- `totalTargetStrokesEquals100`
- `persistenceSavesAndLoadsRoundTrip`  (using `UserDefaults(suiteName: UUID().uuidString)`)
- `clearPersistenceResetsToInitial`
- `walkThroughEntireSessionReaches100Strokes`  (loop 100 strokes, advance batches as needed, assert at end)

### PracticeSessionViewModelTests.swift

- `touchDownTransitionsToRecording`
- `touchUpWithoutEnoughSamplesGoesBackToSetup`
- `touchUpWithSufficientSamplesProducesResult`
- `tapDoneFromShowingAdvancesToSetup`
- `tapDoneOnLastStrokeOfBatchTransitionsToBatchTransition`
- `tapDoneOnLastStrokeOfBatchDTransitionsToBreak`
- `tapDoneOnLastStrokeReachesSessionComplete`
- `samplesAccumulateOnlyDuringRecordingPhase`

Use `NoopMotion` and `FakeARTrackingManager` for DI (already exist in test fixtures).

---

## Rigorous audits BEFORE push

Execute IN ORDER:

### Audit 1 — Spec conformance
Re-read every NEW file and check:
- No locked-decision violations (touch protocol, schema unchanged, algorithm unchanged)
- No emoji in code or button labels (per "no emojis" rule)
- All file paths match the file plan above
- Imports are minimal and correct

### Audit 2 — Test count integrity
- Count tests in `PuttingLabTests/` before and after this change
- New count = 315 + (new tests added — 11 + 8 = 19) → expected 334 tests
- If any existing test was changed/removed: flag and explain

### Audit 3 — StrokeReplay schema unchanged
- `grep -n "schemaVersion" PuttingLab/Models/StrokeReplay.swift` should still be 1
- `grep -n "CodingKeys" PuttingLab/Models/StrokeReplay.swift` unchanged
- Confirm no edits to StrokeReplay.swift in this commit

### Audit 4 — Algorithm files unchanged
- `git diff --stat HEAD` should show ZERO changes to:
  - `PuttingLab/Physics/*.swift`
  - `PuttingLab/Sensors/*.swift`
  - `PuttingLab/SessionCoordinator.swift`
- If any have changes: stop and revert

### Audit 5 — Codegraph (skip if Swift not indexed)
- Already confirmed earlier — codegraph doesn't index Swift. Skip.

### Audit 6 — Gemini auto-review
- The PostToolUse hook should have fired Gemini reviews on every Write/Edit
- If any review found issues: flag in commit message + address them or revert

### Audit 7 — Compile sanity (best-effort, no Xcode)
- For every new Swift file: read through manually checking:
  - `@MainActor` annotations consistent
  - `@Observable` macro applied correctly
  - `import` statements present
  - No undefined types
  - No missing `try` on throws
- This is the LAST gate before commit.

---

## Commit + push process

```bash
cd "c:/Users/james/Desktop/Claude Agent/projects/PuttingLab"

# Verify only the expected files are staged
git status

# Stage
git add PuttingLab/Models/TestBatch.swift
git add PuttingLab/Models/TestSessionState.swift
git add PuttingLab/UI/PracticeSessionView.swift
git add PuttingLab/UI/PracticeSessionViewModel.swift
git add PuttingLab/UI/PhoneHoldVisual.swift
git add PuttingLab/App/PuttingLabApp.swift
git add PuttingLabTests/UI/TestSessionStateTests.swift
git add PuttingLabTests/UI/PracticeSessionViewModelTests.swift
git add docs/testing-tomorrow-plan.md
git add goals/in-app-test-session-mode.md

# Confirm staged set
git diff --cached --stat

# Commit with [skip ci] so push does NOT trigger paid CI
git commit -m "Add guided 100-stroke session mode + touch-controlled recording [skip ci]

(full commit body — see goal file for spec)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"

# Push
git push

# Verify no CI auto-fired
sleep 5
gh run list --workflow=test.yml --limit 1

# Manually trigger signed release with skip_tests for cost
gh workflow run test.yml -f release=true -f skip_tests=true

# Wait + watch
sleep 5
gh run list --workflow=test.yml --limit 1
```

---

## CI watching + failure handling

### Success path
- Watch run via `gh run view <ID>` periodic poll
- Expected wall-clock: ~2 min (release job only since skip_tests=true)
- Expected cost: ~$0.30
- On green: confirm via App Store Connect → PuttingLab → TestFlight that
  Build 2 (or higher) appears. Status will be "Processing" for 5-10 min.

### Failure path
- Pull failed step log via `gh run view <ID> --log-failed | tail -100`
- Diagnose
- Hard limit: **ONE** corrective commit + push. If THAT fails too, STOP and
  document. Don't keep burning budget.

### Budget hard ceiling
- This goal's spend ceiling: $1.50
- If hit: stop pushing, document local-only state, leave for James.

---

## Output (what James sees when he returns)

1. Memory updated at `C:\Users\james\.claude\projects\c--Users-james-Desktop-Claude-Agent\memory\project_puttinglab_build.md` with:
   - Latest commit SHA
   - CI run ID + status
   - TestFlight Build number + status
   - Cost spent
   - Any unresolved issues

2. A concise message to James:
   ```
   Build N processing in TestFlight (or specific failure).
   Commit <sha>. Tests <N> green / <M> changed.
   Cost: $X.XX of $1.50 ceiling.
   Outstanding: <if any>.
   To install: TestFlight app → Apps in Development → PuttingLab → tap Update
   ```

3. This goal file marked complete in todos.

---

## Hard rules

- ⛔ NO changes to algorithm code (Physics/, Sensors/, SessionCoordinator)
- ⛔ NO changes to StrokeReplay.swift schema
- ⛔ NO spec deviations
- ⛔ NO speculative refactors
- ⛔ NO more than 2 commits total (1 success + at most 1 fix)
- ⛔ NO spending past $1.50
- ⛔ NO emojis in code or button text
- ✅ DO write tests for new state machine
- ✅ DO follow the audit checklist before commit
- ✅ DO use the existing motion/arkit/impact pipeline (DI from existing types)
- ✅ DO save StrokeReplay JSONs via the existing store (no new schema)
- ✅ DO update memory at end
