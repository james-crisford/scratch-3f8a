import Foundation
import simd

struct CalibrationInput: Sendable {
    let window: StrokeWindow
    let impact: ImpactResult
}

enum CalibrationModel {

    static func compute(
        from inputs: [CalibrationInput],
        targetDistanceFeet: Double
    ) -> CalibrationProfile {
        let count = Double(inputs.count)
        let countSafe = max(count, 1.0)

        let meanTempo = inputs.reduce(0.0) { $0 + $1.window.duration } / countSafe
        let meanFaceAngle = inputs.reduce(0.0) { $0 + $1.impact.faceAngleRaw } / countSafe
        let meanPeakVel = inputs.reduce(0.0) { $0 + $1.impact.peakVelocity } / countSafe

        let factor: Double
        if meanPeakVel > 1e-9, targetDistanceFeet > 0 {
            let requiredFps = sqrt(targetDistanceFeet * DistanceModel.decelerationConstant / DistanceModel.defaultStimp)
            factor = requiredFps / (meanPeakVel * DistanceModel.mpsToFps)
        } else {
            factor = 1.0
        }

        var axisSum = SIMD3<Double>.zero
        for r in inputs {
            let accels = r.window.samples.map { $0.userAcceleration }
            axisSum += ImpactDetector.principalAxis(of: accels)
        }
        let swingAxis: SIMD3<Double>
        let axisLen = simd_length(axisSum)
        swingAxis = axisLen > 1e-9 ? axisSum / axisLen : SIMD3(1, 0, 0)

        var stddevSq = 0.0
        for r in inputs {
            let d = r.impact.faceAngleRaw - meanFaceAngle
            stddevSq += d * d
        }
        let stddev = inputs.count > 1 ? sqrt(stddevSq / countSafe) : 0.0
        let stability = 1.0 / (1.0 + stddev * 10.0)

        return CalibrationProfile(
            meanTempoSeconds: meanTempo,
            speedToDistanceFactor: factor,
            faceAngleBiasRad: meanFaceAngle,
            swingPlaneAxis: swingAxis,
            arkitBaselineStability: stability,
            validStrokeCount: inputs.count,
            targetDistanceFeet: targetDistanceFeet
        )
    }

    static func applyBias(_ faceAngleRaw: Double, profile: CalibrationProfile) -> Double {
        ImpactDetector.wrapAngle(faceAngleRaw - profile.faceAngleBiasRad)
    }
}
