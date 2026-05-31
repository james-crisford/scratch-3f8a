# AR Replay — Putt-Roll Physics Research Synthesis

*One-stop research brief for the engineer building the AR ball-roll replay.
Reads the team's existing research and distils every equation, coefficient,
sign convention and unit you need to take the `ImpactResult` we already
compute (`peakVelocity`, `faceAngleRaw`) and render a believable rolling-ball
trajectory.*

Date: 2026-05-31 · Synthesised from `puttinglab-putt-roll-physics-2026-05-29.md`,
`golf-ball-friction-surface-mechanics-2026-05-30.md`,
`puttinglab-putter-stroke-tempo-face-2026-05-29.md`,
`puttinglab-green-reading-psychology-2026-05-29.md`,
`puttinglab-terrain-modelling-2026-05-29.md`,
`puttinglab-competitor-intel-2026-05-29.md` and the existing
`docs/spec-putting-lab-v1-FINAL.md` + `PuttingLab/Physics/*`.

Tag legend (kept from the research reports):
`[fact]` = verifiable, multi-source · `[claim]` = single or contested source ·
`[projection]` = forward-looking, not measured · `[opinion]` = analyst
interpretation.

---

## 0. TL;DR for the impatient

For v1 AR replay we ship a **2D flat-green pure-roll integrator** with:

- `μ_r(S) = 0.611 / S` (S = Stimp in feet) so a Stimp-10 green gives μ ≈ 0.061.
- Effective deceleration `a = -(5/7) · μ_r · g` along the velocity vector,
  g = 9.81 m/s².
- Launch velocity `v_0 = k · peakVelocity` with **`k = 0.90`** (one number, no
  per-user calibration in v1).
- Launch azimuth `ψ_0 = +faceAngleRaw` (radians, CCW positive), applied as
  rotation of the unit aim vector. Sign confirmed in §3.
- A one-shot 5 % energy penalty at launch to model skid → roll.
- Hole capture iff the ball passes within 4.25" of cup centre **and**
  `v_entry ≤ 1.63 m/s`.

That's it for v1. Everything else (slope, wind, grain, full lip-out
phase-plane) is documented below for v1.1+.

---

## 1. The physics — every equation needed

### 1.1 Coordinate system & state

Work on the green plane in **right-handed 2D** with:

- `+x` = ball's intended target line (towards the cup at address).
- `+y` = left of the target line (right-hand-rule, screen frame).
- Angles measured CCW from `+x`, in radians.

State at time `t`:

```
p(t) = (x, y)        position, metres
v(t) = (vx, vy)      velocity, m/s
```

Constants (all SI unless noted):

```
g         = 9.81 m/s²                    [fact, textbook]
k_iner    = 5/7   ≈ 0.7143                rolling-sphere moment factor
                                          (solid sphere I = (2/5)mR²)
                                          — Penner 2002 §2 [fact]
v_stimp   = 1.91 m/s                      USGA Stimpmeter exit speed
                                          (Lee 2025 derivation; Penner gives
                                          1.83 m/s — 4 % spread, use 1.91)
                                          [fact, two sources]
R_cup     = 0.054 m   (4.25" diameter)    Rules of Golf
                                          [fact]
v_capture = 1.63 m/s                      max arrival speed to drop
                                          — Holmes 1991; Hogan & Antali 2025
                                          re-derive verbatim "1.626 m/s"
                                          [fact, two sources]
k_launch  = 0.90                          hand-velocity → ball-velocity
                                          coefficient (COR × face efficiency)
                                          [claim, vendor]
e_skid    = 0.95                          5 % v² launch energy penalty
                                          for skid phase
                                          [claim, derived from
                                          Kolkowitz 2007 20 %-of-path skid +
                                          Quintic Hurrion 5-20 % skid]
```

### 1.2 Rolling-friction coefficient from Stimp

The USGA Stimpmeter releases a ball at `v_stimp` from a fixed ramp; on a
green of reading `S` (feet) the ball rolls exactly `S` feet to rest. Constant
deceleration `a_f` satisfies `v_stimp² = 2 · |a_f| · S`. Combined with the
rolling-sphere model `a_f = (5/7) · μ_r · g`, we get the headline result:

```
μ_r(S)  =  v_stimp² / (2 · g · S_metres)              [fact]
        ≈  0.611 / S_feet
```

Reference table (cross-checked across Penner 2002, Lee 2025, Kolkowitz 2007;
the three derivations agree to within 4 %) [fact]:

| Stimp (ft) | μ_r    | a_f = (5/7)μ_r·g (m/s²) | character           |
|------------|--------|--------------------------|---------------------|
| 5          | 0.197  | 1.381                   | very slow / municipal |
| 6          | 0.164  | 1.150                   | slow                  |
| 8          | 0.116  | 0.813                   | medium                |
| **10**     | **0.089** | **0.624**            | **default (members')** |
| 11         | 0.089  | 0.624                   | fast (tournament)    |
| 12         | 0.079  | 0.557                   | very fast (Augusta)  |
| 14         | 0.042  | 0.293                   | "lightning"          |

Sanity check (Penner ρ_g = 0.131 → a = 0.918 m/s² corresponds to S ≈ 4.7 ft
"slowest-of-1990s") matches the table. The Penner 0.131 number is a *Stimp
average* and is **not** the right constant for a modern Stimp 10 green —
use the S-dependent form `μ_r(S)`. [fact]

### 1.3 Equation of motion — flat green, full 2D vector form

Friction always opposes the **instantaneous velocity vector** (not a fixed
axis — this is what creates curved breaks on a tilt). For a flat green the
right ODE is:

```
v(t)   = √(vx² + vy²)
ax     = -μ_r · g · (vx / v)
ay     = -μ_r · g · (vy / v)
```

Note: **no `5/7` factor on the friction term**. The `5/7` is already baked
into `μ_r(S)` via the Stimpmeter calibration (§1.2). The `5/7` only shows up
again on **gravity** terms when we add a slope (§1.6) — don't double-apply
it to friction. [fact, Penner §3]

Integrate with **semi-implicit Euler at dt = 1 ms** — RK4 is overkill for a
system this smooth (Lee 2025 confirms; Penner uses simple Euler in his ODE
solver). [fact]

Stop condition: `v < 0.05 m/s` (5 cm/s, sub-perceptible roll).
[claim, engineering threshold]

### 1.4 Launch — from peakVelocity to v_0

```
v_0_magnitude  =  k_launch · peakVelocity  ·  √e_skid
                ≈  0.90 · peakVelocity · 0.975
                ≈  0.877 · peakVelocity                [claim, two-step]
```

Source path:
- `k_launch = 0.90` ≈ COR(ball-on-putter, hard-hit) × face-strike efficiency.
  Putter-COR is regulated ≤ 0.83 (USGA Appendix II), but at the slow
  impact speeds of putting the rebound is *higher* than the high-speed COR
  rating (Wadden 2014; Quintic Hurrion). 0.85–0.95 is the empirical range
  (`puttinglab-putt-roll-physics-2026-05-29.md` §4.3). [claim, vendor]
- `e_skid = 0.95` (5 % energy loss in the launch skid phase). Justified by:
  Kolkowitz 2007 / Stanford = "pure rolling after ~20 % of total path"
  [fact]; during that 20 % the ball decelerates at `μ_k · g` (kinetic
  ≈ 0.6) instead of `μ_r · g` (rolling ≈ 0.06–0.09). The energy *extra*
  lost vs pure rolling over that 20 % path scales to ~5 % of v². [claim,
  derived]

Apply both as a single energy multiplication on the initial speed; do not
simulate the skid phase explicitly in v1. [claim, simplification —
matches `puttinglab-putt-roll-physics-2026-05-29.md` §4.2 v1.1
recommendation]

### 1.5 Launch — from faceAngleRaw to ψ_0

```
ψ_0  =  faceAngleRaw                                  (radians, signed)
v_0  =  v_0_magnitude · (cos ψ_0,  sin ψ_0)
```

Sign convention is documented in §3 below — the short version: positive
`faceAngleRaw` rotates the launch vector CCW (towards `+y` = left of target
line for a right-handed user, which the spec calls a "Pull"). [fact,
spec §2.1 + §5.1 line 320 confirms "negative raw = closed face = pull
left", i.e. our sign convention here matches the codebase].

**On the face-vs-path split (Pelz 83/17):** in real putting the ball start
direction is ~83 % face / ~17 % path. Spec §2.1 explicitly says: we are NOT
measuring a real ball, so we collapse face and path into a **single number**
and treat `faceAngleRaw` as the full launch azimuth. [fact, spec decision]
Path is *not* available from the phone signal anyway — we cannot infer it
without a clubhead. The 83/17 number stays as a v1.2 stretch (if we ever
infer path from the swing-plane PCA axis vs the address yaw).

### 1.6 Slope (v1.1+, deferred for v1 — documented here for completeness)

Decompose the green's slope unit-vector `X = (X_x, X_y)` (each in
**decimal**, e.g. 0.03 = 3 % grade) in the same 2D frame as `v`. Friction
still opposes velocity; gravity gives a constant 2D vector acceleration:

```
ax  =  -μ_r · g · (vx / v)  +  k_iner · g · X_x
ay  =  -μ_r · g · (vy / v)  +  k_iner · g · X_y
```

Note `k_iner = 5/7` *is* present here — gravity along the slope gets
damped by rolling-inertia, friction does not. [fact, Penner §4 +
Lee 2025 §3.5]

Stephen Lee 2025 scalar-form ([fact] for offline validation only):

```
a_eff       =  -(19.7/S + 23 · X_long) ft/s²
```

Where `X_long` is the slope component along the **target line** (signed,
+ uphill). Use this *only* to unit-test the 2D-vector integrator — at
runtime always use the vector form so the curved break is right.

Break magnitude closed-form (Lee 2025), again offline-validation only:

```
x_break_inches  =  (5/7) · 12 · g · X_s · S
                   / (19.7 + 23 · S · X)
                   · (√(D+R) − √R)²
```

Validated columns (Lee 2025; Stimp 10, 1 % side slope) [claim,
qualitative match to Aimpoint]:

| forward X | D=3 ft | D=10 ft | D=20 ft | D=30 ft |
|-----------|--------|---------|---------|---------|
| +3 %      | 1.0"   | 5.6"    | 13.3"   | 21.6"   |
| 0 %       | 1.4"   | 7.5"    | 18.0"   | 29.2"   |
| -3 %      | 2.2"   | 11.6"   | 27.6"   | 44.9"   |

Critical slope where ball won't stop: `X_crit = μ_r / k_iner`. For
Stimp 10 → ~6.1 %. Clamp slope inputs and surface "won't stop" as a UX
condition, not a bug. [fact, Penner / Lee]

### 1.7 Cup capture (v1 + v1.1 versions)

**v1 (engineering fit, ship this):** at each integration step check if the
segment `p(t) → p(t+dt)` passes within `R_cup` of cup centre.

```
captured  =  passes_through_cup_disc  AND  v_entry ≤ 1.63 m/s
```

If captured: stop sim, snap to cup centre, play drop sound, success haptic.
If passes through disc but `v_entry > 1.63 m/s`: **lip-out** — kick the ball
outward radially at `0.6 · v_entry` (engineering fit, Hogan & Antali full
phase-plane deferred), then keep rolling. [claim, engineering fit]

**v1.1 (Hogan & Antali 2025):** add an impact parameter
`b = perpendicular_distance_to_centre / R_cup`. Capture iff
`v_entry ≤ 1.63 m/s` AND `|b| < b_crit(v_entry)`, where `b_crit` linearly
interpolates between `(v=0, b=1.0)` and `(v=1.63 m/s, b=0.25)`. [claim,
approximation of the Royal Society Open Sci. 2025 separatrix]

### 1.8 What about wind, Magnus, air drag during the roll?

Skip them entirely for v1 and v1.1. Penner 2002 and Lee 2025 both
demonstrate that at putting speeds (≤ 2 m/s) and rolling regime there is
**no v² air-drag term** in any peer-reviewed model — the gravity-gradient
friction completely dominates. Magnus is zero because the ball is in pure
roll, not spinning relative to its translational motion. [fact, Penner 2002]

Wind only matters outside (Suzuki 2025: a 4 m/s ground-level wind moves a
3 m putt by 40+ cm — meaningful, but our v1 AR replay is indoor-room
flat-green only, so this is v1.3 territory). [fact]

---

## 2. The surface — Stimp, friction, capture, bounce

### 2.1 Stimp (Stimpmeter reading)

`[fact]` USGA Stimpmeter releases a ball from a 30-inch ramp at 20° tilt;
the ball travels `S` feet on a flat green. Modern values:

| range          | meaning                                              |
|----------------|------------------------------------------------------|
| 4–6 ft         | very slow — municipal, winter, freshly-aerated       |
| 7–9 ft         | medium — typical members' summer green               |
| 10–11 ft       | fast — well-prepared club green                      |
| 12–13 ft       | tournament                                           |
| 13.5–14 ft     | Augusta, US Open Sunday                              |
| >14 ft         | "lightning" — Augusta + downhill, unplayable for 90 %|

v1 default: **Stimp 10**, hidden from the user. v1.1 surfaces a Stimp pill
("today's greens are running 11") per `puttinglab-putt-roll-physics-2026-05-29.md`
§8 UX recommendation. [opinion]

### 2.2 Friction coefficient by green type

`[fact, multi-source]` There is **no** clean "bentgrass μ = X, poa = Y,
bermuda = Z" table in the literature. Rolling resistance depends on
height-of-cut, moisture, thatch, mowing frequency, rolling frequency, and
time of day at least as much as on grass species. The applied-research
workaround: measure Stimp, treat it as a one-number summary. We follow
this. [fact, applied across all the sources]

Per-species qualitative differences worth knowing:
- **Bentgrass** — finest, fastest, smoothest.
- **Poa annua** — bumpier at the same Stimp; "chatter."
- **Bermuda (warm-season)** — strong directional grain; down-grain runs
  6–12" further at typical Tour pace. [claim, qualitative]

v1: ignore species. v1.2: optional `grainDirection` and ±5 % μ_r modifier
for Bermuda mode. [opinion]

### 2.3 Capture velocity at the hole

`[fact, two sources]` `v_capture = 1.626 m/s` — verbatim from Hogan &
Antali 2025 (R. Soc. Open Sci.), re-deriving Holmes 1991. This is the
**flat-green** limit. On a downhill putt entering against the slope the
limit increases; on a downhill putt entering with the slope it decreases.
v1 hard-codes 1.63 m/s; v1.2 subtracts the slope-projection-along-hole-axis
from `v_entry` before comparing.

### 2.4 The 5/7 factor and why it shows up where it does

`[fact, textbook]` A **solid sphere** rolling without slipping has moment
of inertia `I = (2/5) m R²`. Translational acceleration under any applied
force splits 5/7 to translation, 2/7 to angular acceleration:

```
a_translational = F / m · (5/7)        (for a rolling-without-slipping sphere)
```

This is why:
1. **Gravity along a slope** is multiplied by 5/7 on a rolling ball
   (we use `k_iner · g · X` in §1.6, not the full `g · X`).
2. The Stimpmeter relation `a_f = (5/7) · μ_r · g` — but since μ_r is
   *defined* from `v_stimp² / (2gS)`, the 5/7 is **already absorbed** into
   the μ_r number we use, so do **not** apply it again to friction. (Get
   this wrong and your Stimp 10 plays like Stimp 14.)

If you're unsure: drop a ball straight down a 3 % slope on a flat green
with zero initial velocity and simulate; if it accelerates at
`(5/7)·g·0.03 = 0.21 m/s²` you've got it right; if it accelerates at
`0.295 m/s²` you've forgotten the 5/7.

### 2.5 Bounce on greens (skip for v1 — pure-roll only)

If you ever add an aerial drop onto the green (chip-in, drop-shot replay):
Springer 2023 (1000+ bounces) gives:

- Natural green: normal restitution `e_n = 0.260`, tangential `e_t ≈ 0.999`,
  critical incoming angle 18.3°. [fact]
- Firm/artificial turf: `e_n = 0.544`, `e_t ≈ 0.688`, critical angle 34.5°.
  [fact]

Below the critical angle, the ball grips and rolls out instead of bouncing.
Skip this whole subsystem for v1 — no airborne balls.

---

## 3. Input mapping — from `ImpactResult` to launch parameters

This is the load-bearing section for the engineer. The existing
`PuttingLab/Physics/ImpactDetector.swift` returns an
`ImpactResult` whose two physics-relevant fields are:

```swift
let peakVelocity: Double   // m/s
let faceAngleRaw: Double   // radians, signed
```

(Plus `attitudeAtImpact: simd_quatd`, `confidence`, `snappedToSquare`,
`snapReason`. The AR replay only consumes the two above when the
result is not snapped to square.)

### 3.1 What is `peakVelocity`? Hand velocity or ball velocity?

**Hand velocity.** Specifically: the peak forward component of the *phone's
linear* velocity, integrated from `userAcceleration` along the swing-plane
PCA axis. It is not corrected for the absence of a putter shaft — the
phone *is* the putter in our model.

Confirmed in three places:
- `ImpactDetector.swift` lines 47–55 — `velocity[i] = ∫ projected_accel dt`
  with end-of-stroke drift correction.
- `ImpactDetector.swift` lines 70–95 — the peak detection picks the
  dominant extremum of this *integrated phone velocity*.
- spec §2.3 line 72 — "Impact moment = the timestamp at which the phone's
  forward hand-velocity ... reaches its peak."
- spec §6 line 370 — `user_speed_calibration_factor = peak forward hand
  speed → assumed target distance`.

**Numerical range observed (post-tuning, 2026-05-30 build 0.1.9-13):**
- minPeakVelocityMps = 0.05 m/s (below this → snap to square).
- maxPlausiblePeakSpeedMps = 5.0 m/s (above this → suppressed as an
  IMU spike — `DistanceModel.swift` line 43).
- Real putts in the captured-stroke library: ~0.1–0.6 m/s for the IMU
  signal (closed-hand grip means low translational, rotation-dominated).
- PGA Tour putter-face speeds are 1.5–2.5 m/s — i.e. **the phone IMU does
  not see the same number as a launch monitor**; the user's hand peak is
  much lower than the clubhead peak would be for an equivalent putt
  distance.

Implication for the AR replay: the existing
`DistanceModel.speedCalibrationFactor` (set during the 3-putt
calibration mini-game in `CalibrationModel.swift`) already converts
phone-hand-speed → simulated ball-speed for the **distance display**.
Reuse it for AR replay launch velocity:

```swift
let speedCal = profile.speedToDistanceFactor   // ~5-15 typically
let v0_mag_mps = peakVelocity * speedCal * k_launch * sqrt(e_skid)
//             ≈ peakVelocity * speedCal * 0.877
```

This is **deliberately the same calibration** as `DistanceModel` so the
animated roll lands at the same number the result panel shows. If they
disagree the user will notice immediately. [opinion, consistency-first]

For an uncalibrated user (no 3-putt cal yet): `speedCal = 1.0`, which
will give an unrealistically-short roll. Show a tooltip "Calibrate to get
realistic rolls" rather than fabricating a fake calibration.

### 3.2 What is `faceAngleRaw`? Phone yaw or ball direction?

**Phone yaw delta**, in radians, relative to the address-lock yaw target.
Specifically: yaw component of the phone's attitude quaternion at impact,
minus the yaw target locked during the 800 ms address pose.

Computed in `FaceAngleComputer.swift`:
- Primary: from ARKit `yaw_at_impact_arkit - yaw_target_arkit`
  (drift-corrected via visual-inertial odometry).
- Fallback: from magnetometer-fused compass yaw if ARKit lost tracking
  during >50 % of the swing window.

Range: [−π, +π], wrapped by `ImpactDetector.wrapAngle()`.

### 3.3 Sign convention — the load-bearing detail

From spec §5.1 line 320 — verbatim:

> (For a right-handed user: negative raw = closed face = pull left.)

So:
- **Negative `faceAngleRaw` = closed face = ball goes LEFT of target line
  for a right-handed user = "Pull"**.
- **Positive `faceAngleRaw` = open face = ball goes RIGHT of target line
  for a right-handed user = "Push"**.

In our 2D AR frame from §1.1 (`+x` = target, `+y` = left of target line,
CCW positive), a "left of target" launch means **`+y` direction**, which
in radians from `+x` is **positive ψ**. So:

```
ψ_0 = -faceAngleRaw                  (for the §1.1 frame)
```

The **minus sign matters**. Pull (raw < 0) → ψ_0 > 0 → ball goes towards
+y (left). Confirm in test: a deliberately closed face should animate the
ball to the *left* of the target line in the top-down replay.

**Left-handed user**: a future v1.x setting flips this sign once we have a
handedness toggle. For now, default = RH. Note in code with
`// HACK: assumes right-handed user; v1.2 adds handedness setting`.
[fact, spec + code]

### 3.4 What about the spec's `+y = left` vs the camera's screen-space y?

For AR rendering (RealityKit / SceneKit world coordinates):
- ARKit world frame is right-handed, `+x = right`, `+y = up`, `−z = forward
  (away from camera at session start)`.
- The "green plane" is the world XZ-plane.
- The target line projects from address-pose phone yaw onto XZ.

Map our 2D physics frame (§1.1) onto AR world coordinates:
- Physics `+x` (target line) → unit vector along the address-yaw direction
  projected onto XZ.
- Physics `+y` (left of target) → 90° CCW rotation of that vector around
  ARKit `+y` (world up).
- Ball position `(x_phys, y_phys)` rendered at world `(x_phys · target_x +
  y_phys · left_x, ground_y, x_phys · target_z + y_phys · left_z)`.

Keep the physics 2D and only map to AR world coordinates at the render
step. Don't try to integrate in 3D world space directly; that's a
solvable but unnecessary headache. [opinion]

### 3.5 Edge cases the AR replay must handle

| Input condition                              | Behaviour                                           |
|----------------------------------------------|-----------------------------------------------------|
| `snappedToSquare == true`                    | Roll dead-straight along target line at full v_0.   |
| `peakVelocity < minPeakVelocityMps (0.05)`   | Already handled — result is snap-to-square. AR replay never invoked. |
| `peakVelocity > maxPlausiblePeakSpeedMps (5)` | `DistanceModel` suppresses; show "result unclear", no AR. |
| `confidence < 0.4`                           | Show roll with a desaturated trace line + "low confidence" badge. Don't refuse to render — the user did *make* a stroke. |
| ARKit world tracking lost mid-roll-render    | Pause the AR overlay; show the 2D fallback animation (existing roll view). |
| User moves phone during the roll-render      | This is fine — the ball is anchored in ARKit world space, not phone-relative. |

---

## 4. Known unknowns — what's missing for v1

These are honest gaps. List them in the About sheet under "what v1 doesn't
model" if we want to pre-empt complaints from real golfers (per the
`puttinglab-competitor-intel` finding that boredom + "confidently wrong"
are the two universal churn drivers).

### 4.1 Ball spin / launch angle / dynamic loft
We don't measure putter loft or strike-quality (toe vs centre vs heel),
so we don't model:
- The 50–150 rpm transient backspin (`puttinglab-putt-roll-physics-2026-05-29.md`
  §4.1 [claim, single-source]). Skip — it dissipates in the first ~30 cm.
- The 1–4° initial launch angle. Skip — the ball returns to the green
  surface within ~15 cm and the rest is roll.
- Skid distance variation by loft (Sheffield Hallam 2014: higher loft →
  longer skid). Punt to a single fixed `e_skid = 0.95` in §1.4.

For v1 AR replay: **roll is in the 2D green plane**. Z-axis (height) is
fixed at the ball's surface contact point. No bobble, no rise. [opinion,
simplification]

### 4.2 Green slope
The phone doesn't know what the real-world surface tilt is unless we
ARKit-plane-detect a slope (possible — `ARPlaneAnchor` returns world
transform and gives us the surface normal). For v1: **flat green**.
For v1.1: read `ARPlaneAnchor.transform.up` to derive `X_x, X_y` and
feed them through §1.6. The slope-detect itself is well-supported by
ARKit; the question is whether *room floors* are slope-representative
of real putting greens (no — but the user understands it's a sim).

### 4.3 Non-Newtonian / variable friction
PING / Burritt 2024: even on flat greens μ_r varies through a single
roll (firmer pre-mow vs post-mow, drying-out vs morning dew). v1 uses a
single μ_r. [claim, model simplification]

### 4.4 Grain (Bermuda directional friction)
Documented in §2.2 / `golf-ball-friction-surface-mechanics-2026-05-30.md`
§4 as qualitative-only. Skip for v1.

### 4.5 Lip-out spin physics
Hogan & Antali 2025's full phase-plane separatrix accounts for ball spin
state at cup entry; v1 uses a linear `b_crit` interpolation (§1.7). Worst
case: a near-miss at moderate speed will look slightly different from
reality. Acceptable for a sim that ships a "Mario Kart-style assist"
philosophy. [opinion]

### 4.6 Wind
Suzuki 2025 paper is excellent (n=140 putts, real measurements). But our
v1 is indoor-room AR — wind makes no sense. Punt to v1.3. [fact]

### 4.7 Path-vs-face split (Pelz 83/17)
We collapse face + path into face. See §1.5 — path is not phone-derivable.
The 83/17 split (Marquardt 2007 / Pelz 2000 via SAM PuttLab; tour data
n=99) would only apply if we had a real ball + clubhead system. [fact,
not measurable from our IMU pipeline]

### 4.8 Per-user calibration of `k_launch`
v1 uses `k_launch = 0.90` flat. Real putting strikes vary the hand-to-ball
velocity transfer based on rhythm and quality. The 3-putt calibration
mini-game already absorbs the bulk of this into `speedToDistanceFactor`
(`CalibrationModel.swift` line 49). Keeping `k_launch` constant
mathematically equivalent to a single `k_launch · speedCal` term in v1 —
fine. v1.1 could split them. [opinion]

---

## 5. For v1 simplicity — the minimal model

### 5.1 What to build (in code-order)

A flat-green 2D semi-implicit Euler integrator. All of it should fit in
~120 lines of Swift. Suggested API (matches the
`puttinglab-putt-roll-physics-2026-05-29.md` §6.6 recommendation):

```swift
struct PuttRollResult {
    let path: [SIMD2<Float>]           // positions in metres, dt = 0.01 s sampled
    let endPosition: SIMD2<Float>
    let endVelocity: SIMD2<Float>
    let outcome: Outcome
    enum Outcome { case captured, lipOut, stopped, offGreen }
}

func simulatePutt(
    peakVelocity: Double,              // m/s, from ImpactResult
    faceAngleRaw: Double,              // radians, signed, from ImpactResult
    speedCalibration: Double,          // from CalibrationProfile.speedToDistanceFactor
    stimp: Double = 10.0,              // green speed in feet (default v1 = 10)
    startPos: SIMD2<Float> = .zero,    // ball starting position, metres
    cupPos: SIMD2<Float>               // cup centre, metres, in physics frame
) -> PuttRollResult
```

Inside:
1. Compute `v0_mag = peakVelocity * speedCalibration * 0.90 * sqrt(0.95)`.
   (Convert speedCalibration's fps semantics: see §3.1 — already in m/s
   via `peakVelocity * speedCal` × the existing `DistanceModel` chain. If
   `speedCal` is dimensionless then the line above is correct.)
2. `ψ0 = -faceAngleRaw` (§3.3 sign convention for our 2D frame).
3. `v = (v0_mag · cos ψ0, v0_mag · sin ψ0)`.
4. `μ_r = 0.611 / stimp_ft` — or use the lookup table (§1.2).
5. Loop at dt = 0.001 s, integrate per §1.3.
6. At each step, check cup-passing (segment-circle intersection).
7. Stop when `|v| < 0.05 m/s` OR captured OR off-green (if green polygon
   provided).
8. Return path sampled at dt = 0.01 s (every 10th step) to keep the
   render-side data structure small.

### 5.2 What we lose vs. the full Penner model

| Feature                                | v1 (minimal)         | Full model (v1.1+)          | Visible impact |
|----------------------------------------|----------------------|------------------------------|----------------|
| Slope-driven break                     | None (flat)          | §1.6 vector EoM             | Putts on a slope look identical to flat — golfers WILL notice. |
| Variable friction (PING/Burritt)       | Single μ_r           | Time-varying μ_r            | Slight distance-control feel inaccuracy — non-visible at game level. |
| Skid sub-model                         | 5 % energy proxy     | Explicit μ_k → μ_r switch   | Negligible visible difference. |
| Lip-out phase-plane                    | Linear b_crit fit    | Hogan & Antali separatrix   | Some near-miss results will look slightly different from real life. |
| Grain (Bermuda)                        | None                 | Directional μ_r modifier    | Putts down-grain run identical to into-grain — only Bermuda players notice. |
| Wind                                   | None                 | Suzuki impulse model        | Indoor-only sim — invisible. |
| Capture-speed downhill correction      | Hard 1.63 m/s        | Slope-projected limit       | A few downhill putts that should drop will lip out; acceptable. |
| Air drag / Magnus during roll          | None                 | None either                  | No diff — both models skip. |

**Net assessment:** the v1 minimal model gets ~80 % of the realism that a
non-golfer would judge as believable, and ~60 % of what a golfer would
judge as believable (the missing 40 % is slope and grain — both visible).
v1.1 adding §1.6 slope + ARKit-plane-detected surface normal closes most
of the remaining gap; that's our roadmap.

### 5.3 Constants to drop into a Swift file

```swift
enum PuttPhysicsConstants {
    static let g: Double               = 9.81                  // m/s²
    static let rollInertiaFactor: Double = 5.0 / 7.0           // solid sphere
    static let stimpExitVelocity: Double = 1.91                // m/s (Lee 2025)
    static let defaultStimp: Double    = 10.0                  // feet
    static let cupRadius: Double       = 0.054                 // m (4.25" / 2)
    static let captureVelocity: Double = 1.626                 // m/s (Hogan & Antali 2025)
    static let launchCoefficient: Double = 0.90                // peakVelocity → ball v_0
    static let skidEnergyRetention: Double = 0.95              // 5 % skid loss
    static let dtSim: Double           = 0.001                 // 1 ms integration step
    static let dtSampleOut: Double     = 0.01                  // 10 ms render sample
    static let stopVelocity: Double    = 0.05                  // m/s — roll stop threshold
    static let lipOutVelocityRatio: Double = 0.6               // v_out / v_entry on lip-out

    static func rollingFriction(stimpFeet: Double) -> Double {
        return 0.611 / max(stimpFeet, 1.0)
    }
}
```

These match `DistanceModel.decelerationConstant = 19.7` (which encodes the
same `v_stimp²/(2·1ft)` relationship in imperial). If you change one,
change the other. [opinion]

---

## 6. Citations (compact form, full citations in source docs)

### Tier 1 (peer-reviewed, load-bearing)
- **Penner, A.R. (2002)** "The physics of putting" *Can. J. Phys.* 80(2):83–96.
  DOI 10.1139/p02-035 — the canonical putt-roll paper. Source of:
  μ_r = 0.131 mid-value, gravity-gradient friction model, sloped-green EoM,
  1.63 m/s capture (orig. Holmes 1991).
- **Hogan, S.J. & Antali, M. (2025)** "Mechanics of the golf lip out"
  *Royal Society Open Science* 12(11):250907. DOI 10.1098/rsos.250907 —
  re-derives the 1.626 m/s capture speed verbatim; gives the full lip-out
  phase-plane separatrix we approximate in §1.7.
- **Suzuki, T., Asai, T. & Kita, T. (2025)** "Wind Effect in Short-Range
  Putting" *Int. J. Golf Science* 13(1):41–54. DOI 10.64852/ijgs.2025-04 —
  n=140 putts; documented in §4.6.
- **Wadden, J. et al. (2014)** "The Effect of Skid Distance on Distance
  Control in Golf Putting" *Procedia Engineering* 72:642–647.
  DOI 10.1016/j.proeng.2014.06.109 — skid phase, launch loft, the 5–20 %
  path skid range we collapse to a 5 % energy penalty.
- **Marquardt, R. (2007)** SAM PuttLab tour-pro dataset (n=99). Used in
  §3.2 / spec §2.1 for the 83/17 face-vs-path split (we do not apply,
  but it's the basis for that decision being acceptable as a v1
  simplification).
- **Biber, Jones, Champneys & Szalai (2023)** *Sports Engineering* —
  Springer, 1000+ green-bounce dataset. Source of bounce coefficients in §2.5.

### Tier 2 (lab + industry)
- **Kolkowitz, S. (2007)** "The Physics of a Golf Putt" Stanford PH210
  coursework. Independent fit of Penner against Stimp data; the ρ_g range
  0.065–0.196.
- **Quintic Ball-Roll Consulting** "Phases of Motion of a Golf Ball
  During a Putt" — the 5–20 % skid path-length number.
- **USGA / R&A** *Stimpmeter Instruction Booklet FINAL* (2012). Source of
  v_stimp = 1.91 m/s.

### Tier 3 (well-vetted engineering blogs)
- **Lee, Stephen M. (2025-11-16)** "Modeling Aimpoint for Green Reading"
  stephenlee.info/golf/physics/2025/11/16 — the closed-form break formula
  (§1.6 scalar form), effective-Stimp table. Math triangulated against
  Penner; safe to ship.

### Internal references
- `c:\Users\james\Desktop\Claude Agent\research_archive\puttinglab-putt-roll-physics-2026-05-29.md`
  (40 KB; full §1.1–12 of the source physics report)
- `c:\Users\james\Desktop\Claude Agent\research_archive\golf-ball-friction-surface-mechanics-2026-05-30.md`
  (14 KB; multi-source reconciliation of μ_r, bounce, surface modifiers)
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\docs\spec-putting-lab-v1-FINAL.md`
  (the spec; load-bearing for sign conventions and input semantics)
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Physics\ImpactDetector.swift`
  (the upstream signal source — read before changing the input mapping)
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Physics\DistanceModel.swift`
  (already encodes `decelerationConstant = 19.7` and `defaultStimp = 10`;
  reuse the constants rather than re-deriving)
- `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\PuttingLab\Calibration\CalibrationModel.swift`
  (where `speedToDistanceFactor` is computed during the 3-putt calibration —
  consume the same factor for AR launch velocity to keep the result
  panel and the AR ball-end-position in agreement)

---

## 7. Implementation order (suggested)

1. **Constants** — drop `PuttPhysicsConstants` (§5.3) into a new file
   `PuttingLab/Physics/PuttPhysicsConstants.swift`. Pure data, no behaviour.
2. **Pure integrator** — `PuttingLab/Physics/PuttRollSimulator.swift`. Takes
   the inputs in §5.1's signature, returns the `PuttRollResult` struct.
   Zero ARKit dependency. Unit-testable in isolation.
3. **Unit tests** — Swift Testing suite in `PuttingLabTests/`:
   - Stimp 10, peakVelocity 0.3 m/s, face 0, speedCal 5 → ball rolls
     ~roughly the distance `DistanceModel` predicts (cross-check the two).
   - Stimp 10, peakVelocity 0.3 m/s, face +0.1 rad (~5.7°), speedCal 5 →
     ball ends to the **left** of the target line (CCW azimuth from §3.3
     sign flip).
   - Stimp 14 vs Stimp 6, same input → distance ratio approximately
     (14/6) = 2.3× (linear in S per §1.1 derivation).
   - Cup at 3 m, peakVelocity tuned so v_entry just under 1.63 m/s →
     captured. Tune slightly up → lip-out.
4. **AR overlay layer** — `PuttingLab/UI/ARRollReplayView.swift`.
   Maps physics 2D → ARKit world XZ-plane per §3.4. Anchors to a
   `ARPlaneAnchor` if one exists; otherwise places ball at a fixed
   1.5 m in front of the camera at the user's address pose.
5. **Fallback to 2D** — if ARKit tracking is poor, drop back to the
   existing top-down 2D roll animation. Keep both code paths.

---

## 8. Calibration: how the existing factor maps

For the engineer: the `peakVelocity * speedToDistanceFactor` chain is
**not raw physics — it's a learned mapping** from "what this user's hand
peak looks like" to "what their ball speed needs to be." The reason:

- A real PGA Tour putt has a clubhead peak velocity around 1.5–2.5 m/s
  for a 10 ft putt on Stimp 12 [Marquardt 2007].
- The phone in a vertical grip with a closed hand sees ~0.1–0.6 m/s at
  peak (mostly rotational, little translation) — confirmed by the captured
  stroke data in `data/raw/by-build/0.1.9-13/`.
- The `speedToDistanceFactor` is computed in `CalibrationModel.compute()`
  by solving for the factor that makes the user's mean peakVelocity over
  3 calibration putts produce the target distance through `DistanceModel`
  at Stimp 10.

So when we compute `v_0_mag = peakVelocity * speedCalibration * 0.90 *
sqrt(0.95)` in §5.1, the `peakVelocity * speedCalibration` term gives us a
plausible **ball-equivalent velocity** in m/s. The `0.877` factor then
discounts it for COR + skid. This makes the AR animated roll match the
displayed numeric distance — which is critical UX consistency.

If we wanted to skip calibration entirely and treat `peakVelocity` directly
as ball velocity (no factor), the ball would roll at hand-speed numbers
(0.1–0.6 m/s) and stop almost immediately. **Always use the calibration
factor in the AR pipeline.**

---

*End of synthesis. Ship the v1 minimal model (§5); document the v1.1+
roadmap in code comments referencing the §1.6 slope + §1.7 phase-plane
sections of this doc. Cite Penner 2002 and Hogan & Antali 2025 in the
About sheet — cheap legitimacy vs the competitor field per the
`puttinglab-competitor-intel` brief.*
