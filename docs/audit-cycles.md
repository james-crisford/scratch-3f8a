# Break-Fix-Break Audit Cycles

## Cycle 1 — 2026-05-29

### Source of findings
- 18 known bugs from initial multi-auditor sweep (commit 390d12b state) — focus on critical only.

### Findings addressed (4 critical)

| # | Bug | File | Fix |
|---|---|---|---|
| C1 | PCA sign-flip via `mean(accel)` is unreliable because mean ≈ 0 for a complete stroke | `Physics/ImpactDetector.swift` | Sign-agnostic peak detection: compute both `maxV` and `minV` of smoothed velocity, choose the dominant absolute extremum (tie-break: later index). Flip the velocity array if the forward direction was opposite. |
| C2 | ARKit baseline yaw captured at `arkit.attitudeYaw()` regardless of tracking state | `SessionCoordinator.swift` | `isArKitDegraded()` gate: while `.limited(...)`, suppress lock firing and `stillness.reset()` every sample. `.normal` and `.notAvailable` (no-ARKit device) both pass. |
| C3 | Stillness gravity-dot threshold 0.96 = 16.26° cone (spec wants 15°) | `Sensors/StillnessDetector.swift` | Threshold raised to 0.966 (= cos 15°) with spec citation in code. |
| C4 | No haptic on stillness lock in SessionCoordinator path (only in SensorDebugView) | `SessionCoordinator.swift` | Injected `@MainActor onLockHaptic` closure; default fires `UIImpactFeedbackGenerator(.medium).impactOccurred()`. Wired in both `handleArm` and `handleReady` re-lock paths. |

### Regression tests added (9 new)

- `pcaSignNegatedAccel` — verifies detector still produces positive peakVelocity when accel is negated
- `pcaSignSymmetry` — original + negated produce peak velocity within 5%
- `pcaIgnoresBackswingPeak` — asymmetric stroke (slow takeaway, fast forward) places impact in second half
- `arkitBaselineGatedOnNormal` — 90 still samples while ARKit `.limited(.initializing)` keeps coordinator in `.arm`
- `arkitNormalAllowsLock` — once ARKit transitions to `.normal`, lock proceeds after 800ms
- `gravityAt0_96NotStill` — explicit spec-boundary case
- `gravityAt0_97Still` — explicit spec-boundary case
- `hapticFiresOnLock` — counter-closure asserts haptic fires exactly once
- `hapticFiresOnReLock` — second stroke + re-address fires second haptic

### Deferred to known-issues.md

- Bug C1 #1 (pull/push sign inversion in MarioKartAssist) — internal convention is consistent across fixtures and code; deferred pending real-device verification because the on-device ARKit sign depends on player orientation choices not yet specified.
- Bug C1 #6 (velocity[0]=0 assumption) — under-analysis. Stroke begins at takeaway when hand velocity is ≈ 0; auditor's concern may not apply. Verify with real IMU data.
- Bug C1 #7 (Task @MainActor sample-dispatch reordering) — significant refactor, deferred to Cycle 2 with dedicated AsyncStream design.

### CI / outcome

- Commit `a076bcd` — CI green, 290 tests passing in 26.5s (was 281, +9 new).
- Build clean, no warnings-as-errors.

### Next cycle scope

Cycle 2: spawn 5 fresh adversarial auditors with prompts emphasising what Cycle 1 touched (ImpactDetector, SessionCoordinator handleArm gate, StillnessDetector threshold change) PLUS the deferred items (sample-dispatch ordering, velocity[0]=0). Look for regressions and cross-module integration bugs.
