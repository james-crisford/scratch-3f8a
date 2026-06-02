# Brief — Build Days 2 → 5

Source of truth for the autonomous Days 2-5 sprint. Read this end-to-end before TodoWriting.

## State at session start

- Day 1 GREEN on CI (run 26611455633, commit a4923bf, 19/19 tests passing on macos-15).
- Files: `PuttingLab/Models/MotionSample.swift`, `PuttingLab/Models/StrokeBuffer.swift`, `PuttingLab/Sensors/MotionManager.swift`, `PuttingLab/Sensors/SensorClock.swift`, `PuttingLab/App/PuttingLabApp.swift`, `PuttingLab/UI/SensorDebugView.swift`, `PuttingLab/Info.plist`.
- Tests: `PuttingLabTests/Models/StrokeBufferTests.swift`, `PuttingLabTests/Sensors/MotionManagerTests.swift` (includes `MotionSampleTests` suite).
- CI: `.github/workflows/test.yml` runs on `macos-15`, picks highest installed Xcode 16.x via the auto-select shell snippet, uses destination `platform=iOS Simulator,OS=18.5,name=iPhone 16`.
- GitHub CLI auth: `$env:GH_TOKEN = "<GITHUB-TOKEN-REMOVED-2026-06-02 see tokens/scrubbed-secrets-2026-06-02.md — ROTATE>"` already in Git Credential Manager; reuse it for polling.

## Operating loop, per day

1. TodoWrite the day's tasks. Mark complete as you go.
2. Read the relevant skill before touching a file: `ios-coremotion-arkit-sensors` for sensor work, `golf-swing-game-design` for physics/results, `swift-modern-architecture` + `ios-dev-guidelines` for code style, `swift-development` for build/test commands.
3. **Write the test first** (TDD). Then the implementation. Then run the test mentally against the spec.
4. Commit. Push. Then in PowerShell:
   ```
   $env:Path = "C:\Program Files\GitHub CLI;$env:Path"
   $env:GH_TOKEN = "<GITHUB-TOKEN-REMOVED-2026-06-02 see tokens/scrubbed-secrets-2026-06-02.md — ROTATE>"
   Set-Location "c:\Users\james\Desktop\Claude Agent\projects\PuttingLab"
   Start-Sleep -Seconds 240
   gh run list --limit 1
   ```
5. If failed: `gh run view <id> --log-failed | Select-Object -Last 60`. Diagnose, fix, re-push. Max 3 attempts per day; on 3rd failure stop and ask James.
6. End of day: append a summary block to `docs/day-handoffs.md` (create if missing) with: (a) what was built, (b) test count green, (c) iPhone-13 device checklist additions, (d) next day scope.

## Day 2 — ARKit foundation

Per spec §10 Day 2.

**Files to create:**
- `PuttingLab/Sensors/ARTrackingManager.swift`: wraps `ARWorldTrackingConfiguration`. Configure with `planeDetection = []`, `frameSemantics = []` (no body tracking). Low-power profile. Expose:
  - `var isRunning: Bool`
  - `var trackingState: ARCamera.TrackingState?`
  - `var latestTransform: simd_float4x4?`
  - `func start() throws`
  - `func stop()`
  - `func attitudeYaw() -> Double?` — extracts yaw from current camera transform via Euler angles (atan2 of relevant rotation matrix elements)
- Protocol `ARTracking` (Sendable) so we can fake it in tests.
- A `FakeARTrackingManager` test double in `PuttingLabTests/Sensors/Fakes/FakeARTrackingManager.swift` for unit tests (no real ARSession on CI).

**Tests in `PuttingLabTests/Sensors/ARTrackingManagerTests.swift`:**
- starts in stopped state
- start sets isRunning true
- stop is idempotent
- yaw extracted from a known transform matches expected radians
- yaw nil when no transform yet
- trackingState passes through when fake reports limited/normal

**Wire into `SensorDebugView`:** show a third "arkit yaw" row alongside compass yaw. Both should match within ~0.05 rad on a still device (real-device test).

**Out of scope today:** plane detection, mesh, body tracking, ARKit drift correction logic (we use yaw raw for now; the fusion happens at impact in Day 5).

## Day 3 — Stillness detector (auto-address)

Per spec §3 phase 2 + §4. Detect address pose: 800ms continuous with `|rotationRate| < 5°/s` AND `|userAcceleration| < 0.2 m/s²` AND `dot(gravity, [0,-1,0]) > 0.96`.

**Files:**
- `PuttingLab/Sensors/StillnessDetector.swift`: stateful detector that consumes `MotionSample` and emits a `StillnessLock` event when the 800ms window is satisfied.
  - `func consume(_ sample: MotionSample) -> StillnessLock?`
  - `StillnessLock` struct: `yawTargetCompass`, `gravity`, `lockedAt`
  - Reset on any sample that violates the conditions.
- `PuttingLab/Models/StillnessLock.swift`
- Wire haptic feedback in `SensorDebugView` (already calls .medium feedback generator — confirm).

**Tests:**
- locks after 800ms of stillness (use synthetic stream)
- does NOT lock at 799ms
- resets when rotationRate spikes mid-window
- resets when phone tilts past 15° from vertical
- preserves yaw at moment of lock
- handles repeated lock attempts cleanly

**Add to SensorDebugView:** show "Aimed ✓" when lock fires + haptic tick.

## Day 4 — Stroke detector

Per spec §3 phase 4. Start when `|rotationRate| > 30°/s` sustained ≥50ms. End via stillness <30°/s for 300ms continuous OR 2s hard cutoff from start.

**Files:**
- `PuttingLab/Sensors/StrokeDetector.swift`: state machine `armed → starting → recording → ended`. Inputs `MotionSample` stream + a `StillnessLock` (must be locked to arm). Emits a `StrokeWindow` (start + end timestamps + collected samples).
- `PuttingLab/Models/StrokeWindow.swift`

**Tests:**
- detects start with sustained rotation above threshold
- rejects start when rotation is a flick (<50ms)
- ends via return-to-stillness
- ends via 2s hard cutoff
- captures all samples in the window
- requires prior StillnessLock to arm

**Wire into SensorDebugView:** show stroke segmentation on the screen (badge changes from "Aimed" → "STROKE" → "DONE").

## Day 5 — Impact detection (the big one)

Per spec §2.3 + §5. This is the headline feature. Read `ios-coremotion-arkit-sensors` skill carefully before starting.

**Files:**
- `PuttingLab/Physics/ImpactDetector.swift`: the full algorithm. PCA on userAcceleration to find principal forward axis → integrate velocity → drift-correct (assume end velocity = 0) → 5-point moving average smooth → find peak index → parabolic interpolation for sub-sample `impact_time` → slerp attitude at impact → yaw delta from `yawTargetCompass` = `faceAngleRaw`.
- `PuttingLab/Models/ImpactResult.swift`: timestamp, peakVelocity, faceAngleRaw, attitudeAtImpact, confidence.
- `PuttingLabTests/Fixtures/clean_straight_8ft.json`: first synthetic fixture. Generate it via a small helper that produces ~1.2s of 100Hz IMU samples representing a clean square putting stroke. Document the generator in `PuttingLabTests/Fixtures/Generator.swift` so future fixtures (pull, push, flick) can be added by parameter.

**Tests (`PuttingLabTests/Physics/ImpactDetectorTests.swift`):**
- clean_straight fixture: face_angle within ±2° of 0
- clean_straight fixture: impact time within 5ms of fixture-declared truth
- throws on stroke <200ms (synthetic flick)
- throws on no clear peak (constant velocity synthetic)
- sub-sample interpolation: synthetic peak at i+0.3 returns offset ≈0.3
- confidence < 0.5 when ARKit-lost flag set in fixture metadata

**Update SensorDebugView:** show the computed face_angle + peak_velocity + confidence after each stroke. No buckets yet (that's Day 8).

## Stop conditions

- Any spec deviation needed (stop, ask James).
- CI fails 3× in a row on same day (stop, paste the last failure log, ask).
- All 4 days done, all CI green = goal met. Update `project_puttinglab_build` memory with progress.

## Rules

- Use the 5 skills exclusively. Don't re-derive what's in `ios-coremotion-arkit-sensors`.
- TDD: test first, implementation second.
- Never edit `docs/spec-putting-lab-v1-FINAL.md`. Spec is the contract.
- Never edit other research reports.
- No comments in code unless explicitly needed.
- No hardcoded user-facing strings — wrap in `Strings` enum local to the file.
- Swift 6 strict concurrency. `@Observable`, NOT `ObservableObject`. `@MainActor` on UI types.
- After each successful day push: update `docs/day-handoffs.md`.
