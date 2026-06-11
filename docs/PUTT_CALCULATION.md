# How PuttingLab Calculates a Putt

A walkthrough of every step the app takes between you tapping "press" and the chip telling you "PUSH 4° / 8.2 ft". Written so you can read it cold without knowing the codebase.

Last updated: 2026-06-08 (B78 — press-attitude pipeline + height-based stance).

---

## 1. The four numbers the app is trying to produce

By the time the result chip appears, the app has decided four things:

1. **Face angle** — how open or closed the putter face was when the ball was struck, in degrees. Positive = pushed right of target. Negative = pulled left.
2. **Peak hand velocity** — how fast the lead hand was moving forward at impact, in m/s.
3. **Distance** — how far the ball would have rolled on a real green.
4. **Direction call** — Mario-Kart-style bucket: SQUARE / slight PUSH / PUSH / slight PULL / PULL, with confidence.

Everything else in the pipeline exists to compute, verify, or render those four numbers.

---

## 2. What the phone is actually measuring

The iPhone gives us two independent streams:

- **CoreMotion** at 100 Hz: rotation rate (gyro), user acceleration (without gravity), gravity vector, and a fused **attitude quaternion** (the phone's 3D orientation in the world).
- **ARKit** (optional) at ~60 Hz: world-anchored 6-DoF camera pose and a coarse LiDAR mesh.

The pipeline only requires CoreMotion. ARKit positions the ball + hole + foot markers visually, but the stroke maths runs on IMU data alone. This matters because IMU samples are dense, deterministic, and don't reset between sessions — ARKit's world frame does.

---

## 3. Phone-as-putter coordinate convention

**The grip (corrected 2026-06, see `docs/putting-stance-reference.md`):** you hold the phone with BOTH hands in a normal putter grip, arms hanging in front of you at address, top of the phone toward the floor, back of the phone toward your legs, one LONG SIDE of the phone facing the target. The phone replaces the putter head; your stroke is a normal putting stroke.

> The original spec said "vertical in lead hand, screen facing you" — that hold is dead. It survives in some older docs; if you find it, it's stale, not a second supported grip. (PuttingLab/CLAUDE.md §3 decision #2 still carries the old wording pending a sign-off to amend a locked decision.)

- **Phone's long side** = the putter face (the side facing the target at address)
- **Rotation of the phone about the WORLD VERTICAL axis** = how open/closed the face is
- The press at address declares "this heading = square = 0°"; the absolute hold angle doesn't matter, only the press-to-impact rotation

**Sign convention (v3, B80 — golf convention, enforced in `FaceAngleComputer`):**

```
faceAngle < 0  →  face CLOSED  →  PULL  →  ball left of the target line
faceAngle > 0  →  face OPEN    →  PUSH  →  ball right of the target line
```

CoreMotion's attitude yaw is CCW-positive viewed from above, and for a right-handed golfer *closing* the face is a CCW rotation — so the producer emits `yaw(press) − yaw(impact)` to land on the golf convention. (B78/B79 emitted `impact − press`, which labelled every open-faced push as a "pull"; combined with a mirrored renderer the on-screen ball went the physically-correct way while the text said the opposite. Fixed atomically in B80.)

---

## 4. The flight path of one putt

Each putt walks through six distinct stages. Each one only fires when the previous one has produced a clean result.

### Stage 1 — Place the ball and the hole

Tap the floor to drop a virtual ball at a real-world point; tap again to drop the hole. ARKit raycasts against the LiDAR mesh to pin both points to actual horizontal surfaces. Once both are placed, the app draws the aim line and the address foot markers (see §6 for how the markers are sized).

### Stage 2 — Press to "declare square"

You stand to the ball, get into your address pose, and **press anywhere on the screen** when you feel set. That press is the most important event in the whole pipeline:

- The press captures the **IMU attitude quaternion** at that exact moment.
- The app calls this `attitudeAtPress` and stores it in the `StillnessLock` record for the stroke.
- By pressing, you are telling the app: *"Right now, where I'm pointing, is straight at the target. This is face = 0°."*

Why this matters: pre-B78 the app tried to figure out "square" for you by fusing ARKit yaw + magnetometer compass + a per-user calibration mean. That calculation drifted -6.6° → +2.4° → -8.9° → +5.6° across four indoor sessions in James's living room with no technique change. The press gesture replaces all of that. There is no world-frame reference any more — *you* are the reference.

See [PuttingLab/Physics/FaceAngleComputer.swift](../PuttingLab/Physics/FaceAngleComputer.swift) for the full rationale.

### Stage 3 — Take the stroke

You move the phone backwards (backswing), then forwards through the line of the imaginary ball. The app does three things during this window:

1. **StrokeDetector** watches the IMU for a backswing → forward-swing pattern and decides where the impact window starts and ends.
2. **ImpactDetector** scans the forward swing for the **peak forward velocity** along the swing-plane axis. That's the moment the imaginary ball would be struck. It also captures the IMU attitude quaternion at that instant — `attitudeAtImpact`.
3. **FaceAngleComputer** reads `attitudeAtPress` from the lock and `attitudeAtImpact` from the detector, extracts the yaw of each, and subtracts:

   ```
   faceAngle = wrapAngle( yaw(attitudeAtPress) − yaw(attitudeAtImpact) )    # v3, B80
   ```

   That single subtraction IS the face angle. No fusion, no compass, no bias correction. The press-minus-impact order lands the result on the golf sign convention (§3): a CCW (closing) rotation reads negative = pull. The yaw extraction uses the standard `atan2(2·(w·z + x·y), 1 − 2·(y² + z²))` formula on the quaternion components — exact for world-vertical rotations while the phone's X axis stays off vertical (true throughout the both-hands grip), gimbal-degenerate only when X points straight up/down.

   > **Known caveat (under instrumentation in B80):** "peak forward velocity" is not exactly "ball passage". The audit of the b79 session found the velocity peak can sit 100+ ms away from the moment the phone re-passes the address position, which at a 30-60°/s face sweep inflates the reading by several degrees. B80 logs a per-stroke `b80_impact_timing_shadow` event comparing both definitions; the timing fix lands once that data sets the thresholds.

### Stage 4 — Translate velocity to distance

`DistanceModel` converts the peak velocity (m/s) into a roll distance (feet) using a deceleration model parameterised by:

- Stimp meter (green speed) — defaults to 10 (typical UK club green).
- A per-user `speedToDistanceFactor` learned during calibration. A 4× difference in arm strength would otherwise produce a 4× distance error.

The formula is `distance_ft = (v_fps² × stimp) / decelerationConstant`, where v is the peak hand velocity scaled by the user's factor.

### Stage 5 — Mario-Kart bucket the direction call

`MarioKartAssist` takes the face angle and snaps it into a bucket:

| |faceAngle| | Bucket |
|---|---|
| < 6° | SQUARE |
| 6°–10° | slight PUSH/PULL |
| 10°–18° | PUSH/PULL |
| > 18° | Big PUSH/PULL |

The 6° square threshold is set to match the hardware noise floor of consumer phone IMUs measured indoors. Calling anything inside that noise floor "SQUARE" is the **Wii Sports Tennis Rule 1**: err toward square when uncertain. We would rather miss a real 5° push than report a phantom 5° pull caused by gyro drift.

Confidence is reduced (and the bucket pulled toward SQUARE) if the impact detector's signal-to-noise was low, the stroke window was unusually short, or the IMU reported tracking degradation.

### Stage 6 — Animate the roll, render the chip

`BallRollAnimator` rolls the virtual ball along the aim line, biased by the face angle. The chip shows direction + degrees + distance. If face angle was snapped to square, the chip says so.

---

## 5. Why the press-attitude pipeline (B78) replaces the old fusion (B57–B77)

The old pipeline did this every stroke:

```
faceAngle_raw     = ARKit camera yaw − ARKit baseline yaw at session start
faceAngle_fallback = compass yaw at impact − compass yaw locked at address
                    (depending on ARKit tracking quality)
faceAngle_corrected = faceAngle_raw − calibration_mean_face_angle
```

Three failure modes:

- **ARKit world drift**: every new AR session picks a new world-frame yaw origin. A 5° difference between sessions baked straight into the result.
- **Magnetometer interference**: indoor magnetic fields from desks, screens, wifi routers drift the compass by 2°–8° over the course of a calibration batch.
- **Calibration over-correction**: the mean of 5 calibration putts treated as the user's bias. If 4 putts were clean and 1 was a real 8° push, the bias became +1.6° and got subtracted from every subsequent stroke — meaning a clean square putt would display as a 1.6° pull.

The B78 pipeline structurally removes all three. There is no world-frame reference, no magnetometer subtraction, and no bias correction. The user declares "square" by pressing, and the face angle is the IMU yaw delta from that press to impact. Gyro noise on a ~700 ms stroke is about 0.5°–1° — well inside the 6° square bucket.

---

## 6. Where the foot markers come from (B78)

The address foot markers are sized to **you**, not to a one-size-fits-all stance:

- Settings (gear icon, top-right) lets you set your **height in cm** (default 170 — the UK adult median per ONS Health Survey for England 2021).
- `StanceGeometry` computes your shoulder width as `height × 0.245` — the bideltoid-to-stature ratio from ANSUR II (averaged across adult male and female medians).
- Each foot marker sits **half a shoulder-width** to the left and right of the ball, perpendicular to the aim line. A 170 cm user gets foot markers ~21 cm to each side of the ball; a 190 cm user gets ~23 cm.

This replaces the pre-B78 hard-coded ±18 cm spread that ignored the user entirely. The full math is in [PuttingLab/Physics/StanceGeometry.swift](../PuttingLab/Physics/StanceGeometry.swift).

The handedness setting determines which side of the ball the lead foot sits on (the picker is wired through `UserProfile.handedness`; v1 only uses it for foot ordering, future versions will tilt the putter-grip model).

---

## 7. What ends up in the stroke JSON

Every stroke is serialized to a JSON file you can save and email back for offline debugging. The B78 schema (`schemaVersion: 2`) carries enough to re-run the pipeline byte-for-byte without the phone:

- All IMU samples in the window (100 Hz: timestamp, rotationRate, userAcceleration, gravity, attitude quaternion).
- The `StillnessLock` including `attitudeAtPress` (new in B78).
- The `ImpactResult` (peak velocity, face angle, confidence, snap reason).
- A `faceAngleRawMeaning` tag: `"v3_press_attitude_delta_golf_sign"` for B80+ strokes (negative = closed/pull/left); `"v2_press_attitude_delta"` (B78/B79) and `"v1_arkit_compass_fused_with_bias"` (legacy) both carry the INVERTED sign relative to v3 — anything comparing across builds must branch on this tag.
- The `peakImpact` log event now includes `attitude_at_press_yaw_deg`, `attitude_at_impact_yaw_deg`, and `press_to_impact_delta_yaw_deg` so you can sanity-check the math against the displayed result without re-running the code.

Legacy v1 replays still deserialize cleanly. Missing `attitudeAtPress` falls back to the first sample's attitude in the window (the closest stand-in the old format stored).

---

## 8. The Wii Sports Tennis rules, restated

Every design choice in the pipeline is filtered through three rules:

1. **Err toward "Square" when uncertain.** That's why the 6° bucket is wider than the typical noise floor and why confidence-reductions pull the bucket toward square, not away from it.
2. **Surface the cause, not just the result.** The chip shows degrees + bucket + (optionally) snap reason, not just "MISS LEFT".
3. **Never invent direction the user clearly didn't produce.** The press-attitude pipeline makes this enforceable: there is no fused signal that can wander, only the IMU yaw delta you produced between press and impact.

If something in this document and the code disagree, the code is the source of truth — file an issue on `docs/spec-putting-lab-v1-FINAL.md`.
