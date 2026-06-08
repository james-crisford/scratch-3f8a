import Foundation
import simd

struct FaceAngleSource: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        case arkit
        case compass
        case fallbackArkitLost
        case fallbackNoBaseline
        /// B78 — IMU attitude quaternion delta from press to impact. This is
        /// the only origin the v2 pipeline emits. The legacy cases are kept
        /// for serialization compatibility with pre-B78 logs and tests.
        case pressAttitude
    }

    let radians: Double
    let origin: Origin

    var degrees: Double { radians * 180.0 / .pi }
}

final class FaceAngleComputer: Sendable {

    /// B78 — press-attitude self-calibrating face angle.
    ///
    /// Pre-B78 this fused ARKit camera yaw + magnetometer compass yaw and
    /// subtracted a per-user calibration bias on top. That pipeline
    /// accumulated three independent noise sources (ARKit drift across
    /// sessions, magnetometer interference indoors, mean-of-5 cal-batch
    /// outlier sensitivity) AND coupled to a calibration bias that
    /// shifted -6.58° → +2.37° → -8.90° → +5.64° across four of James's
    /// indoor cal-batches with no real underlying technique change. The
    /// B69 ±3° cap was a stopgap.
    ///
    /// B78's design (James's idea, refined by the b78 workflow):
    ///   1. At press-begin, capture the phone's IMU attitude quaternion.
    ///      That moment IS the user's declared "square" by gesture.
    ///   2. At impact, take the IMU attitude quaternion again.
    ///   3. faceAngle = wrapAngle(yaw(attitudeAtImpact) - yaw(attitudeAtPress)).
    ///
    /// CoreMotion's fused attitude is dominated by the gyroscope at sub-
    /// second timescales (the magnetometer mostly contributes drift
    /// correction over seconds). For a ~700 ms stroke window the yaw
    /// delta is essentially pure gyro integration, which has ~0.5-1.0°
    /// noise — well inside the hardware floor.
    ///
    /// Properties:
    ///   * No world-frame reference → no cross-session drift.
    ///   * No magnetometer subtraction → indoor interference cannot
    ///     introduce a systematic shift between sessions.
    ///   * No bias correction → no overcorrection on a noisy cal batch.
    ///   * The user owns "square" — they press when they feel set, and
    ///     whatever rotation they produce from that moment to impact IS
    ///     their face angle.
    ///
    /// Every B78+ stroke reports `.pressAttitude`. The legacy origin
    /// cases (`.arkit`, `.compass`, `.fallbackArkitLost`,
    /// `.fallbackNoBaseline`) are retained on the enum for
    /// deserialization compatibility with pre-B78 logs/tests but are
    /// never emitted by production code.
    func compute(
        window: StrokeWindow,
        attitudeAtImpact: simd_quatd,
        impactTime: TimeInterval,
        arkitPoses: [ARPose] = [],
        arkitBaselineYaw: Double? = nil
    ) -> FaceAngleSource {
        _ = impactTime
        _ = arkitPoses
        _ = arkitBaselineYaw
        let yawAtPress = ImpactDetector.yawFromQuaternion(window.lock.attitudeAtPress)
        let yawAtImpact = ImpactDetector.yawFromQuaternion(attitudeAtImpact)
        let raw = ImpactDetector.wrapAngle(yawAtImpact - yawAtPress)
        return FaceAngleSource(radians: raw, origin: .pressAttitude)
    }
}
