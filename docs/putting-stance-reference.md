# PuttingLab — Putting Stance & Grip Reference

> **The locked design.** Cited from `docs/spec-putting-lab-v1-FINAL.md` (§4) and `CLAUDE.md` (§3) +
> the actual runtime thresholds in `Sensors/StillnessDetector.swift`, `Sensors/StrokeDetector.swift`,
> and `Physics/ImpactDetector.swift` as of B50 (0.5.5).
>
> Read this file BEFORE touching any code that affects the address / stroke / impact pipeline.
> Future James + future Claude can both ground here. If something here conflicts with the spec,
> the spec wins — raise it, don't silently deviate.

---

## 1. How the user holds the phone

| Property | Value | Why |
|---|---|---|
| Hand | **Lead hand** | Left hand for right-handed user (the hand closer to the target). Locked decision #2 in CLAUDE.md §3. |
| Orientation | **Vertical** | Phone is upright, mimicking a putter shaft. |
| Screen | **Facing the user** | So they can read instructions + see the AR scene reflected back. |
| Back camera | **Facing the direction of the swing** | Toward the target / hole. The camera feeds the AR view; this is also how ARKit knows where the hole is in world space. |
| Phone Y axis | **Aligned with the putter shaft** | Pointing roughly up. Spec §4 + CLAUDE.md §3 locked decision #2. |
| Phone X axis | **Face normal** | Perpendicular to the target line. Phone X is what determines face open/closed. |

### Why phone-Y is NOT perfectly vertical (the ~20° tilt)

Real putters have a **lie angle around 70°** — the shaft is NOT perfectly perpendicular to the ground. When the user grips the phone like a putter, the phone-Y axis ends up **about 20° off world vertical** to mirror that natural lie angle.

The spec §4.2 originally said "phone within ±15° of vertical". That was tested-and-rejected: real grip poses fell outside 15°. `StillnessDetector` ships with **`minGravityDot = 0.9` ≈ ±25° tolerance** to accept natural grips while still rejecting "user is holding phone flat on the table".

```
cos(25°) ≈ 0.906
minGravityDot: 0.9  // with safety margin for hand tremor
```

---

## 2. The address pose (the silent calibration)

This is **the most important moment in every stroke** (spec §4) — the only time we get to anchor the reference frames.

### The flow (NO BUTTON, INVISIBLE)

1. User naturally walks to where they want to stand
2. User grips the phone in lead hand, vertical, back-camera-toward-target
3. User aims at the hole on the AR screen
4. **User holds still for 800 ms** — passively detected, no UI gate
5. App **silently locks** the address — quietly fills a progress ring as feedback
6. If user breaks stillness, window silently **resets** — no error, no haptic, ring shrinks back
7. User naturally holds still again; ring re-fills

**What we DON'T do** (and B46-B47 violated):
- No "Set address" button to tap
- No "Re-calibrate" affordance
- No phone-icon hologram showing what was captured
- No prescription of WHERE the user stands

The spec calls this "auto-address" and explicitly says it must feel invisible (§4.3).

### What gets locked at 800 ms (spec §4.2)

| Locked value | Source | Used for |
|---|---|---|
| `yaw_target_compass` | `CMDeviceMotion.attitude.yaw` with `.xMagneticNorthZVertical` reference frame | Backup face-angle reference if ARKit loses tracking |
| `yaw_target_arkit` | `arSession.currentFrame.camera.transform` → Euler yaw | Primary face-angle reference (drift-corrected) |
| `gravity_reference` | `CMDeviceMotion.gravity` | Defines "up" for the user's grip; used to project rotation onto yaw axis |
| `address_lock_time` | `mach_absolute_time()` | Anchor timestamp for everything that follows |
| `pre_swing_imu_baseline` | mean of last 200 ms of IMU samples | Lets the StrokeDetector detect stroke start cleanly above baseline noise |

### Why 800 ms

**Long enough to:**
- Get a stable magnetometer reading (mag updates at ~10 Hz; need ~3 readings for noise rejection)
- Let ARKit world tracking converge if it was drifting
- Give the user a moment of natural settling before the stroke

**Short enough to:**
- Not feel laggy
- Match a real golfer's natural pre-shot routine

### Live values in the code

```swift
// Sensors/StillnessDetector.swift
static let maxRotationRateRadPerSec: Double = 5.0 * .pi / 180.0   // 5°/s gyro ceiling
static let maxAccelMagnitude: Double = 0.2                         // 0.2 m/s² accel ceiling
static let minGravityDot: Double = 0.9                             // ~25° verticality tolerance
static let requiredDurationSeconds: TimeInterval = 0.8             // 800 ms still required
```

---

## 3. The swing motion (the "press the phone down")

The putting stroke is a **pendulum motion of the lead arm + putter**. Phone is gripped to the shaft, so phone follows putter.

The user **presses the phone down through the stroke** — back-swing up, then down-and-through accelerating toward the imaginary ball position. The lowest point of the arc = the moment of impact = the moment phone forward velocity peaks.

### Stroke detection chain

**Trigger** (StrokeDetector arms when StillnessDetector emits a lock):

```swift
// Sensors/StrokeDetector.swift
static let startThresholdRadPerSec: Double = 30.0 * .pi / 180.0   // 30°/s rotation rate
static let startSustainSeconds: TimeInterval = 0.050              // 50 ms sustained
static let endQuietSeconds: TimeInterval = 0.300                  // 0.3 s of quiet to end
static let hardCutoffSeconds: TimeInterval = 2.0                  // max stroke duration
```

State machine: `armed → starting → recording → ended`.

**Impact detection** (runs on the closed StrokeWindow):

```swift
// Physics/ImpactDetector.swift
static let minStrokeDurationSeconds: TimeInterval = 0.200
static let minPeakVelocityMps: Double = 0.05
```

The `0.05 m/s` minimum was tuned for **putting-specific** motion. The original Wii-Sports default of `0.30 m/s` was calibrated for full-arm swings and **rejected every real putt**, because putting is mostly **rotation** at the IMU rather than translation (a putting stroke held in a closed hand produces ~0.1-0.2 m/s of linear translation at the IMU).

### Impact moment = peak forward hand velocity (Wii Golf style)

This is locked decision #3 in CLAUDE.md §3. **No physical ball** is being hit; the IMU is the only sensor of impact. Peak forward velocity is the proxy.

---

## 4. After impact — Mario Kart assist

Locked decision #4 in CLAUDE.md §3. **Snap to square when confidence is low. Never confidently wrong.**

```
|face_angle_raw| < 6°         →  "Square"           (snap to 0° displayed)
6°  ≤ |raw| < 12°              →  "Slight pull/push" (display 4–8°)
12° ≤ |raw| < 20°              →  "Pull/Push"        (display 12–18°)
|face_angle_raw| ≥ 20°         →  "Miss"             (display 20–30°, capped)
```

(For a right-handed user: negative raw = closed face = pull left.)

Confidence-low triggers a snap-to-square (spec §5.2):
- ARKit lost tracking for >50% of the stroke
- Stroke duration < 200 ms
- No clear peak velocity
- Peak speed < 0.3 m/s

Wii Sports Tennis 3 rules (CLAUDE.md §4 — non-negotiable):
1. Err toward "Square" when uncertain
2. Surface the cause, not just the result
3. Never invent direction the user clearly didn't produce

---

## 5. What the AR layer ADDS on top (Stage 2 / B40+)

The above (sections 1-4) is the **locked sensor + game-feel design**. The AR placement layer adds:

- Place a virtual ball + hole in world space (B40 / B44 / B45 lighting)
- Render a stance hint — **foot markers** on the floor 60 cm behind the ball (B46). These are **a hint**, NOT a prescription — user stands wherever feels right.
- LiDAR scene reconstruction for the floor mesh (B41)
- Watch the ball roll across the AR floor after impact (B49)
- See the result card (B50)

The AR layer must NEVER override the locked sensor design. Specifically:
- No "Set address" button (B47 was wrong — invisible auto-address is the design)
- No phone-icon hologram showing captured pose (B47 was wrong — captured pose is not user-facing)
- No "Ready" button before swing (B48 was wrong — once stillness lock fires, app is already armed)

---

## 6. The correct end-to-end loop (for B51 forward)

1. User opens AR. LiDAR scans floor.
2. User taps to place ball. Taps to place hole.
3. **Yellow foot markers appear** as a stance hint (B46 — kept, but advisory).
4. User walks to where THEY want to stand.
5. User grips phone in lead hand, vertical, back-camera toward hole (locked decision #2).
6. **Stillness detector is silently running.** Once user holds phone still for 800 ms in proper grip pose, address locks. No button. No haptic at lock. Progress ring may fill quietly as feedback.
7. User swings the phone-as-putter — down-and-through pendulum motion.
8. StrokeDetector picks up the swing automatically. ImpactDetector computes peak velocity + face angle.
9. **Ball rolls** on the AR floor per `BallPhysics.simulatePutt`.
10. User pans camera toward the hole to watch the ball.
11. Result panel slides up with Mario Kart bucket call (B50 — kept).

**No taps required between step 4 and step 11.** That's the design intent.

---

## 7. Common deviations to catch in code review

When the AR / UI layer adds friction the spec didn't want, the spec wins. Watch for:

- ❌ Any modal asking "are you ready?" before swing
- ❌ Any button labelled "Set address" / "Calibrate" / "Ready to swing"
- ❌ Any prescriptive geometry telling the user WHERE to physically stand
- ❌ Any address lock that requires user confirmation (`Re-calibrate` is OK as an escape hatch, but the default path is invisible)
- ❌ Any sensor-derived pose rendered as a user-facing entity (phone hologram, head marker, etc.)

The correct shape is: **passive sensing, single visible affordance (place ball + hole), invisible address lock, instant stroke detection, ball rolls, result card.**

---

## 8. Cited research (for the curious)

- `docs/spec-putting-lab-v1-FINAL.md` §3 (locked decisions), §4 (address pose), §5 (Mario Kart assist)
- `CLAUDE.md` §3 (4 locked decisions), §4 (Wii Sports rules)
- Memory: `project_puttinglab_phone_ergonomics_research` (2026-05-29 v2 — rejected held-phone configurations, confirmed lead-hand-vertical-grip)
- Memory: `project_puttinglab_putter_stroke_research` (Pelz 82/18, Marquardt 2007 SAM PuttLab)
- Memory: `project_puttinglab_high_speed_imu_research` (2026-05-29 "claim vs suppress" UX matrix)
- `golf-swing-game-design` skill (Mario Kart bucket math + Wii Sports Tennis rules)

---

*Last updated: 2026-06-03 — after B47-B48 introduced "Set address" + "Ready" buttons that violated the auto-address design. This reference exists to prevent that drift from happening again.*
