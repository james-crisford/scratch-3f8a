import Foundation
import simd

final class ImpactDetector: Sendable {
    static let nominalDt: TimeInterval = 0.01
    static let minStrokeDurationSeconds: TimeInterval = 0.200
    static let minPeakVelocityMps: Double = 0.3
    static let smoothingWindow: Int = 5
    static let fpTolerance: TimeInterval = 1e-6

    let faceAngleComputer: FaceAngleComputer

    init(faceAngleComputer: FaceAngleComputer = FaceAngleComputer()) {
        self.faceAngleComputer = faceAngleComputer
    }

    func detect(
        in window: StrokeWindow,
        arkitLost: Bool = false,
        arkitPoses: [ARPose] = [],
        arkitBaselineYaw: Double? = nil
    ) throws -> ImpactResult {
        let samples = window.samples
        guard samples.count >= 3 else {
            throw ImpactDetectorError.insufficientSamples
        }
        guard window.duration + Self.fpTolerance >= Self.minStrokeDurationSeconds else {
            return Self.snappedToSquare(
                window: window,
                reason: .strokeTooShort
            )
        }

        let dt = inferDt(samples: samples)
        let accels = samples.map { $0.userAcceleration }
        let forward = Self.principalAxis(of: accels)
        let projected = accels.map { simd_dot($0, forward) }

        var velocity = [Double](repeating: 0, count: projected.count)
        for i in 1..<projected.count {
            velocity[i] = velocity[i - 1] + 0.5 * (projected[i - 1] + projected[i]) * dt
        }
        if velocity.count > 1, let endV = velocity.last {
            let n = velocity.count
            for i in 0..<n {
                velocity[i] -= endV * Double(i) / Double(n - 1)
            }
        }

        var smoothed = Self.movingAverage(velocity, window: Self.smoothingWindow)

        // Sign-agnostic peak detection: find both extrema and choose the forward direction.
        // The PCA axis sign is ambiguous (covariance is invariant under negation), and a stroke's
        // mean acceleration ≈ 0 makes mean-based sign-correction unreliable. Instead, pick the
        // dominant velocity extremum; if it's negative, flip the velocity array so the impact
        // peak is positive.
        // Restrict search to the smoothing-window interior: movingAverage leaves the first/last
        // (window/2) samples unsmoothed, so they retain raw transients that could dominate.
        let half = Self.smoothingWindow / 2
        let searchLow = min(half, smoothed.count - 1)
        let searchHigh = max(smoothed.count - half, searchLow + 1)
        var maxV = -Double.infinity
        var maxIdx = searchLow
        var minV = Double.infinity
        var minIdx = searchLow
        for i in searchLow..<searchHigh {
            let v = smoothed[i]
            guard v.isFinite else { continue }
            if v > maxV { maxV = v; maxIdx = i }
            if v < minV { minV = v; minIdx = i }
        }
        guard maxV.isFinite, minV.isFinite else {
            return Self.snappedToSquare(window: window, reason: .noClearPeak)
        }

        // Pick later extremum (impact happens after backswing peak in a real putting stroke).
        // Magnitude-ratio tiebreak only kicks in when one extremum dominates by >2× — useful
        // for fully clamped data where the order may be flipped by noise.
        let useMax: Bool
        if abs(maxV) > abs(minV) * 2.0 {
            useMax = true
        } else if abs(minV) > abs(maxV) * 2.0 {
            useMax = false
        } else {
            useMax = maxIdx > minIdx
        }

        var peakIdx: Int
        var peakValue: Double
        if useMax {
            peakIdx = maxIdx
            peakValue = maxV
        } else {
            smoothed = smoothed.map { -$0 }
            peakIdx = minIdx
            peakValue = -minV
        }

        guard
            peakIdx > 0,
            peakIdx < smoothed.count - 1,
            peakValue > 1e-9
        else {
            return Self.snappedToSquare(window: window, reason: .noClearPeak)
        }

        let offset = Self.parabolicPeak(
            prev: smoothed[peakIdx - 1],
            peak: smoothed[peakIdx],
            next: smoothed[peakIdx + 1]
        )
        let impactTime = samples[peakIdx].timestamp + offset * dt

        let attitude: simd_quatd
        if offset >= 0 {
            let nextIdx = min(peakIdx + 1, samples.count - 1)
            attitude = simd_slerp(samples[peakIdx].attitude, samples[nextIdx].attitude, offset)
        } else {
            let prevIdx = max(peakIdx - 1, 0)
            attitude = simd_slerp(samples[peakIdx].attitude, samples[prevIdx].attitude, -offset)
        }

        let face = faceAngleComputer.compute(
            window: window,
            attitudeAtImpact: attitude,
            impactTime: impactTime,
            arkitPoses: arkitPoses,
            arkitBaselineYaw: arkitBaselineYaw
        )
        let faceAngleRaw = face.radians

        // Spec §5.2 condition 4 + Wii Sports rule #1: peak speed below the meaningful
        // putting envelope MUST snap to square — a "soft tap" is unreadable, not just low
        // confidence. Previously this was only a confidence multiplier which let the result
        // through as a confident-but-tiny reading.
        if peakValue < Self.minPeakVelocityMps {
            return Self.snappedToSquare(window: window, reason: .peakSpeedTooLow)
        }

        var confidence = 1.0
        if arkitLost { confidence *= 0.4 }
        if window.duration < 0.250 { confidence *= 0.7 }

        return ImpactResult(
            timestamp: impactTime,
            peakVelocity: peakValue,
            faceAngleRaw: faceAngleRaw,
            attitudeAtImpact: attitude,
            confidence: confidence
        )
    }

    private func inferDt(samples: [MotionSample]) -> TimeInterval {
        guard samples.count >= 2 else { return Self.nominalDt }
        let span = samples.last!.timestamp - samples.first!.timestamp
        let dt = span / Double(samples.count - 1)
        guard dt > 0, dt.isFinite else { return Self.nominalDt }
        return dt
    }

    static func principalAxis(of accelerations: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !accelerations.isEmpty else { return SIMD3(1, 0, 0) }
        var mean = SIMD3<Double>.zero
        for a in accelerations { mean += a }
        mean /= Double(accelerations.count)

        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for a in accelerations {
            let d = a - mean
            for i in 0..<3 {
                for j in 0..<3 {
                    cov[i][j] += d[i] * d[j]
                }
            }
        }

        var totalCov = 0.0
        for i in 0..<3 {
            for j in 0..<3 { totalCov += abs(cov[i][j]) }
        }
        if totalCov < 1e-12 { return SIMD3(1, 0, 0) }

        var v = simd_normalize(SIMD3<Double>(1, 1, 1))
        for _ in 0..<30 {
            let next = SIMD3<Double>(
                cov[0][0] * v.x + cov[0][1] * v.y + cov[0][2] * v.z,
                cov[1][0] * v.x + cov[1][1] * v.y + cov[1][2] * v.z,
                cov[2][0] * v.x + cov[2][1] * v.y + cov[2][2] * v.z
            )
            let len = simd_length(next)
            if len < 1e-12 { return SIMD3(1, 0, 0) }
            v = next / len
        }

        if simd_dot(v, mean) < 0 { v = -v }
        return v
    }

    static func parabolicPeak(prev: Double, peak: Double, next: Double) -> Double {
        let denom = prev - 2.0 * peak + next
        guard abs(denom) > 1e-12, denom.isFinite else { return 0 }
        let offset = 0.5 * (prev - next) / denom
        return max(-1.0, min(1.0, offset))
    }

    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 0, values.count >= window else { return values }
        let half = window / 2
        var result = values
        for i in half..<(values.count - half) {
            var sum = 0.0
            for j in (i - half)...(i + half) { sum += values[j] }
            result[i] = sum / Double(window)
        }
        return result
    }

    static func yawFromQuaternion(_ q: simd_quatd) -> Double {
        let w = q.real
        let x = q.imag.x
        let y = q.imag.y
        let z = q.imag.z
        return atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))
    }

    static func snappedToSquare(window: StrokeWindow, reason: SnapReason) -> ImpactResult {
        let midpoint = window.start + (window.end - window.start) / 2.0
        return ImpactResult(
            timestamp: midpoint,
            peakVelocity: 0,
            faceAngleRaw: 0,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            confidence: 0,
            snappedToSquare: true,
            snapReason: reason
        )
    }

    static func wrapAngle(_ angle: Double) -> Double {
        var a = angle
        while a > .pi { a -= 2.0 * .pi }
        while a <= -.pi { a += 2.0 * .pi }
        return a
    }
}
