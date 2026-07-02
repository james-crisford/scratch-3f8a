import Foundation
import simd

struct CalibrationProfile: Codable, Sendable, Equatable {
    /// Pipeline version this profile was learned under.
    /// 2 = B78/B79 press-attitude delta with the INVERTED sign (impact -
    /// press); 3 = B80 golf-sign convention (press - impact; negative =
    /// closed/pull/left) — `faceAngleBiasRad` learned under v2 means the
    /// OPPOSITE direction under v3, so loaders discard pre-v3 bias.
    /// 4 = S2 fix — speedToDistanceFactor objective re-derived against
    /// BallPhysics.simulatePutt (the law the AR ball actually rolls with).
    /// Pre-v4 factors inverted the legacy DistanceModel formula and
    /// under-deliver by ~2.6x through the live sim (b79: 10 ft target →
    /// 3.8 ft rolls), so loaders reset them to
    /// `defaultSpeedToDistanceFactor`; the user must recalibrate.
    static let currentPipelineVersion = 4

    /// Uncalibrated launch factor (B57-era hand-tuning against
    /// BallPhysics); also the reset value when migrating a pre-v4 profile.
    static let defaultSpeedToDistanceFactor: Double = 14.4

    let meanTempoSeconds: TimeInterval
    let speedToDistanceFactor: Double
    let faceAngleBiasRad: Double
    let swingPlaneAxis: SIMD3<Double>
    let arkitBaselineStability: Double
    let validStrokeCount: Int
    let targetDistanceFeet: Double
    let pipelineVersion: Int

    init(
        meanTempoSeconds: TimeInterval,
        speedToDistanceFactor: Double,
        faceAngleBiasRad: Double,
        swingPlaneAxis: SIMD3<Double>,
        arkitBaselineStability: Double,
        validStrokeCount: Int,
        targetDistanceFeet: Double,
        pipelineVersion: Int = CalibrationProfile.currentPipelineVersion
    ) {
        self.meanTempoSeconds = meanTempoSeconds
        self.speedToDistanceFactor = speedToDistanceFactor
        self.faceAngleBiasRad = faceAngleBiasRad
        self.swingPlaneAxis = swingPlaneAxis
        self.arkitBaselineStability = arkitBaselineStability
        self.validStrokeCount = validStrokeCount
        self.targetDistanceFeet = targetDistanceFeet
        self.pipelineVersion = pipelineVersion
    }

    /// Sanitize at the load boundary (B80 + S2 rules):
    /// - pre-v3 profiles: zero the face-angle bias (learned under the
    ///   inverted sign convention — a flipped-sign value in telemetry is
    ///   exactly how the b79 session misled log-only debugging).
    /// - pre-v4 profiles: reset speedToDistanceFactor to the default —
    ///   it was learned by inverting the legacy DistanceModel formula and
    ///   under-delivers ~2.6x through the live BallPhysics sim.
    var sanitizedForCurrentPipeline: CalibrationProfile {
        guard pipelineVersion < Self.currentPipelineVersion else { return self }
        return CalibrationProfile(
            meanTempoSeconds: meanTempoSeconds,
            speedToDistanceFactor: pipelineVersion < 4
                ? Self.defaultSpeedToDistanceFactor
                : speedToDistanceFactor,
            faceAngleBiasRad: pipelineVersion < 3 ? 0 : faceAngleBiasRad,
            swingPlaneAxis: swingPlaneAxis,
            arkitBaselineStability: arkitBaselineStability,
            validStrokeCount: validStrokeCount,
            targetDistanceFeet: targetDistanceFeet,
            pipelineVersion: pipelineVersion
        )
    }

    private enum CodingKeys: String, CodingKey {
        case meanTempoSeconds, speedToDistanceFactor, faceAngleBiasRad
        case swingPlaneAxisX, swingPlaneAxisY, swingPlaneAxisZ
        case arkitBaselineStability, validStrokeCount, targetDistanceFeet
        case pipelineVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meanTempoSeconds = try c.decode(TimeInterval.self, forKey: .meanTempoSeconds)
        speedToDistanceFactor = try c.decode(Double.self, forKey: .speedToDistanceFactor)
        faceAngleBiasRad = try c.decode(Double.self, forKey: .faceAngleBiasRad)
        let x = try c.decode(Double.self, forKey: .swingPlaneAxisX)
        let y = try c.decode(Double.self, forKey: .swingPlaneAxisY)
        let z = try c.decode(Double.self, forKey: .swingPlaneAxisZ)
        swingPlaneAxis = SIMD3<Double>(x, y, z)
        arkitBaselineStability = try c.decode(Double.self, forKey: .arkitBaselineStability)
        validStrokeCount = try c.decode(Int.self, forKey: .validStrokeCount)
        targetDistanceFeet = try c.decode(Double.self, forKey: .targetDistanceFeet)
        // Profiles persisted before B80 predate the field — they were
        // learned under the v2 (inverted-sign) pipeline.
        pipelineVersion = try c.decodeIfPresent(Int.self, forKey: .pipelineVersion) ?? 2
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(meanTempoSeconds, forKey: .meanTempoSeconds)
        try c.encode(speedToDistanceFactor, forKey: .speedToDistanceFactor)
        try c.encode(faceAngleBiasRad, forKey: .faceAngleBiasRad)
        try c.encode(swingPlaneAxis.x, forKey: .swingPlaneAxisX)
        try c.encode(swingPlaneAxis.y, forKey: .swingPlaneAxisY)
        try c.encode(swingPlaneAxis.z, forKey: .swingPlaneAxisZ)
        try c.encode(arkitBaselineStability, forKey: .arkitBaselineStability)
        try c.encode(validStrokeCount, forKey: .validStrokeCount)
        try c.encode(targetDistanceFeet, forKey: .targetDistanceFeet)
        try c.encode(pipelineVersion, forKey: .pipelineVersion)
    }
}
