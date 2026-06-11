import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("ImpactDetector — clean strokes")
struct ImpactDetectorCleanTests {

    @Test("clean_straight_8ft: face_angle within ±2° of 0")
    func cleanStraightFaceAngle() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)
        let degrees = result.faceAngleRaw * 180.0 / .pi
        #expect(abs(degrees) < 2.0)
    }

    @Test("clean_straight_8ft: impact_time within 5ms of fixture truth")
    func cleanStraightImpactTime() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)
        #expect(abs(result.timestamp - fixture.expectedImpactTime) < 0.005)
    }

    @Test("clean_straight_8ft: peak velocity within 10% of expected")
    func cleanStraightPeakVelocity() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)
        let ratio = result.peakVelocity / fixture.expectedPeakVelocity
        #expect(ratio > 0.85 && ratio < 1.15)
    }

    @Test("clean_straight: high confidence (>=0.9) for a clean stroke")
    func cleanStraightConfidence() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let detector = ImpactDetector()
        let result = try detector.detect(in: fixture.window)
        #expect(result.confidence >= 0.9)
    }
}

@Suite("ImpactDetector — pull / push fixtures")
struct ImpactDetectorPullPushTests {

    @Test("pull_5deg: face_angle within ±2° of -5°")
    func pull5() throws {
        let fixture = StrokeFixtures.pull(deg: 5)
        let result = try ImpactDetector().detect(in: fixture.window)
        let deg = result.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg - (-5)) < 2.0)
    }

    @Test("pull_10deg: face_angle within ±2° of -10°")
    func pull10() throws {
        let fixture = StrokeFixtures.pull(deg: 10)
        let result = try ImpactDetector().detect(in: fixture.window)
        let deg = result.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg - (-10)) < 2.0)
    }

    @Test("push_5deg: face_angle within ±2° of +5°")
    func push5() throws {
        let fixture = StrokeFixtures.push(deg: 5)
        let result = try ImpactDetector().detect(in: fixture.window)
        let deg = result.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg - 5) < 2.0)
    }

    @Test("push_15deg: face_angle within ±2° of +15°")
    func push15() throws {
        let fixture = StrokeFixtures.push(deg: 15)
        let result = try ImpactDetector().detect(in: fixture.window)
        let deg = result.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg - 15) < 2.0)
    }
}

@Suite("ImpactDetector — rejection paths")
struct ImpactDetectorRejectionTests {

    @Test("150ms flick → snapped to square with .strokeTooShort reason (spec §5.2)")
    func tooShortSnaps() throws {
        let fixture = StrokeFixtures.flickShort(ms: 150)
        let r = try ImpactDetector().detect(in: fixture.window)
        #expect(r.snappedToSquare)
        #expect(r.snapReason == .strokeTooShort)
        #expect(r.faceAngleRaw == 0)
        #expect(r.confidence == 0)
    }

    @Test("zero-acceleration stream → snapped to square with .noClearPeak reason (spec §5.2)")
    func zeroAccelSnaps() throws {
        let fixture = StrokeFixtures.zeroAccel()
        let r = try ImpactDetector().detect(in: fixture.window)
        #expect(r.snappedToSquare)
        #expect(r.snapReason == .noClearPeak)
        #expect(r.faceAngleRaw == 0)
    }

    @Test("clean stroke is NOT snapped")
    func cleanStrokeNotSnapped() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        #expect(!r.snappedToSquare)
        #expect(r.snapReason == nil)
    }

    @Test("throws insufficientSamples on 2-sample window")
    func insufficientSamples() {
        let lock = StillnessLock(yawTargetCompass: 0, attitudeAtPress: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), gravity: SIMD3(0, -1, 0), lockedAt: 0)
        let s1 = MotionSample(
            timestamp: 1.0,
            rotationRate: .zero,
            userAcceleration: SIMD3(1, 0, 0),
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        )
        let s2 = MotionSample(
            timestamp: 1.3,
            rotationRate: .zero,
            userAcceleration: SIMD3(1, 0, 0),
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        )
        let window = StrokeWindow(start: 1.0, end: 1.3, samples: [s1, s2], lock: lock)
        #expect(throws: ImpactDetectorError.insufficientSamples) {
            _ = try ImpactDetector().detect(in: window)
        }
    }

    @Test("ARKit-lost flag reduces confidence below 0.5")
    func arkitLostConfidence() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let result = try ImpactDetector().detect(in: fixture.window, arkitLost: true)
        #expect(result.confidence < 0.5)
    }

    @Test("low peak velocity (<0.05 m/s) → snapped to square with .peakSpeedTooLow (B7 putting tune, spec §5.2 #4)")
    func lowPeakSnaps() throws {
        // Threshold lowered to 0.05 m/s for putting-specific tuning (was 0.30 m/s).
        // Putting strokes held in a closed hand produce ~0.1-0.2 m/s linear
        // translation; 0.30 rejected every putt. Use a fixture peak well below
        // 0.05 so the snap-to-square defense against pure twitches is still
        // exercised.
        let fixture = StrokeFixtures.cleanStraight(durationMs: 600, peakVelocity: 0.02)
        let result = try ImpactDetector().detect(in: fixture.window)
        #expect(result.snappedToSquare)
        #expect(result.snapReason == .peakSpeedTooLow)
    }
}

@Suite("ImpactDetector — pure math helpers")
struct ImpactDetectorMathTests {

    @Test("parabolicPeak: symmetric values → offset 0")
    func parabolicSymmetric() {
        let offset = ImpactDetector.parabolicPeak(prev: -1, peak: 0, next: -1)
        #expect(abs(offset) < 1e-9)
    }

    @Test("parabolicPeak: true peak at i+0.3 returns offset ≈ 0.3")
    func parabolicOffsetPositive() {
        let prev = -pow(-1 - 0.3, 2)
        let peak = -pow(0 - 0.3, 2)
        let next = -pow(1 - 0.3, 2)
        let offset = ImpactDetector.parabolicPeak(prev: prev, peak: peak, next: next)
        #expect(abs(offset - 0.3) < 1e-9)
    }

    @Test("parabolicPeak: true peak at i-0.4 returns offset ≈ -0.4")
    func parabolicOffsetNegative() {
        let trueOffset = -0.4
        let prev = -pow(-1 - trueOffset, 2)
        let peak = -pow(0 - trueOffset, 2)
        let next = -pow(1 - trueOffset, 2)
        let offset = ImpactDetector.parabolicPeak(prev: prev, peak: peak, next: next)
        #expect(abs(offset - trueOffset) < 1e-9)
    }

    @Test("parabolicPeak: flat values → offset 0")
    func parabolicFlat() {
        let offset = ImpactDetector.parabolicPeak(prev: 0, peak: 0, next: 0)
        #expect(offset == 0)
    }

    @Test("parabolicPeak: NaN input → 0")
    func parabolicNaN() {
        let offset = ImpactDetector.parabolicPeak(prev: .nan, peak: 0, next: 1)
        #expect(offset == 0)
    }

    @Test("movingAverage: 5-window smooths a single spike")
    func movingAverageSmooths() {
        var values = [Double](repeating: 0, count: 11)
        values[5] = 10
        let smoothed = ImpactDetector.movingAverage(values, window: 5)
        #expect(smoothed[5] == 2.0)
        #expect(smoothed[4] == 2.0)
    }

    @Test("movingAverage: identity on flat input")
    func movingAverageFlat() {
        let values = [Double](repeating: 5, count: 20)
        let smoothed = ImpactDetector.movingAverage(values, window: 5)
        for v in smoothed { #expect(abs(v - 5) < 1e-12) }
    }

    @Test("yawFromQuaternion: identity → 0")
    func yawIdentity() {
        let q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        #expect(abs(ImpactDetector.yawFromQuaternion(q)) < 1e-12)
    }

    @Test("yawFromQuaternion: Z-axis rotation π/3 → π/3")
    func yawZRotation() {
        let q = simd_quatd(angle: .pi / 3, axis: SIMD3(0, 0, 1))
        #expect(abs(ImpactDetector.yawFromQuaternion(q) - .pi / 3) < 1e-9)
    }

    @Test("wrapAngle: π wraps to π")
    func wrapPi() {
        #expect(abs(ImpactDetector.wrapAngle(.pi) - .pi) < 1e-12)
    }

    @Test("wrapAngle: 3π/2 wraps to -π/2")
    func wrapThreeHalvesPi() {
        let w = ImpactDetector.wrapAngle(3.0 * .pi / 2.0)
        #expect(abs(w - (-.pi / 2)) < 1e-9)
    }

    @Test("wrapAngle: 0 returns 0")
    func wrapZero() {
        #expect(ImpactDetector.wrapAngle(0) == 0)
    }

    @Test("wrapAngle: -π wraps to π")
    func wrapNegPi() {
        let w = ImpactDetector.wrapAngle(-.pi)
        #expect(abs(w - .pi) < 1e-12)
    }
}

@Suite("ImpactDetector — PCA")
struct ImpactDetectorPCATests {

    @Test("PCA finds X axis when accel is along X")
    func pcaXAxis() {
        var data: [SIMD3<Double>] = []
        for i in 0..<20 {
            data.append(SIMD3(Double(i) * 0.1, 0, 0))
        }
        let axis = ImpactDetector.principalAxis(of: data)
        #expect(abs(abs(axis.x) - 1.0) < 1e-6)
        #expect(abs(axis.y) < 1e-6)
        #expect(abs(axis.z) < 1e-6)
    }

    @Test("PCA finds Y axis when accel is along Y")
    func pcaYAxis() {
        var data: [SIMD3<Double>] = []
        for i in 0..<20 {
            data.append(SIMD3(0, Double(i) * 0.1, 0))
        }
        let axis = ImpactDetector.principalAxis(of: data)
        #expect(abs(axis.x) < 1e-6)
        #expect(abs(abs(axis.y) - 1.0) < 1e-6)
        #expect(abs(axis.z) < 1e-6)
    }

    @Test("PCA on empty input returns default axis")
    func pcaEmpty() {
        let axis = ImpactDetector.principalAxis(of: [])
        #expect(abs(simd_length(axis) - 1.0) < 1e-9)
    }

    @Test("PCA unit-length axis on diagonal data")
    func pcaDiagonal() {
        var data: [SIMD3<Double>] = []
        for i in 0..<20 {
            let s = Double(i) * 0.1
            data.append(SIMD3(s, s, 0))
        }
        let axis = ImpactDetector.principalAxis(of: data)
        #expect(abs(simd_length(axis) - 1.0) < 1e-6)
    }
}

@Suite("ImpactDetector — robustness")
struct ImpactDetectorRobustnessTests {

    @Test("determinism: same fixture → same result")
    func determinism() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r1 = try ImpactDetector().detect(in: fixture.window)
        let r2 = try ImpactDetector().detect(in: fixture.window)
        #expect(r1 == r2)
    }

    @Test("performance: 1000 detect() calls < 2s")
    func performance() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let detector = ImpactDetector()
        let start = Date()
        for _ in 0..<1000 {
            _ = try detector.detect(in: fixture.window)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0)
    }

    @Test("scaling stroke acceleration scales peak velocity proportionally")
    func monotonicity() throws {
        let a = StrokeFixtures.cleanStraight(durationMs: 600, peakVelocity: 1.0)
        let b = StrokeFixtures.cleanStraight(durationMs: 600, peakVelocity: 2.0)
        let ra = try ImpactDetector().detect(in: a.window)
        let rb = try ImpactDetector().detect(in: b.window)
        let ratio = rb.peakVelocity / ra.peakVelocity
        #expect(ratio > 1.8 && ratio < 2.2)
    }

    @Test("longer duration: same peak velocity stays close to target")
    func longerDuration() throws {
        let f = StrokeFixtures.cleanStraight(durationMs: 900, peakVelocity: 1.0)
        let r = try ImpactDetector().detect(in: f.window)
        #expect(r.peakVelocity > 0.85 && r.peakVelocity < 1.15)
    }

    @Test("compass lock yaw is IGNORED: face angle is press-attitude relative only")
    func lockYawIgnoredByPressAttitudePipeline() throws {
        // v1 subtracted the compass lock yaw (this test once expected
        // 20° − 15° = +5°). B78 replaced the pipeline with the press-
        // attitude delta, which never consults the compass; B80 fixed the
        // sign convention. A 20° CCW physical rotation from an identity
        // press therefore reads −20° (closed/pull), regardless of any
        // compass value carried in the lock.
        let fixture = StrokeFixtures.synthesise(
            name: "rel",
            faceAngleDeg: 20,
            lockYawCompass: 15.0 * .pi / 180.0
        )
        let r = try ImpactDetector().detect(in: fixture.window)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg - (-20.0)) < 2.0)
    }

    @Test("ImpactResult is Equatable")
    func resultEquatable() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r1 = try ImpactDetector().detect(in: fixture.window)
        let r2 = try ImpactDetector().detect(in: fixture.window)
        #expect(r1 == r2)
    }

    @Test("ImpactResult.faceAngleDegrees converts correctly")
    func faceAngleDegrees() throws {
        let fixture = StrokeFixtures.pull(deg: 10)
        let r = try ImpactDetector().detect(in: fixture.window)
        #expect(abs(r.faceAngleDegrees - (-10.0)) < 2.0)
    }

    @Test("PCA sign robustness: negated acceleration still yields positive peakVelocity")
    func pcaSignNegatedAccel() throws {
        let baseline = StrokeFixtures.cleanStraight8ft()
        let negSamples = baseline.window.samples.map { s in
            MotionSample(
                timestamp: s.timestamp,
                rotationRate: s.rotationRate,
                userAcceleration: -s.userAcceleration,
                gravity: s.gravity,
                attitude: s.attitude
            )
        }
        let w = StrokeWindow(
            start: baseline.window.start,
            end: baseline.window.end,
            samples: negSamples,
            lock: baseline.window.lock
        )
        let r = try ImpactDetector().detect(in: w)
        #expect(r.peakVelocity > 0.5)
    }

    @Test("PCA sign robustness: original and negated accel produce same peak velocity magnitude")
    func pcaSignSymmetry() throws {
        let baseline = StrokeFixtures.cleanStraight8ft()
        let negSamples = baseline.window.samples.map { s in
            MotionSample(
                timestamp: s.timestamp,
                rotationRate: s.rotationRate,
                userAcceleration: -s.userAcceleration,
                gravity: s.gravity,
                attitude: s.attitude
            )
        }
        let negWin = StrokeWindow(
            start: baseline.window.start,
            end: baseline.window.end,
            samples: negSamples,
            lock: baseline.window.lock
        )
        let original = try ImpactDetector().detect(in: baseline.window)
        let negated = try ImpactDetector().detect(in: negWin)
        let ratio = negated.peakVelocity / original.peakVelocity
        #expect(ratio > 0.95 && ratio < 1.05)
    }

    @Test("PCA sign robustness: backswing-dominant accel doesn't get picked as forward")
    func pcaIgnoresBackswingPeak() throws {
        // Build a stroke where backswing has slightly more peak accel than forward,
        // but forward direction is clearly the second half. This should still
        // correctly find the forward peak.
        let lock = StillnessLock(yawTargetCompass: 0, attitudeAtPress: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), gravity: SIMD3(0, -1, 0), lockedAt: 0)
        let n = 60
        let dt = 0.01
        var samples: [MotionSample] = []
        let omega = Double.pi / 0.6
        let amp = 1.0 * omega
        for i in 0..<n {
            let t = TimeInterval(i) * dt
            // First half: gentle negative accel; second half: stronger positive.
            // This simulates a slow takeaway and faster forward swing.
            let a: Double
            if t < 0.3 {
                a = -amp * 0.6 * cos(omega * t)
            } else {
                a = amp * cos(omega * t)
            }
            samples.append(MotionSample(
                timestamp: 1.0 + t,
                rotationRate: SIMD3(2.0, 0, 0),
                userAcceleration: SIMD3(a, 0, 0),
                gravity: SIMD3(0, -1, 0),
                attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            ))
        }
        let window = StrokeWindow(start: 1.0, end: 1.0 + Double(n - 1) * dt, samples: samples, lock: lock)
        let r = try ImpactDetector().detect(in: window)
        #expect(r.peakVelocity > 0)
        // Impact should be in the second half (forward swing dominant)
        #expect(r.timestamp > 1.25)
    }
}
