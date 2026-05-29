import Foundation
import simd

struct ImpactResult: Sendable, Equatable {
    let timestamp: TimeInterval
    let peakVelocity: Double
    let faceAngleRaw: Double
    let attitudeAtImpact: simd_quatd
    let confidence: Double

    var faceAngleDegrees: Double {
        faceAngleRaw * 180.0 / .pi
    }
}

enum ImpactDetectorError: Error, Equatable {
    case strokeTooShort
    case noClearPeak
    case emptyStream
    case insufficientSamples
}
