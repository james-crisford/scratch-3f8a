# PuttingLab — Putting Stance & Grip Reference (CORRECTED)

> **CLARIFICATION 2026-06-03 (post-B58):** James confirmed in conversation
> that **his grip has been CONSTANT throughout development** — the 200+
> historical strokes (data/raw/by-build/0.1.3 through 0.2.2) are in the
> SAME grip he uses now. The 2026-06-03 11-point confirmation that
> originally produced this doc was James **describing his actual practice**,
> not approving a new design.
>
> **There was no "old pose → new pose" transition.** The original spec text
> (CLAUDE.md §3 #2, spec-putting-lab-v1-FINAL.md §1 row 7) describing
> "vertical in lead hand, screen facing user" was the **theoretical** spec,
> not what James ever actually did. The app implementation was always
> calibrated against his real grip, which this doc accurately describes.
>
> Practical implications:
> - The 80-stroke calibration's `LiveImpactDetector` thresholds DO apply
>   directly (no "pose change" retune needed)
> - The 200+ stroke dataset's derived `speedCalibration` factor (~14.4)
>   IS the correct factor for him today
> - The `faceAngleBiasRad` computed from his historical strokes IS his
>   actual stroke bias and applies in-app the moment ProfileStore.save()
>   is wired into the cal flow (B58.2)


> **THE LOCKED OPERATING DESIGN.** Sourced from James's direct confirmation 2026-06-03,
> Build 4 commit `f06ee52` (2026-05-30 — "orientation instruction rewrite"), and the
> `PhoneHoldVisual` two-pose card.
>
> **Read this FIRST before touching any code that affects address / stroke / impact.**
>
> ⚠️ **Stale design to ignore:** `CLAUDE.md` §3 decision #2 ("vertical in lead hand,
> screen facing user, back camera facing direction of swing") and `docs/spec-putting-lab-v1-FINAL.md`
> §1 row 7 say the SAME stale thing. Both predate Build 4. Build 4 explicitly dropped that
> prescription. **The correct design is below.** If the spec / CLAUDE.md ever drifts back
> to "vertical / screen toward you", that is a regression — fix the doc, not the code.

---

## 1. The two-pose flow

There are TWO distinct phone-holds in a session. Don't conflate them.

### Reading pose
Holding the phone normally to look at the screen — portrait, screen toward face.
This is just normal phone use. Pre-putt UI / instructions / setup happens in this pose.

### Putting pose
The user's **own natural putting grip**. The app does NOT prescribe one specific orientation.
The 5-stroke calibration loop personalises "0° face" for whichever grip the user lands on.

That said, the typical putting pose looks like this:

---

## 2. The putting pose — described point-by-point

| # | What | Confirmed |
|---|---|---|
| 1 | **Back camera points at user's feet / legs** (downward, toward user's lower body) | ✅ James 2026-06-03 |
| 2 | **ONE LONG EDGE (side) of the phone faces the target** — this is the "putt face" (equivalent of the putter face) | ✅ James 2026-06-03 |
| 3 | **TOP of the phone (camera / notch end) angles DOWN toward the ground** — tilted, NOT vertical | ✅ James 2026-06-03 |
| 4 | **Speakers / lightning port at the BOTTOM** point toward the user's chest / body | ✅ James 2026-06-03 |
| 5 | User can see the **screen slightly, at an angle** | ✅ James 2026-06-03 |
| 6 | **BOTH HANDS on the phone** — like both hands wrapped around a putter grip | ✅ James 2026-06-03 |
| 7 | **Right-handed users only in v1** — left-handed grip support is post-v1 | ✅ James 2026-06-03 |
| 8 | User's **own natural grip** — algorithm calibrates per-user from whatever orientation the phone is in at press time | ✅ B4 commit `f06ee52` + James 2026-06-03 |

### The mental model

Think of holding a **flat tablet horizontally** and **tipping its far end down toward the ground**. Both hands grip the near end. That's the putting pose — phone held like a divining rod, both hands at the near end, far end (top of phone) dipping down toward where the ball / cup would be.

### Phone axis → world direction table

This is what each face / edge of the phone points at when the user is in the putting pose, looking down at the target (hole). The user is facing **forward** along the target line.

| Phone part | iPhone landmark | Where it points in the world |
|---|---|---|
| **Bottom edge** (short edge with speakers + lightning port) | charging port | **Toward user's chest** — hands grip here |
| **Top edge** (short edge with notch / dynamic island + camera bump) | front camera notch | **Down toward the ground, away from user** — the far end of the "wand", tilted lower than the bottom edge |
| **Long edge A** (one of the two long sides) | volume buttons | **Toward the target** (= the "putt face" — analogous to the leading edge of a putter face) |
| **Long edge B** (opposite long side) | power button | **Away from target, back toward user's body** |
| **Back of phone** (rear case with camera lens) | rear camera lens | **Down + toward user's feet / legs** — lens looks at user's lower body |
| **Front of phone** (screen) | display | **Up + slightly toward user** — user glances down to see it at an angle |

### Confirmation checklist (what James confirmed 2026-06-03)

- [x] Back camera at user's feet / legs
- [x] One long edge (= putt face) at target, the other away
- [x] Top of phone angles DOWN at the ground (not vertical)
- [x] Speakers / lightning toward user's chest
- [x] User sees screen at a slight angle
- [x] Both hands on the phone
- [x] Right-handed users in v1

### Visual diagrams — deferred

The Three.js + SVG attempts at depicting this pose didn't land — 2D rendering of a 3D pose with crude stick figures isn't clear enough to be useful (see `docs/stance-renders/DEPRECATED.md`). Better paths:
- **One real photo** of James in the putting pose would be the canonical reference — kills all ambiguity instantly
- A short **video clip** of the swing motion would be even better
- Until then, the axis-table above is the single source of truth

---

## 3. The "press" gesture — the trigger

This is **the only user input at swing time**. There is no "Set address" button. There is no "Ready" tap.

### Sequence

1. User holds the phone in their putting pose (both hands, side toward target, top angled down)
2. User **presses the screen** (any touch, single finger) — this means "I'm about to take my putt now"
3. The press locks the address pose. Whatever orientation the phone is in at the press moment = "0° face" for this stroke
4. **User must NOT change grip while pressed.** If they do, the only way to recover is to take their fingers off and re-orient
5. User makes the putting motion (both hands swing the phone) while still pressed
6. User releases (unpresses) when the stroke is done

### Why press + unpress

The software uses **BOTH** the press AND the unpress to detect "is this a real swing or did the user abandon?":

- Press start = stroke attempt begins
- Motion during press = the swing data
- Unpress = stroke attempt complete
- If a credible swing arc was detected between press and unpress → real attempt → run ImpactDetector + show result
- If no credible swing arc → ignored, no result shown

This is different from the B47-B48 design I (Claude) shipped — there I had an "address calibration" + "Ready" button flow. Wrong. The press+unpress gesture replaces both.

---

## 4. The swing motion

- **Both hands swing the phone through the putting arc**, gripped on the bottom edge of the phone like a putter handle
- The phone moves with the user's hands as a pendulum
- **"Forward" along the target line is defined by the long-edge of the phone that was facing the target at press time** (face-direction reference locked at the press)
- **Peak forward velocity = impact moment** (Wii Golf-style — this is the ONE part of CLAUDE.md still correct)
- At impact, the yaw component of the phone's attitude (rotation about gravity) vs the locked target-line reference = the **raw face angle**

### Stroke detection thresholds (live in code)

```
Sensors/StrokeDetector.swift:
    startThresholdRadPerSec  = 30°/s rotation rate
    startSustainSeconds       = 50 ms sustained
    endQuietSeconds           = 300 ms of quiet to end
    hardCutoffSeconds         = 2.0 s max stroke duration

Physics/ImpactDetector.swift:
    minStrokeDurationSeconds  = 200 ms
    minPeakVelocityMps        = 0.05 m/s
```

`0.05 m/s` was tuned for **putting-specific motion** (mostly rotation at the IMU, not translation). The Wii-Sports-derived `0.30 m/s` default was rejecting every real putt — see commit `816e4c6`.

---

## 5. Per-user calibration

5-stroke calibration loop (`Calibration/CalibrationCoordinator.swift`) personalises everything because **every user's grip is slightly different**:

- **Per-user "0° face"** — the orientation the phone happens to be in at the user's natural press
- **Speed-to-distance factor** — how the user's hand peak velocity maps to a real ball-equivalent distance
- **Typical grip orientation** — calibrated implicitly via the 5 reference strokes

Calibration accepts strokes that satisfy:
```
impact.confidence >= 0.5
window.duration  >= 0.2 s
impact.peakVelocity >= 0.3 m/s
```
(see `CalibrationCoordinator.isValid`)

---

## 6. Mario Kart assist bucket (locked decision #4, CLAUDE.md §3)

```
|face_angle_raw| < 6°         →  "Square"           (snap to 0° displayed)
6°  ≤ |raw| < 12°              →  "Slight pull/push" (display 4–8°)
12° ≤ |raw| < 20°              →  "Pull/Push"        (display 12–18°)
|face_angle_raw| ≥ 20°         →  "Miss"             (display 20–30°, capped)
```

For right-handed v1: negative raw = closed face = pull left.

**Confidence-low always snaps to square** (Wii Sports rule #1 — never confidently wrong):
- ARKit lost >50% of stroke
- Stroke duration < 200 ms
- No clear peak velocity
- Peak speed < 0.3 m/s

---

## 7. The AR layer (Stage 2 / B40+) — what's correct vs what's wrong

### Correct
- LiDAR floor scan + green mesh overlay (B41)
- Place a virtual ball + virtual hole in world space (B40)
- Hole render with PBR materials + environment probe (B45 — when working)
- Ball roll animation across the AR floor (B49)
- Result card with distance / face / Mario Kart bucket (B50)
- **Yellow foot markers as an OPTIONAL stance hint** (B46 — advisory only, user stands wherever)

### Wrong (shipped in B47-B48, needs stripping)
- ❌ "Set address" button — there is no such button in the design
- ❌ "Ready" button — the press IS the readiness signal
- ❌ Phone-icon hologram — the captured pose is internal, not user-facing
- ❌ Any modal or progress ring asking user to confirm the address
- ❌ The address-flow PlacementState cases (.calibratingAddress, .addressReady, .readyForStroke) — collapse into a single .complete state with press-gesture armed

---

## 8. The correct end-to-end loop (for B51 forward)

1. User opens AR. LiDAR scans floor.
2. User taps to place ball. Taps to place hole.
3. (Optional foot markers appear behind ball as a hint — user can stand wherever)
4. **User walks to where they want to stand.**
5. **User grips phone in PUTTING POSE** (both hands, side toward target, top angled down — Section 2 above).
6. **User presses the screen** to lock the address pose (Section 3 above). Press = "I'm putting now".
7. **User swings the phone while pressed** — pendulum motion (Section 4 above).
8. **User unpresses** when stroke is complete.
9. App computes ImpactResult between press and unpress. Mario Kart bucket assigned.
10. Ball rolls across AR floor per `BallPhysics.simulatePutt`.
11. User pans camera toward the hole to watch the ball roll into / past / lip out.
12. Result panel slides up.
13. **Putt again** preserves placement + calibration; user just re-presses + swings.

**Total taps in the swing flow: 1 (the press).** Total taps to do another putt: 1.

---

## 9. Reciprocity test — read this before changing any code

If a future change tries to add:
- A modal asking the user to confirm something pre-swing → **wrong, remove it**
- A button labelled "Ready" / "Set address" / "Calibrate now" → **wrong, remove it**
- A rendered marker showing where the user MUST stand → **wrong, foot markers are advisory only**
- Any text instructing the user to "hold phone vertically" → **wrong, putting pose is tilted**
- Any text instructing the user "screen toward you" at address → **wrong, screen faces down/body at address**
- One-handed grip detection / single-hand stillness checks → **wrong, both hands by design**

If a future change goes against this list, **fix the change, not the design**. The design is locked.

---

## 10. Version control bread-crumbs

| Commit | Date | What |
|---|---|---|
| `f06ee52` | 2026-05-30 | B4 — orientation instruction rewrite; dropped "vertical / screen toward you"; introduced two-pose card |
| `816e4c6` | (post-B4) | Cycle 2 — stillness 25° tolerance for natural grip (was 15° in original spec) |
| `e0ee72f` | 2026-06-03 | First (wrong) version of this doc — I read the spec without checking version control |
| **THIS COMMIT** | 2026-06-03 | Corrected — both hands + press-gesture + camera-at-feet + side-at-target |

If the design ever drifts again, search `git log -p --grep="orientation"` to find the next rewrite.

---

## 11. Stale-design watch

These three places STILL say the original (wrong) prescription:

- `CLAUDE.md` §3 decision #2
- `docs/spec-putting-lab-v1-FINAL.md` §1 Table of Locked Decisions row 7
- `docs/spec-putting-lab-v1-FINAL.md` §3 phase 2 ("phone within ±15° of vertical")

**Action:** flag these in the docs as superseded. Don't silently fix unless James OKs editing the spec.

---

*Last updated: 2026-06-03 — after James's point-by-point confirmation. This replaces the earlier (incorrect) version of the same file.*
