import Foundation
import simd
@testable import PuttingLab

// H5 testbed — synthetic strokes with a KNOWN true ball-passage time and
// a face that sweeps through impact at a controlled rate, so the error
// introduced by sampling the face at peak-hand-velocity (the shipped
// definition of "impact") can be measured against ground truth using the
// REAL ImpactDetector.
//
// Ground-truth model: the ball sits at the hand's address position
// (x = 0). Ball passage = the instant the forward swing re-crosses x = 0.
// Hand velocity: -Vb*sin(pi*t/t1) backswing, +Vf*sin(pi*(t-t1)/t2)
// forward — both phases start and end at rest, so the detector's
// end-velocity drift correction is a no-op on clean data.
//
// LIMITS: synthetic-only. Clean IMU (no noise/drift), planar swing,
// linear face sweep. Proves the sampling-time sensitivity and prototypes
// the re-approach fix candidate; the shipped fix must be validated on
// real ARKit pose tracks (B81 data, not yet collectable).

struct SyntheticStroke {
    let window: StrokeWindow
    let trueImpactTime: TimeInterval
    let trueFaceDeg: Double
}

func makeSweepStroke(
    backswingSpeed: Double,
    backswingDur: Double,
    forwardSpeed: Double,
    forwardDur: Double,
    faceSweepDegPerSec: Double,
    hz: Double = 100
) -> SyntheticStroke? {
    let t1 = backswingDur
    let t2 = forwardDur
    let backswingDisp = backswingSpeed * 2 * t1 / .pi
    let forwardTravelCap = forwardSpeed * 2 * t2 / .pi
    guard forwardTravelCap > backswingDisp else { return nil }

    // Analytic ball-passage time: forward displacement equals backswing.
    let tau = t1 + (t2 / .pi) * acos(1 - backswingDisp * .pi / (forwardSpeed * t2))

    let pad = 0.10
    let total = t1 + t2 + 2 * pad
    let dt = 1.0 / hz
    let omega = faceSweepDegPerSec * .pi / 180

    func handAccel(_ t: Double) -> Double {
        if t < 0 || t > t1 + t2 { return 0 }
        if t < t1 { return -backswingSpeed * (.pi / t1) * cos(.pi * t / t1) }
        return forwardSpeed * (.pi / t2) * cos(.pi * (t - t1) / t2)
    }
    // Face yaw sweeps linearly through the stroke; zero at press (t = -pad
    // relative to swing start, i.e. first sample) so attitudeAtPress is
    // the identity-yaw reference the v3 pipeline expects.
    func yaw(_ t: Double) -> Double { omega * (t + pad) }

    var samples: [MotionSample] = []
    var t = -pad
    while t <= t1 + t2 + pad {
        samples.append(MotionSample(
            timestamp: 100.0 + t,
            rotationRate: SIMD3(0, 0, omega),
            userAcceleration: SIMD3(handAccel(t), 0, 0),
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(angle: yaw(t), axis: SIMD3(0, 0, 1))
        ))
        t += dt
    }

    let lock = StillnessLock(
        yawTargetCompass: 0,
        attitudeAtPress: samples[0].attitude,
        gravity: SIMD3(0, -1, 0),
        lockedAt: samples[0].timestamp
    )
    let window = StrokeWindow(
        start: samples[0].timestamp,
        end: samples[samples.count - 1].timestamp,
        samples: samples,
        lock: lock
    )
    // v3 golf sign: face = wrap(yawPress - yawImpact).
    let trueFace = ImpactDetector.wrapAngle(yaw(-pad) - yaw(tau)) * 180 / .pi
    return SyntheticStroke(
        window: window,
        trueImpactTime: 100.0 + tau,
        trueFaceDeg: trueFace
    )
}

/// Fix-candidate prototype: ball passage = the forward-phase re-approach
/// of the integrated hand position to the address position (x = 0).
/// Mirrors the detector's integration (trapezoid + linear drift
/// correction) so the candidate uses the same signal the detector already
/// has. On clean synthetic data this recovers tau; on real data the
/// shipped version should use ARKit poses instead of IMU double
/// integration (drift).
func reapproachTime(window: StrokeWindow) -> TimeInterval? {
    let samples = window.samples
    guard samples.count >= 3 else { return nil }
    let n = samples.count
    let accels = samples.map { $0.userAcceleration.x }
    let dt = (samples[n - 1].timestamp - samples[0].timestamp) / Double(n - 1)

    var velocity = [Double](repeating: 0, count: n)
    for i in 1..<n {
        velocity[i] = velocity[i - 1] + 0.5 * (accels[i] + accels[i - 1]) * dt
    }
    let drift = velocity[n - 1]
    for i in 0..<n {
        velocity[i] -= drift * Double(i) / Double(n - 1)
    }
    var position = [Double](repeating: 0, count: n)
    for i in 1..<n {
        position[i] = position[i - 1] + 0.5 * (velocity[i] + velocity[i - 1]) * dt
    }
    // Deepest backswing, then the first forward re-crossing of x = 0.
    guard let minIdx = position.indices.min(by: { position[$0] < position[$1] }),
          position[minIdx] < 0 else { return nil }
    for i in (minIdx + 1)..<n where position[i] >= 0 {
        let x0 = position[i - 1], x1 = position[i]
        let frac = x1 == x0 ? 0 : -x0 / (x1 - x0)
        return samples[i - 1].timestamp + frac * dt
    }
    return nil
}

func faceAtTime(_ time: TimeInterval, window: StrokeWindow) -> Double {
    let samples = window.samples
    var idx = 0
    for i in 0..<(samples.count - 1) where samples[i].timestamp <= time {
        idx = i
    }
    let s0 = samples[idx], s1 = samples[min(idx + 1, samples.count - 1)]
    let span = s1.timestamp - s0.timestamp
    let frac = span > 0 ? min(max((time - s0.timestamp) / span, 0), 1) : 0
    let att = simd_slerp(s0.attitude, s1.attitude, frac)
    let raw = ImpactDetector.wrapAngle(
        ImpactDetector.yawFromQuaternion(window.lock.attitudeAtPress)
            - ImpactDetector.yawFromQuaternion(att))
    return raw * 180 / .pi
}

func cmdH5() {
    struct Profile { let name: String; let vb: Double; let t1: Double; let vf: Double; let t2: Double }
    let profiles = [
        Profile(name: "symmetric", vb: 0.3, t1: 0.40, vf: 1.0, t2: 0.40),
        Profile(name: "quick-hit", vb: 0.3, t1: 0.40, vf: 1.2, t2: 0.25),
        Profile(name: "long-follow", vb: 0.3, t1: 0.40, vf: 0.8, t2: 0.60),
        Profile(name: "soft-1m", vb: 0.15, t1: 0.45, vf: 0.4, t2: 0.45),
    ]
    let sweeps: [Double] = [0, 10, 30, 60, 90]

    print("=== plab h5 — face-at-peak-velocity sampling error (real ImpactDetector on synthetic ground truth) ===")
    print("true impact = forward re-crossing of address position; sweep = face rotation rate through impact")
    print("")
    print("profile,sweep_dps,true_impact_ms,detected_peak_ms,dt_ms,true_face_deg,detected_face_deg,error_deg,candidate_dt_ms,candidate_error_deg")

    for p in profiles {
        for omega in sweeps {
            guard let s = makeSweepStroke(
                backswingSpeed: p.vb, backswingDur: p.t1,
                forwardSpeed: p.vf, forwardDur: p.t2,
                faceSweepDegPerSec: omega) else {
                print("\(p.name),\(f(omega, 0)),DEGENERATE (forward travel < backswing)")
                continue
            }
            guard let r = try? ImpactDetector().detect(in: s.window) else {
                print("\(p.name),\(f(omega, 0)),DETECT FAILED")
                continue
            }
            let t0 = s.window.samples[0].timestamp
            let detFace = r.faceAngleRaw * 180 / .pi
            let dtMs = (r.timestamp - s.trueImpactTime) * 1000

            var candDtMs = Double.nan
            var candErr = Double.nan
            if let tCand = reapproachTime(window: s.window) {
                candDtMs = (tCand - s.trueImpactTime) * 1000
                candErr = faceAtTime(tCand, window: s.window) - s.trueFaceDeg
            }
            print([
                p.name, f(omega, 0),
                f((s.trueImpactTime - t0) * 1000, 1),
                f((r.timestamp - t0) * 1000, 1),
                f(dtMs, 1),
                f(s.trueFaceDeg, 2), f(detFace, 2), f(detFace - s.trueFaceDeg, 2),
                f(candDtMs, 1), f(candErr, 2),
            ].joined(separator: ","))
        }
    }
    print("")
    print("Reading: error_deg is what the shipped pipeline over/under-reads purely from WHEN it samples the face;")
    print("candidate_* shows the re-approach definition recovering ground truth on the same samples.")
    print("CAVEAT: clean synthetic IMU. Real-data validation requires ARKit pose tracks (B81 ship).")
}
