# Stage 3 — From AR Placement to Actual Putting

**Where we are (end of Stage 2 / B45):**
- AR placement of ball + hole is rock-solid (LiDAR mesh, persistence 10/10, gold-rim cup, dimpled ball)
- All instrumentation in place for Gemini verification (180-event JSON, materialApplied/meshStats/lightEstimate)
- Move ball / Move hole UX works clean
- TestFlight pipeline is one push from a signed IPA in 15 min

**What Stage 2 still ISN'T:**
- You can place a ball + hole. You can't actually putt.
- Stroke detection lives in `Sensors/StrokeDetector.swift` but is NOT wired to the AR view.
- No address-pose calibration shown in AR.
- No "stand here" anchor — you have no idea where to physically position yourself.
- No putt-roll physics visualisation — the ball just sits.

**Stage 3 closes that gap.** When Stage 3 ships, the user can:
1. Place ball + hole (existing)
2. See where to stand (NEW)
3. Make a putting motion through the air (NEW)
4. Watch the ball roll across the AR floor and either fall in, miss, or stop short (NEW)
5. See a result panel with distance / face angle / Mario Kart bucket call (NEW)

---

## Stage 3 — slice list

Five slices, each roughly two TestFlight builds of work (~3 hours each). Ship them in order so we can re-grade at every slice boundary.

### Slice 3.1 — Address-pose marker on the floor

**Goal:** when the user places the ball, render a translucent footprint marker on the floor showing where to stand (1 club-length behind the ball, perpendicular to the aim line).

**Why first:** zero physics involved, pure visual. Validates the visual language for "user-action markers" we'll reuse for stroke-zone affordances. Catches AR-anchor accuracy issues before they're hidden by motion.

**Tech:**
- Two new `ModelEntity`s anchored to the ball: left foot + right foot rectangles (~24×10 cm each)
- Position computed from ball world coord + aim-line normal: `ballPos - aimDir * 0.6m + perpAimDir * ±0.13m`
- Translucent yellow material with strong contact shadow
- Auto-hide once stroke detection begins (Slice 3.4)

**Verification:** Gemini scores the visual; user confirms "yes I'd stand there" on a real putt.

### Slice 3.2 — Address-pose calibration in AR

**Goal:** the existing `Calibration/CalibrationCoordinator.swift` runs in AR view. User holds the phone in putting grip, app captures the address pose (phone orientation + position relative to ball).

**Why second:** stroke detection depends on this. Without a calibrated address pose, "how much the phone moved" is meaningless because we don't know what neutral was.

**Tech:**
- Add a new `PlacementState` case: `.calibratingAddress(ball, hole)`
- Render a phone-icon hologram in AR at the captured address position so the user can SEE what was captured
- Use existing `StillnessLock` to capture pose only when user is still
- Log `addressCalibrated` event with `phone_yaw / pitch / roll` + `phone_to_ball_distance_m`
- Tap "Re-calibrate" to redo

**Verification:** logged orientation matches phone IMU read; placement state transitions cleanly.

### Slice 3.3 — Stroke detection wired

**Goal:** the existing `Sensors/StrokeDetector.swift` runs in AR view. Phone-swing motion is detected. The peak impact frame is identified.

**Why third:** detection needs the calibrated address pose to know "neutral". Detection BEFORE roll physics so we have a confident `impactVelocity` to feed into the physics.

**Tech:**
- Add `PlacementState`: `.readyForStroke(ball, hole, addressPose)` and `.strokeInProgress`
- Subscribe to `StrokeDetector` from the Coordinator (existing service, just needs view binding)
- Log new event kinds: `strokeStarted`, `peakImpact (velocity, accelerometer, faceAngle)`, `strokeEnded`
- Surface a brief "GO" affordance (small SF Symbol pulse on the ball) when address-pose held still for 1 s
- Surface a "STROKE" pulse on the ball when peak impact detected

**Verification:** Gemini sees the swing → stroke event → physics happen at the right wall-clock instant.

### Slice 3.4 — Putt-roll physics in AR

**Goal:** ball physically rolls across the AR floor from address position toward the hole based on impact velocity, friction model, and the existing `Physics/BallPhysics.swift` + `Physics/DistanceModel.swift`.

**Why fourth:** the visible payoff. Up to now everything was preparation; this is the user seeing the putt actually happen.

**Tech:**
- New `BallRollAnimator` class — runs at 60 Hz, updates `ballAnchor.position` per frame
- Inputs: peak impact velocity + face angle from Slice 3.3; rolling friction coefficient from `μ_r=0.131` (memory-stored)
- Outputs: ball trajectory + whether ball falls in cup + final resting position
- Collision-with-cup test: when ball world-coord is within 5.4 cm horizontally of cup centre AND velocity < 1.5 m/s, snap into cup (visual: ball drops + small bounce)
- Edge case — ball lips out (high speed past the rim) → continues past
- During roll: tail of fading translucent yellow markers shows the actual roll path

**Verification:** ball comes to rest at the predicted distance; Gemini scores the animation realism.

### Slice 3.5 — Result panel + Mario Kart assist

**Goal:** after the ball stops, surface a clean result card overlaying the AR view. Distance struck, face angle, judged direction (Mario Kart bucket per the locked decisions in CLAUDE.md), pass/fail vs the target.

**Why last:** depends on physics output. Once the ball roll is correct, layering the data on top is straightforward UI.

**Tech:**
- New SwiftUI view: `StrokeResultPanel` — renders as a card sliding up from the bottom
- Inputs: `StrokeResult` struct (already defined in `Models/`)
- Mario Kart assist via existing `Physics/MarioKartAssist.swift` (the bucket math is done)
- "Putt again" button → loops back to `.readyForStroke` (preserves ball + hole positions)
- "Reset all" → drops back to `.waitingForPlane`
- Result panel persists ~6 s then auto-dismisses (or until "Putt again" tapped)
- Log new event kinds: `strokeResult` (distance, face, bucket, drained/missed/short/long)

**Verification:** the panel's distance/face match the JSON values for the stroke; Mario Kart bucket call matches user expectation.

---

## Sequencing — when to ship what

Each slice is a single TestFlight build. After each, James plays the build a few times to validate before going to the next. Stages can stack if confidence is high.

| Slice | Build target | Effort | Risk |
|---|---|---|---|
| 3.1 Address-pose marker | B46 | 1 build | Low |
| 3.2 Address calibration | B47 | 1 build | Medium (UX flow) |
| 3.3 Stroke detection wired | B48 | 1 build | Medium (sensor integration) |
| 3.4 Putt-roll physics | B49 | 1 build | High (physics tuning) |
| 3.5 Result panel | B50 | 1 build | Low |

**v1.0 ship target:** when all 5 slices are at Gemini ≥ 8/10 + James says it feels right. Probably at B50–B52 once we iterate Slice 3.4 once or twice.

---

## What's NOT in Stage 3 (deliberately)

- **Break detection / curved putts.** Treated floor as flat throughout Stage 3. Adding slope-aware physics is Stage 4.
- **Multiple holes per session / driving range.** v1.1.
- **Asynchronous multiplayer.** Already designed in memory under `project_puttinglab_async_multiplayer_research.md`. v1.1+.
- **Apple Watch.** Locked iPhone-only.
- **Tutorial / onboarding flow.** v1.0 ships as "open AR → place → calibrate → putt".
- **Stat tracking persistence.** Strokes get logged to the JSON event stream during testing but NOT yet stored in the strokes DB. Wire after Stage 3 lands.

---

## What we need before starting Slice 3.1

Nothing — every dependency is already in the repo:
- `Sensors/StrokeDetector.swift` ✓
- `Physics/BallPhysics.swift` ✓
- `Physics/MarioKartAssist.swift` ✓
- `Physics/DistanceModel.swift` ✓
- `Calibration/CalibrationCoordinator.swift` ✓
- `Models/StrokeResult.swift` ✓
- `Storage/StrokeHistoryStore.swift` ✓

The B45 placement code becomes the platform. Stage 3 wires these existing services into the AR view via new `PlacementState` cases.

---

## What I need from James to start coding Slice 3.1

Just a thumbs-up after the B45 recording lands at Gemini ≥ 7/10 for the hole. If that's a pass, I start Slice 3.1 immediately on the same day. If B45 still has issues with the materials, fix those first before opening a new front.

**Stretch idea worth flagging:** Slice 3.1 could ALSO include the "Phase 1 hand-map 50 features" terrain modelling step from the existing memory (`project_puttinglab_terrain_modelling_research.md`) — capture floor-feature anchors at session start so the physics in Slice 3.4 has true ground-truth positions to roll against. Not required for v1.0 but cheap to add while we're already wiring scene-mesh data.
