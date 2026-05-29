# Known Issues — deferred from audit cycles

## Critical (verify on device first)

### KI-1: Pull/push sign convention (MarioKartAssist:54)
- **Auditor claim:** `isPull = faceAngleDeg < 0` is inverted because ARKit yaw is right-handed.
- **Current state:** internal convention is fixture-consistent — `StrokeFixtures.pull(deg:)` uses negative face angle, `ImpactDetector` returns negative for pull-style fixtures, `MarioKartAssist` reads negative as pull. All tests pass.
- **Risk:** if on-device ARKit yaw delta sign for a real pull doesn't match the synthetic convention, every righty user sees pull/push swapped.
- **Verification plan:** on iPhone 13, make a deliberate pull (face closed) stroke, observe the sign of `ImpactResult.faceAngleRaw`. If positive → invert the synthetic fixture sign + flip `isPull` condition.
- **Severity:** critical if wrong; trivial if right.

### KI-2: Velocity[0]=0 assumption (ImpactDetector:38)
- **Auditor claim:** Phone is rotating >30°/s when stroke detector starts buffering, so v[0] ≠ 0 → peak velocity systematically underestimated.
- **Current analysis:** Stroke begins at TAKEAWAY (start of backswing). At takeaway, the hand is just starting to move; v ≈ 0 is approximately correct. The phone IS rotating about the shaft axis, but rotation rate ≠ forward velocity.
- **Verification plan:** sanity-check on device that peak velocity for a 10ft putt sits around 1.0-1.5 m/s as the Marquardt 2007 PuttLab data predicts. If chronically low (e.g. 0.6-0.8 m/s), revisit.
- **Severity:** suspected non-issue. Re-evaluate after device data.

### KI-3: Sample-dispatch reordering via Task @MainActor
- **Auditor claim:** `Task { @MainActor in self?.handle(sample) }` per sample does NOT preserve enqueue order at 100Hz on a busy main actor.
- **Risk:** out-of-order timestamps break stillness/stroke detectors which are timestamp-stateful.
- **Mitigation plan:** replace per-sample Task spawn with an `AsyncStream<MotionSample>` continuation written from the CoreMotion queue + a single `Task { @MainActor for await s in stream { handle(s) } }` consumer started in `start()` and cancelled in `stop()`.
- **Severity:** important. Deferred to Cycle 2 — significant refactor of MotionManager + SessionCoordinator wiring.

## Important (UX / quality)

### KI-4: Compass yaw corrupted by steel putter shaft
- **Research finding** (puttinglab-high-speed-imu-bounds-2026-05-29.md): steel shaft saturates magnetometer; `xMagneticNorthZVertical` reference frame anchors attitude to corrupted north.
- **Mitigation plan:** switch motion reference frame to `.xArbitraryZVertical` (gyro-only, no compass), make ARKit yaw the primary source, and reduce confidence on compass-origin face angles. Document trade-off.
- **Severity:** important. Defer until ARKit-primary path is robust enough.

### KI-5: 30°/s stroke threshold may be too high for slow tap-ins
- **Research finding:** amateur peak rotation can be ~50°/s; slow tap-in may peak at 25-35°/s.
- **Mitigation plan:** lower to 20°/s OR add OR-clause `|userAccel| > 0.4 m/s²` for slow-but-accelerating strokes. Calibrate after device data.
- **Severity:** important. May make app feel broken on slow strokes.

### KI-6: Calibration brittleness (5/5 valid required)
- **Auditor claim:** Repeated `noClearPeak` / `strokeTooShort` rejections during onboarding can leave user stuck.
- **Mitigation plan:** Accept 3/5 with reduced confidence in profile; widen stillness thresholds during calibration mode; surface live "captured X/5" UI hint.
- **Severity:** important. First-run experience.

### KI-7: ConfidenceFlags exist but unwired from ImpactDetector
- **Current state:** ImpactDetector throws `ImpactDetectorError.strokeTooShort` / `.noClearPeak` instead of returning a result with `snappedToSquare`.
- **Spec:** §5.2 wants snap-to-square with a result shown, not a thrown error.
- **Mitigation plan:** ImpactDetector returns `ImpactResult` always, plus a `ConfidenceFlags` value. MarioKartAssist consumes flags. UI shows "Square" + cause for low confidence instead of "couldn't read".
- **Severity:** important. Affects UX framing.

### KI-8: ARKit-lost check is binary, spec wants ">50% of window"
- **File:** `FaceAngleComputer.swift:28` uses `allSatisfy { isNormal }` — any one bad frame falls back.
- **Spec:** §2.5 says fallback when >50% of stroke window is non-`.normal`.
- **Mitigation plan:** count non-normal poses and threshold against 50%.
- **Severity:** important.

### KI-9: Distance jitter 0.05 vs spec 0.10
- **File:** `DistanceModel.swift` has `jitterAmplitude = 0.05`. Spec §2.6 says `±0.1`.
- **Mitigation plan:** change constant, update tests.
- **Severity:** cosmetic-to-important (depends on whether the empirical Stimp model invalidates the spec's jitter recommendation).

### KI-10: Calibration tempo is mean stroke duration, spec wants backswing/forward ratio
- **File:** `CalibrationModel.swift:18`.
- **Blocked on:** needing a TempoComputer that identifies backswing-vs-forward halves of the stroke. Spec §9 mentions TempoComputer but it's not built.
- **Mitigation plan:** Cycle 3+ — add TempoComputer (identifies top-of-swing via rotation rate sign reversal), feeds ratio into calibration.
- **Severity:** important (calibration accuracy).

## Test quality (track + fix opportunistically)

### KI-11: Fixture circularity in Generator.swift
- **Line:** `expectedFaceAngleRad = ImpactDetector.wrapAngle(faceRad - lockYawCompass)`.
- **Issue:** fixture uses production `wrapAngle` to compute its truth value. If wrapAngle has a bug, every face-angle test still passes.
- **Mitigation plan:** add a test-only `wrapAngleReference` that mirrors the math independently. Use it in fixture and assert wrapAngle matches it.
- **Severity:** test quality. Cycle 2 fix.

### KI-12: NoiseRobustnessTests `heavyNoise` has no assertion
- **File:** `NoiseRobustnessTests.swift:27-32`.
- **Issue:** `_ = try detector.detect(...)` — only verifies no throw.
- **Mitigation plan:** add `#expect(r.peakVelocity > 0 && r.peakVelocity.isFinite)`.
- **Severity:** test quality. Trivial fix in Cycle 2.

### KI-13: Tolerance bands wide on noise-free inputs
- **Issue:** `±2°` tolerance on noise-free fixtures lets ±1° silent regressions through.
- **Mitigation plan:** tighten to `±0.1°` on noise-free fixtures, keep `±5°` for noisy ones.
- **Severity:** test quality. Cycle 2.

### KI-14: 1000-stroke fuzz tolerance `<10°` too wide
- **Issue:** a detector returning 0° passes 40% of fuzz inputs in `[-25, +25]`.
- **Mitigation plan:** tighten to `<3°` (allows for FP imprecision + smoothing but catches systematic bugs).
- **Severity:** test quality. Cycle 2.

### KI-15: Missing negative-sign boundary tests in MarioKartAssist
- **Issue:** boundaries tested at +6, +12, +20 but never -6, -12, -20.
- **Mitigation plan:** add mirror tests.
- **Severity:** test quality. Cycle 2.
