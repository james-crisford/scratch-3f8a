---
name: golf-swing-game-design
description: Golf physics, Mario Kart assist rules, calibration model, and game-feel design principles for the PuttingLab project. Use whenever working on result-display logic, the bucket mapping that converts raw face angle to displayed direction, the per-user calibration model, distance estimation, the confidence-snap-to-square rule, or any code that turns raw sensor data into user-facing results.
---

# Golf Swing Game Design (PuttingLab)

This skill bundles the physics + game-feel knowledge from research reports #1, #2, #5 and the spec. Read this BEFORE touching anything in `Physics/MarioKartAssist.swift`, `Physics/DistanceModel.swift`, or the calibration code.

## ⚠️ Known unknowns (pending device verification — do not codify)

As of 2026-05-29, the following are ASSUMPTIONS in the code that have NOT been
verified on a real iPhone. Tomorrow's TestFlight session is the verification
event. Until then, do not present any of these as established truth, and do
not propagate them into other systems:

- **KI-1: pull/push sign convention** — code currently treats `faceAngleRaw < 0`
  as "pull (for righty)". If Batch B/C data tomorrow shows the sign is flipped,
  the convention in `MarioKartAssist.bucket()` flips with it. Both directions
  must be cross-validated, not assumed.
- **KI-2: velocity[0] = 0 baseline** in trapezoidal integration. Assumes the
  stroke window starts from rest. If not, drift accumulates.
- **KI-4: magnetometer corruption by ferromagnetic objects** (steel radiators
  etc.) — paired Batch E will tell us how bad.
- **KI-5: 25° stillness tolerance** for natural grip — may be too tight or too
  loose, paired Batch F will tell us.
- **KI-6: calibration profile brittleness** — if Batch A scatter is huge or
  snap rate >50%, the 5-stroke onboarding is undersampling user variance.

Until each KI has a VERIFIED/REFUTED verdict in `docs/device-verification-day-1.md`,
treat them as live uncertainties.

## Algorithmic deviations from the spec (logged 2026-05-29)

The implementation diverges from the spec in 5 documented ways. These are
INTENTIONAL — do not "fix" them back to the spec.

1. **Trapezoidal vs right-endpoint Riemann integration** in `ImpactDetector` —
   eliminates symmetric-profile ambiguity.
2. **PCA principal axis seeded at `(1,1,1)/√3`**, not `(1,0,0)` — the spec
   seed fails for pure-Y data.
3. **1µs FP tolerance** on all time-window comparisons — robust to
   seconds-since-boot timestamps.
4. **Multiplicative confidence formula** in `MarioKartAssist` — not additive
   as spec implies. Better behaviour at the edges.
5. **ARKit baseline stored on `SessionCoordinator`**, not `StillnessLock` —
   preserves the Day 3 contract.

## Load-bearing patterns that look like overhead (do not remove)

- **ARSession interruption handlers** in `ARTrackingManager` (`sessionWasInterrupted`
  + `sessionInterruptionEnded`) — required for app-backgrounding survival, NOT
  optional. Cycle 5 audit fixed this gap.
- **AsyncStream with `.unbounded` buffering** for motion dispatch — preserves
  sample order AND keeps the stillness window intact under bursty load.
  Cycle 4 + Cycle 5 chose this; do not revert to closures or `.bufferingNewest(N)`.
- **NSLock + `*Locked` private helpers** in `StrokeReplayStore` — NSLock is
  NOT reentrant. The locked-helper pattern is what prevents the
  `clear() → list()` deadlock the audit caught.

## Validating algorithm changes (post-2026-05-30)

Once real-device StrokeReplay JSONs exist in `research_archive/stroke-replays/`,
any change to the physics/bucket/calibration code must:

1. Be expressed as a passing Swift Testing case in `PuttingLabTests/`.
2. Be replayed against the captured StrokeReplay corpus and produce the same
   user-facing result (face direction, snap reason) within tolerance.
3. If the replay output changes, surface that explicitly in the PR description.

This is the closest thing we have to a regression test for sensor algorithms.

## The thesis (do not deviate)

The goal is **a fun, believable, semi-realistic game — NOT a training aid.**

This means:
- Honest physics where possible.
- Generous when uncertain ("err toward square").
- Never confidently wrong (the GolfGo failure mode).
- Always surface the cause, not just the result.

## The physical envelope (research-confirmed)

Phone-only, no audio, no Apple Watch:

| Metric | Confidence | Notes |
|---|---|---|
| Stroke tempo (backswing-to-forward ratio) | ±10–20 ms | Excellent |
| Backswing length (angle) | ±2–3° | Excellent |
| Peak hand speed | ±5–10% | Good |
| Face angle at peak forward velocity | ±10–15° | OK with address-pose calibration |
| Ball roll distance (after user calibration) | ±15–25% | Acceptable for game feel |

Anything claiming more accuracy is wrong. Anything implying less is fine — we can always promise less and deliver more.

## Distance model

```swift
struct DistanceModel {
    let userSpeedCalibration: Double  // from 5-stroke onboarding
    let frictionConstant: Double = 1.7  // tuned by feel during testing

    func roll(forPeakSpeed peakSpeedMps: Double) -> (distance: Double, lowBand: Double, highBand: Double) {
        // Translate peak hand speed into ball speed via per-user constant
        let ballSpeedMps = peakSpeedMps * userSpeedCalibration
        let ballSpeedFps = ballSpeedMps * 3.281

        // Roll distance: empirical exponent, tuned
        let distance = pow(ballSpeedFps, 1.6) / frictionConstant

        // Confidence band: always ±15%
        let lowBand = distance * 0.85
        let highBand = distance * 1.15

        // Small random jitter for game feel (NOT the confidence band — this is "feel")
        let jitter = Double.random(in: -0.05...0.05)
        let displayed = distance * (1.0 + jitter)

        return (displayed, lowBand, highBand)
    }
}
```

Always display the band, e.g. `"18 ft (est. 15–21 ft)"`. Honesty about uncertainty is the whole point.

## Mario Kart assist bucket mapping

The CORE game-feel rule. Raw face angle is honest; *displayed* face angle is generous.

```swift
enum DisplayedDirection {
    case square           // ±0° displayed
    case slightPullPush   // ±4–8° displayed (curve start direction)
    case pullPush         // ±12–18° displayed
    case miss             // ±20–30° displayed, capped at 30°
}

func bucket(faceAngleRaw: Double, confidence: Double) -> (label: String, displayDegrees: Double) {
    // Confidence-low → snap to square
    guard confidence > 0.5 else {
        return ("Square — didn't catch a clean read", 0)
    }

    let abs_ = abs(faceAngleRaw)
    let sign = faceAngleRaw < 0 ? -1.0 : 1.0  // negative = closed = pull (for righty)
    let direction = sign < 0 ? "Pull" : "Push"

    switch abs_ {
    case ..<6:
        return ("Square ✓", 0)

    case 6..<12:
        let displayed = 6.0 * sign
        return ("Slight \(direction.lowercased()) — face was \(Int(abs_))° \(sign < 0 ? "closed" : "open")", displayed)

    case 12..<20:
        let displayed = 14.0 * sign
        return ("\(direction) — face was \(Int(abs_))° \(sign < 0 ? "closed" : "open") at impact", displayed)

    default:
        let displayed = min(28.0, abs_) * sign
        return ("Miss \(direction == "Pull" ? "left" : "right") — face was \(Int(abs_))°", displayed)
    }
}
```

### The bucket numbers explained

- **±6° threshold for "Square"**: matches our ±10–15° measurement uncertainty. A raw reading within 6° is well within the noise.
- **Display 4–8° for the 6–12° bucket**: the user sees a slight curve, not the full raw value. Generous but visible.
- **Cap at 30°**: any further is uninterpretable. The display becomes "Miss" rather than a wider angle.

### The 4 confidence-low snap conditions

If ANY of the following is true, the bucket FORCES "Square — didn't catch a clean read":
1. ARKit tracking was lost during >50% of the stroke window.
2. Stroke duration < 200ms (too fast — flick, not stroke).
3. No clear forward-velocity peak (no obvious impact moment).
4. Peak hand speed < 0.3 m/s (barely moved).

## The three Wii Sports Tennis rules (research #5)

1. **Err toward square when uncertain.** Never call a direction when confidence is low.
2. **Surface the cause, not just the result.** "Pull 6° — face was closed at impact" > "You missed left".
3. **Never invent direction the user clearly didn't produce.** If IMU shows barely-rotated, don't fabricate a hook for "variety". The user knows what they did.

These are non-negotiable. If a future feature would violate one of them, the feature loses.

## Calibration model (5-stroke onboarding)

After the user's first 5 strokes, compute:

```swift
struct CalibrationProfile: Codable {
    let userTempoBaseline: Double          // mean backswing/forward ratio
    let userSpeedCalibration: Double       // peak speed → distance factor
    let userDistanceCalibration: Double    // inverse of above for clarity
    let userFaceAngleBias: Double          // mean systematic pull/push to subtract
    let userSwingPlaneAxis: SIMD3<Double>  // mean PCA principal axis
    let yawTargetCompass: Double           // address-locked reference (not really user-specific but live here)
    let yawTargetArkit: Double             // address-locked reference
    let arkitBaselineStability: Double     // mean ARKit drift during calibration
    let calibrationDate: Date
}
```

### How to compute each

- **userTempoBaseline**: arithmetic mean of (backswingDuration / forwardDuration) across the 5 strokes.
- **userSpeedCalibration**: assume the user was aiming at the target distance shown on screen during calibration. mean(peakSpeed) / targetDistance gives the constant. Refine with each calibration session.
- **userFaceAngleBias**: arithmetic mean of `faceAngleRaw` across the 5 strokes. If user systematically pulls, subtract that bias from future readings. (This is what removes GolfGo's "every shot is a hook" — that bias is the user's natural release pattern.)
- **userSwingPlaneAxis**: mean of the per-stroke PCA principal axis. Re-orthogonalise if needed.
- **arkitBaselineStability**: standard deviation of ARKit pose during the address-pose windows. Used to decide ARKit vs compass weighting in future strokes.

### Storage

```swift
extension UserDefaults {
    var calibrationProfile: CalibrationProfile? {
        get {
            guard let data = data(forKey: "calibrationProfile") else { return nil }
            return try? JSONDecoder().decode(CalibrationProfile.self, from: data)
        }
        set {
            guard let value = newValue, let data = try? JSONEncoder().encode(value) else {
                removeObject(forKey: "calibrationProfile")
                return
            }
            set(data, forKey: "calibrationProfile")
        }
    }
}
```

### Ongoing recalibration

At end of every practice session, prompt: *"Tune sharper? (+3 strokes)"*. Adds 3 strokes to a running mean — gradually drifts the calibration toward the user's actual current technique.

## Tempo display

Show as a ratio with context:

```
2.1 — your norm
```

`your norm` is the user's calibrated `userTempoBaseline` rounded to 1 dp. If the current stroke's tempo is within 0.2 of norm: "your norm". If above by >0.2: "quicker than usual". If below by >0.2: "slower than usual".

Don't make the user feel judged about their tempo. It's context, not a grade.

## Strikes the app should explicitly REFUSE to comment on

Even though the sensors COULD say something:
- **Strike location on the putter face** — impossible without a sensor on the club. Don't fake it.
- **Greens slope effect** — no terrain data. Don't simulate it.
- **Putt direction left/right beyond ±30°** — meaningless. Cap at "Miss left/right".

## Result panel content (final UI consumption)

For every stroke result, the result panel should show, in this order:
1. **Distance** (large) — `18 ft (est. 15–21 ft)`
2. **Face chip** — `Square ✓` / `Slight pull — face was 7° closed` / etc. Colour-coded (green/yellow/red).
3. **Tempo** — `2.1 — your norm`
4. **Replay** button — small icon.

NEVER show:
- Raw face angle in degrees (only the bucketed display value).
- Confidence score as a number.
- The internal sensor data (gyro/accel readings).

## Test cases (for `golf-swing-game-design` related tests)

- A simulated "perfect" stroke (face angle 0°, peak speed at target) → result: "Square ✓", distance within ±10% of target.
- A simulated "pulled" stroke (face angle -10°) → result: "Slight pull — face was 10° closed". Display angle = 6° (capped).
- A simulated "fast flick" (stroke duration 150ms) → confidence-low, force "Square — didn't catch a clean read".
- A simulated "no peak" (constant velocity) → confidence-low, throw or snap to square.

## When to deviate from this skill

You DON'T. This is the contract. Any change to the bucket numbers, the confidence rules, or the surfacing-cause-not-result principle goes in v1.1, not v1.

## References

- `docs/research/research-1-imu-swing-physics.md` — physics envelope
- `docs/research/research-2-golfer-jtbd.md` — JTBD (Mario Kart assist comes from here)
- `docs/research/research-5-multisensor-swing-detection.md` — Wii Sports Tennis rules
- `docs/spec-putting-lab-v1-FINAL.md` — the spec this skill implements
