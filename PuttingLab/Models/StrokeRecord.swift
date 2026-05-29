import Foundation

struct StrokeRecord: Codable, Sendable, Equatable {
    let recordedAt: Date
    let impactTimestamp: TimeInterval
    let peakVelocity: Double
    let faceAngleRaw: Double
    let confidence: Double
    let distanceFeet: Double
    let strokeDurationSeconds: TimeInterval
    let directionBucket: DirectionBucket

    init(
        recordedAt: Date,
        impact: ImpactResult,
        strokeDurationSeconds: TimeInterval,
        distance: DistanceResult,
        direction: DirectionResult
    ) {
        self.recordedAt = recordedAt
        self.impactTimestamp = impact.timestamp
        self.peakVelocity = impact.peakVelocity
        self.faceAngleRaw = impact.faceAngleRaw
        self.confidence = impact.confidence
        self.distanceFeet = distance.displayedFeet
        self.strokeDurationSeconds = strokeDurationSeconds
        self.directionBucket = direction.bucket
    }

    init(
        recordedAt: Date,
        impactTimestamp: TimeInterval,
        peakVelocity: Double,
        faceAngleRaw: Double,
        confidence: Double,
        distanceFeet: Double,
        strokeDurationSeconds: TimeInterval,
        directionBucket: DirectionBucket
    ) {
        self.recordedAt = recordedAt
        self.impactTimestamp = impactTimestamp
        self.peakVelocity = peakVelocity
        self.faceAngleRaw = faceAngleRaw
        self.confidence = confidence
        self.distanceFeet = distanceFeet
        self.strokeDurationSeconds = strokeDurationSeconds
        self.directionBucket = directionBucket
    }
}
