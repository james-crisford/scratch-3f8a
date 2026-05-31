# AR Replay — Overnight Summary

*2026-05-31 morning brief. Build 14 (0.2.0) on TestFlight, untouched.*

## TL;DR

- Designed and partially built a v1.1 **AR ball-replay** layer that sits *additively* on top of `.showing` — Build 14 paths untouched, 2D top-down result still default.
- **Ready to review**: research synthesis, codebase audit, full architecture, adversarial design critique, plus `BallPhysics.swift` + 23 Swift Testing cases (Steps 1-3 of the build order — pure logic, compiles in the Simulator, no AR yet).
- **Needs your input** before further AR work: the **viewmodel-extension vs StrokeReplay-schema-v2** decision (critique §4.1 — current architecture proposes a file you've ringfenced) plus 14 design questions in `architecture.md` §8.
- The critic flagged the **carpet vs grass** mismatch — default Stimp 10 will over-roll ~2.5x on lounge carpet. Surface a DEBUG Stimp override before you test, or you'll think the integrator is broken.

## Files produced

- `docs/ar-replay/research-synthesis.md` — every equation/coefficient/sign convention needed; carries Penner 2002 + Hogan & Antali 2025 citations.
- `docs/ar-replay/codebase-audit.md` — Build 14 surface map, integration seams, the 6 fragility zones to not touch.
- `docs/ar-replay/architecture.md` — v1.1 design: 12 new files, AR state machine, build order, 14 open questions.
- `docs/ar-replay/design-critique.md` — adversarial red-team pass. Read this *first* tomorrow.
- `PuttingLab/Physics/BallPhysics.swift` — pure 2D semi-implicit Euler integrator (415 lines, no ARKit dep, deterministic).
- `PuttingLabTests/Physics/BallPhysicsTests.swift` — 23 Swift Testing cases across 6 suites (distance, sign, boundary, stop, determinism, capture).

## Key research findings

1. **`μ_r(S) = 0.611 / S_feet`** — rolling friction from Stimpmeter reading. Stimp 10 -> μ ≈ 0.061. [Penner 2002, Lee 2025, Kolkowitz 2007 agree ±4 %]
2. **`v_0 ≈ peakVelocity · speedCal · 0.877`** — that's `k_launch=0.90 · √e_skid=0.95` collapsed. Reuses the existing `speedToDistanceFactor` so the AR end-position matches the result-panel number. [Quintic Hurrion / Wadden 2014]
3. **`v_capture = 1.626 m/s`** — hard ceiling for cup capture on flat green. [Holmes 1991 / Hogan & Antali 2025 verbatim]
4. **`ψ_0 = -faceAngleRaw`** — sign flip from phone-yaw-delta to green-frame azimuth. Negative raw = closed face = pull left (RH user). Internal to `BallPhysics`, callers stay oblivious. [Spec §5.1 + audit §2.2]
5. **No 5/7 on friction.** It's already absorbed into μ_r via the Stimpmeter derivation. Apply 5/7 only on slope gravity (v1.2). The constant in `BallPhysics.swift` exists for v1.2 and is named `rollInertiaFactor` — critic flagged this is one rename away from safer.

## Architecture in one screen

**User flow:** `.showing` → tap "Replay in AR" → full-screen cover → scan plane → tap to place ball → tap to place hole → tap Replay → ball tweens → tap Done → back to `.showing` (Build 14's `tapDone()` runs unchanged).

**File structure (12 new files, no existing files modified):**
- `Physics/BallPhysics.swift` + `Physics/BallPhysicsConstants.swift` (constants embedded in `BallPhysics` for now — extract if size grows)
- `Models/ARSceneState.swift` (`@Observable` cover state machine)
- `UI/ARSceneCoordinator.swift` + 4 view files + 1 button + 1 view-extension overlay
- `Sensors/ARTrackingManager+PlaneDetection.swift` (extension)
- `UI/PracticeSessionViewModel+ARReplayAccessors.swift` — **the critic killed this**; replace with `StrokeReplay` schema v2

**New phases (cover-local, parallel to viewmodel.Phase):** `scanningPlane → placingBall → placingHole → readyToReplay → replaying → replayComplete → failed(reason)`.

## BallPhysics.swift implementation strategy

- **Equations.** Semi-implicit Euler at 16 ms steps. Friction term `a = -μ_r·g·(v/|v|)` only — no 5/7. Launch magnitude as above. Sign flip applied internally. Stimp clamped `[4, 14]`. Cup capture via closest-point-on-segment to handle fast passes. Lip-out kicks radially at `0.6·v_entry` and snaps clear of the disc so the next step doesn't re-trigger.
- **Deterministic.** Caseless `enum BallPhysics` — no instances. No RNG, no async, no globals. Same inputs → byte-identical `Result`. Validated by a 5-call determinism test.
- **Rejection-on-pathological.** NaN/Inf/negative-velocity/non-positive-dt → `.rejected` with empty path. Zero velocity → single stationary sample, `.stopped`.
- **Tests validate:** (a) headline 3-m putt within ±5 % of analytic distance; (b) Stimp 14:6 ratio ≈ 2.33; (c) closed face goes +y, open face goes -y, zero face goes straight; (d) slow putt at cup → `.captured`, hard putt → `.lipOut`, wide putt → not captured; (e) end-velocity ≤ stop threshold; (f) NaN/Inf/zero-dt rejected; (g) 5-call determinism.

## Design critique highlights

1. **Hard-constraint clash.** Architecture proposes a `PracticeSessionViewModel` extension reading the private `posesDuringRecording`. That cannot be done from an extension without modifying the viewmodel — which the brief forbids. **Cheaper path: extend `StrokeReplay` to schema v2 with ARKit poses serialised.** This is a `Models/` change, not a viewmodel change. ~1.2× file size penalty, but Build 14 stays sealed.
2. **Carpet vs grass.** `μ_r(S) = 0.611/S` is a Stimpmeter-on-bentgrass derivation. Lounge carpet stims ~4 ft — plugging Stimp 4 gives μ ≈ 0.15. Default Stimp 10 will over-roll by ~2.5x on your test surface. **Mitigation:** DEBUG-only Stimp override (long-press corner of HUD, seeded to 4).
3. **ARKit world-frame continuity is unverified.** The whole architecture assumes `session.run(config, options: [])` swap from `planeDetection=[]` to `[.horizontal]` preserves the world frame. Apple's docs are vague. **Verify on device in 10 min** before any UI work: capture `attitudeYaw()` before/after the swap, assert delta < 1°.
4. **`LiveImpactDetector` keeps running** during the AR cover. CoreMotion still streams; consume() still fires. Stray haptic mid-replay is possible. Add an explicit pause/resume.
5. **5-7 day timeline is 8-10 in reality.** First-time RealityKit + iOS 17/18 RealityView fork + on-device verification all under-estimated. Critic also offers a **2-day MVP slice**: `BallPhysics.swift` + a `RealityView` with no anchors, ball tweens in screen-space over the live feed. Worth considering.

## Open questions for James

- **Q1: Which integration seam?** Options: (a) `StrokeReplay` schema v2 — Models change only, Build 14 untouched, AR replay works in-session AND from saved strokes; (b) viewmodel extension — needs a private-storage bump in `PracticeSessionViewModel.swift`, violates the hard constraint. **Recommendation: (a)**, per critique §4.1. Adds ~1 h of migration code for existing TestFlight users' saved strokes.
- **Q2: MVP slice vs full architecture?** Options: (a) ship the 2-day "ball over live camera, no anchors" slice to TestFlight first, gather usage telemetry, then invest in full anchored version; (b) build the full 8-10 day anchored version end-to-end. **Recommendation: (a)** — same logic as Build 14 itself; ship cheap, learn from data, then invest.
- **Q3: DEBUG Stimp override now?** Options: (a) add it before any device testing; (b) skip and tune in field. **Recommendation: (a)** — half-hour of code prevents a wasted evening per critique §1.1.
- **Q4: Triage the 14 questions in `architecture.md` §8.** Ball appearance (Q3), hole appearance (Q4), tooltip behaviour (Q5), capture haptic (Q6), and the AR button visibility (Q8) are blocking on you. The rest can default.
- **Q5: Sign-convention re-confirm.** Negative `faceAngleRaw` should animate the ball *left* of target line in the AR view. **Recommendation:** confirm by inspection on the first device test; the unit test already asserts the green-frame y-sign.

## What's NOT done

- AR scene wiring (`ARSceneCoordinator.swift`, `ARReplayView.swift`, all UI files).
- `ARSceneState` observable + state-machine tests.
- `ARTrackingManager+PlaneDetection` extension (the config-swap helper).
- "Replay in AR" button + the overlay `ViewModifier` on `ResultPhaseView`.
- `StrokeReplay` schema v2 (the recommended integration path).
- Ball + flag asset selection (USDZ vs stylised).
- Capture haptic asset (`.caf` "ball-in-cup").
- Any state-machine edit to `PracticeSessionViewModel` (locked).
- Any device-only verification — physics ships testable in the Simulator, AR doesn't.
- `Info.plist` `NSCameraUsageDescription` audit (locked).
- Spec amendment for decision #6 (architecture.md §3.1).

## Suggested morning order

1. **Read `docs/ar-replay/design-critique.md` first.** Skim the other three only if a critique point looks wrong. It's the highest signal-to-noise of the four.
2. **Answer Q1** (integration seam) and **Q2** (MVP slice vs full). Those gate the next 8-10 days.
3. **Run `BallPhysicsTests` in the Simulator.** Validates the physics work without touching the iPhone. `xcodebuild test -scheme PuttingLab -destination 'platform=iOS Simulator,name=iPhone 16'` (per CI defaults). If green, the v1 minimal physics model is locked.
4. Once Q1/Q2 are decided, the next code-task is either (a) `StrokeReplay` schema v2 if you pick the full architecture, or (b) a `RealityView` MVP spike if you pick the cheap slice.

Build 14 (0.2.0) is on TestFlight unchanged. No code was committed.
All overnight work is in your working tree for review.
