import Foundation
import ARKit

enum ARTrackingState: Sendable, Equatable {
    case notAvailable
    case limited(ARTrackingLimitReason)
    case normal

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .notAvailable:
            self = .notAvailable
        case .limited(let reason):
            self = .limited(ARTrackingLimitReason(reason))
        case .normal:
            self = .normal
        }
    }

    var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }
}

enum ARTrackingLimitReason: Sendable, Equatable {
    case initializing
    case excessiveMotion
    case insufficientFeatures
    case relocalizing
    case unknown

    init(_ reason: ARCamera.TrackingState.Reason) {
        switch reason {
        case .initializing: self = .initializing
        case .excessiveMotion: self = .excessiveMotion
        case .insufficientFeatures: self = .insufficientFeatures
        case .relocalizing: self = .relocalizing
        @unknown default: self = .unknown
        }
    }
}
