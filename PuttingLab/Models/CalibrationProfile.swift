import Foundation
import simd

struct CalibrationProfile: Codable, Sendable, Equatable {
    let meanTempoSeconds: TimeInterval
    let speedToDistanceFactor: Double
    let faceAngleBiasRad: Double
    let swingPlaneAxis: SIMD3<Double>
    let arkitBaselineStability: Double
    let validStrokeCount: Int
    let targetDistanceFeet: Double

    init(
        meanTempoSeconds: TimeInterval,
        speedToDistanceFactor: Double,
        faceAngleBiasRad: Double,
        swingPlaneAxis: SIMD3<Double>,
        arkitBaselineStability: Double,
        validStrokeCount: Int,
        targetDistanceFeet: Double
    ) {
        self.meanTempoSeconds = meanTempoSeconds
        self.speedToDistanceFactor = speedToDistanceFactor
        self.faceAngleBiasRad = faceAngleBiasRad
        self.swingPlaneAxis = swingPlaneAxis
        self.arkitBaselineStability = arkitBaselineStability
        self.validStrokeCount = validStrokeCount
        self.targetDistanceFeet = targetDistanceFeet
    }

    private enum CodingKeys: String, CodingKey {
        case meanTempoSeconds, speedToDistanceFactor, faceAngleBiasRad
        case swingPlaneAxisX, swingPlaneAxisY, swingPlaneAxisZ
        case arkitBaselineStability, validStrokeCount, targetDistanceFeet
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
    }
}
