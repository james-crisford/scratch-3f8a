import Foundation
import simd

enum SnapReason: String, Sendable, Equatable, Codable {
    case strokeTooShort
    case noClearPeak
    case arkitLost
    case peakSpeedTooLow
}

struct ImpactResult: Sendable, Equatable {
    let timestamp: TimeInterval
    let peakVelocity: Double
    let faceAngleRaw: Double
    let attitudeAtImpact: simd_quatd
    let confidence: Double
    let snappedToSquare: Bool
    let snapReason: SnapReason?

    init(
        timestamp: TimeInterval,
        peakVelocity: Double,
        faceAngleRaw: Double,
        attitudeAtImpact: simd_quatd,
        confidence: Double,
        snappedToSquare: Bool = false,
        snapReason: SnapReason? = nil
    ) {
        self.timestamp = timestamp
        self.peakVelocity = peakVelocity
        self.faceAngleRaw = faceAngleRaw
        self.attitudeAtImpact = attitudeAtImpact
        self.confidence = confidence
        self.snappedToSquare = snappedToSquare
        self.snapReason = snapReason
    }

    var faceAngleDegrees: Double {
        faceAngleRaw * 180.0 / .pi
    }
}

enum ImpactDetectorError: Error, Equatable {
    case insufficientSamples
    case emptyStream
}
