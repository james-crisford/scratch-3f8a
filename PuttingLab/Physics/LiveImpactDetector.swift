import Foundation
import simd

/// Real-time "impact moment" detector for haptic feedback during a stroke.
///
/// The full ImpactDetector runs only AFTER touchUp because it needs the whole
/// window to compute principal axis + integrate velocity + drift-correct. That
/// gives perfect impact time post-hoc but zero feedback during the swing — so
/// the user can't judge whether their felt impact matched the algorithm.
///
/// This live detector is a cheap proxy: it watches |rotationRate| magnitude
/// and fires when the magnitude descends back through `disarmThreshold` after
/// having peaked above `armThreshold`. For putting strokes the wrist-roll peak
/// in rotation rate aligns closely with peak forward hand velocity (within
/// ~20 ms in James's calibration data), which is "impact" by the algorithm's
/// definition.
///
/// **Per-stroke usage**: call `reset()` on touchDown, feed every sample into
/// `consume(_:)` while phase == .recording, fire a strong haptic each time
/// the call returns true (typically once or twice per stroke — top-of-backswing
/// + forward-swing peak; the LAST tap before release is the impact one).
@MainActor
final class LiveImpactDetector {
    /// Magnitude must exceed this to "arm" (rad/s). Default tuned to putting:
    /// James's 5 sample strokes peaked at 2.1–3.1 rad/s, baseline ~0.5 rad/s.
    let armThreshold: Double
    /// Fallback fire trigger: if the peak-confirmation path never fires for
    /// some reason (very flat decay, etc.), descending past this magnitude
    /// fires anyway. Acts as a safety net so the haptic always lands.
    let disarmThreshold: Double
    /// Number of consecutive samples where |ω| < maxMagSinceArmed required
    /// to confirm we've passed the rotation-rate peak. Build 13 default = 1
    /// (~10 ms latency from true peak) after the B12 first-session data
    /// showed James judging 11/12 strokes "felt late" — the +30 ms B11/B12
    /// confirmation latency was perceptible on top of the algorithm impact
    /// already being slightly post-perceived-contact. Higher = more noise
    /// rejection but more latency.
    let peakConfirmationSamples: Int
    /// Minimum drop from `maxMagSinceArmed` required for the
    /// peak-confirmation fire path to trigger. Build 13 default = 0.02 (2 %)
    /// — tighter than B11/B12's 5 % to fire closer to the actual peak time.
    /// Still suppresses sub-1 % noise on the arm-threshold plateau (the
    /// stroke #5 false-fire case from B11) but no longer waits for the
    /// magnitude to drop a full 5 % from peak before declaring impact.
    let minPeakDropFraction: Double
    /// Minimum gap between successive haptic fires (seconds). Prevents one
    /// noisy peak with a few jittery samples from double-firing.
    let coolDownSeconds: Double
    /// Consecutive below-disarm samples required at the START of a stroke
    /// before arming is permitted. Prevents a wrist-flick during touchDown
    /// from immediately tripping a phantom "impact" haptic — the detector
    /// must see proof that the user actually settled into address before it
    /// will recognise a peak. 5 samples at 100 Hz = 50 ms.
    let warmUpSamplesBelowDisarm: Int
    /// Minimum elapsed time after touchDown (= first sample of the stroke)
    /// before any fire is allowed. Suppresses backswing-peak fires entirely
    /// on James's strokes (B13 data: backswing peaks 469–1023 ms, forward
    /// swing peaks 994–2317 ms — a 1.0 s gate suppresses every backswing
    /// fire while preserving every forward-swing fire). Set to 0 to disable
    /// the gate (e.g. in unit tests that don't simulate the full stroke).
    let minFireDelayFromTouchDownSeconds: Double

    private var armed: Bool = false
    private var lastFireTime: TimeInterval = -.infinity
    private var consecutiveBelowDisarm: Int = 0
    private var warmedUp: Bool = false
    /// B67 — session-wide warm-up latch. Once `forceWarmUp()` is called
    /// (or warm-up completes naturally once during a stroke), this stays
    /// true for the lifetime of the detector. `reset()` keeps it set so
    /// the per-stroke `warmedUp` re-arms immediately on the next sample,
    /// instead of restarting the 5-sample below-disarm count from zero.
    /// Without this, the per-stroke warm-up could miss the very first
    /// stroke (and any stroke where the user presses + immediately
    /// swings rather than holding the address pose for ≥ 50 ms).
    private var sessionWarmedUp: Bool = false
    /// Maximum |ω| seen during the current armed window. Used to detect
    /// "we just passed the peak" by counting samples that descend from it.
    private var maxMagSinceArmed: Double = 0
    /// Count of consecutive samples whose magnitude was below
    /// `maxMagSinceArmed`. Reset to 0 every time a new max is recorded.
    /// When this hits `peakConfirmationSamples`, we fire.
    private var consecutiveBelowMax: Int = 0
    /// Timestamp of the first sample observed since the last reset(). Used
    /// to gate fires by `minFireDelayFromTouchDownSeconds`. -.infinity =
    /// not yet seen any sample.
    private var touchDownTimestamp: TimeInterval = -.infinity

    init(
        armThreshold: Double = 1.7,
        disarmThreshold: Double = 1.0,
        peakConfirmationSamples: Int = 1,
        minPeakDropFraction: Double = 0.015,
        coolDownSeconds: Double = 0.4,
        warmUpSamplesBelowDisarm: Int = 5,
        minFireDelayFromTouchDownSeconds: Double = 1.0
    ) {
        precondition(
            armThreshold > disarmThreshold,
            "armThreshold (\(armThreshold)) must be > disarmThreshold (\(disarmThreshold)) " +
            "otherwise the rising/falling cross-detection cannot fire."
        )
        precondition(
            peakConfirmationSamples >= 1,
            "peakConfirmationSamples must be >= 1"
        )
        precondition(
            minPeakDropFraction >= 0 && minPeakDropFraction < 1,
            "minPeakDropFraction must be in [0, 1)"
        )
        precondition(coolDownSeconds >= 0, "coolDownSeconds must be non-negative")
        precondition(warmUpSamplesBelowDisarm >= 0, "warmUpSamplesBelowDisarm must be non-negative")
        precondition(minFireDelayFromTouchDownSeconds >= 0, "minFireDelayFromTouchDownSeconds must be non-negative")
        self.armThreshold = armThreshold
        self.disarmThreshold = disarmThreshold
        self.peakConfirmationSamples = peakConfirmationSamples
        self.minPeakDropFraction = minPeakDropFraction
        self.coolDownSeconds = coolDownSeconds
        self.warmUpSamplesBelowDisarm = warmUpSamplesBelowDisarm
        self.minFireDelayFromTouchDownSeconds = minFireDelayFromTouchDownSeconds
    }

    /// Reset state at the start of a new stroke (touchDown).
    ///
    /// B67 — does NOT clear `sessionWarmedUp`. Once the detector has
    /// seen a quiescent baseline (either naturally during a previous
    /// stroke or via `forceWarmUp()` from the AR view's onAppear), every
    /// subsequent stroke arms immediately on the first sample. Without
    /// this latch the very first stroke can miss its haptic when the
    /// user presses + swings without holding (AR7 stroke 1
    /// `live_haptic_fires = 0`); the wrist-flick gate is still enforced
    /// by `minFireDelayFromTouchDownSeconds` (1.0 s post-touchDown), so
    /// pre-baseline phantom fires remain suppressed.
    func reset() {
        armed = false
        lastFireTime = -.infinity
        consecutiveBelowDisarm = 0
        warmedUp = sessionWarmedUp
        maxMagSinceArmed = 0
        consecutiveBelowMax = 0
        touchDownTimestamp = -.infinity
    }

    /// B67 — preempt warm-up so the very first stroke of an AR session
    /// can fire a haptic. AR7 stroke 1 had `live_haptic_fires = 0`
    /// because the 5-sample below-disarm warm-up requirement had not
    /// completed by the time the user took their first putt: the motion
    /// stream had been running long enough that the warm-up *could* have
    /// succeeded, but `reset()` cleared it on touchDown and the stroke
    /// began before 5 sub-disarm samples accumulated. Strokes 2-5 all
    /// fired because the post-stroke quiescent window satisfied warm-up.
    ///
    /// Call this from ARPlacementView.onAppear ≥200 ms after starting
    /// the motion stream — by then the IMU has produced enough samples
    /// to confirm a quiescent baseline. The `sessionWarmedUp` latch
    /// then survives every subsequent `reset()`.
    func forceWarmUp() {
        warmedUp = true
        sessionWarmedUp = true
        consecutiveBelowDisarm = warmUpSamplesBelowDisarm
    }

    /// Feed every motion sample during recording. Returns `true` exactly when
    /// the rotation-rate magnitude has just descended through
    /// `disarmThreshold` after having been above `armThreshold` — the
    /// estimated impact peak. Caller should fire a haptic on `true`.
    func consume(_ sample: MotionSample) -> Bool {
        // Defence: a non-finite timestamp (CoreMotion clock-jump during
        // background restore, or a corrupted replay) would make every
        // cool-down comparison NaN — comparisons against NaN are always
        // false, so we'd skip the cool-down check AND eventually set
        // `lastFireTime` to non-finite, permanently disabling the detector
        // until reset(). Reject the sample outright instead.
        guard sample.timestamp.isFinite else { return false }

        let mag = simd_length(sample.rotationRate)
        // Same defence for magnitude: NaN/Inf rotation never fires.
        guard mag.isFinite else { return false }

        // Latch the touchDown timestamp on the first sample after reset().
        if touchDownTimestamp == -.infinity {
            touchDownTimestamp = sample.timestamp
        }
        // Fire-delay gate: from B13 80-stroke data, backswing-peak fires
        // cluster 469–1023 ms after touchDown while forward-swing (impact)
        // fires cluster 994–2317 ms. A 1.0 s gate suppresses every
        // backswing fire but preserves every forward-swing fire. State is
        // still tracked during the gate so the detector arms naturally
        // once the gate expires.
        let elapsedSinceTouchDown = sample.timestamp - touchDownTimestamp
        let inFireGate = elapsedSinceTouchDown < minFireDelayFromTouchDownSeconds

        // Warm-up: require N consecutive samples below disarm before we
        // permit any arming. Stops a touchDown-time wrist flick from firing
        // a phantom haptic on the FIRST sample of the stroke.
        if !warmedUp {
            if mag <= disarmThreshold {
                consecutiveBelowDisarm += 1
                if consecutiveBelowDisarm >= warmUpSamplesBelowDisarm {
                    warmedUp = true
                    // B67 — latch the session-wide warm-up so every
                    // subsequent stroke can fire immediately without
                    // re-counting 5 sub-disarm samples per stroke.
                    sessionWarmedUp = true
                }
            } else {
                consecutiveBelowDisarm = 0
            }
            return false
        }

        // Cool-down: hard suppression for `coolDownSeconds` after a fire.
        // We do NOT track armed/max state during cool-down — that lets a
        // stale max-since-arm from the just-fired peak linger, then trigger
        // a spurious second fire as soon as the cool-down expires (the
        // failure mode that the realisticPuttingProfileWithWarmUp test
        // exposed on a slow-decay synthetic stroke). After cool-down ends
        // we restart cleanly: armed=false, no max — the next genuine peak
        // re-arms and confirms.
        if sample.timestamp - lastFireTime < coolDownSeconds {
            armed = false
            maxMagSinceArmed = 0
            consecutiveBelowMax = 0
            return false
        }

        if !armed {
            if mag >= armThreshold {
                armed = true
                maxMagSinceArmed = mag
                consecutiveBelowMax = 0
            }
            return false
        }

        // Armed: PEAK-CONFIRMATION path (fires ~30 ms after the true peak).
        // Track max-since-arm; count consecutive samples that fall below
        // it. Fire only when BOTH conditions hold:
        //   1. ≥ `peakConfirmationSamples` consecutive below-max samples
        //      (rejects a single noisy descent during the rise).
        //   2. Current mag is ≥ `minPeakDropFraction` below max (rejects
        //      sub-1 % jitter on the arm-threshold plateau which would
        //      otherwise produce a false-positive fire — see stroke #5).
        // Calibrated on James's 5 B7 strokes (Build 11): all 5 strokes
        // land within ±80 ms of the algorithm's chosen impact time.
        if mag > maxMagSinceArmed {
            maxMagSinceArmed = mag
            consecutiveBelowMax = 0
        } else if mag < maxMagSinceArmed {
            consecutiveBelowMax += 1
            let dropTrigger = maxMagSinceArmed * (1.0 - minPeakDropFraction)
            if consecutiveBelowMax >= peakConfirmationSamples && mag < dropTrigger {
                armed = false
                maxMagSinceArmed = 0
                consecutiveBelowMax = 0
                // Inside the fire gate, suppress haptic but still update
                // lastFireTime so the cool-down logic stays consistent.
                lastFireTime = sample.timestamp
                return !inFireGate
            }
        }
        // Safety-net fallback for very-slow descents: classic disarm-cross.
        if mag < disarmThreshold {
            armed = false
            maxMagSinceArmed = 0
            consecutiveBelowMax = 0
            lastFireTime = sample.timestamp
            return !inFireGate
        }
        return false
    }
}
