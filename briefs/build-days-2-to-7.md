# Brief — Build Days 2 → 7 + stretch Days 8 → 10 (OVERNIGHT, James asleep, ~8h budget)

Source of truth for the autonomous Days 2-7 overnight sprint. Read this end-to-end before TodoWriting.

## State at session start (durable, post-compaction-safe)

- **Day 1 GREEN on CI** (run 26611455633, commit `a4923bf`, 19/19 tests passing on macos-15).
- Repo: `https://github.com/james-crisford/PuttingLab` (private)
- Files shipped Day 1:
  - `PuttingLab/Models/MotionSample.swift`
  - `PuttingLab/Models/StrokeBuffer.swift`
  - `PuttingLab/Sensors/MotionManager.swift`
  - `PuttingLab/Sensors/SensorClock.swift`
  - `PuttingLab/App/PuttingLabApp.swift`
  - `PuttingLab/UI/SensorDebugView.swift`
  - `PuttingLab/Info.plist`
  - `PuttingLabTests/Models/StrokeBufferTests.swift` (7 tests)
  - `PuttingLabTests/Sensors/MotionManagerTests.swift` (8 tests + 4 MotionSample tests)
- **CI workflow at `.github/workflows/test.yml`:**
  - Runs on `macos-15`
  - Auto-picks highest installed Xcode 16.x (Xcode 16.0 SDK isn't installed)
  - Destination: `platform=iOS Simulator,OS=18.5,name=iPhone 16`
  - Generates project via xcodegen from `project.yml`
- **Git remote credentials wired** via Git Credential Manager. `git push` works silently.
- **GitHub CLI token** is stored in your Git Credential Manager (use `git credential fill` to retrieve if needed for `gh` commands).
- **Spec is locked** at `docs/spec-putting-lab-v1-FINAL.md`. Do not edit.

## "James asleep" protocol (CRITICAL)

James is asleep. You CANNOT ask him questions. Defer ALL device-verification to morning — instead, **append** to `docs/day-handoffs.md` at the end of every day:

```markdown
## Day N — <date>

### What was built
- file list with one-line descriptions

### Tests passing
- N tests green on CI run <run-id>, commit <sha>

### iPhone 13 device checklist (verify in morning)
- [ ] item 1
- [ ] item 2
- ...

### Next day scope
- one paragraph
```

James reads `docs/day-handoffs.md` in the morning and runs through every checklist on his iPhone in one batch.

## Hard stop conditions (do NOT push through these without James)

- **Spec ambiguity or contradiction** found. Document in `docs/day-handoffs.md` under a "🛑 PAUSED — needs James" section and stop.
- **CI fails 3 times in a row on same day** despite reasonable fix attempts. Stop, write the last failure log into `docs/day-handoffs.md`, stop.
- **A locked decision** in CLAUDE.md or spec §1 would need to be deviated from. Stop.
- **You finish Day 7.** Stop. Don't proceed to Day 8 (UI shell needs James's aesthetic eye).
- **Weekly token limit approaching.** Stop gracefully — finish the current Day's commit + handoff, don't start a new Day with <50% budget remaining.

## Testing — exhaustive coverage required

James asleep = no manual safety net. Tests are the safety net. **Every module gets ALL of these test categories.** Minimum test count per module = **15**, not the 6-8 in the day sections.

### Required test categories (per module)

1. **Happy path** — clean expected input → expected output (3+ variants).
2. **Boundary** — exactly at every threshold (5°/s, 6°, 12°, 200ms, 30°/s, 800ms, 50ms, 300ms, 2s). Test both `=` and `<` and `>` of every number that appears in the spec.
3. **Off-by-one** — one sample before / after every threshold.
4. **Empty / nil / zero** — empty stream, nil sample, zero-magnitude vectors, NaN, infinity.
5. **Numerical edge** — very small (1e-10), very large (1e10), negative where positive is expected, NaN propagation must throw or return nil — never poison downstream.
6. **State transition** — every legal transition. Every illegal transition must be rejected gracefully.
7. **Concurrency** — `@MainActor` actors must not deadlock; sensors must not crash when stopped from a different task than started.
8. **Re-entrancy** — start → stop → start → stop, repeated 100×.
9. **Determinism** — given the same input stream, output must be byte-identical across runs. Hash the output, assert.
10. **Adversarial synthetic strokes** — at least 5 per detector: clean, slow, fast, jerky, mid-stroke-grip-change, noisy.
11. **Performance** — `XCTClockMetric` or timestamp before/after: every per-sample function must complete in <100µs on a synthesized 1000-sample stroke. Assert.
12. **Memory** — no retain cycles. Use `weak`/`unowned` correctly. Add a test that allocates the detector in a scope, runs 1000 samples, scope ends, then asserts a sentinel object inside the detector has been deallocated.
13. **Fixture-driven regression** — every fixture in `PuttingLabTests/Fixtures/*.json` is replayed through ALL applicable detectors. Each fixture has a JSON sidecar `<fixture>.expected.json` with the expected output for every detector. Any drift between detector output and expected = test failure.
14. **Cross-module integration** — combinations: stillness → stroke, stroke → impact, full ARM→ROLL pipeline with synthetic stream.
15. **Documentation tests** — every public function has a `///` doc comment, every doc comment that shows example code is wrapped in a test that runs that example. Use Swift Testing parameterized `@Test(arguments:)` where natural.

### Fixture library — expand BEYOND Day 5

Day 5 introduces fixtures. Days 6-7 expand them. By end of Day 7 `PuttingLabTests/Fixtures/` must contain at least:

- `clean_straight_3ft.json`
- `clean_straight_8ft.json`
- `clean_straight_20ft.json`
- `clean_straight_30ft.json`
- `pull_5deg.json` (right at threshold)
- `pull_6deg.json` (just over Square→SlightPull boundary)
- `pull_11deg.json` (right at SlightPull→Pull boundary)
- `pull_12deg.json` (just over Pull boundary)
- `pull_19deg.json`
- `pull_20deg.json` (right at Pull→Miss boundary)
- `pull_25deg.json` (clear Miss)
- `push_5deg.json` through `push_25deg.json` (mirror set)
- `flick_short_150ms.json` (rejected — too fast)
- `flick_short_199ms.json` (rejected — just under threshold)
- `flick_short_200ms.json` (just over — accepted)
- `no_peak_constant.json` (rejected — no impact moment)
- `no_peak_zigzag.json` (rejected — multiple peaks at same magnitude)
- `arkit_lost_midswing.json` (compass-yaw fallback path)
- `arkit_lost_atIimpact.json` (rejected by confidence)
- `walking_baseline_noise.json` (does NOT trigger stroke detector)
- `phone_picked_up_no_stroke.json` (does NOT trigger stroke detector)
- `back_to_back_strokes.json` (segmented cleanly into 2 strokes)
- `calibration_run_5strokes.json` (full onboarding fixture, all 5 strokes inside)
- `slow_stroke_1500ms.json`
- `fast_stroke_400ms.json`

Each fixture has a sidecar `<name>.expected.json` with the canonical expected output for every detector. Generator code in `PuttingLabTests/Fixtures/Generator.swift` parameterises everything so adding a fixture = one line.

### Simulation tests (multi-stroke session)

By end of Day 7, ship `PuttingLabTests/Integration/SimulationTests.swift`:

- **50-stroke session**: feed 50 mixed fixtures through SessionCoordinator. Assert: no crashes, no leaks, no state-machine wedges, every stroke produces an ImpactResult (or rejected with valid reason). Timing of full session <2 seconds on CI.
- **1000-stroke fuzz**: programmatically perturb the clean fixture (add noise, vary speed, vary face angle). Run 1000 through the pipeline. Assert: zero crashes, every fail path explainable (logged), >95% produce an ImpactResult.
- **Pathological inputs**: zero-length stream, single-sample stream, billion-sample stream truncated to buffer cap, samples-with-NaN. All handled gracefully.
- **Sensor-permission-denied** simulation: `MotionManagerError.deviceMotionUnavailable` propagates correctly all the way through the coordinator.

### CI assertions

CI workflow gets new assertions:
- Total test count must INCREASE (or stay equal) every commit. Add to workflow: count tests, write to `.ci-test-count`, fail if previous count > current. (Defends against accidentally removing tests during refactor.)
- Test runtime must stay <30 seconds total. (Defends against accidentally introducing slow tests.)
- Code coverage of `Sensors/` and `Physics/` must be ≥90%. Use `xcodebuild test -enableCodeCoverage YES` (already enabled) + a parsing step.

## Operating loop, per day

1. TodoWrite the day's tasks. Mark complete as you go.
2. Read the relevant skill *before* touching a file:
   - `ios-coremotion-arkit-sensors` for Sensors/ + Physics/
   - `golf-swing-game-design` for Physics/ + result display
   - `swift-modern-architecture` for code style
   - `ios-dev-guidelines` for project conventions
   - `swift-development` for build/test commands
3. **Write the test first** (TDD). Then implementation.
4. Commit. Push. Then poll CI in PowerShell:
   ```powershell
   $env:Path = "C:\Program Files\GitHub CLI;$env:Path"
   $env:GH_TOKEN = "<get from git credential fill>"
   Set-Location "c:\Users\james\Desktop\Claude Agent\projects\PuttingLab"
   Start-Sleep -Seconds 240
   & gh run list --limit 1
   ```
5. If failed: `& gh run view <id> --log-failed 2>&1 | Select-Object -Last 60`. Diagnose, fix, re-push. Max 3 fix attempts per day.
6. End of day: append to `docs/day-handoffs.md` per the template above.

## Day 2 — ARKit foundation

Per spec §10 Day 2.

**Files:**
- `PuttingLab/Sensors/ARTrackingManager.swift`:
  - Wraps `ARWorldTrackingConfiguration` with `planeDetection = []`, `frameSemantics = []`
  - Low-power profile
  - `var isRunning: Bool`, `var trackingState: ARCamera.TrackingState?`, `var latestTransform: simd_float4x4?`
  - `func start() throws`, `func stop()`
  - `func attitudeYaw() -> Double?` — extracts yaw via Euler from camera transform
- Protocol `ARTracking: AnyObject, Sendable` so we can fake it in tests
- `PuttingLabTests/Sensors/Fakes/FakeARTrackingManager.swift` — pure-Swift fake, no `ARSession`

**Tests in `PuttingLabTests/Sensors/ARTrackingManagerTests.swift`:**
- starts in stopped state
- start sets isRunning true (via fake)
- stop is idempotent
- yaw extracted from known transform matches expected radians (math test, no AR)
- yaw nil when no transform yet
- trackingState passes through fake states

**Wire into `SensorDebugView`:** show third "arkit yaw" row alongside compass yaw.

**Out of scope today:** plane detection, mesh, body tracking, drift correction logic (saved for Day 6).

## Day 3 — Stillness detector

Per spec §3 phase 2 + §4. Detect address pose:
```
for 800ms continuous:
  |rotationRate| < 5°/s
  AND |userAcceleration| < 0.2 m/s²
  AND dot(gravity, [0,-1,0]) > 0.96  (phone within ±15° of vertical)
```

**Files:**
- `PuttingLab/Sensors/StillnessDetector.swift`: stateful detector. Consumes `MotionSample`, emits `StillnessLock?` when 800ms window satisfied. Resets on any violating sample.
- `PuttingLab/Models/StillnessLock.swift`: `{ yawTargetCompass: Double, gravity: SIMD3<Double>, lockedAt: TimeInterval }`

**Tests:**
- locks after 800ms of synthetic still stream
- does NOT lock at 799ms
- resets when rotationRate spikes mid-window
- resets when phone tilts past 15° from vertical
- preserves exact yaw at moment of lock
- handles back-to-back lock cycles cleanly

**Update SensorDebugView:** show "Aimed ✓" + fire `UIImpactFeedbackGenerator(style: .medium)` haptic when lock fires.

## Day 4 — Stroke detector

Per spec §3 phase 4.
- Start when `|rotationRate| > 30°/s` sustained ≥50ms
- End via `|rotationRate| < 30°/s` for 300ms continuous OR 2s hard cutoff from start
- Debounce flicks <50ms

**Files:**
- `PuttingLab/Sensors/StrokeDetector.swift`: state machine `armed → starting → recording → ended`. Requires prior `StillnessLock` to arm.
- `PuttingLab/Models/StrokeWindow.swift`: `{ start: TimeInterval, end: TimeInterval, samples: [MotionSample], lock: StillnessLock }`

**Tests:**
- detects start with sustained rotation above threshold
- rejects flick (<50ms above threshold)
- ends via return-to-stillness
- ends via 2s hard cutoff
- captures all samples in window
- refuses to arm without prior StillnessLock

**Wire into SensorDebugView:** badge changes ARMED → STROKE → DONE.

## Day 5 — Impact detection (HARD)

Per spec §2.3 + §5. The headline algorithm. Read `ios-coremotion-arkit-sensors` skill carefully first.

**Algorithm:**
1. PCA on `userAcceleration` to find principal forward axis
2. Integrate velocity along it
3. Drift-correct (assume end velocity = 0, linearly subtract drift)
4. Smooth with 5-point moving average
5. Find peak index
6. Parabolic interpolation for sub-sample `impact_time`
7. Slerp attitude at impact (between surrounding samples)
8. Compute yaw delta from `yawTargetCompass` → `faceAngleRaw`
9. Confidence score: low if no clear peak, stroke <200ms, peak velocity <0.3 m/s, or ARKit lost flag set

**Files:**
- `PuttingLab/Physics/ImpactDetector.swift`
- `PuttingLab/Models/ImpactResult.swift`: `{ timestamp, peakVelocity, faceAngleRaw, attitudeAtImpact, confidence }`
- `PuttingLabTests/Fixtures/clean_straight_8ft.json` (first fixture)
- `PuttingLabTests/Fixtures/Generator.swift` — helper that produces parameterised synthetic strokes (so future fixtures `pull_10deg`, `push_15deg`, `flick_short_150ms`, `no_peak_constant` are 1-line additions)

**Tests in `PuttingLabTests/Physics/ImpactDetectorTests.swift`:**
- clean_straight fixture: face_angle within ±2° of 0
- clean_straight fixture: impact_time within 5ms of fixture-declared truth
- throws on stroke <200ms (synthetic flick)
- throws on no clear peak (constant-velocity synthetic)
- sub-sample interpolation: synthetic peak at i+0.3 returns offset ≈0.3
- confidence < 0.5 when ARKit-lost flag set

## Day 6 — Face angle computation (refinement + ARKit drift correction)

Per spec §2.4 + §2.5. Day 5 used compass yaw only. Day 6 layers in ARKit yaw with fallback.

**Files:**
- `PuttingLab/Physics/FaceAngleComputer.swift`:
  - Inputs: `StrokeWindow` + `StillnessLock` + ARKit pose stream
  - Decides: if ARKit `trackingState == .normal` throughout, use ARKit yaw; else fall back to compass yaw
  - Returns: `faceAngleRaw` signed, in degrees
- Update `ImpactDetector` to delegate face-angle computation to `FaceAngleComputer`

**Tests:**
- zero on straight (synthetic stroke with no yaw rotation)
- signed correctly: negative = closed/pull (righty)
- ARKit lost mid-stroke → falls back to compass
- ARKit clean throughout → uses ARKit
- both sources agree within 2° on synthetic stroke

## Day 7 — End-to-end console glue (no UI yet)

Per spec §10 Day 7. Wire everything from sensor → impact result, output to console for the first time end-to-end.

**Files:**
- `PuttingLab/SessionCoordinator.swift`: composes MotionManager + ARTrackingManager + StillnessDetector + StrokeDetector + ImpactDetector + FaceAngleComputer. Phase state machine (ARM → ADDRESS → READY → STROKE → IMPACT → ROLL). `@MainActor` and `@Observable`.
- `PuttingLab/Models/PhaseState.swift`: enum cases for the phase machine
- Update `SensorDebugView` to use SessionCoordinator and print every stroke's result to console
- New test `PuttingLabTests/Integration/SessionCoordinatorTests.swift`:
  - feeds fixture stream → expects ImpactResult on output
  - phase transitions correct (ARM → ADDRESS only after stillness, ADDRESS → READY immediate, READY → STROKE on rotation threshold, STROKE → IMPACT on stroke end, IMPACT → ROLL after compute, ROLL → ARM after 3s)
  - re-arms after stroke ends
  - illegal transitions rejected silently (no crash)
  - re-address resets cleanly mid-READY
  - 15-second READY timeout returns to ARM

## STRETCH GOAL — Day 8 — Distance model + Mario Kart assist (NO UI)

Only if Days 2-7 finish with green CI AND >2 hours of budget remain. Pure logic, no UI decisions — safe for overnight.

Per spec §2.6 + §5.

**Files:**
- `PuttingLab/Physics/DistanceModel.swift`: per spec §2.6
  - `ball_speed_fps = peak_speed_mps * user_speed_calibration_factor * 3.281`
  - `ball_roll_distance_ft = pow(ball_speed_fps, 1.6) / friction_constant` (friction_constant = 1.7)
  - Returns `(distance, lowBand, highBand)` with ±15% band
  - Small random jitter ±5% for game feel
- `PuttingLab/Physics/MarioKartAssist.swift`: per spec §5
  - Bucket mapping: `|raw|<6° → Square`, `6-12 → SlightPullPush`, `12-20 → PullPush`, `≥20 → Miss`
  - Confidence-low override → forces Square (4 conditions: ARKit lost >50%, stroke <200ms, no clear peak, peak speed <0.3 m/s)
  - Returns `(label: String, displayDegrees: Double, cause: String)`
- Wire both into `SessionCoordinator` — result now includes distance + bucketed direction

**Tests (each module ≥15 tests per the testing section above):**
- Every boundary tested explicitly (5, 6, 11, 12, 19, 20 degrees, signed)
- Monotonicity: faster peak speed → longer distance, always
- Calibration constant: 2× constant → ~2× distance
- Confidence-low → snap to Square
- Each "surface the cause" sentence is generated correctly for each bucket
- Distance band: low < displayed < high, always

## STRETCH GOAL — Day 9 — Calibration onboarding (NO UI)

Only if Day 8 finished with green CI AND >1 hour budget remains.

Per spec §6.

**Files:**
- `PuttingLab/Calibration/CalibrationCoordinator.swift`: stateful 5-stroke onboarding flow
  - Accepts target distance per stroke (8 ft default)
  - Captures 5 valid strokes (rejects flicks, ARKit-lost-at-impact strokes)
  - Batch-computes at end: mean tempo, speed→distance factor, face-angle bias, swing-plane axis, ARKit baseline stability
- `PuttingLab/Models/CalibrationProfile.swift`: `Codable`, exactly per spec §6.2 spec table
- `PuttingLab/Storage/ProfileStore.swift`: `UserDefaults` wrapper, round-trip-safe
- `PuttingLab/Calibration/CalibrationModel.swift`: pure functions for the batch-compute math

**Tests:**
- 5-stroke fixture run produces expected mean tempo (within 1ms of fixture truth)
- Speed→distance factor inferred matches fixture truth ±5%
- Face-angle bias detected when synthetic strokes systematically pull
- Profile round-trips through UserDefaults byte-identical
- 4-stroke run (incomplete) → not yet calibrated, no profile written
- 5-stroke run with 2 invalid → re-requests until 5 valid
- Profile applied to future strokes: face-angle bias subtracted correctly

## STRETCH GOAL — Day 10 — Persistence + leaderboards data layer (NO UI)

Only if Day 9 finished green AND >30 min budget remains.

**Files:**
- `PuttingLab/Storage/StrokeHistoryStore.swift`: append-only log of recent strokes in UserDefaults (cap at 50, FIFO)
- `PuttingLab/Models/StrokeRecord.swift`: `Codable` snapshot of a `StrokeResult` for history
- `PuttingLab/Storage/StatsAggregator.swift`: pure functions to compute longest drive, closest pin, best tempo, current streak (from StrokeHistoryStore)

**Tests:**
- History stores 50 strokes, 51st evicts oldest
- Round-trip through UserDefaults
- Stats aggregator returns correct longest/closest/tempo across 50 fixtures
- Streak: 3 strokes in same day → streak=3; gap of 1 day → streak resets

**STOP HERE.** Day 11+ (UI shell, result panel, roll animation, polish, TestFlight) is DEFINITELY out of scope. UI needs James's eye.

## Reference algorithms (do NOT re-derive — implement exactly as specified)

### PCA on 3D acceleration samples (Day 5 ImpactDetector)

```swift
func principalAxis(of accelerations: [SIMD3<Double>]) -> SIMD3<Double> {
    var mean = SIMD3<Double>.zero
    for a in accelerations { mean += a }
    mean /= Double(accelerations.count)

    var cov = [[Double]](repeating: [0,0,0], count: 3)
    for a in accelerations {
        let d = a - mean
        for i in 0..<3 {
            for j in 0..<3 {
                cov[i][j] += d[i] * d[j]
            }
        }
    }

    var v = SIMD3<Double>(1, 0, 0)
    for _ in 0..<10 {
        let next = SIMD3<Double>(
            cov[0][0]*v.x + cov[0][1]*v.y + cov[0][2]*v.z,
            cov[1][0]*v.x + cov[1][1]*v.y + cov[1][2]*v.z,
            cov[2][0]*v.x + cov[2][1]*v.y + cov[2][2]*v.z
        )
        v = simd_normalize(next)
    }
    return v
}
```

### Parabolic sub-sample peak interpolation

```swift
func parabolicPeak(prev: Double, peak: Double, next: Double) -> Double {
    let denom = prev - 2.0 * peak + next
    guard denom != 0 else { return 0 }
    return 0.5 * (prev - next) / denom
}
```

### Quaternion slerp at sub-sample time

Use `simd_slerp` from the `simd` module. No custom math needed.

### 5-point moving average smoothing

```swift
func movingAverage(_ values: [Double], window: Int) -> [Double] {
    guard window > 0, values.count >= window else { return values }
    let half = window / 2
    var result = values
    for i in half..<(values.count - half) {
        var sum = 0.0
        for j in (i - half)...(i + half) { sum += values[j] }
        result[i] = sum / Double(window)
    }
    return result
}
```

### Velocity integration with linear drift correction

```swift
func integrateAndDriftCorrect(accelerations: [Double], dt: Double) -> [Double] {
    var velocity = [Double](repeating: 0, count: accelerations.count)
    for i in 1..<accelerations.count {
        velocity[i] = velocity[i-1] + accelerations[i] * dt
    }
    let endDrift = velocity.last ?? 0
    let n = velocity.count
    for i in 0..<n {
        velocity[i] -= endDrift * Double(i) / Double(n - 1)
    }
    return velocity
}
```

## Concurrency patterns (do NOT deviate)

- Sensor managers use a dedicated `OperationQueue` (see `MotionManager.swift` Day 1 — copy the pattern)
- Detectors are NOT `@MainActor` — they are plain `final class` with internal `NSLock` for state
- `SessionCoordinator` IS `@MainActor` and `@Observable`
- Tests can use `@Sendable` closures freely
- NEVER use `DispatchQueue.main.async` — use `MainActor.run` or `@MainActor` annotation
- NEVER use `Combine` — use `AsyncSequence` or direct callbacks

## Quality bars

- Build: clean, zero warnings, zero `// TODO` comments left for self.
- Code coverage: ≥90% on `Sensors/` and `Physics/` (enforced by CI).
- Cyclomatic complexity: no function over 15 (use SwiftLint if added).
- File length: no `.swift` file over 400 lines. Split if needed.
- Function length: no function over 50 lines. Refactor if needed.
- No `print()` calls outside `SensorDebugView` (use `os.Logger` if logging needed).

## Final handoff at end of run

When stopping (success or hard stop), write `docs/day-handoffs.md` final section:

```markdown
## 🏁 Overnight sprint complete

- Days completed: N of 7
- Total tests: M passing
- Total commits: K
- Final CI run: <run-id>, commit <sha>, status <green/red>
- Hard stops encountered: <list>
- iPhone 13 device verification queue: see per-day checklists above

## Tomorrow

- Resume from Day <next> via briefs/build-days-2-to-7.md
- OR proceed to Day 8 (UI shell — needs James's eye)
```

Then `git add docs/day-handoffs.md && git commit -m "Day N handoff" && git push`.

## Rules

- TDD: test first, implementation second.
- Use the 5 skills exclusively. Don't re-derive.
- Spec is the contract. Never edit `docs/spec-putting-lab-v1-FINAL.md`.
- No comments in code unless explicitly needed.
- No hardcoded user-facing strings.
- Swift 6 strict concurrency. `@Observable`, `@MainActor`, Swift Testing (not XCTest).
- After every successful day push: append to `docs/day-handoffs.md`.
- If James seems to wake up and respond mid-run: defer to his next instruction.
