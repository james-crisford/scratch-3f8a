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
    /// to confirm we've passed the rotation-rate peak. 3 samples at 100 Hz
    /// = ~30 ms latency from true peak — calibrated on James's 5 B7
    /// strokes to land within 0–80 ms of the algorithm's chosen impact
    /// time (vs. 274–388 ms for the original disarm-cross logic).
    /// Higher = more noise rejection but more latency.
    let peakConfirmationSamples: Int
    /// Minimum gap between successive haptic fires (seconds). Prevents one
    /// noisy peak with a few jittery samples from double-firing.
    let coolDownSeconds: Double
    /// Consecutive below-disarm samples required at the START of a stroke
    /// before arming is permitted. Prevents a wrist-flick during touchDown
    /// from immediately tripping a phantom "impact" haptic — the detector
    /// must see proof that the user actually settled into address before it
    /// will recognise a peak. 5 samples at 100 Hz = 50 ms.
    let warmUpSamplesBelowDisarm: Int

    private var armed: Bool = false
    private var lastFireTime: TimeInterval = -.infinity
    private var consecutiveBelowDisarm: Int = 0
    private var warmedUp: Bool = false
    /// Maximum |ω| seen during the current armed window. Used to detect
    /// "we just passed the peak" by counting samples that descend from it.
    private var maxMagSinceArmed: Double = 0
    /// Count of consecutive samples whose magnitude was below
    /// `maxMagSinceArmed`. Reset to 0 every time a new max is recorded.
    /// When this hits `peakConfirmationSamples`, we fire.
    private var consecutiveBelowMax: Int = 0

    init(
        armThreshold: Double = 2.0,
        disarmThreshold: Double = 1.0,
        peakConfirmationSamples: Int = 3,
        coolDownSeconds: Double = 0.4,
        warmUpSamplesBelowDisarm: Int = 5
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
        precondition(coolDownSeconds >= 0, "coolDownSeconds must be non-negative")
        precondition(warmUpSamplesBelowDisarm >= 0, "warmUpSamplesBelowDisarm must be non-negative")
        self.armThreshold = armThreshold
        self.disarmThreshold = disarmThreshold
        self.peakConfirmationSamples = peakConfirmationSamples
        self.coolDownSeconds = coolDownSeconds
        self.warmUpSamplesBelowDisarm = warmUpSamplesBelowDisarm
    }

    /// Reset state at the start of a new stroke (touchDown).
    func reset() {
        armed = false
        lastFireTime = -.infinity
        consecutiveBelowDisarm = 0
        warmedUp = false
        maxMagSinceArmed = 0
        consecutiveBelowMax = 0
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

        // Warm-up: require N consecutive samples below disarm before we
        // permit any arming. Stops a touchDown-time wrist flick from firing
        // a phantom haptic on the FIRST sample of the stroke.
        if !warmedUp {
            if mag <= disarmThreshold {
                consecutiveBelowDisarm += 1
                if consecutiveBelowDisarm >= warmUpSamplesBelowDisarm {
                    warmedUp = true
                }
            } else {
                consecutiveBelowDisarm = 0
            }
            return false
        }

        // Cool-down rejects rapid double-fires from a single peak with a
        // sample or two of jitter. We still track armed/disarmed transitions
        // so the next legitimate peak after the cool-down still fires.
        if sample.timestamp - lastFireTime < coolDownSeconds {
            if mag >= armThreshold {
                armed = true
                if mag > maxMagSinceArmed { maxMagSinceArmed = mag }
            } else if mag <= disarmThreshold {
                armed = false
                maxMagSinceArmed = 0
                consecutiveBelowMax = 0
            }
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
        // it. When that count hits `peakConfirmationSamples`, we're past
        // the peak. Calibrated on James's 5 B7 strokes: this typically
        // fires 0–80 ms after the algorithm's chosen impact time (vs.
        // 274–388 ms for the original disarm-cross fallback).
        if mag > maxMagSinceArmed {
            maxMagSinceArmed = mag
            consecutiveBelowMax = 0
        } else if mag < maxMagSinceArmed {
            consecutiveBelowMax += 1
            if consecutiveBelowMax >= peakConfirmationSamples {
                armed = false
                maxMagSinceArmed = 0
                consecutiveBelowMax = 0
                lastFireTime = sample.timestamp
                return true
            }
        }
        // Safety-net fallback for very-slow descents: classic disarm-cross.
        if mag < disarmThreshold {
            armed = false
            maxMagSinceArmed = 0
            consecutiveBelowMax = 0
            lastFireTime = sample.timestamp
            return true
        }
        return false
    }
}
