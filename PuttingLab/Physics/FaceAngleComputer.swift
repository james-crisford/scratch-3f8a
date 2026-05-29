import Foundation
import simd

struct FaceAngleSource: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        case arkit
        case compass
        case fallbackArkitLost
        case fallbackNoBaseline
    }

    let radians: Double
    let origin: Origin

    var degrees: Double { radians * 180.0 / .pi }
}

final class FaceAngleComputer: Sendable {

    func compute(
        window: StrokeWindow,
        attitudeAtImpact: simd_quatd,
        impactTime: TimeInterval,
        arkitPoses: [ARPose] = [],
        arkitBaselineYaw: Double? = nil
    ) -> FaceAngleSource {
        let arkitAvailable = !arkitPoses.isEmpty
        // Spec §2.5: fallback when >50% of poses are non-.normal during the window.
        let normalCount = arkitPoses.filter { $0.trackingState.isNormal }.count
        let arkitClean = arkitAvailable && Double(normalCount) / Double(arkitPoses.count) > 0.5

        if arkitClean, let baseline = arkitBaselineYaw,
           let arkitYaw = arkitYawAt(impactTime, in: arkitPoses) {
            let raw = ImpactDetector.wrapAngle(arkitYaw - baseline)
            return FaceAngleSource(radians: raw, origin: .arkit)
        }

        let compassYaw = ImpactDetector.yawFromQuaternion(attitudeAtImpact)
        let raw = ImpactDetector.wrapAngle(compassYaw - window.lock.yawTargetCompass)

        let origin: FaceAngleSource.Origin
        if arkitAvailable {
            origin = arkitClean ? .fallbackNoBaseline : .fallbackArkitLost
        } else {
            origin = .compass
        }
        return FaceAngleSource(radians: raw, origin: origin)
    }

    private func arkitYawAt(_ time: TimeInterval, in poses: [ARPose]) -> Double? {
        // Filter to .normal poses only — placeholder/.limited transforms (e.g.
        // identity-matrix fallbacks captured when ARKit had no real pose) would otherwise
        // be picked as "closest to impact time" and inject a yaw of 0 into the result.
        var bestYaw: Double?
        var bestDelta = Double.infinity
        for p in poses where p.trackingState.isNormal {
            let delta = abs(p.timestamp - time)
            if delta < bestDelta, let yaw = ARTrackingManager.yaw(from: p.transform) {
                bestDelta = delta
                bestYaw = yaw
            }
        }
        return bestYaw
    }
}
