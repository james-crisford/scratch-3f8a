import Foundation
import simd

struct CalibrationProfile: Codable, Sendable, Equatable {
    /// B80 — face-angle pipeline version this profile was learned under.
    /// 2 = B78/B79 press-attitude delta with the INVERTED sign (impact -
    /// press); 3 = golf-sign convention (press - impact; negative = closed/
    /// pull/left). `faceAngleBiasRad` learned under v2 means the OPPOSITE
    /// direction under v3, so loaders must discard the bias of any profile
    /// older than `currentPipelineVersion` (speedToDistanceFactor is a
    /// magnitude — sign-agnostic — and survives the migration).
    static let currentPipelineVersion = 3

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

    /// B80 — self with the face-angle bias zeroed when it was learned under
    /// an older sign convention. The bias has no production consumer today
    /// (logging/manifests only), but a flipped-sign value in telemetry is
    /// exactly how the b79 session misled log-only debugging — sanitize at
    /// the load boundary.
    var sanitizedForCurrentPipeline: CalibrationProfile {
        guard pipelineVersion < Self.currentPipelineVersion else { return self }
        return CalibrationProfile(
            meanTempoSeconds: meanTempoSeconds,
            speedToDistanceFactor: speedToDistanceFactor,
            faceAngleBiasRad: 0,
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
