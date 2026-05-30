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
    /// Once armed, fires when magnitude descends below this (rad/s).
    let disarmThreshold: Double
    /// Minimum gap between successive haptic fires (seconds). Prevents one
    /// noisy peak with a few jittery samples from double-firing.
    let coolDownSeconds: Double

    private var armed: Bool = false
    private var lastFireTime: TimeInterval = -.infinity

    init(
        armThreshold: Double = 2.0,
        disarmThreshold: Double = 1.0,
        coolDownSeconds: Double = 0.4
    ) {
        self.armThreshold = armThreshold
        self.disarmThreshold = disarmThreshold
        self.coolDownSeconds = coolDownSeconds
    }

    /// Reset state at the start of a new stroke (touchDown).
    func reset() {
        armed = false
        lastFireTime = -.infinity
    }

    /// Feed every motion sample during recording. Returns `true` exactly when
    /// the rotation-rate magnitude has just descended through
    /// `disarmThreshold` after having been above `armThreshold` — the
    /// estimated impact peak. Caller should fire a haptic on `true`.
    func consume(_ sample: MotionSample) -> Bool {
        let mag = simd_length(sample.rotationRate)

        // Cool-down rejects rapid double-fires from a single peak with a
        // sample or two of jitter. We still track armed/disarmed transitions
        // so the next legitimate peak after the cool-down still fires.
        if sample.timestamp - lastFireTime < coolDownSeconds {
            if mag >= armThreshold {
                armed = true
            } else if mag <= disarmThreshold {
                armed = false
            }
            return false
        }

        if !armed {
            if mag >= armThreshold {
                armed = true
            }
            return false
        }

        // Armed: fire when magnitude crosses back DOWN through the disarm
        // threshold (the peak is just behind us by 10–30 ms at 100 Hz).
        if mag < disarmThreshold {
            armed = false
            lastFireTime = sample.timestamp
            return true
        }
        return false
    }
}
