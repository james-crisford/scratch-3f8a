# Putting Lab v1 — Master Spec (FINAL)

*Generated: 2026-05-29 | Supersedes earlier draft | Status: ready for goal-prompt assembly*

This is the **single source of truth** for what we are building. It absorbs:
- 5 prior research reports
- The "no physical ball" correction
- All locked James decisions as of 2026-05-29
- The Wii-Golf release-at-bottom-of-arc impact model

The goal-prompt that drives the actual build will reference this document. Nothing here should need re-deriving.

---

## Quick orientation — the 60-second pitch

> The user holds an iPhone vertically in their lead hand like a putter grip. They hold it still and aim at a virtual hole on the screen; the app silently calibrates (locks magnetometer + ARKit + gravity references). They make a putting motion through the air. There is no physical ball. The app detects the bottom of the swing arc (peak forward hand speed) as the "impact moment", reads the phone's orientation at that exact instant relative to the target line locked at address, and produces a believable ball-roll animation with a Mario-Kart-style direction call that's generous when the signal is unclear. The result shows distance, tempo, and an honest face-direction read. 5-stroke calibration onboarding personalises everything.

That sentence is the whole product. Every UI, sensor, and math decision below serves it.

---

## Section 1 — Locked decisions (do not re-litigate)

| # | Decision | Rationale | Source |
|---|---|---|---|
| 1 | iPhone-only v1 | James call | session |
| 2 | No Apple Watch, no accessory | James call | session |
| 3 | Mode B — attempt direction (not training aid) | James call — "fun semi-realistic game" | session |
| 4 | Mario Kart-style assist (snap-to-square when uncertain) | James call | session |
| 5 | Auto-address — silent stillness-triggered calibration | James call | session |
| 6 | Baby steps — no AR ground plane in v1; 2D top-down result | James call | session |
| 7 | Phone orientation: vertical in lead hand, screen-facing-user, back-camera-facing-direction-of-swing | Research #5 Orientation D | report 5 |
| 8 | NO PHYSICAL BALL — phone-only swing-in-air mechanic | James correction 2026-05-29 | session |
| 9 | Impact moment = peak forward hand speed at bottom of arc (Wii Golf-style) | James call | session |
| 10 | Build language: Swift + SwiftUI | Research #4 | report 4 |
| 11 | iOS minimum: **17.0** (override needs justification) | Wider TAM, sufficient APIs | report 4 + James leaning |

---

## Section 2 — Physics model (what we are actually measuring)

### 2.1 Ball direction model (honest version)

In real putting, ball start direction is ~83% determined by face angle at impact, ~17% by club path. We are NOT measuring a real ball; we are simulating one. So we use a simplified model:

```
displayed_start_direction (°) = face_angle_at_impact (°)
displayed_distance (ft)       = f(hand_speed_at_impact, user_calibration_constant)
```

Where `face_angle_at_impact` is the yaw component (rotation about the gravity axis) of the phone's attitude **at the moment of peak forward hand speed**, relative to the target-line reference locked during the address pose.

### 2.2 What the IMU can deliver — honest envelope (revised post-audio-loss)

Without audio impact precision, we lose ~10ms of timing accuracy. This degrades face-angle measurement at impact. Revised envelope vs Research #5:

| Metric | Confidence | Notes |
|---|---|---|
| Stroke tempo (backswing-to-forward ratio) | **±10–20 ms** | Excellent — unaffected by ball loss |
| Backswing length (angle) | **±2–3°** | Excellent |
| Peak hand speed | **±5–10%** | Good |
| Face angle at peak-forward-speed moment | **±10–15°** | Was ±5–10° with audio; now wider |
| Estimated ball roll distance | **±15–25%** after calibration | Acceptable for game feel |

These widened error bars are why the Mario Kart assist (Section 5) is mandatory. We are not measuring; we are *simulating with a credible direction bias*.

### 2.3 The Wii-Golf impact detection model

The user swings the phone through an arc. There is no physical strike, so we define "impact" as the kinematic moment that maps to where a real ball would have been struck:

**Definition:** Impact moment = the timestamp at which the phone's forward hand-velocity (component along the swing's principal axis) reaches its peak after the start of the forward stroke and before deceleration begins.

**Detection algorithm (real-time):**

```
1. After STROKE start detected (Section 3 phase 4):
2. At each IMU sample (100Hz):
     a. Compute device_velocity_vector by integrating user_acceleration since stroke start.
     b. Project velocity onto the swing-plane forward axis (derived at calibration from user's reference strokes — Section 6).
     c. Track magnitude of this projection.
3. Watch for a peak: forward_speed_magnitude rises, plateaus, then falls.
4. Impact_moment = timestamp at peak (use parabolic interpolation across the 3 samples around the peak for sub-sample resolution).
5. Read phone attitude_quaternion at impact_moment (interpolate between surrounding samples).
6. Compute yaw at impact relative to target-line reference (locked at address).
7. That yaw delta = face_angle_at_impact.
```

**Why this works:** in a real putt the club is moving fastest at the bottom of the arc, right at ball contact. In a phone-only swing the user's hand follows the same kinematic pattern. The peak of forward hand speed is the natural analog of impact and is well-defined in the IMU signal even without an audio event.

**Failure modes + mitigations:**
- *Multiple peaks (jerky stroke)* → take the first peak after a sustained acceleration phase.
- *Very slow stroke (no clear peak)* → fall back to the midpoint of the forward phase (start_of_forward to end_of_forward).
- *No detectable forward phase* → reject the stroke; show "didn't catch that, try again".

### 2.4 What the magnetometer gives us (the real unlock)

During the 800ms address pose:
- Lock a reference yaw `yaw_target = fused_yaw_from_magnetometer_and_gyro`.
- During the swing, track yaw relative to `yaw_target`.
- At impact, `face_angle_raw = current_yaw - yaw_target`.

This is the technique that makes face-angle measurement honest — GolfGo doesn't do it.

### 2.5 What ARKit gives us (the drift killer)

`ARWorldTrackingConfiguration` runs visual-inertial odometry. Its `ARCamera.transform` gives sub-degree-accurate orientation, much better than raw CoreMotion integrated yaw.

During address: lock `arkit_yaw_target` from the same reference moment.
During swing: at each sample, compute `arkit_yaw_delta`.
At impact: `face_angle = arkit_yaw_delta_at_impact - magnetometer_target_offset`.

If ARKit loses tracking briefly during the fast downswing (Apple docs flag this — fast motion is a known degradation), fall back to magnetometer + gyro for that window only. ARKit reconverges within ~100ms after the swing ends.

### 2.6 Distance model

```
ball_speed_in_ft_per_sec = peak_forward_hand_speed_m_per_s * user_speed_to_ball_constant * 3.281
ball_roll_distance_ft    = ball_speed_in_ft_per_sec^1.6 / friction_constant
displayed_distance_ft    = ball_roll_distance_ft * (1 + random_jitter(-0.1, +0.1))
```

`user_speed_to_ball_constant` is set during the 5-stroke calibration (Section 6).
`friction_constant` is a fixed game constant tuned by feel during testing.

Distance always shows ±15% confidence band: *"18 ft (est. 15–21 ft)"*.

---

## Section 3 — The 6-phase stroke loop (exact UX)

### Phase 1: ARM

**State:** App launched or returning from a completed stroke.

**Continuously running:**
- CoreMotion `CMDeviceMotion` stream at 100Hz (queued to a 4-second ring buffer).
- ARKit `ARWorldTrackingConfiguration` session active, low-power profile.

**UI:**
- Top: distance picker — 3ft / 6ft / 10ft / 20ft / Free.
- Centre: simple ball + flag illustration. Ball glows when ready.
- Bottom: instruction text: "Hold phone vertically, aim at the hole, hold still".

**No buttons. No tap-to-start. The whole UI is one screen.**

### Phase 2: ADDRESS (auto-calibration)

**Trigger:** for **800ms continuous**:
- `|deviceMotion.rotationRate|` < 5°/s
- `|deviceMotion.userAcceleration|` < 0.2 m/s²
- Phone within ±15° of vertical (gravity vector check)

**Actions, in order:**
1. Snapshot `deviceMotion.attitude.yaw` → `yaw_target_compass`.
2. Snapshot `arCamera.transform` → extract Euler yaw → `yaw_target_arkit`.
3. Snapshot `deviceMotion.gravity` → `gravity_reference`.
4. Note start timestamp `address_lock_time` (mach_absolute_time).
5. Start the IMU "session window" recording into a dedicated stroke buffer (overwriting the ambient ring buffer).
6. Fire one `UIImpactFeedbackGenerator(style: .medium)` haptic tick.
7. UI feedback: progress ring around the ball fills smoothly during the 800ms. NO text saying "calibrating" — keep it silent.

**Exit conditions:**
- → READY (immediately on lock).
- → ARM (if stillness broken during the 800ms — silently re-arm; no error).

### Phase 3: READY

**State:** Address locked, awaiting stroke.

**UI:**
- Progress ring stays full.
- Ball icon glows.
- Text fades in below: "Aimed" (subtle).

**Watching for:**
- Stroke start: `|deviceMotion.rotationRate|` > 30°/s sustained for >50ms → Phase 4.
- Re-address: extended stillness → stay in READY.
- Massive movement (user lowered phone, picked up call etc.): timeout 15s → ARM.

### Phase 4: STROKE (motion capture)

**Trigger:** detected at end of Phase 3.

**Recording continues:** all IMU samples + ARKit poses streamed into the stroke buffer.

**End-of-stroke detection (either condition triggers Phase 5):**
- `|rotationRate|` < 30°/s for 300ms continuous, OR
- 2-second hard cutoff from stroke start.

**UI during stroke:**
- **Nothing changes.** Do not animate, do not show timers. The user isn't looking at the screen during the stroke. Don't break the focus.

**What's being captured (in the stroke buffer):**
- IMU at 100Hz: rotationRate (3-axis), userAcceleration (3-axis), attitude quaternion, gravity.
- ARKit poses at 60Hz: ARCamera.transform.
- Timestamps via mach_absolute_time on every sample.

### Phase 5: IMPACT DETECTION + RESULT COMPUTATION

**Triggered at end of Phase 4. All compute happens in <50ms (it's fast).**

Algorithm (executed sequentially):

```
1. Identify swing-plane forward axis from the stroke buffer:
   - Take all IMU samples from stroke start to end.
   - Compute principal axis of userAcceleration via PCA.
   - Forward axis = direction of largest variance (the swing plane).

2. Compute device_velocity at each sample:
   - Integrate userAcceleration along forward axis since stroke start.
   - Subtract drift via end-of-stroke velocity → ~0 calibration.

3. Find peak forward velocity:
   - Smooth the forward_velocity trace with a 5-point moving average.
   - Find max index. Call it impact_sample.

4. Parabolic-interpolate around impact_sample for sub-sample timestamp:
   impact_time = parabolic_interp(impact_sample-1, impact_sample, impact_sample+1)
   impact_attitude = slerp_interp(attitude_at_samples_around(impact_time))

5. Compute face angle:
   yaw_at_impact_compass = euler_yaw(impact_attitude)
   yaw_at_impact_arkit   = euler_yaw(arkit_pose_at_time(impact_time))
   
   face_angle_raw = yaw_at_impact_arkit - yaw_target_arkit
   
   // If ARKit tracking was lost during the swing, fall back:
   if (arkit_tracking_lost) {
       face_angle_raw = (yaw_at_impact_compass - yaw_target_compass)
   }

6. Compute hand speed:
   peak_forward_speed = forward_velocity[impact_sample]
   hand_speed_mps = peak_forward_speed * user_speed_calibration_factor

7. Compute tempo:
   backswing_duration = (peak_backswing_time - stroke_start_time)
   forward_duration   = (impact_time - peak_backswing_time)
   tempo_ratio        = backswing_duration / forward_duration

8. Apply Mario Kart bucket mapping (Section 5):
   face_angle_displayed = bucket(face_angle_raw)

9. Apply distance model (Section 2.6):
   ball_distance = distance_model(hand_speed_mps, user_distance_calibration)
```

### Phase 6: ROLL (the result animation)

**View:** 2D top-down. Ball animates from start position along a curve to its resting position.

**Curve shape:**
- Start direction = `face_angle_displayed` (in degrees from target line).
- Length = `ball_distance`.
- Curve = slight quadratic Bezier with control point biased by face angle * 0.4 (gives a believable arc).

**Numbers shown after the roll completes:**
- **Distance**: large — `18 ft (est. 15–21 ft)`
- **Face at impact**: text + colour-coded chip — e.g. `Square ✓` (green) / `Pull 6°` (yellow) / `Miss left` (red)
- **Tempo**: ratio with subtle context — `2.1 — your norm`

**Haptic:**
- If "make" (within hole radius + distance match): `UINotificationFeedbackGenerator(success)` + small celebration animation.
- If clear miss: subtle `UISelectionFeedbackGenerator` tick.

**Replay button:** small icon — re-runs the 2D roll animation.

**Auto-advance:** 3 seconds after ball stops → back to Phase 1 (ARM).

---

## Section 4 — The address pose & calibration locks (deep dive)

The address pose is the most important moment in every stroke. It is the *only* time we get to anchor our reference frames. Below is exactly what gets locked and why.

### 4.1 The 800ms stillness window

A 800ms window is long enough to:
- Get a stable magnetometer reading (mag updates at ~10Hz; needs ~3 readings for noise rejection).
- Let ARKit world tracking converge if it was drifting.
- Give the user a moment of natural "settling" before the stroke.

It is short enough to:
- Not feel laggy or break flow.
- Match a real golfer's natural pre-shot routine.

### 4.2 What we lock (and how we use it later)

| Locked value | Source API | Used for |
|---|---|---|
| `yaw_target_compass` | `CMDeviceMotion.attitude.yaw` (using `CMAttitudeReferenceFrame.xMagneticNorthZVertical`) | Backup face-angle reference if ARKit loses tracking |
| `yaw_target_arkit` | `arSession.currentFrame.camera.transform` → Euler yaw | Primary face-angle reference (drift-corrected) |
| `gravity_reference` | `CMDeviceMotion.gravity` | Defines "up" for the user's grip; used to project rotation onto yaw axis |
| `address_lock_time` | `mach_absolute_time()` | Anchor timestamp for everything that follows |
| `pre_swing_imu_baseline` | mean of last 200ms of IMU samples | Used to detect stroke start cleanly above baseline noise |

### 4.3 Re-addressing

If the user breaks stillness during the 800ms (e.g. adjusts grip), the address window silently resets. No error message, no haptic — just the progress ring shrinks back. They naturally hold still again and it re-fills.

This is the "auto-address" mechanic from James's decision — invisible.

---

## Section 5 — Mario Kart assist (the game-feel layer)

Raw face angle is honest. The *displayed* direction is generous. This is what makes the game fun and what distinguishes us from GolfGo's "confidently wrong" failure mode.

### 5.1 The bucket mapping (post-audio-loss, wider buckets)

```
|face_angle_raw| < 6°       →  "Square"           (snap to 0° displayed)
6°  ≤ |raw| < 12°            →  "Slight pull/push" (display 4–8° curve)
12° ≤ |raw| < 20°            →  "Pull/Push"        (display 12–18° curve)
|face_angle_raw| ≥ 20°       →  "Miss"             (display 20–30° curve, capped)
```

(For a right-handed user: negative raw = closed face = pull left.)

### 5.2 Confidence-low snap-to-square

If any of the following are true, snap face_angle_displayed to "Square" regardless of raw value:
- ARKit tracking was lost during >50% of the stroke window.
- Stroke duration < 200ms (too fast — probably a flick, not a stroke).
- No clear forward-velocity peak (no obvious impact moment).
- Peak hand speed < 0.3 m/s (barely moved — probably a misfire).

The user gets *"Didn't catch a clean read — recorded as straight"* in subtle small text, only on the result screen.

### 5.3 Always surface the cause, not just the result

After the roll, show:
- "Square ✓" — face was within 6° of target
- "Pull 6° — face was closed at impact" — *the cause*
- "Long by 4 ft — slightly fast through impact" — *the cause*

This is the Wii Sports Tennis rule from Research #5. Surfacing the cause makes the user feel like the app *sees them*, even when the measurement is rough.

### 5.4 The three Wii-Sports-Tennis design rules (research #5)

1. **Err toward square when uncertain.** Never call a direction when confidence is low.
2. **Surface cause, not just result.** Why it went left, not just that it went left.
3. **Never invent direction the user clearly didn't produce.** If the IMU says barely-rotated, don't show a hook to "add variety".

---

## Section 6 — Calibration onboarding (5 strokes)

Runs once per user. Re-runnable from Settings. Required before first practice session.

### 6.1 The flow

**Screen 1:** "Let's tune the app to your stroke. Take 5 comfortable putts at the same imaginary target. Don't worry about result — we're learning *you*."

**Screens 2–6 (one per stroke):** Same 6-phase loop as practice, but with these differences:
- After each stroke: just a checkmark and "Captured ✓ — 3 more". NO direction call, NO distance, NO judgement.
- Buffer the stroke's full IMU + ARKit data for batch processing at the end.

**Screen 7:** "Tuning your model…" with a real spinner (1–2 seconds — yes, here it's fine to show progress). Then:

**Screen 8:** "You're set! Your tempo: **2.1** — quick and consistent. Distance feel: smooth. Let's go."

### 6.2 What gets computed at end of calibration

| Computed value | How | Used for |
|---|---|---|
| `user_tempo_baseline` | Mean tempo ratio across 5 strokes | Compare future strokes against "your norm" |
| `user_speed_calibration_factor` | Mean peak forward hand speed → assumed target distance | Distance model constant |
| `user_distance_calibration` | Inverse of the above — speed to distance | Used in every future stroke |
| `user_face_bias` | Mean of `face_angle_raw` across 5 strokes (NOT corrected) | If user systematically pulls/pushes, this subtracts the bias |
| `user_audio_clarity_score` | (omitted — no audio in v1) | n/a |
| `user_swing_plane_axis` | Mean principal axis of userAcceleration across the 5 strokes | Used to project forward velocity in future strokes |
| `arkit_baseline_stability` | Mean ARKit pose drift during the 5 strokes | If low, downweight ARKit and rely on compass |

Stored in `UserDefaults` under a `CalibrationProfile` struct.

### 6.3 Ongoing recalibration

At end of every practice session: prompt "Tune sharper? (+3 strokes)". Adds 3 strokes to the rolling calibration profile (running mean). Optional, never required.

---

## Section 7 — Sensor stack & iOS APIs (the build manifest)

| Sensor / Feature | iOS API | Sample rate / detail | Notes |
|---|---|---|---|
| Gyroscope + accelerometer + attitude | `CMMotionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to:)` | 100Hz | The magnetic-north reference frame fuses magnetometer in automatically |
| Magnetometer (raw access for diagnostics) | `CMMotionManager.startMagnetometerUpdates(to:)` | ~10–50Hz | Mostly NOT used directly — the fused yaw above is the primary signal |
| ARKit world tracking | `ARWorldTrackingConfiguration` | 60Hz pose updates | Low-power profile; `planeDetection = []` (no plane detection needed in 2D version) |
| Haptics | `UIImpactFeedbackGenerator(style:)` `UINotificationFeedbackGenerator()` | event-driven | Address lock + make feedback |
| 2D rendering | SwiftUI `Canvas` + animation | 60fps | Ball roll animation |
| Storage | `UserDefaults` for calibration profile + session history | n/a | No backend in v1 |

**Explicitly NOT in v1:**
- `AVAudioEngine` / microphone (no audio impact detection — there's no ball)
- `AVCaptureSession` 240fps camera (no ball to track)
- LiDAR `ARSceneReconstruction`
- `WatchKit`
- Any networking — no leaderboards, no friend mode, no sign-in.

---

## Section 8 — UI screens & component breakdown

### Screen 1: Practice

```
┌─────────────────────────────────┐
│  [3]  [6]  [10]  [20]  [Free]   │  ← Distance picker (segmented)
│                                  │
│                                  │
│                                  │
│            ╭───╮                 │  ← Hole illustration (top-down)
│            │ ● │                 │     showing flag
│            ╰───╯                 │
│                                  │
│                                  │
│            (○)                   │  ← Ball icon at bottom
│         [ring filling]           │     with progress ring overlay
│                                  │
│      Hold phone steady           │  ← Instruction (auto-changes
│      Aim at the hole             │     based on phase)
│                                  │
└─────────────────────────────────┘
```

**Phase-driven instruction text:**
- ARM: "Hold phone vertically, aim at the hole"
- ADDRESS (during 800ms): instruction fades, ring fills
- READY: "Aimed" (subtle, small)
- STROKE: instruction hidden (no UI updates)
- IMPACT/ROLL: result panel slides up

### Screen 2: Result (slides up over Practice screen)

```
┌─────────────────────────────────┐
│  ←  Next                         │  ← Auto-advances in 3s
│                                  │
│       18 ft                      │  ← Distance, large
│       est. 15–21 ft              │     with band, small
│                                  │
│   ┌──────────────────┐           │
│   │   [Square ✓]      │          │  ← Face chip, colour-coded
│   └──────────────────┘           │
│                                  │
│   Tempo: 2.1 — your norm         │  ← Tempo line
│                                  │
│   ┌──────────────────────┐       │
│   │  ↻ Replay            │       │  ← Replay button
│   └──────────────────────┘       │
│                                  │
│   [animated 2D ball trail        │  ← The roll visualisation
│    shown on the green]           │
│                                  │
└─────────────────────────────────┘
```

### Screen 3: Calibration onboarding (linear sequence)

5 screens, each = Practice screen with overlay: "Stroke 1 of 5 — take a comfortable putt". No result shown between strokes.

Final screen: summary with user's tempo, "you're set" message.

### Screen 4: Settings (minimal)

- Recalibrate (re-runs onboarding)
- About / version
- That's it.

---

## Section 9 — File / module structure (Swift project)

```
PuttingLab/
├── App/
│   └── PuttingLabApp.swift              // SwiftUI App entrypoint
├── Models/
│   ├── StrokeBuffer.swift               // Ring buffer for IMU + ARKit samples
│   ├── CalibrationProfile.swift         // Codable, stored in UserDefaults
│   ├── StrokeResult.swift               // Distance, face angle, tempo, raw + displayed
│   └── PhaseState.swift                 // Enum: arm, address, ready, stroke, impact, roll
├── Sensors/
│   ├── MotionManager.swift              // Wraps CMMotionManager, 100Hz stream
│   ├── ARTrackingManager.swift          // Wraps ARSession, exposes pose stream
│   ├── StillnessDetector.swift          // 800ms address-pose detector
│   ├── StrokeDetector.swift             // Start/end stroke threshold detector
│   └── SensorSyncClock.swift            // mach_absolute_time helpers
├── Physics/
│   ├── ImpactDetector.swift             // Peak-forward-velocity finder + parabolic interp
│   ├── FaceAngleComputer.swift          // Yaw delta vs target line, with ARKit/compass fusion
│   ├── DistanceModel.swift              // Hand speed → ball distance with calibration
│   ├── TempoComputer.swift              // Backswing/forward ratio
│   └── MarioKartAssist.swift            // Bucket mapping + confidence-snap-to-square
├── Calibration/
│   ├── CalibrationCoordinator.swift     // Manages 5-stroke onboarding flow
│   └── CalibrationModel.swift           // PCA, mean calculations
├── UI/
│   ├── PracticeView.swift               // Main loop screen
│   ├── ResultPanelView.swift            // Slides up after stroke
│   ├── RollAnimationView.swift          // 2D Canvas ball animation
│   ├── ProgressRingView.swift           // Address pose ring
│   ├── DistancePickerView.swift         // Segmented picker
│   ├── CalibrationFlowView.swift        // Onboarding sequence
│   └── SettingsView.swift               // Minimal settings
├── Storage/
│   └── ProfileStore.swift               // UserDefaults wrapper
└── Resources/
    └── Assets.xcassets                  // Ball, flag, app icon
```

---

## Section 10 — 2-week sprint plan (day-by-day)

### Week 1: Sensors + impact detection (the hard half)

**Day 1: Project setup + IMU foundation**
- Create Xcode project (iOS 17.0 minimum, SwiftUI).
- Add `MotionManager.swift` — start `CMDeviceMotion` updates at 100Hz with `.xMagneticNorthZVertical` reference frame.
- Add `StrokeBuffer.swift` — fixed-size ring buffer (5 seconds at 100Hz = 500 samples).
- Tiny test view that prints rotation rate + acceleration to console.
- ✓ Done when console shows clean 100Hz stream.

**Day 2: ARKit foundation**
- Add `ARTrackingManager.swift` — `ARWorldTrackingConfiguration`, no plane detection.
- Stream poses at 60Hz.
- `SensorSyncClock.swift` — verify mach_absolute_time can be queried from both motion and ARKit callbacks.
- ✓ Done when console shows time-aligned motion + AR streams.

**Day 3: Address-pose stillness detector**
- `StillnessDetector.swift` — gyro magnitude + accel magnitude + verticality check.
- 800ms continuous window.
- On lock: capture all reference values (compass yaw, ARKit yaw, gravity).
- ✓ Done when holding phone still for 800ms reliably triggers a console log.

**Day 4: Stroke detector + end-of-stroke**
- `StrokeDetector.swift` — 30°/s threshold to start, return-to-stillness or 2s cutoff to end.
- Buffer the stroke window into a separate `StrokeData` object.
- ✓ Done when swinging the phone reliably segments a stroke.

**Day 5: Impact detection algorithm**
- `ImpactDetector.swift` — PCA on userAcceleration to find forward axis.
- Integrate velocity along forward axis.
- Smooth + find peak + parabolic interpolation.
- ✓ Done when log shows a believable impact timestamp for each test stroke.

**Day 6: Face angle computation**
- `FaceAngleComputer.swift` — yaw delta from target line.
- ARKit-primary, compass-fallback logic.
- ✓ Done when intentionally rotating the phone left or right between address and stroke produces the expected face_angle_raw.

**Day 7: Buffer + glue + first end-to-end console test**
- Wire everything: ARM → ADDRESS → READY → STROKE → IMPACT → log result.
- No UI yet — just print results to console.
- ✓ Done when 10 sequential strokes produce 10 plausible (distance, face angle) tuples in the console.

### Week 2: UI + game feel + calibration

**Day 8: PracticeView shell**
- SwiftUI screen: distance picker, ball/flag illustration, instruction text.
- Phase-state-driven instruction text changes.
- ProgressRingView animating during address.
- ✓ Done when the UI matches Section 8 Screen 1 in all phases.

**Day 9: Result panel + roll animation**
- ResultPanelView slides up after stroke.
- RollAnimationView with 2D Canvas ball trail.
- Curve generation from face angle + distance.
- ✓ Done when after a real stroke, the ball animates with a believable curve.

**Day 10: Mario Kart assist**
- `MarioKartAssist.swift` — bucket mapping + confidence-snap-to-square rules.
- All 4 fallback conditions wired.
- "Surface the cause" text generation.
- ✓ Done when intentionally swinging straight reliably shows "Square ✓"; intentionally pulling shows "Pull X°".

**Day 11: Distance model + tempo**
- `DistanceModel.swift` with placeholder calibration constants.
- `TempoComputer.swift` — backswing/forward ratio.
- Wire into result display.
- ✓ Done when distance feels in the right ballpark + tempo numbers look right.

**Day 12: Calibration onboarding**
- `CalibrationCoordinator.swift` + `CalibrationFlowView.swift`.
- 5 sequential strokes, batch process at end.
- Store `CalibrationProfile` in UserDefaults.
- ✓ Done when fresh install → 5 strokes → personalised constants live.

**Day 13: Polish + haptics + edge cases**
- Haptic on address lock + result.
- Re-address silent reset.
- Stroke too fast / too slow / no peak → "didn't catch that".
- Timeout from READY back to ARM after 15s.
- ✓ Done when edge cases all behave gracefully.

**Day 14: Real-world testing + tuning**
- Take a real putter + phone and test 30+ strokes outdoors and in.
- Tune Mario Kart bucket thresholds based on feel.
- Tune address-pose timing (might want 600ms or 1000ms based on feel).
- Build a TestFlight build.
- Share with 1–2 golfer friends + James.
- ✓ Done when 4 of 5 strokes produce a believable result and the loop feels natural.

### End of week 2: v1 is shippable to internal testers.

---

## Section 11 — Open decisions for James before goal-prompt

These are the ones I still need answers on. Everything else is locked.

1. **Confirm iOS minimum = 17.0** ← my recommendation
2. **App working name** — "PuttLab" placeholder OK?
3. **Repo location** — new private GitHub repo? Local-only? Where does the Swift code live?
4. **First testers** — who beyond you?
5. **Acceptance signal** — at end of week 2, what's "good enough to keep going"? My suggestion: 4-of-5 strokes feel believable to a golfer (Section 1 success criteria).

---

## Section 12 — What the goal-prompt will need to reference

When we assemble the goal-prompt, it must load/cite:

**Spec documents (read fully):**
- This file: `golfgo-spec-putting-lab-v1-FINAL-2026-05-29.md`

**Research reports (cite as background, may be referenced):**
- `golfgo-research-1-imu-swing-physics-2026-05-28.md` (physics envelope)
- `golfgo-research-4-arkit-realitykit-feasibility-2026-05-28.md` (iOS feasibility)
- `golfgo-research-5-multisensor-swing-detection-2026-05-29.md` (sensor patterns)
- `golfgo-synthesis-cross-cut-2026-05-29.md` (overall context)

**Skills to invoke (to be created via skill-creator BEFORE goal-prompt):**
- `ios-native-golf-app` — Swift / SwiftUI / CoreMotion / ARKit / haptics conventions specific to this project
- `golf-swing-physics` — physics constants, calibration model, Mario Kart bucket math, Wii Sports design rules

**External docs to fetch as needed (via WebFetch / firecrawl):**
- developer.apple.com — `CMMotionManager`, `CMDeviceMotion`, `ARWorldTrackingConfiguration`, `ARCamera`, `UIImpactFeedbackGenerator`, SwiftUI `Canvas`
- Apple WWDC sessions on ARKit + CoreMotion

**No external code dependencies in v1.** No Firebase, no Supabase, no Swift packages beyond what Xcode ships with.

---

## Section 13 — Risks & how we mitigate

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Impact detection (peak forward velocity) is noisier than expected | Medium | High — wrong impact moment = wrong face angle | Day 5 is reserved for exactly this; if noisy, add Kalman smoothing or learn personal "release point" pattern |
| ARKit drift / loss during fast strokes | Medium | Medium | Compass-yaw fallback wired; spec already accounts for this |
| Mario Kart buckets feel patronising (too generous) or too punitive (too tight) | High | Medium | Day 14 is tuning; thresholds are constants we adjust by feel |
| Distance estimate feels random | Medium | Medium | 5-stroke calibration nails the per-user constant; jitter is bounded ±10% |
| Stroke detection mis-triggers from incidental motion (walking, picking up phone) | Medium | Low | Require stillness BEFORE stroke detection arms |
| User holds phone in unexpected orientation | Low | Medium | Verticality check in stillness detector rejects orientations >15° off vertical |
| Phone in pocket triggers stroke detection randomly | Low | Low | App backgrounds → sensors stop; not an issue in-session |

---

## Section 14 — Definition of done for v1

v1 ships when ALL of these are true:

1. Fresh install → calibration → first practice session works end to end without crashing.
2. 10 sequential strokes produce 10 plausible (distance, face, tempo) results.
3. Mario Kart assist is tuned: a golfer testing it says "feels about right" 4 of 5 strokes.
4. Address auto-lock works silently and reliably (no taps to start a stroke).
5. Roll animation reads as believable golf (not robotic, not random).
6. App handles all edge cases from Section 13 without errors visible to the user.
7. Build runs on iPhone 12 through iPhone 17 (test 1 lower-end, 1 newer).
8. TestFlight build shared with at least 2 testers beyond James.

If any of these fail at end of week 2, we extend by up to 1 week. If still failing, we revisit the spec.

---

*This spec is the contract. Anything we change later goes in v1.1, not v1.*
