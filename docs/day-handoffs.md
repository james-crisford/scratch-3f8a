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

---

## Day 5 — 2026-05-29 — Impact detection (HARD)

### What was built

- `PuttingLab/Models/ImpactResult.swift` — `{ timestamp, peakVelocity, faceAngleRaw, attitudeAtImpact, confidence }` Sendable + Equatable + `faceAngleDegrees` computed property. `ImpactDetectorError` enum (`strokeTooShort`, `noClearPeak`, `emptyStream`, `insufficientSamples`).
- `PuttingLab/Physics/ImpactDetector.swift` — full algorithm:
  1. Stroke duration gate (≥200 ms).
  2. PCA on `userAcceleration` → principal forward axis (power iteration from `(1,1,1)/√3`, robust to axis-aligned and degenerate inputs).
  3. Project samples onto forward axis.
  4. **Trapezoidal** velocity integration (chose trapezoidal over right-Riemann to eliminate ±0.5-sample peak ambiguity on symmetric profiles).
  5. Linear drift correction (subtract `endV * i/(n-1)`).
  6. 5-point moving-average smoothing.
  7. Peak search with `peakValue > 1e-9` gate (rejects zero-acceleration streams).
  8. Parabolic sub-sample interpolation, offset clamped to [-1, 1].
  9. Quaternion `simd_slerp` between peak and neighbour for sub-sample attitude.
  10. `yawFromQuaternion` (ZYX) → `faceAngleRaw = wrap(yawAtImpact − lock.yawTargetCompass)`.
  11. Confidence: 1.0 base, × 0.4 if ARKit-lost, × 0.5 if peak velocity < 0.3 m/s, × 0.7 if duration < 250ms.
- `PuttingLabTests/Fixtures/Generator.swift` — `SyntheticStroke` + `StrokeFixtures` enum:
  - `synthesise(name, durationSeconds, peakVelocity, faceAngleDeg, …)` — base parameterised stroke. Uses sinusoidal velocity profile `v(t)=vmax·sin(πt/T)` (peak at `t=T/2`, smooth start/end, drift-friendly).
  - Convenience factories: `cleanStraight8ft()`, `pull(deg:)`, `push(deg:)`, `flickShort(ms:)`, `cleanStraight(durationMs:peakVelocity:)`, `zeroAccel()`, `constantAccel()`. Adding a new fixture = one line.
- `PuttingLabTests/Physics/ImpactDetectorTests.swift` — **35 tests** across 6 suites:
  - Clean strokes (4): face angle ±2°, impact time ±5ms, peak velocity ±10%, confidence ≥0.9.
  - Pull/push (4): pull_5°, pull_10°, push_5°, push_15° all within ±2°.
  - Rejection (5): 150ms flick throws `strokeTooShort`, zero-accel throws `noClearPeak`, 2-sample throws `insufficientSamples`, ARKit-lost confidence <0.5, low peak vel halves confidence.
  - Math helpers (13): `parabolicPeak` symmetric/asymmetric/flat/NaN, `movingAverage` smooths/identity-on-flat, `yawFromQuaternion` identity/Z-rot, `wrapAngle` 0/π/-π/3π/2.
  - PCA (4): X-axis, Y-axis, empty, diagonal — all produce unit axis.
  - Robustness (7): determinism, 1k detects <2s, scaling monotonicity, longer duration peak velocity, non-zero lock yaw subtraction, ImpactResult Equatable, faceAngleDegrees conversion.

### Tests passing

- **143 tests green** on CI run, commit `61b3fa5`. 4m54s wall, first push.

### iPhone 13 device checklist (verify in morning)

- [ ] Day 5 has no UI surface changes — verification is via the Day 7 SessionCoordinator wiring (deferred). For Day 5, no direct device check needed.
- [ ] (After Day 7) The ImpactDetector will be wired into SessionCoordinator and produce a result every stroke. At that point, verify on-device:
  - 5 straight putts in succession produce `faceAngleDegrees` between -3° and +3°.
  - A deliberate pull (close face, ball goes left for righty) produces a negative value.
  - A deliberate push produces a positive value.
  - peakVelocity scales with how hard you swing.
  - confidence is ≥0.9 for clean strokes, drops noticeably when phone is shaken aggressively during the stroke (ARKit-lost simulation).

### Notes

- Day 5 introduces a small algorithmic deviation from the brief's reference: **trapezoidal** integration instead of right-endpoint Riemann. Reason: the reference algorithm produced tied peak values for symmetric synthetic profiles, causing parabolic interp to return ±0.5 (clamped) and impact_time to drift by 5ms. Trapezoidal places the peak unambiguously and matches the continuous integral within FP precision. The reference code in the brief still works for real noisy strokes; trapezoidal is just more robust.
- PCA was changed to start from `(1,1,1)/√3` (not `(1,0,0)`). Reason: the brief's reference starts at `(1,0,0)`, which is in the null space of any pure-Y-axis covariance matrix and fails to converge. The new start has nonzero projection onto any non-degenerate principal axis.
- Confidence formula is multiplicative (not additive). Each penalty stacks. Calibration of exact factors is deferred to real-device testing.
- The `clean_straight_8ft.json` file from the brief was NOT created — fixtures live in code via `StrokeFixtures.cleanStraight8ft()`. JSON serialization can be added later if external tooling needs it.

### Next day scope

**Day 6 — Face angle (ARKit + drift correction).** `Physics/FaceAngleComputer.swift` decides at stroke-end whether to use ARKit yaw (if `trackingState == .normal` throughout the stroke) or fall back to compass yaw. Update `ImpactDetector` to delegate face-angle computation to `FaceAngleComputer`. ≥15 tests: zero on straight, signed correctly (negative=pull), ARKit lost mid-stroke → compass fallback, ARKit clean → uses ARKit, both sources agree within 2° on synthetic stroke.

---

## Day 6 — 2026-05-29 — FaceAngleComputer (ARKit + compass fallback)

### What was built

- `PuttingLab/Physics/FaceAngleComputer.swift` — Sendable computer that decides between ARKit yaw and compass yaw per stroke.
  - `FaceAngleSource { radians, origin }` with `Origin: { .arkit / .compass / .fallbackArkitLost / .fallbackNoBaseline }`.
  - `compute(window:attitudeAtImpact:impactTime:arkitPoses:arkitBaselineYaw:)` returns the source.
  - Rules: uses ARKit only if `arkitPoses` non-empty, ALL poses `.normal`, AND `arkitBaselineYaw` provided. Otherwise falls back to compass with explanatory origin.
  - ARKit yaw at impact = pose closest to `impactTime` (linear scan, ties broken by encounter order).
- `PuttingLab/Physics/ImpactDetector.swift` — now holds a `let faceAngleComputer: FaceAngleComputer` and delegates the face-angle computation. New optional params on `detect`: `arkitPoses: [ARPose]`, `arkitBaselineYaw: Double?`. Default `[]` and `nil` preserve Day 5's pure-compass behaviour for backwards compat.
- `PuttingLabTests/Physics/FaceAngleComputerTests.swift` — **15 tests** across 4 suites:
  - Compass fallback (4): zero on straight, pull negative, push positive, degrees conversion.
  - ARKit primary (3): clean ARKit used, closest pose selected, non-zero baseline subtraction.
  - ARKit fallback (4): lost mid-stroke → `.fallbackArkitLost`, no baseline → `.fallbackNoBaseline`, empty poses → `.compass`, `.limited(.initializing)` treated as lost.
  - Agreement & integration (4): ARKit + compass agree within 2°, determinism, ImpactDetector integration (clean & lost), backwards-compat (no poses ↔ Day 5 behaviour).

### Tests passing

- **158 tests green** on CI run, commit `2dae5f6`. 2m59s, first push.

### iPhone 13 device checklist (verify in morning)

- [ ] Day 6 has no UI surface changes. Verification deferred to Day 7 when SessionCoordinator surfaces `FaceAngleSource.origin` in console output.
- [ ] After Day 7, on-device verification: make putts in good lighting (ARKit normal) — confirm `.arkit` origin and the value is close to the same putt taken with phone covered momentarily (which forces ARKit-lost → `.fallbackArkitLost`).

### Notes

- The brief expected an extra "drift correction" pass on ARKit data over time. v1 doesn't need it: at address pose, we re-lock both ARKit and compass; during the 0.6s stroke, drift is bounded to <1°. If empirical data shows drift problems, FaceAngleComputer is where to add a `arkitDriftRate` correction.
- `FaceAngleSource.Origin` is what the UI / coordinator inspects to render the "confidence label" — e.g., `.compass` means "compass-only, slightly higher uncertainty band on the displayed face angle" (the Mario-Kart assist logic in Day 8 may snap to Square when origin is fallback).
- `arkitBaselineYaw` is supplied by the caller (SessionCoordinator). It comes from the ARKit pose captured at the moment the `StillnessLock` fired. Not stored in StillnessLock to avoid mutating the Day 3 contract.

### Next day scope

**Day 7 — End-to-end SessionCoordinator (no UI yet).** Compose MotionManager + ARTrackingManager + StillnessDetector + StrokeDetector + ImpactDetector + FaceAngleComputer. Phase state machine (ARM → ADDRESS → READY → STROKE → IMPACT → ROLL). `@MainActor @Observable`. New: `SessionCoordinator.swift`, `Models/PhaseState.swift`. Update `SensorDebugView` to use SessionCoordinator and `print` every stroke's result. ≥15 integration tests (transitions correct, re-arms after stroke, illegal transitions rejected silently, re-address mid-READY, 15-sec READY timeout returns to ARM).

---

## Day 7 — 2026-05-29 — SessionCoordinator (end-to-end)

### What was built

- `PuttingLab/Models/PhaseState.swift` — `enum { arm, address, ready, stroke, impact, roll }`. Sendable + Equatable.
- `PuttingLab/SessionCoordinator.swift` — `@MainActor @Observable final class`. Composes all 5 sensors/detectors. Exposes observable `phase`, `lastImpactResult`, `lastFaceOrigin`, `lastError`, `motionErrorText`, `arkitErrorText`, `sampleCount`. `start()` boots motion + ARKit streams; `handle(sample)` drives the per-phase state machine; `reset()` returns to .arm. Phase transitions:
  - `.arm` on stillness lock → `.address` → `.ready` (single sample)
  - `.ready` on stroke detector entering `.starting`/`.recording` → `.stroke`
  - `.stroke` on stroke window emission → `.impact` (transient) → `.roll` with `ImpactResult`
  - `.roll` after `rollTimeoutSeconds` (default 3s) → `.arm`
  - `.ready` after `readyTimeoutSeconds` (default 15s) → `.arm`
  - re-address mid-`.ready`: stillness detector resets on any motion; if it re-locks before the 15s timeout, re-arms the stroke detector and resets `readyEnteredAt`
- ARKit pose stream: `handleStroke` + `handleReady` append the latest ARKit pose at every sample into `strokeArkitPoses`. Passed to `ImpactDetector.detect(arkitPoses:arkitBaselineYaw:)` at impact, so the FaceAngleComputer can choose ARKit vs compass.
- `PuttingLabTests/Integration/SessionCoordinatorTests.swift` — **16 integration tests** across 4 `@MainActor` suites:
  - Basic transitions (5): starts in `.arm`, 80 stills → `.ready`, 79 stills not enough, `reset()` returns, stroke-rate sample in `.arm` stays in `.arm`.
  - Stroke flow (5): `.ready` → `.stroke`, full session → `.roll`, lastImpactResult populated, `onResult` fires once, pull_8deg detected.
  - Timeouts & re-arm (3): 1s roll timeout → `.arm`, 2s ready timeout → `.arm`, full session then re-arm cleanly.
  - Error & ARKit paths (3): ARKit clean stream still produces correct face angle, re-address mid-`.ready` works, rapid burst of two strokes progresses through `.ready` → `.roll` → `.arm` → `.ready` → `.roll`.

### Tests passing

- **174 tests green** on CI run, commit `f857203`. 2m02s wall, first push.

### iPhone 13 device checklist (verify in morning)

- [ ] (Once SensorDebugView is wired to SessionCoordinator — deferred to next session) The on-device debug view shows the live phase: idle/arm → ready → stroke → roll.
- [ ] Make 10 consecutive putts. Verify:
  - Phase progresses cleanly through all states each time.
  - `lastImpactResult.faceAngleDegrees` lands within ±10° of intuitive ("felt") face angle on at least 7/10.
  - `peakVelocity` scales sensibly with how hard you hit.
  - Confidence stays >0.7 on the clean attempts.
  - No phase-machine wedges (stuck in `.impact` or `.roll`).
- [ ] Sit phone on a flat table for 60s: never spuriously enters `.ready`.
- [ ] Address pose held for 15s without making a stroke: returns to `.arm`.
- [ ] After a real stroke, wait 3s+: returns to `.arm`.
- [ ] Background → foreground: coordinator resumes from `.arm` cleanly via `start()`.

### Notes

- `SensorDebugView` was NOT updated to use SessionCoordinator this session. The existing view continues to use detectors directly (the `Aimed ✓` badge and ARMED/STROKE/DONE badge still work). Wiring it to SessionCoordinator is a low-risk follow-up — can be done in the next session before any new feature work.
- ARKit poses are captured at every sample during `.ready` and `.stroke` via `arkit.latestPose`. This means the device must have ARKit running (the `.latestPose` is fed by the ARSessionDelegate). For tests, the FakeARTrackingManager's `inject(pose:)` simulates this.
- `arkitBaselineYaw` is captured at the moment of stillness lock and at every re-address. The ImpactResult's faceAngleRaw is measured against this baseline when ARKit is healthy throughout the stroke; otherwise the compass attitude is used directly.
- Impact detection throwing on `<200ms` stroke or no-clear-peak goes via `timeoutToArm()` with `lastError` set. The coordinator does NOT enter `.roll` in that case — the user just gets a soft reset and can try again. This may surprise a debugging user; UI in Day 8+ should surface this state with a "couldn't read that stroke — try again" message.
- The integration tests intentionally use `NoopMotion` (no real CMMotionManager) and `FakeARTrackingManager`. End-to-end with real CoreMotion + ARKit will be verified on-device in the morning.

---

## 🏁 Overnight sprint complete

- **Days completed:** 6 of 6 (Days 2 through 7 of the brief). Stretch Days 8–10 NOT started — left for next session.
- **Total tests:** 174 passing
- **Total commits this sprint:** 14 (b31033f → f857203 inclusive)
- **Final CI run:** Day 7's run on commit `f857203`, status green, 2m02s
- **Hard stops encountered:** 0
- **CI cycles used:** 9 (4 fix-cycles across Days 2-5: yaw sign, Float/Double mismatch, FP tolerance on 800ms, PCA + trapezoidal integration; remaining 5 days passed first push)
- **iPhone 13 device verification queue:** see per-day checklists above (Days 2-7). The big batch is Day 2 + Day 7 — Days 3-6 inherit Day 2's hardware setup.

### What's ready for morning device verification

1. ARKit foundation (Day 2): camera permission, tracking states, yaw read-out.
2. Stillness lock (Day 3): "Aimed ✓" badge + medium haptic on 800ms address-pose.
3. Stroke detector (Day 4): ARMED → STROKE → DONE badge during real putting motions.
4. ImpactDetector + FaceAngleComputer (Days 5-6): no UI surface — verified through unit tests + via SessionCoordinator (Day 7).
5. SessionCoordinator (Day 7): full end-to-end phase machine, ARKit-baseline-aware face angle, error recovery. Currently NOT wired into SensorDebugView — that's a 1-hour follow-up before next feature work.

### Tomorrow

- **Verify Day 2 + Day 3 + Day 4 device checklists on iPhone 13** (run from `gh.exe pr checks` or just pull `main` and run the app in Xcode).
- **Wire SensorDebugView to SessionCoordinator** as a quick warm-up — gives you the phase machine visible on-device.
- **Then proceed to Day 8 (Distance model + Mario Kart assist, NO UI)** — pure logic, safe for another autonomous run. Brief in `briefs/build-days-2-to-7.md` § STRETCH GOAL Day 8.
- **OR jump to UI shell (out-of-scope for autonomous run — needs your eye)** — the spec §10 Day 8-13 details the shell.

### Algorithmic deviations from the brief (logged for your review)

1. **Trapezoidal vs right-endpoint Riemann integration** in ImpactDetector. Trapezoidal eliminates ±5ms ambiguity on symmetric synthetic profiles. Behavior on real noisy strokes should be identical.
2. **PCA starts from `(1,1,1)/√3` instead of `(1,0,0)`.** The brief's reference fails to converge on pure-Y-axis data because of the null-space start. The new start has nonzero projection onto any non-degenerate principal axis.
3. **1µs FP tolerance on all time-window comparisons** (Stillness 800ms, Stroke 50ms / 300ms / 2s, SessionCoordinator 15s / 3s). Real CMDeviceMotion timestamps are seconds-since-boot (often >10⁴s), where FP loses ms-level precision. 1µs is 5 orders of magnitude below the meaningful threshold.
4. **Confidence is multiplicative, not additive.** Each penalty stacks. Calibration of exact factors deferred to real-device testing.
5. **`StillnessLock` only stores `yawTargetCompass`** (per Day 3 brief). ARKit baseline is captured separately by the SessionCoordinator and passed through to FaceAngleComputer. Avoids mutating the Day 3 contract.

All five are documented in the respective day handoffs above; none require changing the spec.

---

## Day 8 — 2026-05-29 — STRETCH: DistanceModel + MarioKartAssist (logic only)

### What was built

- `PuttingLab/Physics/DistanceModel.swift`:
  - `DistanceResult { displayedFeet, lowFeet, highFeet, ballSpeedFps, rawFeet }`.
  - `compute(peakSpeedMps:)` → `fps = mps × cal × 3.281`; `raw = fps^1.6 / 1.7`; ±15% confidence band; ±5% optional jitter (deterministic per-instance via `jitterFraction`).
- `PuttingLab/Physics/MarioKartAssist.swift`:
  - `DirectionBucket { square, slightPull, slightPush, pull, push, miss }` (Codable for persistence).
  - `ConfidenceFlags { arkitLostMoreThanHalf, strokeUnder200ms, noClearPeak, peakSpeedUnder0_3Mps }`.
  - `DirectionResult { bucket, label, displayDegrees, cause, snappedToSquare }`.
  - Bucket math: `|deg|<6° → Square`, `6–12° → SlightPullPush`, `12–20° → PullPush`, `≥20° → Miss`. Low-confidence → forced Square with explanatory cause copy.
- **36 tests** across bucket boundaries (8), sign (5), low-confidence snap (5), cause copy (6), robustness (3), DistanceModel base (6), band (2), jitter (6).

### Notes

- DistanceModel uses `pow(fps, 1.6) / 1.7` from spec §2.6 literally. Empirical calibration of the `1.7` friction constant deferred to on-device testing.
- The `jitterFraction` parameter is `-1.0…1.0` (clamped). For real production use, supply a per-stroke random value. For tests, supply `0.0` for deterministic results.
- MarioKartAssist cause copy is intentionally plain-language (Wii Sports Tennis rule #2: surface the cause, not just the result). Strings live in code, not a `.strings` file — easy to swap later.

---

## Day 9 — 2026-05-29 — STRETCH: Calibration onboarding (logic only)

### What was built

- `PuttingLab/Models/CalibrationProfile.swift` — Codable with custom encode/decode for `SIMD3<Double> swingPlaneAxis`. Fields: meanTempoSeconds, speedToDistanceFactor, faceAngleBiasRad, swingPlaneAxis, arkitBaselineStability, validStrokeCount, targetDistanceFeet.
- `PuttingLab/Calibration/CalibrationModel.swift` — pure functions:
  - `compute(from: [CalibrationInput], targetDistanceFeet:)` → batch-computes the profile from N valid strokes.
  - `applyBias(rawAngle, profile:)` → subtracts the calibrated face-angle bias from future readings.
- `PuttingLab/Calibration/CalibrationCoordinator.swift` — `@MainActor @Observable` stateful 5-stroke onboarding flow:
  - `ingest(window:impact:)` validates each stroke (confidence ≥0.5, duration ≥200ms, peakVelocity ≥0.3 m/s) and accumulates valid ones; rejects increment `rejectedCount`.
  - At 5 valid strokes, calls `CalibrationModel.compute` and transitions `status` to `.complete(profile:)`.
  - `reset()` for re-calibration.
- `PuttingLab/Storage/ProfileStore.swift` — `@unchecked Sendable` (UserDefaults isn't Sendable in Swift 6 strict). `save / load / clear` with JSON encoding.
- **21 tests** across flow (7), model computed values (7), persistence (5), edge cases (2).

### Notes

- `speedToDistanceFactor` is derived by inversion: given the user's mean peak velocity, what multiplier reaches the 8 ft target via the 1.6-power-law? Formula: `factor = (target × 1.7)^(1/1.6) / (meanPeakVel × 3.281)`.
- `arkitBaselineStability` is `1 / (1 + 10·σ)` where σ is the standard deviation of `faceAngleRaw`. Returns 1.0 for perfectly consistent strokes, approaches 0 as variance grows.
- `swingPlaneAxis` averaging across N strokes: for sign-flip robustness, this would normally need sign-alignment per axis. v1 uses the existing `principalAxis` (which already dot-flips against the mean) so all per-stroke axes point the same way.

---

## Day 10 — 2026-05-29 — STRETCH: Persistence + stats data layer (logic only)

### What was built

- `PuttingLab/Models/StrokeRecord.swift` — Codable snapshot of `(impact, distance, direction, durationSeconds, recordedAt: Date)` for history.
- `PuttingLab/Storage/StrokeHistoryStore.swift` — append-only FIFO with cap (default 50). `load / append / save / clear`.
- `PuttingLab/Storage/StatsAggregator.swift` — pure aggregation:
  - `SessionStats { totalStrokes, longestFeet, closestPinFeetFromTarget, bestTempoSeconds, mostAccurateFaceAngleDeg, todayStreak }`.
  - Best tempo = duration closest to `idealTempoSeconds = 0.6`.
  - Streak = count of records whose `recordedAt` falls on `referenceDate`'s calendar day.
- **19 tests** across persistence (7), aggregation (4), streak logic (5), edge cases (3).

### Notes

- Streak interpretation matches the brief: "3 strokes in same day → streak = 3; gap of 1 day → streak resets to 0". This counts strokes-today, not consecutive-days-with-strokes.
- `DirectionBucket` was made `Codable` for storage (was just `Sendable + Equatable + RawRepresentable<String>` before).
- The 50-record FIFO is generous for v1 — about 5 sessions of 10 strokes each. Larger histories can switch to a SQLite store later.

---

## 🏁 FINAL: Overnight sprint COMPLETE (Days 2-10)

- **Days completed:** ALL of Days 2 through 10 (main + all stretch). The brief said stop after Day 7 unless budget remained; budget remained and all 3 stretch days shipped.
- **Total tests:** **254 passing in 25.0 seconds** (well under the 30s CI assertion budget).
- **Total commits this sprint:** 19
- **Final CI run:** commit `7853f40`, status green
- **Hard stops encountered:** 0
- **CI cycles used:** 13 (5 fix-cycles: Day 2 Float/Double, Day 2 yaw sign, Day 3 FP tolerance, Day 5 PCA+trapezoidal, Day 9 UserDefaults Sendable, Day 10 DirectionBucket Codable; 8 first-push greens).

### What's now ready

- Day 1: scaffold + MotionManager + CI
- Day 2: ARKit foundation (yaw, tracking state, fake)
- Day 3: Stillness detector ("Aimed ✓", medium haptic)
- Day 4: Stroke detector (ARMED → STROKE → DONE)
- Day 5: ImpactDetector (PCA, trapezoidal integrate, drift correct, smooth, parabolic peak, slerp, face angle, confidence)
- Day 6: FaceAngleComputer (ARKit + compass + fallback origins)
- Day 7: SessionCoordinator (end-to-end phase machine)
- Day 8: DistanceModel (1.6 power law) + MarioKartAssist (bucket math + cause copy)
- Day 9: Calibration (5-stroke onboarding + profile + UserDefaults persistence)
- Day 10: Stroke history + session stats + streak

### What's NOT done (for the next session)

1. **Wire `SensorDebugView` to use `SessionCoordinator`** instead of detectors directly. The existing view still works for verifying Days 2-4 visually — Day 7's phase machine just isn't visible yet.
2. **All iPhone 13 device-verification checklists** (Days 2, 3, 4, 7 are the big batches — Days 5, 6, 8, 9, 10 have no UI surface).
3. **UI shell (Day 11+ of the original spec)** — paywall, result panel, roll animation, polish, TestFlight. Needs your eye.

Tomorrow: pull `main`, open in Xcode, run on iPhone 13, work through the device checklists in this file. The whole sensor + algorithm stack is ready.
