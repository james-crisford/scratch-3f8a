# PuttingLab — Overnight Sprint Handoffs

> James reads this in the morning. Each day section has an iPhone 13 device checklist — run through them in one batch on the phone after pulling the latest CI-green commit.

---

## Day 2 — 2026-05-29 — ARKit foundation

### What was built

- `PuttingLab/Models/ARTrackingState.swift` — Sendable enum mirror of `ARCamera.TrackingState` (.notAvailable, .limited(reason), .normal) + `ARTrackingLimitReason` mirror.
- `PuttingLab/Models/ARPose.swift` — `{ timestamp, transform: simd_float4x4, trackingState }` + computed `yaw` property.
- `PuttingLab/Sensors/ARTrackingManager.swift` — `ARTracking` protocol (`AnyObject, Sendable`) + real `ARTrackingManager` wrapping `ARWorldTrackingConfiguration` (planeDetection=[], frameSemantics=[], envTexturing=.none, lightEstimation=false) + pure static `yaw(from:)` math + `ARTrackingError` enum.
- `PuttingLabTests/Sensors/Fakes/FakeARTrackingManager.swift` — pure-Swift fake, no `ARSession`. Supports pose injection + state injection + simulated `worldTrackingUnsupported`.
- `PuttingLabTests/Sensors/ARTrackingManagerTests.swift` — 35 tests across 5 suites:
  - Yaw math (11): identity, ±45°, ±90°, 180°, bounded sweep -179° to +179°, NaN/inf/zero rejection, determinism, performance (<50ms for 10k calls), continuity.
  - Lifecycle (8): starts stopped, start sets running, stop is idempotent, double-start throws, unsupported throws, restart cleanly, 100× start/stop re-entrancy.
  - Pose stream (5): nil yaw before pose, inject updates latestPose, yaw from injected matches expected, state injection independent, `ARPose.yaw` property matches static.
  - State (6): equality cases, `isNormal`, Sendable cross-actor round-trip, `ARPose` Equatable.
  - Concurrency (4): 300 concurrent reads no crash, stop from detached task, weak-ref deallocates (no retain cycle), `ARTrackingError` Equatable.
- `PuttingLab/UI/SensorDebugView.swift` — added ARKit section: state label + yaw row + error line; view model now injects `ARTracking`, starts both motion + AR, polls `attitudeYaw()` at 10 Hz from a `@MainActor` task.

### Tests passing

- **54 tests green** on CI run `26612734167`, commit `7a7232d`. 2m30s wall.
- Build clean (no warnings-as-errors), Swift 6 strict concurrency, deployment target iOS 17.0, destination `iOS Simulator OS=18.5 iPhone 16`.

### iPhone 13 device checklist (verify in morning)

- [ ] App launches, requests camera permission first time (text says "PuttingLab uses the camera for AR tracking to anchor your putting line. We never record or upload images.").
- [ ] After granting camera, ARKit row in SensorDebugView shows `state: limited:init` → `state: normal` within ~2 seconds.
- [ ] `yaw: +X.XXX rad` row updates as you rotate the phone around its vertical (Y) axis. Hold phone vertically with screen facing you, back camera facing forward.
- [ ] Rotating phone to your right by ~90° → yaw moves toward `+1.57` (positive π/2). Rotating to your left → yaw toward `-1.57`. (Sign convention: positive yaw = clockwise looking down.)
- [ ] Yaw is stable (within ±0.01 rad / ~0.5°) when phone is held still.
- [ ] Putting back-camera over a featureless white wall or pointing at the sky → ARKit state goes to `limited:features` within a few seconds.
- [ ] Shake phone vigorously → ARKit state goes to `limited:motion`, recovers to `normal` within ~1s of stopping.
- [ ] Background app then foreground → SensorDebugView resumes cleanly, no crashes, no stuck state.
- [ ] Memory stable over a 60-second hold (use Xcode debug navigator; should not climb).
- [ ] No `os_log` errors or sensor-related warnings in Xcode console during normal use.

### Notes / known limitations

- `ARTrackingManager` itself has no unit tests — only the fake + the pure `yaw(from:)` static math are tested. The real manager's `ARSessionDelegate` callback path will be exercised on device in the morning checklist.
- `SensorDebugView` polls ARKit yaw at 10 Hz, not via callback. Cheap; fine for debug.
- ARKit is started with `[.resetTracking, .removeExistingAnchors]` on every `start()`. Stop pauses the session (does not destroy it).

### Next day scope

**Day 3 — Stillness detector.** Implement `StillnessDetector` consuming `MotionSample`s, emitting `StillnessLock` when 800 ms of `|rotationRate|<5°/s ∧ |userAccel|<0.2 m/s² ∧ dot(gravity, [0,-1,0])>0.96` holds. Snapshot compass yaw + ARKit yaw + gravity + lock time. 15+ tests including 799ms / 800ms boundary, spike resets, tilt resets, back-to-back locks. Wire into SensorDebugView with "Aimed ✓" badge + `UIImpactFeedbackGenerator(.medium)` haptic on lock.

---

## Day 3 — 2026-05-29 — Stillness detector

### What was built

- `PuttingLab/Models/StillnessLock.swift` — `{ yawTargetCompass: Double, gravity: SIMD3<Double>, lockedAt: TimeInterval }` Sendable + Equatable.
- `PuttingLab/Models/MotionSample.swift` — added `compassYaw` computed property (ZYX yaw from quaternion attitude).
- `PuttingLab/Sensors/StillnessDetector.swift` — stateful detector with `consume(_:) -> StillnessLock?`, `reset()`, `isAccumulating`, `hasEmittedLock`. Thresholds: 5°/s rotation, 0.2 m/s² accel, 0.96 gravity-dot, 800 ms window. NSLock-protected state. 1µs FP tolerance on the 800ms threshold (for robustness against CMDeviceMotion's seconds-since-boot timestamps, which lose ms-level precision at large magnitudes).
- `PuttingLabTests/Sensors/StillnessDetectorTests.swift` — 29 tests across 5 suites:
  - Lock behaviour (9): unlocked start, 800ms lock, 799ms no-lock, single emit while still, rotation/accel/tilt resets, back-to-back lock, `reset()` clears.
  - Boundary (8): rotation at/under 5°/s, accel at/under 0.2 m/s², gravity well-below 0.96 / just above 0.96, zero-gravity rejected, NaN rejected.
  - Snapshot integrity (3): preserves yaw exactly, preserves gravity vector, lockedAt = sample timestamp at fire.
  - Concurrency / perf / memory (5): 10k samples <100ms, determinism across detectors, no retain cycle, 200 concurrent state reads, 100 reset cycles.
  - `MotionSample.compassYaw` (4): identity, +π/4, −π/2, bounded sweep -179° to +179°.
- `PuttingLab/UI/SensorDebugView.swift` — view model now takes `StillnessDetector` + `@MainActor onLockHaptic` closure (default fires `UIImpactFeedbackGenerator(.medium).impactOccurred()`). Consumes detector on every motion sample. View shows "Aimed ✓" (green) or "Aim — hold still" (gray) + `yaw₀` snapshot value when locked.

### Tests passing

- **83 tests green** on CI run 26613201849, commit `7050dd4`. 6m wall (test count is starting to dominate over build time — still well under 30s test runtime cap).

### iPhone 13 device checklist (verify in morning)

- [ ] Launch app, grant camera permission, watch ARKit go from `limited:init` → `normal`.
- [ ] Hold phone vertically as if gripping a putter, screen toward you, back camera forward, then stay still for ~1 second.
- [ ] Within ~800 ms of becoming still, "Aimed ✓" badge turns green AND you feel one medium haptic tap. `yaw₀ +X.XXX` appears showing the locked compass yaw.
- [ ] Move/rotate the phone → badge goes back to "Aim — hold still" within one motion sample.
- [ ] Hold still again → re-locks. Second haptic tap fires. New `yaw₀` value if you rotated since.
- [ ] Tilt phone past ~15° from vertical → stillness does NOT engage (badge stays gray) even if hand is steady.
- [ ] Walking with phone in pocket / hand-shake → never locks (rotation/accel above thresholds).
- [ ] Sitting on a table flat → never locks (gravity dot vs (0,-1,0) is ~0, not vertical).
- [ ] Lock-yaw display value matches the rotation of the phone around its vertical axis: pointing the back camera north gives one value, rotating ¼ turn right increases/decreases by ~π/2 (sign convention TBD vs ARKit yaw — they may differ; that's expected, FaceAngleComputer reconciles in Day 6).
- [ ] App backgrounded then foregrounded → SensorDebugView re-arms cleanly. No stuck "Aimed ✓".
- [ ] Memory + CPU stable over 60s session (Xcode Debug Navigator).

### Notes

- `StillnessDetector` is purely state-machine; it has no time source of its own — entirely driven by `sample.timestamp`. Means tests can drive it at any synthetic rate.
- The 1µs FP tolerance: real CMDeviceMotion timestamps are `mach_absolute_time` in seconds since boot; at hour-long sessions, double-precision loses ms-level resolution. The tolerance is below the meaningful threshold of human "stillness" (5+ orders of magnitude smaller than 800ms) but ensures lock fires reliably.
- Haptic is fired from the `@MainActor` ViewModel via injected closure. Tests can pass a counting stub. (Day 3 doesn't ship a haptic-count test — added if a regression appears.)

### Next day scope

**Day 4 — Stroke detector.** State machine `armed → starting → recording → ended` requiring a prior `StillnessLock`. Start on `|rotationRate| > 30°/s` sustained ≥50 ms (debounce flicks). End on `|rotationRate| < 30°/s` for 300 ms continuous OR 2 s hard cutoff from start. Captures all samples in window into `StrokeWindow { start, end, samples, lock }`. 15+ tests including detection-with-debounce, flick-rejection, return-to-stillness end, hard-cutoff end, arm-only-after-lock. Wire SensorDebugView badge: ARMED → STROKE → DONE.

---

## Day 4 — 2026-05-29 — Stroke detector

### What was built

- `PuttingLab/Models/StrokeWindow.swift` — `{ start, end, samples, lock }` Sendable + `duration` computed property + `StrokeDetectorPhase` enum (`idle / armed / starting / recording / ended`).
- `PuttingLab/Sensors/StrokeDetector.swift` — state machine with `arm(with: StillnessLock) throws`, `consume(_:) -> StrokeWindow?`, `reset()`, `phase`, `sampleCount`. Thresholds: 30°/s (strict `>`), 50ms start-sustain debounce, 300ms quiet-window end, 2s hard cutoff. 1µs FP tolerance on all time comparisons (same robustness logic as Day 3). NSLock-protected internal state.
- `PuttingLabTests/Sensors/StrokeDetectorTests.swift` — 25 tests across 4 suites:
  - Arm + idle (7): starts idle, idle consume noop, arm from idle / from ended, arm-while-starting throws, arm-while-recording throws, reset returns idle.
  - Start detection (4): 50ms → recording, flick (40ms then dip) rejected and buffer cleared, boundary 30°/s exact (not above), boundary just-above starts.
  - End detection (7): 300ms quiet ends, 2s hard cutoff ends, 290ms quiet does NOT end, window captures samples + correct lock, window.start = first-above-threshold timestamp, brief quiet that resumes does NOT end, .ended ignores further input.
  - Robustness (7): determinism, performance (10k samples <200ms), no retain cycle, 200 concurrent reads, NaN rotation ignored, 100 reset cycles.
- `PuttingLab/UI/SensorDebugView.swift` — view model now owns a `StrokeDetector`; on every stillness lock, calls `try? stroke.arm(with: lock)`. On every sample, feeds `stroke.consume(sample)` and surfaces `strokePhase` + `lastStrokeSampleCount`. View shows colour-coded badge: idle=gray, ARMED=blue, starting=orange, STROKE=red, DONE=green.

### Tests passing

- **108 tests green** on CI run 26613363... (`1b0a272`). 3m19s wall, first push.

### iPhone 13 device checklist (verify in morning)

- [ ] After ARKit + stillness lock fires ("Aimed ✓"), the stroke badge turns blue and reads "stroke: ARMED".
- [ ] Make a deliberate putting motion (rotate phone briskly through ~30° of yaw over ~500–800ms). Badge goes `ARMED → starting… → STROKE (red) → DONE (green)`.
- [ ] Quick flick or finger twitch under 50ms above 30°/s does NOT advance the badge past `starting…` and falls back to ARMED.
- [ ] After DONE, on next stillness re-engagement the badge cycles back to ARMED. (Implementation: stillness lock auto re-arms the stroke detector.)
- [ ] During recording, the `samples` count tracks the number of captured frames (should be ~30–80 for a real putt at 100 Hz).
- [ ] Make a deliberately slow drift (under 30°/s the whole way): never advances past ARMED.
- [ ] Make a stroke and then immediately keep moving the phone (no return to still) for >2 s: DONE badge appears (hard cutoff). `samples` should be ~200.
- [ ] Phone held still for >2 minutes never spuriously enters starting/recording.
- [ ] App backgrounded → foregrounded: badge resets cleanly via `viewModel.start()`.
- [ ] Memory / CPU stable; no leaks after 10 consecutive strokes.

### Notes

- The detector is decoupled from the haptic / Aimed UI — it's a pure state machine driven by `MotionSample` timestamps. Means the same instance can be used in coordinator code (Day 7), in simulation tests (Day 7+), and in fixtures (Day 5+).
- `arm()` from `.starting` or `.recording` throws — the UI's `try? stroke.arm(...)` swallows that, but in coordinator code (Day 7) we'll handle it explicitly.
- Sample buffer uses `removeAll(keepingCapacity: true)` to avoid heap churn across multiple strokes per session.
- Day 5 introduces `Fixtures/` — many of the test helpers in StrokeDetectorTests.swift (`spinSample`, `testLock`, `simulateStrokeAndEnd`) will move into the fixture generator on Day 5.

### Next day scope

**Day 5 — Impact detection (HARD).** The headline algorithm. PCA on `userAcceleration` to find swing-plane forward axis, integrate to velocity with linear drift correction, 5-point moving average, find peak, sub-sample parabolic interpolation for `impactTime`, quaternion slerp for attitude at impact, compute `faceAngleRaw` vs `lock.yawTargetCompass`, confidence score. New: `Physics/ImpactDetector.swift`, `Models/ImpactResult.swift`, `Fixtures/clean_straight_8ft.json` + `Fixtures/Generator.swift` parameterised synthesis. ≥15 tests including face_angle within ±2° of 0 on clean fixture, sub-sample interpolation accuracy, throws on <200ms stroke, confidence <0.5 when ARKit-lost flag set.
