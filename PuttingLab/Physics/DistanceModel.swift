import Foundation

struct DistanceResult: Sendable, Equatable {
    let displayedFeet: Double
    let lowFeet: Double
    let highFeet: Double
    let ballSpeedFps: Double
    let rawFeet: Double
}

final class DistanceModel: Sendable {
    static let frictionConstant: Double = 1.7
    static let mpsToFps: Double = 3.281
    static let bandFactor: Double = 0.15
    static let jitterAmplitude: Double = 0.05

    let speedCalibrationFactor: Double
    let jitterFraction: Double

    init(speedCalibrationFactor: Double = 1.0, jitterFraction: Double = 0.0) {
        self.speedCalibrationFactor = speedCalibrationFactor
        self.jitterFraction = max(-1.0, min(1.0, jitterFraction))
    }

    func compute(peakSpeedMps: Double) -> DistanceResult {
        let safeSpeed = max(0, peakSpeedMps)
        let fps = safeSpeed * speedCalibrationFactor * Self.mpsToFps
        let raw = pow(fps, 1.6) / Self.frictionConstant
        let jitter = jitterFraction * Self.jitterAmplitude
        let displayed = raw * (1.0 + jitter)
        return DistanceResult(
            displayedFeet: displayed,
            lowFeet: displayed * (1.0 - Self.bandFactor),
            highFeet: displayed * (1.0 + Self.bandFactor),
            ballSpeedFps: fps,
            rawFeet: raw
        )
    }
}
