# PuttingLab Build 14 — AR Ball-Replay Integration Audit

*Date: 2026-05-31. Audit-only. No code touched. Targets Build 14 (0.2.0) currently on TestFlight.*

The purpose of this document is to map every existing surface that an AR ball-replay feature would have to layer on top of, identify exact integration seams, and call out the parts of Build 14 that are fragile, locked, or otherwise off-limits. All file:line citations are against the working tree as of today.

---

## 1. What's already there for AR

### 1.1 `ARTrackingManager.swift` (Sensors layer)

Single file, ~140 lines. Wraps an `ARSession` and exposes a narrow `ARTracking` protocol (file: `PuttingLab/Sensors/ARTrackingManager.swift:11-18`).

**What it does today:**

- Runs `ARWorldTrackingConfiguration` with every visual feature explicitly disabled (`PuttingLab/Sensors/ARTrackingManager.swift:60-67`):
  - `planeDetection = []`
  - `frameSemantics = []`
  - `environmentTexturing = .none`
  - `isLightEstimationEnabled = false`
- Starts with `[.resetTracking, .removeExistingAnchors]` (line 66) — every `start()` is a hard reset.
- Caches the most recent `ARFrame` as an `ARPose` struct (`timestamp`, `transform: simd_float4x4`, `trackingState`) under `NSLock` (line 86-97).
- Exposes `attitudeYaw()` which derives a yaw from `transform.columns.2` via `atan2(-fx, -fz)` (`PuttingLab/Sensors/ARTrackingManager.swift:80-84, 133-140`).
- Handles `sessionWasInterrupted` (clears pose + sets state `.notAvailable`) and `sessionInterruptionEnded` (full reset-tracking restart) — added in the KI-12 follow-up (line 109-127).

**What it explicitly does NOT do — and what we'd need for AR replay:**

- **No `ARView` / `ARSCNView` / `RealityView`** anywhere in the codebase. The current session is *headless*: ARKit runs purely as a drift-corrected yaw source, never rendering a camera feed. There is no `arkit` import outside this file and `ImpactDetector.swift`.
- **No anchors.** `removeExistingAnchors` is set on every start. No `ARAnchor`, `ARPlaneAnchor`, `ARRaycastQuery`, or `ARWorldMap` reference exists.
- **No plane detection.** Re-enabling `.horizontal` is the first thing the AR replay feature will need.
- **No `Sendable` of `ARPose`** — it's a value type and is read on the main actor via the `lock`, but there's no `AsyncStream<ARPose>`. Frame updates are polled (`arkit.latestPose`) from `PracticeSessionViewModel.handle` (line 222).
- **No raycast / hit-testing layer.** Placing a virtual ball + virtual hole would need this.
- **Spec says §1 decision #6 — "Baby steps — no AR ground plane in v1; 2D top-down result"** (docs/spec-putting-lab-v1-FINAL.md:32). The AR replay would be the first deviation from that locked decision; treat as a v1.1 feature, not v1.

### 1.2 ARKit usage outside the manager

`ImpactDetector.detect` accepts `arkitPoses: [ARPose] = []` and `arkitBaselineYaw: Double? = nil` (`PuttingLab/Physics/ImpactDetector.swift:25-30`). The viewmodel collects `arkit.latestPose` into `posesDuringRecording` while recording (`PuttingLab/UI/PracticeSessionViewModel.swift:223-225`) and snapshots a baseline yaw on touchDown (`PracticeSessionViewModel.swift:276`). The AR replay will need to consume the *same* pose stream — important so that the replay's world-space coordinates line up with the impact-time yaw the algorithm already used.

---

## 2. `ImpactDetector` output contract

The detector returns an `ImpactResult` (defined out-of-file but stitched together via call sites and `StrokeReplay.SerializedImpactResult` at `PuttingLab/Models/StrokeReplay.swift:49-56`).

### 2.1 Fields produced per stroke

| Field | Type | Units | Source |
|---|---|---|---|
| `timestamp` | `TimeInterval` | seconds (mach-anchored) | `ImpactDetector.swift:120, 153` — parabolic-interpolated impact time |
| `peakVelocity` | `Double` | metres / second | `ImpactDetector.swift:99-105, 154` — magnitude of the smoothed forward-axis velocity at the chosen extremum. Always positive (negative case is flipped at line 102). |
| `faceAngleRaw` | `Double` | radians | `ImpactDetector.swift:131-138, 155` — output of `FaceAngleComputer.compute(...).radians` |
| `attitudeAtImpact` | `simd_quatd` | unit quaternion | `ImpactDetector.swift:122-129, 156` — slerp between bracketing samples around the parabolic offset |
| `confidence` | `Double` | 0…1 | `ImpactDetector.swift:148-150, 157` — 1.0 baseline, ×0.4 if `arkitLost`, ×0.7 if stroke shorter than 250 ms |
| `snappedToSquare` | `Bool` | flag | `ImpactDetector.swift:234-244` (snap helper) — defaults `false`; `true` only via the snap helper |
| `snapReason` | `SnapReason?` | enum | snap-path only. Possible values inferred from `MarioKartAssist.causeForSnapReason` (`PuttingLab/Physics/MarioKartAssist.swift:60-72`): `.strokeTooShort`, `.noClearPeak`, `.arkitLost`, `.peakSpeedTooLow` |

### 2.2 Sign conventions

- **`faceAngleRaw`**: radians. The comment at `PuttingLab/Physics/MarioKartAssist.swift:87` (`let isPull = faceAngleDeg < 0`) and the spec's §5.1 (`docs/spec-putting-lab-v1-FINAL.md:320` — *"For a right-handed user: negative raw = closed face = pull left"*) establish the convention:
  - **negative** → closed face → ball goes **left** (pull for a right-hander)
  - **positive** → open face → ball goes **right** (push for a right-hander)
  - Test fixtures `TestBatch.B` (PULL) and `TestBatch.C` (PUSH) (`PuttingLab/Models/TestBatch.swift:57-85`) corroborate: PULL = "phone TOP toward LEFT FOOT", PUSH = "phone TOP toward RIGHT FOOT".
- **`peakVelocity`**: always non-negative — the magnitude of the velocity at the dominant extremum after a possible array-wide flip (`ImpactDetector.swift:97-105`). The AR replay must NOT interpret sign here.
- **`timestamp`**: `TimeInterval` from `mach_absolute_time`-anchored CoreMotion timestamps (`MotionSample.init(from: CMDeviceMotion)` at `PuttingLab/Models/MotionSample.swift:26-45`). Same clock domain as `ARPose.timestamp` (the `ARFrame.timestamp` from `frame.timestamp` at `ARTrackingManager.swift:90`), which is critical: an AR replay can `slerp` between `posesDuringRecording` to find the world-space camera pose AT `ImpactResult.timestamp` without re-clocking.

### 2.3 What is NOT in the output that AR replay would need

- **No swing-plane vector.** The principal axis is computed inside `ImpactDetector.principalAxis` (`PuttingLab/Physics/ImpactDetector.swift:169-205`) but it's local — only the projected velocity escapes. AR replay wants the world-space launch direction; that would require re-running PCA on the saved samples OR plumbing the forward axis out of the detector. **Recommendation: plumb a `forwardAxisWorld: SIMD3<Double>` out alongside `attitudeAtImpact` in a new wrapper struct, leaving `ImpactResult` untouched.**
- **No ball-launch position.** There is no notion of where the virtual ball sits relative to the phone. AR replay must create this via `ARRaycastQuery` (user taps a spot on the green).
- **No `DistanceResult` on the impact result.** `DistanceModel.compute` (`PuttingLab/Physics/DistanceModel.swift:59-82`) returns `displayedFeet / lowFeet / highFeet / ballSpeedFps / rawFeet / isSuppressed`. The viewmodel currently does NOT call this — the result panel shows raw peak velocity only (`PuttingLab/UI/PracticeSessionView.swift:424-425`). AR replay needs the rolled-out distance to know where the ball comes to rest; either layer must call `DistanceModel.compute(peakSpeedMps:)` itself or this becomes a coupling point to add.
- **No `DirectionResult`.** `MarioKartAssist.bucket(from:flags:)` (`PuttingLab/Physics/MarioKartAssist.swift:46-58`) gives the bucketed display angle + cause string. Also not called from the viewmodel today.

In short: the impact result tells you "when and how cleanly", and gives you `faceAngleRaw` + `peakVelocity`. AR replay needs the whole stack — `MarioKartAssist.bucket → DistanceModel.compute` — to turn that into a Bezier in world-space.

---

## 3. Phase state machine (Build 14, exact)

`PracticeSessionViewModel.Phase` enum (`PuttingLab/UI/PracticeSessionViewModel.swift:24-34`).

### 3.1 Phases as built

| Phase | Defined at | View it renders | Persistent state |
|---|---|---|---|
| `.instructions` | line 26 | `InstructionsPhaseView` (`PuttingLab/UI/PracticeSessionView.swift:76-77, 152-234`) | reads `session.currentBatch.instructions` |
| `.ready` | line 28 | `ReadyPhaseView` (`PracticeSessionView.swift:78-79, 238-299`) | nothing — waiting for `DragGesture` |
| `.recording` | line 29 | `RecordingPhaseView` (`PracticeSessionView.swift:80-81, 354-379`) — red background | `samplesDuringRecording`, `posesDuringRecording`, `recordingLock`, `recordingArkitBaseline`, `liveImpactDetector` state |
| `.showing` | line 30 | `ResultPhaseView` (`PracticeSessionView.swift:82-86, 381-528`) | `lastImpactResult`, `pendingWindow`, `pendingResult`, `pendingImpactJudgment` |
| `.batchTransition` | line 31 | `BatchTransitionView` (`PracticeSessionView.swift:87-88, 530-576`) | `justCompletedBatch` |
| `.breakPoint` | line 32 | `BreakView` (`PracticeSessionView.swift:89-90, 578-626`) | none |
| `.sessionComplete` | line 33 | `CompleteView` (`PracticeSessionView.swift:91-97, 628-706`) | `replaySaveFailureCount` |

### 3.2 Transition diagram (every edge)

```
                           cold-launch / mid-session resume
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │   .instructions       │◀──┐
                         └──────────────────────┘   │
                                    │               │
                  tapReadyForStrokes │  ▲  tapBack  │  tapReadyAfterBreak
                                    ▼  │           │  tapContinueFromBatchTransition
                         ┌──────────────────────┐  │
              ┌─────────▶│      .ready          │  │
              │          └──────────────────────┘  │
              │                     │              │
              │ touchUp (sample      touchDown      │
              │  count too low /     (DragGesture) │
              │  ImpactDetector      ▼              │
              │  throws / mid-stroke┌──────────────────────┐
              │  background)        │   .recording         │
              │                     └──────────────────────┘
              │                                │
              │      touchUp                  │
              │      (success)                │
              │      ▼                         │
              │  ┌──────────────────────┐     │
              │  │     .showing          │    │
              │  └──────────────────────┘     │
              │                │              │
              │             tapDone           │
              │                │              │
              │   recordStroke + save         │
              │                │              │
              │   batchComplete?              │
              │   ├─no──────────► back to .ready (no re-read)
              │   ├─yes → next is break ────► .breakPoint ─┐
              │   ├─yes → final batch done ─► .sessionComplete (terminal until restartSession)
              │   └─yes → otherwise ───────► .batchTransition
              │                                              │
              └──────────────────────────────────────────────┘
                       restartSession() from any phase → .instructions
                       stopSession() while .recording → .ready (buffers discarded)
```

### 3.3 Trigger summary

- `.instructions → .ready`: `tapReadyForStrokes()` (`PracticeSessionViewModel.swift:248-252`). Guard: `phase == .instructions`.
- `.ready → .instructions`: `tapBackToInstructions()` (line 256-259). Guard: `phase == .ready`.
- `.ready → .recording`: `touchDown()` (line 263-287). Snapshots `recordingLock` (compass yaw + gravity + timestamp), `recordingArkitBaseline` (from `arkit.attitudeYaw()`), seeds `samplesDuringRecording` with the most recent sample, seeds `posesDuringRecording` from `arkit.latestPose`, resets `liveImpactDetector`, fires `.medium` haptic. Guard: `phase == .ready` AND `latestSample != nil`.
- `.recording → .showing`: `touchUp()` succeeds (line 292-337). Builds a `StrokeWindow` from buffers, calls `impactDetector.detect(in:arkitPoses:arkitBaselineYaw:)`, on success holds `pendingWindow/pendingResult`, fires `.light` haptic. Buffers ALWAYS cleared via `defer` (line 302-305).
- `.recording → .ready`: `touchUp()` rejects (line 306-310 too few samples; line 333-336 detector throws). Sets `lastError`.
- `.showing → .ready` (mid-batch) | `→ .batchTransition` | `→ .breakPoint` | `→ .sessionComplete`: `tapDone()` (line 351-413). The detached `Task` saves the replay JSON (`PracticeSessionViewModel.swift:376-384`); failures bump `replaySaveFailureCount`. Calibration baseline accumulates here too (line 363-365).
- `.batchTransition → .instructions`: `tapContinueFromBatchTransition()` (line 416-421). New batch starts on instructions.
- `.breakPoint → .instructions`: `tapReadyAfterBreak()` (line 424-430). Advances batch, then shows instructions for Block 2.
- `.sessionComplete`: terminal until `restartSession()` (line 433-440) wipes everything back to `.instructions`.
- **Scene-phase side effects** (`PracticeSessionView.swift:42-58`): `.active` → `startSession()` + `isPressing = false`; `.background` → `stopSession()` (which inside the viewmodel will hard-rescue mid-`.recording` strokes back to `.ready` with an error message, `PracticeSessionViewModel.swift:193-202`).

---

## 4. Integration points for AR replay

### 4.1 Recommended new phases

Slot **between `.showing` and the existing post-result transitions**. Three additions, all opt-in (we want the existing `.showing` path to remain the user's default flow because it works on TestFlight):

| New phase | When entered | Tear-down | Setup |
|---|---|---|---|
| `.arSetup` | User taps a new "Replay in AR" button on `ResultPhaseView` | — | First-run only: request `NSCameraUsageDescription`; show "Point your phone at the floor" prompt; ARTrackingManager remains running but `.run` with a NEW config that has `planeDetection = [.horizontal]` |
| `.arPlaceBall` | A horizontal plane has been detected | Visual ball-placement reticle attached to `ARRaycastQuery` | User taps to drop a ball anchor at a hit-tested point |
| `.arPlaceHole` | Ball anchor placed | Reticle stays for hole | User taps to drop a hole anchor |
| `.arReplay` | Hole anchor placed | All sub-views renderable | Compute `forwardAxisWorld` from saved `posesDuringRecording` + `pendingResult.attitudeAtImpact`; run `DistanceModel.compute` → ft → metres; tween a ball entity along a Bezier from ball anchor in the direction of `faceAngleRaw` for the computed distance |

Two options for slotting these in:

**Option A — additive after `.showing`** (recommended): user sees the existing result panel, taps an explicit "Replay in AR" button, then they're in `.arSetup → .arPlaceBall → .arPlaceHole → .arReplay → .showing` (return to the same result panel they were already on). Zero modification to the existing `.showing → tapDone → save + advance` path. The new "Replay in AR" button is the only addition to `ResultPhaseView`. **The save-to-StrokeReplay path stays exactly as it is** (`PracticeSessionViewModel.swift:351-385`) — the AR replay reads from `pendingResult` and `pendingWindow` but doesn't write.

**Option B — replace `.showing` entirely**: when AR is supported, skip the 2D result panel and go straight into AR. Strongly DO NOT recommend — `.showing` is the only place `pendingImpactJudgment` can be set (`PracticeSessionViewModel.swift:340-345`), which is the load-bearing B7 data-collection mechanism. Pre-empting it kills the calibration loop.

Either way, AR runs **as part of the post-impact panel**, not in place of it. The impact detection / face angle / distance computation are all done by the time `.showing` is entered — the AR layer is presentation only.

### 4.2 Where AR state lives

The AR layer needs its own coordinator object (`ARReplayCoordinator`?) holding ball anchor, hole anchor, plane anchors, and the `RealityKit` scene. Do NOT add these to `PracticeSessionViewModel` — that class is already 441 lines and the Build 14 guard rails (`startSession`'s double-start protection at line 132-187, the mid-recording `stopSession` rescue at line 192-202) are testable precisely because the surface is small. The coordinator should be a separate `@Observable` injected into a new `ARReplayView` that is presented as a `.fullScreenCover` from `ResultPhaseView`.

### 4.3 Data the coordinator needs from the existing pipeline

- `ImpactResult` (read from `viewModel.pendingResult` while it's non-nil during `.showing`).
- `StrokeWindow` (`viewModel.pendingWindow`) for `posesDuringRecording`-equivalent — but the poses live in a private field. **This is a real seam**: AR will need a read-only accessor `var pendingArkitPoses: [ARPose] { get }` exposed on the viewmodel, OR the poses must be embedded into a new wrapper struct that includes the impact result. The cleanest non-invasive option is to add a read-only computed property to `PracticeSessionViewModel` that returns the current `posesDuringRecording` while `phase == .showing`. Add nothing else.
- `DirectionResult` (compute on demand via `MarioKartAssist().bucket(from: impactResult)`).
- `DistanceResult` (compute on demand via `DistanceModel().compute(peakSpeedMps: impactResult.peakVelocity)`).

### 4.4 ARKit session compatibility

`ARTrackingManager.start()` throws `.alreadyRunning` (line 49-52) — you cannot re-run with `planeDetection = [.horizontal]` without first calling `stop()`. Two safe paths:

1. **Add a method** `setPlaneDetectionEnabled(_:)` on `ARTrackingManager` that internally calls `session.run(config, options: [])` (no reset) with the new config. ARKit supports config changes without a tracking reset — this is the right path because it preserves the world-space coordinates the impact analysis already used.
2. Stop + restart with new config — DON'T do this. Resetting tracking after impact would invalidate the world-space yaw the impact result was computed against.

Either way, the change is additive on `ARTrackingManager` and doesn't touch the existing `start()/stop()` callers.

---

## 5. Things to NOT touch

Per the hard constraints in the task brief, plus what the codebase tells us:

### 5.1 `PuttingLab/Physics/LiveImpactDetector.swift`

Build 13/14 tuning ladder is documented inline (file: `LiveImpactDetector.swift:38-60`). The 1.0 s `minFireDelayFromTouchDownSeconds` gate was set from B13's 80-stroke field data (backswing peaks 469–1023 ms, forward peaks 994–2317 ms; line 56-60). Any AR feature must NOT alter this — the haptic timing is what the user trusts. Read it; never modify it.

Fragility points to be aware of:
- `consume(_:)` is `@MainActor` (line 22). AR replay must NOT call `consume` from a frame-rate render loop.
- `lastFireTime` defence against non-finite timestamps (line 130-139) is load-bearing. Don't bypass.

### 5.2 `PuttingLab/UI/PracticeSessionViewModel.swift`

- The double-start guard in `startSession()` (line 132-187) is the fix for the silent-empty-stroke bug. AR replay must NOT call `startSession()` or `motion.start()` itself.
- The `defer` in `touchUp()` (line 302-305) is the only thing keeping the per-recording buffers from leaking on every error path. Any new code that reads `samplesDuringRecording` must do so BEFORE `touchUp()` runs.
- The detached save Task (line 376-384) intentionally returns nothing — failures only bump a counter. AR cannot block save; it has to be allowed to fail silently.
- `recordCalibrationFaceAngle` (line 363-365) only fires when `currentBatch.id == "cal"` AND `!result.snappedToSquare`. Don't change that ordering — calibration baseline is what `ResultPhaseView`'s "face (cal)" vs "face (raw)" toggle reads from (`PracticeSessionView.swift:406-419`).

### 5.3 `PuttingLab/UI/PracticeSessionView.swift`

- The `DragGesture(minimumDistance: 0)` (line 132-145) is the touch protocol — any `.fullScreenCover` AR view must consume gestures with `.simultaneousGesture` carefully, or the touch-down will fire `viewModel.touchDown()` on a `.ready` underneath if dismissal animations transiently expose it. Test the dismiss path with `isPressing` deliberately stale.
- The result panel's stroke counter `viewModel.session.totalStrokesCompleted + 1` (line 386) is read pre-`tapDone`. AR cannot call `recordStroke()` itself.

### 5.4 `PuttingLab/Models/TestSessionState.swift`

- The 100-stroke counter, persistence keys, and calibration accumulator all coexist in this file. The user is in the middle of the B7/B8 study (per the dated comments throughout `StrokeReplay.swift:24-33`). Adding new `UserDefaults` keys for AR is fine; adding new fields to `TestSessionState` is not — they will round-trip into the persistence layer and break mid-session resume.

### 5.5 `.github/`, `project.yml`, `Info.plist`

Off-limits per brief. Note: AR replay WILL eventually need `NSCameraUsageDescription` (already present implicitly via ARKit usage, but should be verified before any new build) and possibly `NSWorldSensingUsageDescription`. Surface this as a follow-up — don't change Info.plist now.

---

## 6. Risks

### 6.1 ARKit world-coordinate continuity

`ImpactResult.attitudeAtImpact` is in the IMU's reference frame (`xMagneticNorthZVertical`), NOT the ARKit world frame. Converting "face angle in radians" to "world-space launch direction" requires the ARKit pose at `ImpactResult.timestamp`. That pose IS available in `posesDuringRecording`, but only while the viewmodel holds `pendingWindow`. Once `tapDone` is called, `pendingWindow = nil` and the poses are gone (`PracticeSessionViewModel.swift:386-388`). **AR replay MUST run between `touchUp` and `tapDone` — there is no later opportunity unless you re-load the saved JSON via `StrokeReplayStore`, but `StrokeReplay` does NOT serialize the ARKit poses** (the schema at `PuttingLab/Models/StrokeReplay.swift:35-41` only has motion samples; ARKit poses are dropped at save time). This is a real gap. Workarounds:
- (a) AR replay only available from `.showing` (locks design to Option A above).
- (b) Extend `StrokeReplay` schema v2 with serialized ARKit poses. Cheap to add (`schemaVersion` already supports it, line 75), but bloats every saved file ~1.2x. Defer.

### 6.2 Concurrency

- `MotionSample.timestamp` and `ARFrame.timestamp` are both `CMTime`-derived `TimeInterval` in seconds — same domain. Safe to slerp between AR poses by impact time.
- `ARTrackingManager` uses `NSLock`, exposes `Sendable`-ish state, and runs frame updates on the ARSession queue. Reading `latestPose` from `@MainActor` is fine.
- The new `ARReplayCoordinator` will need its own actor isolation. Coordinating RealityKit's scene updates with `@MainActor` viewmodel state needs care — prefer making the coordinator `@MainActor` end-to-end.
- `liveImpactDetector.consume` is `@MainActor`. AR replay must NOT call it.

### 6.3 State persistence

`TestSessionState.save()` is called on every `recordStroke()` + `advanceBatch()` (`PracticeSessionViewModel.swift:391-407`). If AR replay introduces its own `UserDefaults` key, it MUST NOT share the prefix `TestSessionState_v1.` — that's a Build 14 contract and `loadIfAvailable` clamps against the persisted batch list (`TestSessionState.swift:128-144`). Use `ARReplay_v1.` as a fresh prefix.

### 6.4 Lifecycle

`stopSession()` mid-recording discards everything and bumps the user to `.ready` with an error (`PracticeSessionViewModel.swift:193-202`). If AR replay introduces a `.fullScreenCover` that backgrounds the underlying view, scene-phase logic at `PracticeSessionView.swift:42-58` will fire `stopSession()` on `.background`, killing any AR replay in flight. The coordinator must own the AR session lifecycle for the duration of the cover, OR (cleaner) the AR replay session reuses the existing `ARTrackingManager` and the scene-phase handler keeps working as-is.

### 6.5 Plane detection cost

Spec §1 decision #6 (`docs/spec-putting-lab-v1-FINAL.md:32`) explicitly says NO plane detection in v1. Enabling it under Option A is fine for AR replay, but the user has to consciously opt in (a tap). Don't enable plane detection during `.ready` or `.recording` — it will measurably increase CPU + thermal budget and the user reports in `CompleteView` ("let the phone cool", `PracticeSessionView.swift:599`) hint we're already thermally constrained in long sessions.

### 6.6 ARWorldTracking reset on interruption

`sessionInterruptionEnded` does a full reset-tracking (`ARTrackingManager.swift:118-127`). If a phone call interrupts an AR replay, the world coordinates after resume will not match what the impact was computed against. The AR coordinator should detect this case (the `trackingState` and `latestPose` go through `.notAvailable` + nil) and offer a "Try again" rather than rendering a misaligned replay.

---

## 7. One-line summary

**Build 14 is structurally ready to layer AR on top — `ARTrackingManager` already runs `ARWorldTrackingConfiguration` and `ImpactDetector` already accepts `ARPose` arrays — but `posesDuringRecording` are not serialized to `StrokeReplay`, so the AR replay MUST run during the `.showing` phase before `tapDone` discards them, and the new flow should be additive (Option A) so the load-bearing `pendingImpactJudgment` collection + calibration baseline accumulation in the existing `tapDone` path remains untouched.**

---

*Cited files (all read once for this audit, no edits made):*
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\CLAUDE.md`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\docs\spec-putting-lab-v1-FINAL.md`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Sensors\ARTrackingManager.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\UI\PracticeSessionViewModel.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\UI\PracticeSessionView.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Physics\ImpactDetector.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Physics\LiveImpactDetector.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Physics\DistanceModel.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Physics\MarioKartAssist.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Models\TestSessionState.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Models\TestBatch.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Models\MotionSample.swift`
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Models\StrokeReplay.swift`
