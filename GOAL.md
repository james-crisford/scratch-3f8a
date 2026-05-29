# GOAL — Build Putting Lab v1

> cwd: `projects/PuttingLab/`. CLAUDE.md + 5 skills auto-load. Parent env supplies Gemini auto-review, memory, MCP, codegraph.

## What

iPhone putting game. Phone vertical in lead hand, swing through air, get a believable result. No ball. iOS 17+. Swift 6 + SwiftUI + CoreMotion + ARKit. 2 weeks.

**Source of truth: `docs/spec-putting-lab-v1-FINAL.md`. Don't deviate.**

## How

1. One spec §10 day per session. Don't skip.
2. TodoWrite at start, mark complete as you go.
3. Use the 5 skills. Don't re-derive.
4. Honest accuracy. Snap to Square when confidence low. Surface cause not result.
5. No comments unless asked. No hardcoded user-facing strings.

## Testing — TEST EVERYTHING. TDD.

### Unit (Swift Testing) for every module

Every file in `Sensors/`, `Physics/`, `Calibration/`, `Storage/` ships `*Tests.swift`. Use `@Suite`, `@Test`, `#expect`. Min coverage:

- **MotionManager**: 100Hz stream, clean stop, auth.
- **StillnessDetector**: 800ms lock, reset on break, reject non-vertical.
- **StrokeDetector**: start, end-stillness, end-timeout, debounce.
- **ImpactDetector**: peak on clean stroke, sub-sample interp, throws on no-peak, throws on <200ms.
- **FaceAngleComputer**: zero on straight, signed, ARKit→compass fallback.
- **DistanceModel**: monotonic, respects calibration, ±15% band.
- **MarioKartAssist**: every boundary (5/6/11/12/19/20°), confidence-low forces Square.
- **CalibrationModel**: 5-fixture run → expected stats, persists, round-trips.
- **RingBuffer**: capacity, wrap, chronological snapshot.

### Fixtures — Day 1, expand daily

`PuttingLabTests/Fixtures/*.json`. By Day 7: clean_straight, pull_10deg, push_15deg, flick_short_150ms, no_peak_constant, arkit_lost_midswing, calibration_run_5strokes. Algorithm change re-runs all. Regression = previously-passing fixture changes output.

### Integration — full loop

`Integration/StrokeLoopTests.swift`: fixture → ARM→ADDRESS→READY→STROKE→IMPACT→ROLL, assert `StrokeResult`. Runs every commit. Broken = stop and fix.

### Real device — END OF EVERY DAY

Simulator has no IMU. Output checklist for James: exact tap sequence; 5+ strokes expected vs not; edge cases (fast, slow, mid-stroke re-grip, walking, indoor mag interference); one regression — replay yesterday, still works. James reports. Iterate green before next day.

### Perf + memory — by Day 10

`os_signpost`. Stroke compute <50ms. 60fps during roll. Memory stable over 50 strokes. 20min session <8% battery on iPhone 12.

### Edge cases — green by Day 13

Flat rejected. Upside-down rejected. Backswing-only rejected. 3-strokes-in-2s segments cleanly. Backgrounding recovers. Permission-denied graceful. Low battery. Simulator graceful no-sensor fallback. iPhone 12 vs 17 parity.

### TestFlight — Day 14

To James + ≥1 golfer mate. Feedback in `docs/feedback/`. Iterate thresholds + calibration constants on real-world feel before done.

## Today

Next unfinished day from spec §10. Session 1 = Day 1: Xcode project, `CMDeviceMotion` 100Hz with `xMagneticNorthZVertical`, ring buffer, MotionManagerTests, device verify. **Tests first.**

End-of-session output: (a) built, (b) tests passing, (c) device checklist, (d) next session.

## Stop and ask James

Spec change. Locked-decision deviation. New dep. Pricing/naming/signing. Scope creep.

## Done (v1)

Spec §14 + all tests green + golfer says "feels right" 4/5 + TestFlight delivered.

## Start

> Read CLAUDE.md + docs/spec-putting-lab-v1-FINAL.md. TodoWrite from spec §10 (next unfinished day) including matching tests. Confirm scope in one sentence, then start TDD.
