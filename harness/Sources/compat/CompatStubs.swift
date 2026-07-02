import Foundation
import simd

// ARPose.yaw delegates to ARTrackingManager.yaw(from:), which lives in
// the ARKit-bound Sensors/ARTrackingManager.swift (excluded from this
// target). The math is pure; this mirror is verified against
// ARTrackingManager.swift:133-140 and must be kept in sync if that
// function ever changes.
#if !canImport(ARKit)
enum ARTrackingManager {
    static func yaw(from transform: simd_float4x4) -> Double? {
        let z = transform.columns.2
        let fx = -z.x
        let fz = -z.z
        guard fx.isFinite, fz.isFinite else { return nil }
        if fx == 0 && fz == 0 { return nil }
        return Double(atan2(-fx, -fz))
    }
}
#endif
