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
