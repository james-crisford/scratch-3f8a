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
        if meanPeakVel > 1e-9,
           meanPeakVel <= BallPhysics.maxPlausiblePeakVelocity,
           targetDistanceFeet > 0 {
            factor = Self.factorDelivering(
                targetMetres: targetDistanceFeet * Self.metresPerFoot,
                meanPeakVelocity: meanPeakVel,
                stimpFeet: BallPhysics.defaultStimp
            )
        } else {
            // Degenerate mean (zero, or spike-contaminated beyond the
            // physics gate where every sim call returns .rejected and the
            // bisection would pin to its upper bound): fall back to the
            // uncalibrated default rather than persisting garbage.
            factor = CalibrationProfile.defaultSpeedToDistanceFactor
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

    static let metresPerFoot = 0.3048

    /// S2 fix (pipeline v4): the calibration factor must invert the SAME
    /// law the live AR ball rolls with — `BallPhysics.simulatePutt` — not
    /// the legacy `DistanceModel` formula, whose quadratic law delivered
    /// only ~38% of the calibration target through the real sim (the
    /// b79 session: 10 ft target → 3.8 ft rolls with factor 14.18).
    /// Bisection over the simulator itself keeps this exact by
    /// construction under any future BallPhysics change (friction law,
    /// integration step, launch chain). Monotonic: roll distance strictly
    /// increases with factor. 60 iterations narrows [0.01, 500] to ~1e-9
    /// relative — one-time cost at calibration completion.
    static func factorDelivering(
        targetMetres: Double,
        meanPeakVelocity: Double,
        stimpFeet: Double
    ) -> Double {
        let loBound = 0.01
        let hiBound = 500.0
        var lo = loBound
        var hi = hiBound
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            let rolled = BallPhysics.simulatePutt(
                peakVelocity: meanPeakVelocity,
                faceAngleRaw: 0,
                speedCalibration: mid,
                stimpFeet: stimpFeet,
                cupPosition: SIMD2<Double>(1e9, 0)
            ).endPosition.x
            if rolled < targetMetres {
                lo = mid
            } else {
                hi = mid
            }
        }
        let result = (lo + hi) / 2
        // A result pinned to the ORIGINAL search bounds means the true
        // factor lies outside [loBound, hiBound] — e.g. every sim call
        // returned .rejected (spike-gated input) so distance was 0 for
        // all 60 iterations and lo marched to the top. A pinned bound is
        // never a usable factor (500 turns a normal 0.15 putt into a
        // 65 m/s launch); return the safe default instead of crashing
        // (debug assert) or persisting garbage (release).
        guard result > loBound * 1.01, result < hiBound * 0.99 else {
            return CalibrationProfile.defaultSpeedToDistanceFactor
        }
        return result
    }
}
