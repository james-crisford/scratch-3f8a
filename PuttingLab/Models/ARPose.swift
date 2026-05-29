import Foundation
import simd

struct ARPose: Sendable, Equatable {
    let timestamp: TimeInterval
    let transform: simd_float4x4
    let trackingState: ARTrackingState

    var yaw: Double? {
        ARTrackingManager.yaw(from: transform)
    }
}
