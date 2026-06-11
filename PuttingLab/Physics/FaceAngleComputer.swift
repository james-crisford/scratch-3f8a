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
    ///   3. faceAngle = wrapAngle(yaw(attitudeAtPress) - yaw(attitudeAtImpact)).
    ///
    /// B80 — SIGN CONVENTION (golf convention, enforced HERE and only here):
    ///   negative = closed face = pull = ball LEFT of the target line;
    ///   positive = open face = push = ball RIGHT (right-handed golfer).
    /// CoreMotion attitude yaw is CCW-positive viewed from above, and for a
    /// right-handed golfer (target on his left) CLOSING the face rotates the
    /// face normal CCW — i.e. closed = POSITIVE raw IMU delta. B78 emitted
    /// `yaw(impact) - yaw(press)` directly, so every label downstream
    /// (BallPhysics §3.3, MarioKartAssist, the result panel) — all of which
    /// document "negative = closed/pull/left" — was inverted vs reality.
    /// The b79 session proved it: three intended-square strokes read
    /// -17.9/-10.9/-12.3 (labelled "pull — ball goes left") while the video
    /// showed all three rolls missing RIGHT. The deltas were real clockwise
    /// = OPEN rotations. Negating at the producer (press - impact) makes
    /// every existing consumer true with zero edits. The yaw-delta identity
    /// itself is exact for this grip: a world-vertical rotation θ
    /// premultiplies the attitude by Rz(θ) and ZYX-yaw(Rz(θ)·R) = yaw(R)+θ
    /// while the device X axis stays off vertical (James's grip keeps
    /// gravity.x ≈ 0, so no gimbal trouble; cross-axis crosstalk ≤ ~3° even
    /// at ±20° pitch / ±5° roll swings).
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
        // B80 — golf-sign convention: negative = closed/pull/left. CoreMotion
        // yaw is CCW-positive = closed for an RH golfer, hence press - impact
        // (NOT impact - press as in B78/B79; see the doc block above).
        let raw = ImpactDetector.wrapAngle(yawAtPress - yawAtImpact)
        return FaceAngleSource(radians: raw, origin: .pressAttitude)
    }
}
