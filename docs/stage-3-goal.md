# Stage 3 Goal — full spec

Companion to the `/goal` prompt and the implementation plan at `docs/stage-3-plan.md`.
The goal prompt is short by necessity; this is the durable detail.

---

## Definition of done — every clause must be true

### 1. Address-pose marker (Slice 3.1, B46)
When the ball is placed and a hole exists, two translucent yellow foot markers (~24×10 cm each) render on the AR floor 60 cm behind the ball, perpendicular to the aim-line, 26 cm apart. Auto-hides when the stroke begins. Use `PhysicallyBasedMaterial` so the markers receive ARKit lighting (matches B45 fix).

### 2. Address calibration (Slice 3.2, B47)
New `PlacementState.calibratingAddress(ball, hole)` case. User taps **"Set address"** → app captures phone IMU pose (yaw / pitch / roll) + phone position vs ball when `StillnessLock` reports still for 1 s. A small phone-icon hologram renders at the captured position so the user can SEE what was captured. **"Re-calibrate"** button to redo. New `.addressCalibrated` Event.Kind with full pose payload. Wires `Calibration/CalibrationCoordinator.swift` (already exists).

### 3. Stroke detection wired (Slice 3.3, B48)
`Sensors/StrokeDetector.swift` runs in AR view, subscribed from the Coordinator. New `PlacementState.readyForStroke(ball, hole, addressPose)` and `PlacementState.strokeInProgress`. SF Symbol gentle pulse on the ball when address-pose held still for 1 s (GO affordance). Sharp pulse on the ball at peak-impact frame. New Event.Kinds: `strokeStarted`, `peakImpact` (with `velocity_mps`, `accel_g`, `face_angle_deg` payload), `strokeEnded`. Stroke detector outputs must be DETERMINISTIC for the same phone motion — same swing in same conditions produces same impact velocity ± 2 %.

### 4. Putt-roll physics in AR (Slice 3.4, B49)
New `BallRollAnimator` class running at 60 Hz. Inputs: `peakImpactVelocity` + `faceAngle` from Slice 3.3 + `addressPose` from Slice 3.2. Uses `Physics/BallPhysics.swift` for rolling friction (μ_r=0.131 from the friction-research memory) + `Physics/DistanceModel.swift` for distance prediction.

Ball physically rolls across the AR floor from address position with deceleration from rolling friction. Collision-with-cup test: when ball world-coord within 5.4 cm horizontally of cup centre AND velocity < 1.5 m/s → snap into cup with small bounce animation. If ball passes cup at higher speed → lips out and continues. Trail of fading translucent yellow markers shows actual roll path during animation. Animation can be REPLAYED by tapping **"Replay last putt"**.

### 5. Result panel + Mario Kart assist (Slice 3.5, B50)
New `StrokeResultPanel` SwiftUI view sliding up from bottom after ball stops. Shows:
- distance struck (m + ft, colour-coded as B42)
- face angle (deg)
- Mario Kart bucket call (from `Physics/MarioKartAssist.swift`)
- outcome: drained / lipped out / short / long

**"Putt again"** loops back to `.readyForStroke` (preserving ball + hole + calibration). **"Reset all"** drops to `.waitingForPlane`. Auto-dismisses after 6 s. New `.strokeResult` Event.Kind with full payload for analyser correlation.

### 6. Correctable physics
Every stroke logs the FULL chain in JSON:
`addressCalibrated → strokeStarted → peakImpact(v, accel, face) → strokeResult(distance, bucket)`.
So if a stroke "feels wrong" the user taps `📐 Plane wrong` or `🎯 Drifted` GT marker AND the JSON contains the exact sensor readings that produced the bad result. Recoverable from data alone — no "ghost in the machine" putts.

### 7. Clear instructions + simple intuitive UX
Every state transition shows ONE clear instruction at the bottom HUD. Examples:
1. "Tap to place ball"
2. "Tap to place hole"
3. "Tap Set address when you're ready"
4. "Stay still..."
5. "Make your putting motion"
6. "Roll!" (during animation)
7. "Result"

**Maximum 8 words per instruction.** No tutorials needed — every state is self-explanatory from the on-screen affordance. Test: a first-time user installs the app, hits AR Slice, and putts within 60 seconds without external guidance.

### 8. iPhone 13 Pro Max verified at Gemini ≥ 8/10 (per slice)
After B50 ships, James installs + records a full session (place → calibrate → 3 putts at different distances/strengths → exercise Move ball + Move hole → exit). Run:
```
py -3.12 c:\tmp\gemini_stage3_direct.py <mp4>
```
…against `c:\tmp\gemini_stage3_prompt.txt` (which checks: does the address marker make sense, did stroke detection fire at the right frame, does the roll physics look physically plausible, does the result panel match the JSON, are the user instructions clear and self-explanatory). Goal closes only when EACH of the 5 slices scores ≥ 8/10 in Gemini's frame-by-frame.

### 9. B45 hole + ball lighting MUST keep working in every Stage 3 build
B45 fixed the PhysicallyBasedMaterial lighting bug by enabling `environmentTexturing = .automatic` + adding an `AREnvironmentProbeAnchor`. Every Stage 3 build (B46–B50) must preserve those changes — verified in the Gemini pass by re-scoring the hole render at ≥ 7/10 (vs B44's 3/10). If any Stage 3 commit accidentally reverts the lighting config, fix BEFORE proceeding to the next slice.

---

## Non-goals (locked, do NOT touch)

- B45 placement code (ball + hole + LiDAR + lighting) is FROZEN — Stage 3 is purely additive
- Hole + ball geometry stays at B40/B44 spec — only animations on top
- No Apple Watch, no external accessory
- No break detection / curved putts (Stage 4)
- No multiple holes / driving range (v1.1)
- No async multiplayer (v1.1+)
- No tutorial / onboarding flow — UX must be self-explanatory

## Constraints

- iPhone-only, iOS 17+, Swift 6 strict concurrency
- Test on real iPhone 13 Pro Max (simulator has no IMU + no LiDAR per CLAUDE.md §7)
- Use existing services — DO NOT reimplement:
  - `Sensors/StrokeDetector.swift`
  - `Physics/BallPhysics.swift`
  - `Physics/MarioKartAssist.swift`
  - `Physics/DistanceModel.swift`
  - `Calibration/CalibrationCoordinator.swift`
  - `Models/StrokeResult.swift`
  - `Storage/StrokeHistoryStore.swift`
- All new `PlacementState` cases must preserve `Equatable + Sendable`
- All new logger events must include enough payload to recover the stroke from JSON alone

## Gating

Durable artifact: `docs/stage-3-verification.md` with Gemini's per-slice scores + the 60-second-first-putt test result + the hole-regression check.

Goal hook should block until that file exists with:
- All 5 Stage 3 slices ≥ 8/10
- Hole render still ≥ 7/10 (no B45 regression)
- 60-second first-putt test result documented

Plan: `docs/stage-3-plan.md` (already written) is the implementation guide.
