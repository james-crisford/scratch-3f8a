import Foundation

struct DistanceResult: Sendable, Equatable {
    let displayedFeet: Double
    let lowFeet: Double
    let highFeet: Double
    let ballSpeedFps: Double
    let rawFeet: Double
    let isSuppressed: Bool

    init(
        displayedFeet: Double,
        lowFeet: Double,
        highFeet: Double,
        ballSpeedFps: Double,
        rawFeet: Double,
        isSuppressed: Bool = false
    ) {
        self.displayedFeet = displayedFeet
        self.lowFeet = lowFeet
        self.highFeet = highFeet
        self.ballSpeedFps = ballSpeedFps
        self.rawFeet = rawFeet
        self.isSuppressed = isSuppressed
    }
}

/// Empirical putt-roll model from Marquardt 2007 / Holmes 1991 / Pelz: distance scales
/// as ball_speed² × Stimp / decelerationConstant. Stimp 10 ≈ medium residential green.
/// Friction constant 19.7 ft/s² is derived from Holmes' empirical capture-speed work.
/// See research_archive/puttinglab-putt-roll-physics-2026-05-29.md for sources.
final class DistanceModel: Sendable {
    static let decelerationConstant: Double = 19.7
    static let defaultStimp: Double = 10.0
    static let mpsToFps: Double = 3.281
    static let bandFactor: Double = 0.15
    static let jitterAmplitude: Double = 0.05

    let speedCalibrationFactor: Double
    let stimp: Double
    let jitterFraction: Double

    init(
        speedCalibrationFactor: Double = 1.0,
        stimp: Double = DistanceModel.defaultStimp,
        jitterFraction: Double = 0.0
    ) {
        self.speedCalibrationFactor = speedCalibrationFactor
        self.stimp = max(1.0, stimp)
        self.jitterFraction = max(-1.0, min(1.0, jitterFraction))
    }

    func compute(peakSpeedMps: Double) -> DistanceResult {
        let safeSpeed = max(0, peakSpeedMps)
        let fps = safeSpeed * speedCalibrationFactor * Self.mpsToFps
        let raw = (fps * fps) * stimp / Self.decelerationConstant
        let jitter = jitterFraction * Self.jitterAmplitude
        let displayed = raw * (1.0 + jitter)
        let suppressed = safeSpeed < 0.05  // snap-to-square or no-meaningful-velocity result
        return DistanceResult(
            displayedFeet: displayed,
            lowFeet: displayed * (1.0 - Self.bandFactor),
            highFeet: displayed * (1.0 + Self.bandFactor),
            ballSpeedFps: fps,
            rawFeet: raw,
            isSuppressed: suppressed
        )
    }
}
